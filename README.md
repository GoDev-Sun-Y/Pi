# Pi-Work-Mode

Pi AI Agent 工作模式配置包 —— 从零搭建到完整生产环境的一键迁移方案。

包含完整的配置、规则、脚本和扩展，支持从空白系统一键部署。

> **第一次接触请先读 [docs/部署指南.md](docs/部署指南.md)。**
> 那份文档从「Pi 是什么」讲起，包含完整环境核对清单、分阶段部署步骤、验证方法和已知坑，
> 设计目标是：把它交给任意一个 AI，对方也能照着把环境部署起来。

> **隐私声明**：工作区当前不含任何个人路径、账号或敏感信息，所有路径均使用占位符，安装时由脚本自动替换为实际目录。`tests/verify.ps1` 与 CI 都会用通用正则扫描源码中的硬编码个人路径。
>
> 全部 Git 历史已于 2026-09-12 用 `git-filter-repo` 重写：旧机路径、GitHub 账号、提交作者邮箱均已替换为中性占位符，逐提交扫描确认无残留。**本项目不再推送到远端仓库**，仅保留本地提交。

## 项目结构

```
Pi-Work-Mode/
├── config/                    # 核心配置
│   ├── settings.json          # Pi 主配置（路径、Qdrant 地址、embedding 维度）
│   ├── models-store.json      # 模型路由表（按任务类型分发）
│   ├── presets.json           # /preset 预设定义（9 个预设的工具集与注入指令）
│   └── settings.env.example   # API Key 环境变量模板
├── extensions/
│   └── preset.ts              # /preset 扩展（Pi 官方示例，提供命令/flag/快捷键）
├── docs/                      # 规则文档（本项目的核心资产）
│   ├── 部署指南.md             # ★ 从零部署完整说明（先读这个）
│   ├── AGENTS.md              # 主规则：身份、沟通、工具管理、安全、纪律（必读）
│   ├── WORKFLOW.md            # 工作纪律：熔断、工具优先级、完成判定
│   ├── SUBAGENT_PROTOCOL.md   # 主/分支协作协议
│   ├── 规则索引卡.md           # 会话恢复用的快速参考卡
│   └── QDRANT_USAGE.md        # 向量库使用说明
├── scripts/
│   ├── setup.ps1              # 一键安装脚本（首选入口，含第 2b 步安装 Pi 本体）
│   ├── install-pi.ps1         # Pi 本体一键安装（默认自包含装到 .pi-runtime）
│   ├── install_ollama.ps1     # Ollama + 本地 embedding 模型安装
│   ├── memory_manager.py      # Qdrant 记忆管理客户端
│   └── install-hooks.ps1      # 安装本地 pre-commit 钩子（可选）
├── docker/
│   └── docker-compose.yml     # Qdrant 容器编排
├── templates/
│   └── qdrant-config.json     # 集合结构模板
├── tests/
│   ├── verify.ps1             # 静态检查: 环境/配置/编码/隐私（npm run verify）
│   ├── test_install.ps1       # 动态检查: setup.ps1 干跑全流程（npm run test:install）
│   └── test_memory_search.py  # 记忆检索链路验证，可离线运行（npm run test:memory）
├── .githooks/
│   └── pre-commit             # 本地钩子: 提交前自动跑 verify.ps1
├── .github/workflows/         # CI 校验 + Release 打包
├── .gitattributes             # 锁定钩子脚本为 LF 行尾（否则钩子会失效）
├── .gitignore                 # Git 忽略规则
├── version.txt                # 版本号
└── README.md                  # 本文件
```

## 自检

三个脚本职责不同，建议都跑：

```powershell
# 静态检查：运行环境、配置文件合法性、脚本语法、UTF-8 BOM、硬编码个人路径
npm run verify

# 动态检查：真跑 setup.ps1 的 -DryRun，验证安装流程本身（不产生任何改动）
npm run test:install

# 记忆检索链路：可离线运行，无需 Qdrant 容器与 Ollama
npm run test:memory
```

`verify.ps1` 与 `test_install.ps1` 是只读的，不需要额外依赖；`test_memory_search.py` 需要 `pip install qdrant-client`，未安装时会自动跳过。三者全部通过时退出码为 0。

`verify.ps1` 会把 Qdrant/Ollama 未启动的情况记为「跳过」而非「失败」。

## 本地钩子（可选）

