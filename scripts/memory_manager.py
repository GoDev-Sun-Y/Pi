"""
Pi 记忆管理系统 - Qdrant 客户端

向量由本地 Ollama 生成（免费），Qdrant 负责存储与检索。

使用方法:
    from memory_manager import MemoryManager
    mm = MemoryManager()
    mm.init_collections()
    mm.add_memory("memory_rules", "规则内容")
    results = mm.search_memory("memory_rules", "搜索关键词")

命令行:
    python memory_manager.py init
    python memory_manager.py add <集合> <内容>
    python memory_manager.py search <集合> <查询>
    python memory_manager.py stats
    python memory_manager.py list
    python memory_manager.py delete <集合> <point_id>

配置来源（优先级从高到低）:
    1. 构造函数参数 / 命令行参数
    2. 环境变量 QDRANT_URL / OLLAMA_URL / PI_EMBEDDING_MODEL / PI_EMBEDDING_DIM
    3. ~/.pi/agent/settings.json 的 pi.config 节点
    4. 内置默认值

注意: 依赖 qdrant-client >= 1.12（旧版 client.search 已移除，本脚本使用 query_points）。
"""

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any

try:
    from qdrant_client import QdrantClient
    from qdrant_client.models import Distance, HnswConfigDiff, PointStruct, VectorParams
except ImportError:
    print("请安装 qdrant-client: pip install qdrant-client")
    QdrantClient = None


DEFAULT_COLLECTIONS = ["memory_rules", "daily_logs", "session_log", "novel_chapters"]
DEFAULT_EMBEDDING_MODEL = "all-minilm:33m"
DEFAULT_EMBEDDING_DIM = 384


def _load_settings_config() -> dict[str, Any]:
    """读取 ~/.pi/agent/settings.json 的 pi.config 节点，读不到就返回空字典。"""
    path = Path(os.path.expanduser("~")) / ".pi" / "agent" / "settings.json"
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    conf = data.get("pi", {}).get("config", {})
    return conf if isinstance(conf, dict) else {}


