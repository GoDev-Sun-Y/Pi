# Qdrant 向量库使用说明

Qdrant 负责存 Pi 的长期记忆，是**可选组件**。不装它 Pi 照样运行，只是记不住跨会话的事。

## 连接信息

| 项目 | 值 |
| ------ | ----- |
| HTTP API | <http://localhost:6333> |
| gRPC 端口 | 6334 |
| Web 控制台 | <http://localhost:6333/dashboard> |
| Docker 镜像 | qdrant/qdrant:latest |
| 数据目录 | `<你的数据目录>\qdrant_storage` |

> 下文出现的 `<你的数据目录>` 请替换成你安装时 `-DataDir` 指定的那个目录，
> 例如 `C:\PiData`。

> **关于镜像地址不一致**：`setup.ps1` 自动生成的 compose 文件用的是国内镜像加速地址
> `docker.m.daocloud.io/qdrant/qdrant:latest`（官方源在国内常拉不动）；
> 本仓库 `docker/docker-compose.yml` 和下文的 `docker run` 示例写的是官方地址。
> 两者是同一个镜像，拉不动官方源时手动加上 `docker.m.daocloud.io/` 前缀即可。

## 启动 / 停止

向量数据存放在**你的数据目录**下（`<你的数据目录>\qdrant_storage`），不在仓库里。
`setup.ps1` 第 6 步会自动生成 `<你的数据目录>\docker-compose.yml` 并尝试启动。

```powershell
cd C:\PiData          # 换成你自己的数据目录
docker compose up -d
docker compose down
```

或直接用一条 docker 命令（同样把 `<你的数据目录>` 换成实际路径）：

```powershell
$QDRANT_DATA = "C:\PiData\qdrant_storage"
New-Item -ItemType Directory -Force -Path $QDRANT_DATA | Out-Null
docker run -d --name qdrant -p 6333:6333 -p 6334:6334 `
  -v ${QDRANT_DATA}:/qdrant/storage qdrant/qdrant
```

停止与重启：

```powershell
docker stop qdrant
docker start qdrant
```

## 集合

首次运行 `init` 会自动建好 4 个集合：

| 集合 | 说明 |
| ------ | ------ |
| memory_rules | 规则与偏好 |
| daily_logs | 每日日志 |
| session_log | 会话记录 |
| novel_chapters | 长篇写作（用不到可以不管，留着不影响） |

集合的向量维度由 `config\settings.json` 的 `embeddingDim` 决定，**不要手工改维度**，
改了会和已写入的数据对不上。维度不一致时 `memory_manager.py` 会明确报错，不会静默写坏。

## Embedding 模型

默认用本地 Ollama 的 `all-minilm:33m`（384 维，67 MB），完全免费、离线可用。

| 模型 | 维度 | 大小 | 说明 |
| ------ | ------ | ------ | ------ |
| all-minilm:33m | 384 | 67MB | **默认**，轻量，够用 |
| nomic-embed-text | 768 | 274MB | 英文效果更好 |
| bge-m3 | 1024 | 1.2GB | 中英双语，精度最高 |

换模型时**两处必须同时改**，否则写入会失败：

1. `config\settings.json` → `embeddingModel` 与 `embeddingDim`
2. 已建集合的维度必须匹配 —— 不一致时需要删掉集合重建，旧数据无法自动迁移

```powershell
ollama pull all-minilm:33m
ollama list
```

## 常用命令

```powershell
python scripts\memory_manager.py init                          # 建集合（首次）
python scripts\memory_manager.py stats                         # 查看统计
python scripts\memory_manager.py search memory_rules "关键词"   # 搜索
python scripts\memory_manager.py add memory_rules "记忆内容"    # 添加
```

## 直接查询（Python）

```python
from qdrant_client import QdrantClient
import requests

client = QdrantClient(url="http://localhost:6333")

# 生成向量（Ollama 批量接口 /api/embed 返回 embeddings 数组）
emb = requests.post(
    "http://localhost:11434/api/embed",
    json={"model": "all-minilm:33m", "input": "Pod 一直重启"},
).json()["embeddings"][0]

# 搜索
for point in client.query_points("memory_rules", query=emb, limit=5).points:
    print(point.score, point.payload)
```

> 两个容易踩的 API 变化：
> - `qdrant-client` **1.19+ 已移除 `search()`**，改用 `query_points()`，结果取 `.points`
> - Ollama 的批量接口是 `/api/embed`（返回 `embeddings` 数组）；
>   旧的单条接口 `/api/embeddings` 返回的是 `embedding` 单值，别混用

## 排错

| 现象 | 原因与处理 |
| ------ | ------ |
| 连不上 6333 | Docker Desktop 没启动，或容器没跑 —— 先 `docker ps` 确认 |
| 写入报维度不匹配 | `embeddingDim` 与集合实际维度不一致 —— 删集合重建 |
| 报 embedding 失败 | Ollama 没起来或模型没拉 —— `ollama list` 看看有没有模型 |
| 想彻底重置 | 停容器 → 删掉 `qdrant_storage` 目录 → 重新 `init` |