把 `verify.ps1` 挂到 `git commit` 之前，每次提交自动检查一遍 —— 相当于把 CI 搬到本地执行。

```powershell
.\scripts\install-hooks.ps1              # 安装
.\scripts\install-hooks.ps1 -Uninstall   # 卸载
```

安装后每次提交会自动运行 `tests\verify.ps1 -SkipServices`（约 2 秒，跳过 Qdrant/Ollama 探测）。
检查不通过会**中止提交**并列出失败项；临时绕过用 `git commit --no-verify`。

配置只写入仓库级 `.git/config`，不使用 `--global`，不影响其他仓库。

> **为什么要注意行尾**：`.githooks/pre-commit` 是个 shell 脚本，**必须保持 LF 行尾且无 BOM**。
> 本机 `core.autocrlf=true` 会把它转成 CRLF，sh 会把行尾的 `\r` 当成命令名的一部分，
> 钩子于是静默失效。因此 `.gitattributes` 显式锁定了 `.githooks/*` 的行尾，
> `verify.ps1` 里也有一项断言专门守这个约束。

## 已知限制

1. `setup.ps1` 非管理员运行时会自动请求 UAC 提权，命令行参数会自动透传
2. Docker Desktop 需要手动启动（或重启后自动启动）
3. 国内用户可能需要配置 Docker 镜像加速
4. 记忆检索依赖本地 Ollama；Ollama 不可用时 `memory_manager.py` 会明确报错，而不是静默降级成无意义的向量
5. 含中文的 PowerShell 脚本必须以 UTF-8 BOM 保存，否则 PowerShell 5.1 会读成乱码（`tests/verify.ps1` 会检查这一点）
6. **扩展安装范围**：安装脚本自动装 7 个扩展（npm 来源 6 个 + git 来源 1 个）。
   规则文件里已逐项标注「脚本自动装 / 需手动装」，其余用 `pi install npm:<包名>` 手动补齐
7. **`/preset` 机制已可用**：本包自带 `extensions/preset.ts`（Pi 官方示例）与
   `config/presets.json`，`setup.ps1` 会自动部署到 `~/.pi/agent/`。
   机制已在隔离环境实测通过（`--preset plan` → 工具集切为 `read, grep, find, ls`）。
   但预设里的**扩展工具**（`web_search` / `gui_*` / `ctx_*`）需先装对应扩展才存在，
   未安装时 Pi 会自动过滤并提示，属预期行为

## 快速开始

### 方法一：自动安装（推荐）

```powershell
# 进入仓库目录（下文所有命令都在仓库根目录执行）
cd Pi-Work-Mode

# 第 0 步：装 Pi 本体（自带脚本，默认自包含装到仓库内 .pi-runtime）
#         不写全局 npm 目录、不改 PATH、不动用户主目录
#         已经装过 Pi 可以跳过这步 —— setup.ps1 会自己探测
powershell -ExecutionPolicy Bypass -File scripts\install-pi.ps1 -DryRun   # 先干跑预览
powershell -ExecutionPolicy Bypass -File scripts\install-pi.ps1           # 正式安装

# 干跑预览安装流程（零风险，先确认数据目录）
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -DataDir "C:\PiData" -WhatIf

# 正式安装（默认会弹 UAC，需点「是」；依赖齐全时可加 -NoElevate 跳过）
powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -DataDir "C:\PiData"
```

> **为什么要写 `-ExecutionPolicy Bypass`**：PowerShell 默认执行策略可能拒绝运行 `.ps1`，
> 加上它可绕开拦截，且只对这一次调用生效，不改动系统设置。
>
> **数据目录怎么定**：不传 `-DataDir` 时脚本会交互询问，直接回车则用默认值
> `C:\Users\<你的用户名>\AI\Pi`。**建议显式指定**，放到你自己好找的位置。
> 本文出现的 `C:\PiData` 只是示例，换成任意目录即可（**路径不要含空格**）。

脚本会自动完成：