class MemoryManager:
    """Qdrant 记忆管理器。"""

    def __init__(
        self,
        url: str | None = None,
        collection: str = "default",
        model: str | None = None,
        dim: int | None = None,
        client: Any = None,
    ) -> None:
        if QdrantClient is None and client is None:
            raise ImportError("qdrant-client 未安装")

        conf = _load_settings_config()

        self.url = url or os.environ.get("QDRANT_URL") or conf.get("qdrantUrl") or "http://localhost:6333"
        self.ollama_url = os.environ.get("OLLAMA_URL") or "http://localhost:11434"

        model = model or os.environ.get("PI_EMBEDDING_MODEL") or conf.get("embeddingModel") or DEFAULT_EMBEDDING_MODEL
        self.embedding_model = DEFAULT_EMBEDDING_MODEL if model == "placeholder" else model

        raw_dim = dim or os.environ.get("PI_EMBEDDING_DIM") or conf.get("embeddingDim") or DEFAULT_EMBEDDING_DIM
        try:
            self.embedding_dim = int(raw_dim)
        except (TypeError, ValueError):
            self.embedding_dim = DEFAULT_EMBEDDING_DIM

        self.default_collection = collection
        self.allow_hash_fallback = os.environ.get("PI_ALLOW_HASH_EMBEDDING") == "1"
        self.client = client if client is not None else QdrantClient(url=self.url)

    # ------------------------------------------------------------------
    # 集合管理
    # ------------------------------------------------------------------
    def init_collections(self) -> None:
        """初始化所有必需的集合，已存在的跳过。"""
        for name in DEFAULT_COLLECTIONS:
            try:
                info = self.client.get_collection(collection_name=name)
            except Exception:
                self._create_collection(name)
                print(f"  {name}: 已创建（维度 {self.embedding_dim}）")
                continue

            existing = self._collection_dim(info)
            if existing and existing != self.embedding_dim:
                print(
                    f"  {name}: 已存在，但维度为 {existing}，与配置的 {self.embedding_dim} 不一致。"
                    f"请调整 embeddingModel/PI_EMBEDDING_DIM，或重建该集合。",
                    file=sys.stderr,
                )
            else:
                print(f"  {name}: 已存在")

    def _create_collection(self, name: str) -> None:
        self.client.create_collection(
            collection_name=name,
            vectors_config=VectorParams(size=self.embedding_dim, distance=Distance.COSINE),
            hnsw_config=HnswConfigDiff(m=16, ef_construct=100),
        )

    @staticmethod
    def _collection_dim(info: Any) -> int | None:
        vectors = getattr(info.config.params, "vectors", None)
        return getattr(vectors, "size", None) if vectors is not None else None

    def list_collections(self) -> list[str]:
        return [c.name for c in self.client.get_collections().collections]

    def show_stats(self) -> dict[str, int]:
        stats: dict[str, int] = {}
        for col in self.list_collections():
            try:
                stats[col] = self.client.get_collection(col).points_count or 0
            except Exception:
                stats[col] = 0
        return stats

    # ------------------------------------------------------------------
    # 记忆读写
    # ------------------------------------------------------------------
    def add_memory(
        self, collection: str, content: str, metadata: dict[str, Any] | None = None
    ) -> str:
        """写入一条记忆，返回 point_id。相同内容会覆盖同一条记录。"""
        point_id = str(uuid.UUID(hashlib.md5(content.encode("utf-8")).hexdigest()))
        vector = self._embed(content)
        payload = {"content": content, "type": "memory", **(metadata or {})}
        self.client.upsert(
            collection_name=collection,
            points=[PointStruct(id=point_id, vector=vector, payload=payload)],
        )
        return point_id

    def search_memory(
        self,
        collection: str,
        query: str,
        limit: int = 5,
        score_threshold: float | None = None,
    ) -> list[dict[str, Any]]:
        """语义搜索。score 越高越相似（余弦相似度）。"""
        query_vector = self._embed(query)
        response = self.client.query_points(
            collection_name=collection,
            query=query_vector,
            limit=limit,
            score_threshold=score_threshold,
        )
        return [
            {
                "id": str(hit.id),
                "score": hit.score,
                "content": (hit.payload or {}).get("content"),
                "metadata": {k: v for k, v in (hit.payload or {}).items() if k != "content"},
            }
            for hit in response.points
        ]

    def delete_memory(self, collection: str, point_id: str) -> bool:
        try:
            self.client.delete(collection_name=collection, points_selector=[point_id])
            return True
        except Exception:
            return False

    # ------------------------------------------------------------------
    # Embedding
    # ------------------------------------------------------------------
    def _embed(self, text: str) -> list[float]:
        vector = self._embed_ollama(text)
        if vector is not None:
            return vector
        if self.allow_hash_fallback:
            print(
                "[警告] Ollama 不可用，改用哈希占位向量 —— 该向量不具备语义区分能力，"
                "搜索结果无参考价值。",
                file=sys.stderr,
            )
            return self._hash_vector(text)
        raise RuntimeError(
            f"无法从 Ollama({self.ollama_url}) 获取 embedding。\n"
            f"  1. 确认 Ollama 已启动: ollama serve\n"
            f"  2. 确认模型已拉取:   ollama pull {self.embedding_model}\n"
            f"  3. 如需强制使用占位向量(: 不推荐)，设置环境变量 PI_ALLOW_HASH_EMBEDDING=1"
        )

    def _embed_ollama(self, text: str) -> list[float] | None:
        """调用 Ollama 生成向量。先试新版 /api/embed，再回落旧版 /api/embeddings。"""
        for endpoint, payload in (
            ("/api/embed", {"model": self.embedding_model, "input": text}),
            ("/api/embeddings", {"model": self.embedding_model, "prompt": text}),
        ):
            try:
                request = urllib.request.Request(
                    f"{self.ollama_url}{endpoint}",
                    data=json.dumps(payload).encode("utf-8"),
                    headers={"Content-Type": "application/json"},
                )
                with urllib.request.urlopen(request, timeout=30) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except Exception:
                continue

            if isinstance(data.get("embedding"), list):
                return data["embedding"]
            if isinstance(data.get("embeddings"), list) and data["embeddings"]:
                return data["embeddings"][0]
        return None

    def _hash_vector(self, text: str) -> list[float]:
        """占位向量：确定性哈希，无语义区分能力，仅用于离线自测。"""
        digest = hashlib.sha256(text.encode("utf-8")).digest()
        return [(digest[i % len(digest)] / 255.0) - 0.5 for i in range(self.embedding_dim)]


def main() -> int:
    if QdrantClient is None:
        print("错误: qdrant-client 未安装（pip install qdrant-client）")
        return 1

    parser = argparse.ArgumentParser(description="Pi 记忆管理（Qdrant）")
    parser.add_argument("command", choices=["init", "add", "search", "stats", "list", "delete"])
    parser.add_argument("args", nargs="*", help="add/delete: <集合> <内容|point_id>；search: <集合> <查询>")
    parser.add_argument("--limit", type=int, default=5, help="search 返回条数，默认 5")
    parser.add_argument("--threshold", type=float, default=None, help="search 相似度下限，默认不限")
    parser.add_argument("--url", default=None, help="Qdrant 地址，默认读配置")
    ns = parser.parse_args()

    mm = MemoryManager(url=ns.url)

    if ns.command == "init":
        mm.init_collections()
        return 0

    if ns.command == "list":
        for col in mm.list_collections():
            print(f"  {col}")
        return 0

    if ns.command == "stats":
        stats = mm.show_stats()
        if not stats:
            print("  尚无集合，先执行 init")
        for col, count in stats.items():
            print(f"  {col}: {count} 条")
        return 0

    if len(ns.args) < 2:
        print(f"用法: python memory_manager.py {ns.command} <集合> <内容>")
        return 1

    collection, value = ns.args[0], ns.args[1]

    if ns.command == "add":
        print(f"已添加: {mm.add_memory(collection, value)}")
        return 0

    if ns.command == "delete":
        ok = mm.delete_memory(collection, value)
        print("已删除" if ok else "删除失败")
        return 0 if ok else 1

    if ns.command == "search":
        results = mm.search_memory(collection, value, limit=ns.limit, score_threshold=ns.threshold)
        if not results:
            print("  无结果")
        for item in results:
            print(f"  [{item['score']:.4f}] {item['content']}")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
