# -*- coding: utf-8 -*-
"""记忆检索链路验证（可离线运行，无需 Qdrant 容器与 Ollama）。

为什么需要这个测试:
    memory_manager.py 的检索质量取决于 embedding 是否具备语义区分能力。
    原版实现用 sha256 摘要充当向量，导致「搜索」的结果与随机无异。
    本脚本用本地 HTTP 服务模拟 Ollama 的 /api/embed 接口，返回词袋哈希向量
    （具备真实的词汇重叠相似度），走完整链路验证：
        写入 -> embedding -> upsert -> query_points -> 按相似度排序
    并与 sha256 占位向量做对照，量化两者的检索命中率差异。

    注意: 这里验证的是「检索链路是否正确工作」，不是「某个模型的语义质量」。
    真实使用请拉取 Ollama 模型（默认 all-minilm:33m），效果会优于词袋向量。

用法:
    python tests/test_memory_search.py

依赖: pip install qdrant-client
全部断言通过时退出码 0，否则 1。
"""

import json
import math
import os
import re
import sys
import threading
from hashlib import md5
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

try:
    from qdrant_client import QdrantClient
except ImportError:
    print("跳过: 未安装 qdrant-client（pip install qdrant-client）")
    sys.exit(0)

from memory_manager import MemoryManager

DIM = 384
MOCK_PORT = 11434


def embed_text(text: str) -> list[float]:
    """词袋哈希向量：英文按词切分，中文按单字与二字组合切分。"""
    vec = [0.0] * DIM
    tokens = re.findall(r"[a-zA-Z0-9_]+", text.lower())
    han = re.findall(r"[\u4e00-\u9fff]", text)
    tokens += han
    tokens += [han[i] + han[i + 1] for i in range(len(han) - 1)]
    for token in tokens:
        h = int(md5(token.encode("utf-8")).hexdigest(), 16)
        sign = 1.0 if (h >> 17) % 2 == 0 else -1.0
        vec[h % DIM] += sign
    norm = math.sqrt(sum(v * v for v in vec)) or 1.0
    return [v / norm for v in vec]


class MockOllama(BaseHTTPRequestHandler):
    """模拟 Ollama 的 /api/embed 与 /api/embeddings 接口。"""

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            body = {}
        text = body.get("input") or body.get("prompt") or ""
        payload = json.dumps({"embedding": embed_text(text)}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


MEMORIES = [
    "PowerShell 脚本含中文时必须保存为 UTF-8 BOM，否则 PowerShell 5.1 按 ANSI 解码导致乱码",
    "qdrant-client 1.12 之后 client.search 已被移除，应改用 query_points 接口",
    "HnswConfigDiff 的合法参数是 m 和 ef_construct，不存在 cnf 参数",
    "Git 历史中的个人路径需要用 git filter-repo 重写，普通 commit 无法清除",
    "Docker Desktop 未启动时 docker 命令会报 npipe 连接失败",
]

QUERIES = [
    ("中文乱码要怎么解决", 0),
    ("怎么把 git 里的隐私路径清掉", 3),
    ("docker 命令连不上怎么办", 4),
]

SCRIPT_PASSED = 0
SCRIPT_FAILED = 0


def check(title: str, ok: bool, detail: str = "") -> None:
    global SCRIPT_PASSED, SCRIPT_FAILED
    if ok:
        print(f"  [通过] {title}")
        SCRIPT_PASSED += 1
    else:
        print(f"  [失败] {title}")
        if detail:
            print(f"         {detail}")
        SCRIPT_FAILED += 1


def run_search_round(use_mock: bool) -> int:
    """跑一轮检索，返回 top1 命中数。"""
    if use_mock:
        os.environ["OLLAMA_URL"] = f"http://127.0.0.1:{MOCK_PORT}"
        os.environ.pop("PI_ALLOW_HASH_EMBEDDING", None)
    else:
        os.environ["OLLAMA_URL"] = "http://127.0.0.1:9"
        os.environ["PI_ALLOW_HASH_EMBEDDING"] = "1"

    mm = MemoryManager(client=QdrantClient(":memory:"), dim=DIM)
    mm.init_collections()
    for text in MEMORIES:
        mm.add_memory("memory_rules", text)

    hits = 0
    for query, expected in QUERIES:
        results = mm.search_memory("memory_rules", query, limit=5)
        top = results[0] if results else None
        if top and top["content"] == MEMORIES[expected]:
            hits += 1
        if top:
            print(f"         {query} -> [{top['score']:.4f}] {top['content'][:30]}")
    return hits


def main() -> int:
    server = ThreadingHTTPServer(("127.0.0.1", MOCK_PORT), MockOllama)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    try:
        print()
        print("========================================")
        print("  记忆检索链路验证")
        print("========================================")

        print()
        print("真实 embedding 链路")
        good = run_search_round(use_mock=True)
        check(f"检索命中 {good}/{len(QUERIES)}", good >= 2, "至少应命中 2 条")

        print()
        print("基础行为")
        mm = MemoryManager(client=QdrantClient(":memory:"), dim=DIM)
        mm.init_collections()
        check("初始化创建 4 个集合", len(mm.list_collections()) == 4)

        for text in MEMORIES:
            mm.add_memory("memory_rules", text)
        check("写入后计数正确", mm.show_stats().get("memory_rules") == len(MEMORIES))

        mm.add_memory("memory_rules", MEMORIES[0])
        check("重复写入相同内容保持幂等", mm.show_stats().get("memory_rules") == len(MEMORIES))

        pid = mm.add_memory("memory_rules", "临时记录")
        mm.delete_memory("memory_rules", pid)
        check("删除后计数回落", mm.show_stats().get("memory_rules") == len(MEMORIES))

        print()
        print("对照: sha256 占位向量（原版做法）")
        bad = run_search_round(use_mock=False)
        check(f"占位向量命中 {bad}/{len(QUERIES)}，低于真实链路", bad < good, f"真实 {good} vs 占位 {bad}")

    finally:
        server.shutdown()

    print()
    print("========================================")
    print(f"  通过 {SCRIPT_PASSED} 项 / 失败 {SCRIPT_FAILED} 项")
    print("========================================")
    print()

    if SCRIPT_FAILED > 0:
        print("验证未全部通过。")
        return 1
    print("验证全部通过。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