1. ✅ 检测依赖（Node.js ≥22, Python, Git, Docker）
2. ✅ 自动安装缺失的环境（Node.js、Python、Docker）
3. ✅ **安装 Pi 本体**（默认自包含装到 `.pi-runtime`，也可用 `-PiPrefix` 指定位置）
4. ✅ 创建完整目录结构
5. ✅ 复制配置文件到 `~/.pi/agent/`（`settings.json` 采用**合并写入**，原有 `theme` 等键不会被抹掉）
6. ✅ 把 4 份规则文档部署到 `~/.pi/agent/`（Pi 只在启动时从这里加载 `AGENTS.md`）
7. ✅ 用 `pi install` 安装 7 个扩展（6 个来自 npm + 1 个来自 GitHub，后者失败不影响）并自动登记到 `settings.json` 的 `packages`
8. ✅ 启动 Qdrant 服务（Docker 可用时）
9. ✅ 验证安装状态

> **可隔离运行**：设置环境变量 `PI_CODING_AGENT_DIR`（或用 `-AgentDir`）即可把配置目录
> 重定向到任意位置，用户主目录零写入 —— 这是做干净测试的关键，也是本次验证采用的方式。

> **隐私保证**：此包不包含任何个人路径、账号或敏感信息。
> 配置文件中的 `dataDir` 写作占位符 `{{DATA_DIR}}`，**由 `setup.ps1` 在安装时自动替换**。
> ⚠️ 如果你走「方法二：手动安装」，脚本不参与，**需要自己把 `{{DATA_DIR}}` 改成实际路径**，
> 否则 Pi 会拿到一个带花括号的无效目录。
> 同理，4 份规则文档（AGENTS.md 等）正文里的 `{DATA_DIR}`（单花括号）也要替换——
> 脚本路线由 setup.ps1 自动完成，手动路线两处都得自己改（方法二里有示例命令）。
>
> **覆盖前自动备份**：任何已存在的 `settings.json`、`models-store.json`、`AGENTS.md` 等文件，
> 被覆盖前都会先备份为 `<原名>.bak-<时间戳>`，可随时回滚。

> **注意**：Docker Desktop 安装完成后需要重启电脑，然后重新运行脚本以启动 Qdrant。

### 方法二：手动安装

> 手动路线不经过 `setup.ps1`，所以**占位符不会自动替换、覆盖前也没有自动备份**。
> 适合想逐步看清每一步在做什么的人。任何一步拿不准，回到方法一即可。

```powershell
# 0. 安装 Pi 本体（自包含装到仓库内，不碰全局 npm 和 PATH）
powershell -ExecutionPolicy Bypass -File scripts\install-pi.ps1
#    或走官方全局方式：npm install -g --ignore-scripts @earendil-works/pi-coding-agent

# 1. 确保环境
# Node.js ≥22.19.0, Python 3.10+, Git, Docker（可选）

$AgentDir = "$env:USERPROFILE\.pi\agent"

# 2. 部署规则文档（关键：Pi 只从 ~/.pi/agent/ 加载 AGENTS.md）
Copy-Item docs\AGENTS.md,docs\WORKFLOW.md,docs\SUBAGENT_PROTOCOL.md,docs\规则索引卡.md `
          -Destination $AgentDir -Force
#    ⚠️ 这 4 份文档的正文里写了 {DATA_DIR}\日志\... 这类占位符路径！
#    自动安装时 setup.ps1 会替换成真实数据目录；手动路线必须自己替换，
#    否则记忆/日志功能会静默写到带花括号的无效目录。替换方法：
#    (Get-Content "$AgentDir\AGENTS.md" -Raw).Replace('{DATA_DIR}', '你的数据目录') |
#      Set-Content "$AgentDir\AGENTS.md" -Encoding UTF8   # 其余 3 份同样处理

# 3. 部署 /preset 机制
#    少了这两个文件，AGENTS.md 里那套「按需切换工具集」的规则不会生效
New-Item -ItemType Directory -Force -Path "$AgentDir\extensions" | Out-Null
Copy-Item extensions\preset.ts -Destination "$AgentDir\extensions\" -Force
Copy-Item config\presets.json  -Destination $AgentDir -Force

# 4. 配置 settings.json —— 不要直接覆盖！
#    包里那份是模板：含占位符 {{DATA_DIR}}，直接覆盖还会抹掉你已有的 theme 等键。
#    正确做法是把它里面的 pi 块手动合并进你现有的 settings.json，
#    并把 {{DATA_DIR}} 替换成你的实际数据目录（脚本自动装时有备份，手动没有）

# 5. 安装扩展 —— 必须用 pi install，不要用 npm install -g
#    （Pi 只认自己 settings.json 的 packages 列表，npm 全局安装它发现不了）
#    ⚠️ 第 0 步的自包含安装不会改 PATH，此时 pi 不是全局命令！
#    请用完整路径调用（或把 .pi-runtime 加进 PATH）：
$pi = ".\.pi-runtime\pi.cmd"
& $pi install npm:pi-agnes
& $pi install npm:pi-memory
& $pi install npm:pi-smart-paste
& $pi install npm:pi-subagents
& $pi install npm:pi-lens
& $pi install npm:pi-web-access
& $pi install git:github.com/Blue-B/pi-custom-packages   # 可选，国内网络可能失败

# 6. 安装 Python 包（记忆功能用，可选）
pip install qdrant-client

# 7. 启动 Qdrant（可选，需要 Docker）
$QDRANT_DATA = "C:\PiData\qdrant_storage"   # 换成你的数据目录
New-Item -ItemType Directory -Force -Path $QDRANT_DATA | Out-Null
docker run -d -p 6333:6333 -p 6334:6334 -v ${QDRANT_DATA}:/qdrant/storage qdrant/qdrant

# 8. 验证装好了没
powershell -ExecutionPolicy Bypass -File tests\verify.ps1 -SkipServices
```

## 环境要求

| 依赖 | 最低版本 | 说明 |
| ------ | ---------- | ------ |
| Node.js | ≥22.19.0 | 运行时。这是 Pi 包的硬要求，22.19 以下会在装 Pi 本体时直接报错 |
| Python | ≥3.10 | 记忆管理（可选） |
| Git | ≥2.40 | 扩展管理。**安装脚本硬依赖** —— 缺了会在第 1 步检测时直接中止 |
| Docker | 可选 | Qdrant 服务 |

## 使用流程

### 日常会话

```powershell
# 启动 Pi
pi

# 会话结束前保存
# （系统会自动保存会话记忆）
```

### 记忆管理

```powershell
# 首次使用先建集合
python scripts/memory_manager.py init

# 查看记忆统计
python scripts/memory_manager.py stats

# 搜索记忆
python scripts/memory_manager.py search memory_rules "关键词"

# 添加记忆
python scripts/memory_manager.py add memory_rules "新规则内容"
```

### 配置备份

配置只有两个文件，直接复制即可：

```powershell
Copy-Item "$env:USERPROFILE\.pi\agent\settings.json"     "{DATA_DIR}\备份\"
Copy-Item "$env:USERPROFILE\.pi\agent\models-store.json" "{DATA_DIR}\备份\"
```

## 配置文件说明

### `config/settings.json`

Pi 主配置文件，包含：

- **env**: 环境变量和路径映射
- **tools**: 工具启用/禁用配置
- **agents**: 子代理模型选择

### `config/models-store.json`

模型路由表，定义任务类型到模型的映射：

- `simple` → agnes-2.5-flash（默认）
- `complex` → agnes-3.0-flash（复杂任务）
- `reasoning` → glm-4.7-flash（深度推理）
- 等等...

## 版本历史

当前版本见 `version.txt`。变更记录暂未单独维护。

## 注意事项

1. **首次安装需要管理员权限**（用于自动安装 Node.js/Python）
2. **Docker 为可选依赖**，缺失时 Qdrant 服务将跳过
3. **网络要求**：扩展安装需要联网 —— 7 个扩展里 6 个从 npm 拉取，1 个
   （`git:github.com/Blue-B/pi-custom-packages`）来自 GitHub。国内建议先设镜像：
   `npm config set registry https://registry.npmmirror.com`；Pi 本体下载同理。
   GitHub 那个失败只会打印警告，**不影响其余扩展，也不影响 Pi 本体运行**
4. **数据备份**：安装前建议备份现有 `~/.pi` 目录
5. **API 密钥**：`setup.ps1` 完成后会提示配置 `AGNES_API_KEY`（复制 `config\settings.env.example` 为 `settings.env` 并填入），Agnes 免费渠道见 https://api.sapiens.ai；本地 Ollama 部分（embedding/向量搜索）完全免费无需密钥
6. **Ollama 自动安装**：`setup.ps1` 第 7b 步自动运行 `scripts\install_ollama.ps1`，首次运行会拉取 `all-minilm:33m`（384 维）；如需更高精度可手动 `ollama pull bge-m3`（1024 维）并更新 `config\settings.json` 的 `embeddingModel`/`embeddingDim`

## 许可证

MIT License
