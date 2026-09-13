# Pi-Work-Mode 一键安装脚本
# 版本: v1.1.0
# 用途: 从零搭建 Pi AI Agent 工作模式（Pi 本体 + 配置 + 扩展 + 记忆库 + 本地 embedding）
#
# 用法:
#   .\scripts\setup.ps1                       交互式，会询问数据目录
#   .\scripts\setup.ps1 -DataDir "D:\PiData"  指定数据目录
#   .\scripts\setup.ps1 -PiPrefix "D:\Pi"     把 Pi 本体装到指定目录（默认装到仓库内 .pi-runtime）
#   .\scripts\setup.ps1 -SkipPi               跳过 Pi 本体安装（已有 Pi 时用）
#   .\scripts\setup.ps1 -SkipQdrant           跳过 Qdrant 向量库
#   .\scripts\setup.ps1 -SkipOllama           跳过 Ollama 本地 embedding 安装
#   .\scripts\setup.ps1 -SkipExtensions       跳过 Pi 扩展安装
#   .\scripts\setup.ps1 -SkipPythonDeps       跳过 pip 依赖安装（qdrant-client）
#   .\scripts\setup.ps1 -NoElevate            不自动请求 UAC 提权（依赖已齐全时用）
#   .\scripts\setup.ps1 -DryRun               干跑预览，不产生任何改动
#
# 说明:
#   1) 非管理员运行时会自动请求 UAC 提权，命令行参数会自动透传。
#   2) 配置目录默认是 ~\.pi\agent，可用 -AgentDir 或环境变量 PI_CODING_AGENT_DIR 重定向。
#      做隔离测试（不写用户主目录）时，设 PI_CODING_AGENT_DIR 即可。

param(
    [string]$DataDir,
    [string]$PiPrefix,
    [string]$AgentDir,
    [switch]$SkipQdrant,
    [switch]$SkipOllama,
    [switch]$SkipPi,
    [switch]$SkipExtensions,
    [switch]$SkipPythonDeps,
    [switch]$NoElevate,
    [Alias("WhatIf")]
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path $ScriptPath -Parent      # ...\Pi-Work-Mode\scripts
$RepoRoot   = Split-Path $ScriptDir -Parent       # ...\Pi-Work-Mode

# ============================================================
# 输出辅助
# ============================================================
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor White
    Write-Host "----------------------------------------" -ForegroundColor Cyan
}

function Write-Success  { param([string]$Message) Write-Host "  [OK] $Message"    -ForegroundColor Green }
function Write-Warn     { param([string]$Message) Write-Host "  [警告] $Message"  -ForegroundColor Yellow }
function Write-Failure  { param([string]$Message) Write-Host "  [失败] $Message"  -ForegroundColor Red }
function Write-Info     { param([string]$Message) Write-Host "  [信息] $Message"  -ForegroundColor Blue }

function Should-Process {
    param([string]$Action)
    if ($DryRun) {
        Write-Host "  [干跑] $Action" -ForegroundColor DarkGray
        return $false
    }
    return $true
}

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# 定位 pi 可执行文件：优先显式指定的安装目录 -> 仓库内默认安装位 -> PATH
function Find-PiExecutable {
    param([string]$Prefix)
    $names = @("pi.cmd", "pi.ps1", "pi")

    if ($Prefix) {
        foreach ($n in $names) {
            $cand = Join-Path $Prefix $n
            if (Test-Path $cand) { return $cand }
        }
    }
    foreach ($n in $names) {
        $cand = Join-Path $RepoRoot ".pi-runtime\$n"
        if (Test-Path $cand) { return $cand }
    }
    $cmd = Get-Command "pi" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [string]$Description
    )
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            & $ScriptBlock
            return $true
        } catch {
            if ($i -eq $MaxRetries) {
                Write-Failure "$Description 失败（已重试 $MaxRetries 次）: $_"
                return $false
            }
            Write-Warn "$Description 失败（第 $i/$MaxRetries 次）: $_"
            Start-Sleep -Seconds 3
        }
    }
    return $false
}

function Refresh-Environment {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
}

function Install-Docker {
    Write-Host ""
    Write-Host "  正在下载 Docker Desktop..."

    $dockerUrl = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $dockerInstaller = "$env:TEMP\Docker-Desktop-Installer.exe"

    if (Invoke-WithRetry -ScriptBlock {
        Invoke-WebRequest -Uri $dockerUrl -OutFile $dockerInstaller -UseBasicParsing
    } -Description "Docker 下载") {
        Write-Host "  正在静默安装 Docker Desktop..."
        Start-Process $dockerInstaller -ArgumentList "/quiet", "noreboot" -Wait
        Write-Success "Docker Desktop 安装完成"
        Write-Warn "需要重启电脑后 Docker 才能工作，重启后再跑一次本脚本即可启动 Qdrant"
    } else {
        Write-Failure "Docker 下载失败"
        Write-Host "  手动安装: https://www.docker.com/products/docker-desktop/"
    }
}

# ============================================================
# UAC 提权（干跑模式不需要管理员，直接跳过）
# ============================================================
function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin) -and -not $DryRun -and -not $NoElevate) {
    Write-Host ""
    Write-Warn "当前不是管理员，需要提权才能自动安装环境"
    Write-Host "  即将弹出 UAC 确认框，请选择「是」"
    Write-Host ""

    $elevateArgs = @("-ExecutionPolicy", "Bypass", "-File", "`"$ScriptPath`"")
    if ($DataDir)    { $elevateArgs += @("-DataDir", "`"$DataDir`"") }
    if ($PiPrefix)   { $elevateArgs += @("-PiPrefix", "`"$PiPrefix`"") }
    if ($AgentDir)   { $elevateArgs += @("-AgentDir", "`"$AgentDir`"") }
    if ($SkipQdrant) { $elevateArgs += "-SkipQdrant" }
    if ($SkipOllama) { $elevateArgs += "-SkipOllama" }
    if ($SkipPi)     { $elevateArgs += "-SkipPi" }
    if ($SkipExtensions)  { $elevateArgs += "-SkipExtensions" }
    if ($SkipPythonDeps)  { $elevateArgs += "-SkipPythonDeps" }
    if ($DryRun)     { $elevateArgs += "-DryRun" }

    Start-Process powershell -Verb RunAs -ArgumentList $elevateArgs -Wait
    exit 0
}

# ============================================================
# 第 0 步: 确定数据目录
# ============================================================
Write-Step "第 0 步: 确定数据目录"

if ($DryRun) { Write-Info "干跑模式: 不会写入任何文件" }

if (-not $DataDir) { $DataDir = $env:PI_DATA_DIR }
if (-not $DataDir -and -not $DryRun) {
    $DataDir = Read-Host "请输入 Pi 数据目录（直接回车使用 C:\Users\$env:USERNAME\AI\Pi）"
}
if (-not $DataDir) {
    $DataDir = "C:\Users\$env:USERNAME\AI\Pi"
}
$DataDir = $DataDir.TrimEnd("\").TrimEnd("/")

Write-Host ""
Write-Host "  数据目录: $DataDir" -ForegroundColor Cyan
Write-Host "  安装来源: $RepoRoot" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 第 1 步: 检测依赖
# ============================================================
Write-Step "第 1 步: 检测依赖"

$Prerequisites = @{
    Git    = Test-Command "git"
    Node   = Test-Command "node"
    Python = Test-Command "python"
    Docker = Test-Command "docker"
}

Write-Host ""
Write-Host "  检测结果:" -ForegroundColor Gray

if ($Prerequisites.Git) {
    Write-Success "Git: $(& git --version 2>&1)"
} else {
    Write-Failure "Git 未安装"
    Write-Host ""
    Write-Host "  请先安装 Git:" -ForegroundColor Yellow
    Write-Host "    方案 1（推荐）: winget install Git.Git"
    Write-Host "    方案 2: https://git-scm.com/download/win"
    Write-Host ""
    exit 1
}

if ($Prerequisites.Node) {
    $nodeVer = (& node --version 2>&1 | Select-Object -First 1).ToString().Trim()
    # 注意: -replace 的替换模板必须用单引号，双引号里的 $1 会被当变量展开成空串
    if ($nodeVer -match 'v?(\d+)\.(\d+)') {
        $nodeMajor = [int]$Matches[1]
        $nodeMinor = [int]$Matches[2]
    } else {
        $nodeMajor = 0
        $nodeMinor = 0
    }
    # 与 install-pi.ps1 门槛一致：Pi 官方要求 >= 22.19.0
    if (($nodeMajor -gt 22) -or ($nodeMajor -eq 22 -and $nodeMinor -ge 19)) {
        Write-Success "Node.js: $nodeVer"
    } else {
        Write-Failure "Node.js 版本过低: $nodeVer（Pi 要求 ≥22.19.0）"
        exit 1
    }
} else {
    Write-Warn "Node.js 未安装，稍后自动安装"
}

if ($Prerequisites.Python) {
    Write-Success "Python: $(& python --version 2>&1)"
} else {
    Write-Warn "Python 未安装，稍后自动安装"
}

if ($Prerequisites.Docker) {
    Write-Success "Docker: $(& docker --version 2>&1)"
} else {
    Write-Warn "Docker 未安装（Qdrant 向量库需要它，属可选依赖）"
    if (Should-Process "安装 Docker Desktop") { Install-Docker }
    $Prerequisites.Docker = Test-Command "docker"
}

# ============================================================
# 第 2 步: 安装缺失环境
# ============================================================
Write-Step "第 2 步: 安装缺失环境"

if (-not $Prerequisites.Node) {
    Write-Host ""
    # 必须 >= 22.19.0（install-pi.ps1 的硬门槛），不要钉低于此的版本
    $nodeVersion = "22.22.2"
    Write-Host "  正在下载 Node.js $nodeVersion..."
    $nodeUrl = "https://nodejs.org/dist/v$nodeVersion/node-v$nodeVersion-x64.msi"
    $nodeInstaller = "$env:TEMP\node-installer.msi"

    if (Should-Process "下载并安装 Node.js $nodeVersion") {
        if (Invoke-WithRetry -ScriptBlock {
            Invoke-WebRequest -Uri $nodeUrl -OutFile $nodeInstaller -UseBasicParsing
        } -Description "Node.js 下载") {
            Write-Host "  正在静默安装 Node.js..."
            Start-Process msiexec.exe -ArgumentList "/i `"$nodeInstaller`" /quiet /norestart" -Wait
            Refresh-Environment
            Write-Success "Node.js 安装完成"
        } else {
            Write-Failure "Node.js 下载失败，请手动安装后重跑: https://nodejs.org/"
            exit 1
        }
    }
} else {
    Write-Success "Node.js 已就绪，跳过"
}

if (-not $Prerequisites.Python) {
    Write-Host ""
    Write-Host "  正在下载 Python 3.12.7..."
    $pythonUrl = "https://www.python.org/ftp/3.12.7/python-3.12.7-amd64.exe"
    $pythonInstaller = "$env:TEMP\python-installer.exe"

    if (Should-Process "下载并安装 Python 3.12.7") {
        if (Invoke-WithRetry -ScriptBlock {
            Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonInstaller -UseBasicParsing
        } -Description "Python 下载") {
            Write-Host "  正在静默安装 Python..."
            Start-Process $pythonInstaller -ArgumentList "/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_pip=1" -Wait
            Refresh-Environment
            Write-Success "Python 安装完成"
        } else {
            Write-Warn "Python 下载失败，记忆管理功能将不可用（其余功能不受影响）"
        }
    }
} else {
    Write-Success "Python 已就绪，跳过"
}

# ============================================================
# 第 2b 步: 安装 Pi 本体
# ============================================================
Write-Step "第 2b 步: 安装 Pi 本体"

# 记录 Pi 本体是否装上，用于结尾如实汇报（避免"装残仍打印安装完成"）
$script:PiInstallOk = $true

if ($SkipPi) {
    Write-Info "已指定 -SkipPi，跳过（将使用 PATH 中已有的 pi 命令）"
} else {
    $installPiScript = Join-Path $ScriptDir "install-pi.ps1"
    if (-not (Test-Path $installPiScript)) {
        Write-Warn "未找到 install-pi.ps1，跳过 Pi 本体安装"
        $script:PiInstallOk = $false
    } else {
        $piArgs = @()
        if ($PiPrefix) { $piArgs += @("-InstallDir", $PiPrefix) }
        if ($AgentDir) { $piArgs += @("-AgentDir", $AgentDir) }
        if ($DryRun)   { $piArgs += "-DryRun" }

        # 用子进程调用：install-pi.ps1 内部的 exit 不会带停本脚本
        if ($DryRun) {
            Write-Host "  [干跑] 调用 install-pi.ps1 安装 Pi 本体" -ForegroundColor DarkGray
            Write-Host "         目标: $(if ($PiPrefix) { $PiPrefix } else { "$RepoRoot\.pi-runtime" })" -ForegroundColor DarkGray
        } else {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $installPiScript @piArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "Pi 本体安装未成功（退出码 $LASTEXITCODE），继续部署配置与规则"
                Write-Warn "可稍后手动重试: powershell -ExecutionPolicy Bypass -File scripts\install-pi.ps1"
                $script:PiInstallOk = $false
            }
        }
    }
}

# ============================================================
# 第 3 步: 创建目录结构
# ============================================================
Write-Step "第 3 步: 创建目录结构"

# 配置目录优先级: -AgentDir > 环境变量 PI_CODING_AGENT_DIR > 默认 ~\.pi\agent
# （PI_CODING_AGENT_DIR 是 Pi 官方支持的重定向变量，隔离测试时全靠它）
if ($AgentDir) {
    $PiHome = $AgentDir
} elseif ($env:PI_CODING_AGENT_DIR) {
    $PiHome = $env:PI_CODING_AGENT_DIR
} else {
    $PiHome = "$env:USERPROFILE\.pi\agent"
}

$DocsDir    = "$DataDir\文档\reference"
$ScriptsDir = "$DataDir\脚本"
$LogsDir    = "$DataDir\日志"
$ErrorsDir  = "$DataDir\错误库"
$PlansDir   = "$DataDir\计划库"
$QdrantDir  = "$DataDir\qdrant_storage"

$Dirs = @($PiHome, $ScriptsDir, $LogsDir, $ErrorsDir, $PlansDir, $DocsDir, $QdrantDir)

foreach ($dir in $Dirs) {
    if (Should-Process "创建目录: $dir") {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Write-Success "已创建: $dir"
    }
}

# ============================================================
# 第 4 步: 部署配置与文档
# ============================================================
Write-Step "第 4 步: 部署配置与文档"

$configFiles = @(
    @{ Source = "config\models-store.json"; Dest = "$PiHome\models-store.json" }
)

foreach ($file in $configFiles) {
    $srcPath = Join-Path $RepoRoot $file.Source
    if (-not (Test-Path $srcPath)) {
        Write-Warn "源文件不存在，跳过: $($file.Source)"
        continue
    }
    if (Should-Process "复制 $($file.Source) -> $($file.Dest)") {
        if (Test-Path $file.Dest) {
            $bak = "$($file.Dest).bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item -Path $file.Dest -Destination $bak -Force
            Write-Info "已备份原文件: $bak"
        }
        Copy-Item -Path $srcPath -Destination $file.Dest -Force
        Write-Success "已复制: $($file.Source) -> $($file.Dest)"
    }
}

# settings.json 用「合并写入」，不能直接覆盖：
# Pi 自己的 settings.json 里存有 theme、lastChangelogVersion 等键，
# 直接覆盖会把这些抹掉。这里只写入（或替换）仓库模板中的 pi 块。
$settingsSrc  = Join-Path $RepoRoot "config\settings.json"
$settingsDest = "$PiHome\settings.json"

if (-not (Test-Path $settingsSrc)) {
    Write-Warn "源文件不存在，跳过: config\settings.json"
} elseif (Should-Process "合并 config\settings.json 的 pi 块 -> $settingsDest") {
    $tpl = $null
    try {
        $tpl = (Get-Content $settingsSrc -Raw -Encoding UTF8 | ConvertFrom-Json).pi
    } catch {
        $tpl = $null
    }

    if ($null -eq $tpl) {
        Write-Failure "config\settings.json 解析失败或缺少 pi 块，已跳过（原文件未改动）"
    } else {
        # 占位符替换为实际数据目录；反斜杠交给 ConvertTo-Json 自行转义，不能预先转义
        $tpl.dataDir = $DataDir

        # 同步版本号：避免配置里的 version 与 version.txt 长期漂移（两者语义不同，容易误读）
        $verFile = Join-Path $RepoRoot "version.txt"
        if ((Test-Path $verFile) -and ($tpl.PSObject.Properties.Name -contains "version")) {
            $verTxt = (Get-Content $verFile -Raw -Encoding UTF8).Trim()
            if ($verTxt) { $tpl.version = $verTxt }
        }

        $existing = $null
        if (Test-Path $settingsDest) {
            $bak = "$settingsDest.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item -Path $settingsDest -Destination $bak -Force
            Write-Info "已备份原设置: $bak"
            try {
                $existing = Get-Content $settingsDest -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch {
                Write-Warn "原 settings.json 不是合法 JSON，将按新建处理"
                $existing = $null
            }
        }

        $merged = [ordered]@{}
        if ($null -ne $existing) {
            foreach ($prop in $existing.PSObject.Properties) {
                $merged[$prop.Name] = $prop.Value
            }
        }
        $merged["pi"] = $tpl

        $json = $merged | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($settingsDest, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Success "已合并写入: $settingsDest（原有配置项保留）"
        Write-Info "dataDir -> $DataDir"
    }
}

# ── 规则文档里的 {DATA_DIR} 占位符替换 ──────────────────────────
# 规则文档（AGENTS.md 等）正文里写的是 {DATA_DIR}\日志\会话记忆.md 这类路径。
# 如果不替换，Pi 读到的就是字面花括号，会让会话日志、计划库写到一个假目录，
# 而且**不会报任何错** —— 属于最隐蔽的一类故障。
function Expand-DataDirToken {
    param([string]$Root, [string]$DataDir)
    if ($DryRun) { return 0 }
    if (-not (Test-Path $Root)) { return 0 }
    $token = '{DATA_DIR}'
    $changed = 0
    Get-ChildItem -Path $Root -Recurse -File -Filter *.md -ErrorAction SilentlyContinue | ForEach-Object {
        $text = Get-Content $_.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($text -and $text.Contains($token)) {
            $newText = $text.Replace($token, $DataDir)
            [System.IO.File]::WriteAllText($_.FullName, $newText, (New-Object System.Text.UTF8Encoding($false)))
            $changed++
        }
    }
    return $changed
}

$docsSrc = Join-Path $RepoRoot "docs"
if (Test-Path $docsSrc) {
    if (Should-Process "复制文档 -> $DocsDir") {
        Copy-Item -Path "$docsSrc\*" -Destination $DocsDir -Recurse -Force
        Write-Success "已复制文档 -> $DocsDir"
    }
    $n = Expand-DataDirToken -Root $DocsDir -DataDir $DataDir
    if ($n -gt 0) { Write-Info "已替换 $n 个文档中的 {DATA_DIR} 占位符" }
} else {
    Write-Warn "未找到 docs 目录，跳过"
}

# 规则文档必须落到 $PiHome 才会生效：
# Pi 只在启动时加载 ~/.pi/agent/AGENTS.md（以及父目录、当前目录下的 AGENTS.md），
# 只把文档丢进数据目录的话，Pi 读不到，规则等于没装。
if (Test-Path $docsSrc) {
    $ruleFiles = @("AGENTS.md", "WORKFLOW.md", "SUBAGENT_PROTOCOL.md", "规则索引卡.md")
    foreach ($rule in $ruleFiles) {
        $ruleSrc = Join-Path $docsSrc $rule
        if (-not (Test-Path $ruleSrc)) {
            Write-Warn "规则文档不存在，跳过: $rule"
            continue
        }
        $ruleDest = Join-Path $PiHome $rule
        if (Should-Process "部署规则文档 $rule -> $ruleDest") {
            if (Test-Path $ruleDest) {
                $ruleBak = "$ruleDest.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
                Copy-Item -Path $ruleDest -Destination $ruleBak -Force
                Write-Warn "已存在同名规则文件，原文件备份为: $ruleBak"
            }
            # 规则文档正文含 {DATA_DIR} 占位符，必须替换成实际数据目录后再落盘
            $ruleText = Get-Content -Path $ruleSrc -Raw -Encoding UTF8
            if ($ruleText) {
                $ruleText = $ruleText.Replace('{DATA_DIR}', $DataDir)
                [System.IO.File]::WriteAllText($ruleDest, $ruleText, (New-Object System.Text.UTF8Encoding($false)))
            }
            Write-Success "已部署规则: $ruleDest"
        }
    }
}

# ── 部署 /preset 扩展与预设定义 ──────────────────────────────────
# Pi 官方示例 extensions/preset.ts 提供 /preset 命令（运行时切换工具集/模型/思考级别）。
# 它必须落在 $PiHome\extensions\ 下才会被 Pi 自动发现；
# 预设定义读自 $PiHome\presets.json（以及项目本地 .pi\presets.json）。
$extSrc = Join-Path $RepoRoot "extensions"
if (Test-Path $extSrc) {
    $piExtDir = Join-Path $PiHome "extensions"
    if (Should-Process "创建目录 $piExtDir") {
        New-Item -ItemType Directory -Force -Path $piExtDir | Out-Null
    }
    $extFile = Join-Path $extSrc "preset.ts"
    if (Test-Path $extFile) {
        $extDest = Join-Path $piExtDir "preset.ts"
        if (Should-Process "部署扩展 preset.ts -> $extDest") {
            Copy-Item -Path $extFile -Destination $extDest -Force
            Write-Success "已部署 /preset 扩展: $extDest"
        }
    } else {
        Write-Warn "未找到 extensions\preset.ts，/preset 功能将不可用"
    }
} else {
    Write-Warn "未找到 extensions 目录，/preset 功能将不可用"
}

$presetsSrc = Join-Path $RepoRoot "config\presets.json"
if (Test-Path $presetsSrc) {
    $presetsDest = Join-Path $PiHome "presets.json"
    if (Should-Process "部署 presets.json -> $presetsDest") {
        if (Test-Path $presetsDest) {
            $presetsBak = "$presetsDest.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item -Path $presetsDest -Destination $presetsBak -Force
            Write-Warn "已存在 presets.json，原文件备份为: $presetsBak"
        }
        Copy-Item -Path $presetsSrc -Destination $presetsDest -Force
        Write-Success "已部署预设定义: $presetsDest"
    }
} else {
    Write-Warn "未找到 config\presets.json，跳过"
}

$scriptsSrc = Join-Path $RepoRoot "scripts"
if (Test-Path $scriptsSrc) {
    if (Should-Process "复制脚本 -> $ScriptsDir") {
        Copy-Item -Path "$scriptsSrc\*" -Destination $ScriptsDir -Force
        Write-Success "已复制脚本 -> $ScriptsDir"
    }
} else {
    Write-Warn "未找到 scripts 目录，跳过"
}

# ============================================================
# 第 5 步: 安装扩展
# ============================================================
Write-Step "第 5 步: 安装扩展"

# 两点关键：
# 1) Pi 扩展必须用 `pi install` 装，不能用 `npm install -g`。
#    Pi 只认自己 settings.json 的 packages 列表；用 npm 全局安装的话 Pi 根本发现不了，
#    而且会污染全局 npm 目录。
# 2) 一律走 npm 来源，不再 git clone GitHub。
#    原因：这些包在 npm 上都有正式发布；clone 下来的仓库放进 extensions\ 并不会被 Pi
#    自动注册；而且国内网络 clone GitHub 极易超时，会把整条安装流程卡死。
$piExe = Find-PiExecutable -Prefix $PiPrefix

if ($SkipExtensions) {
    Write-Info "已指定 -SkipExtensions，跳过扩展安装"
} elseif (-not $piExe) {
    Write-Warn "未找到 pi 命令，跳过扩展安装"
    Write-Host "    可先运行 scripts\install-pi.ps1，或用 -PiPrefix 指定 Pi 安装目录" -ForegroundColor Gray
} else {
    Write-Info "使用 Pi: $piExe"

    # 确保 pi 把配置写到本脚本认定的配置目录
    $prevAgentDir = $env:PI_CODING_AGENT_DIR
    $env:PI_CODING_AGENT_DIR = $PiHome

    $NpmExtensions = @(
        @{ Name = "pi-agnes";       Desc = "Agnes 模型提供商（默认 provider）" },
        @{ Name = "pi-memory";      Desc = "记忆系统" },
        @{ Name = "pi-smart-paste"; Desc = "剪贴板增强" },
        @{ Name = "pi-subagents";   Desc = "子代理" },
        @{ Name = "pi-lens";        Desc = "代码智能（LSP + AST）" },
        @{ Name = "pi-web-access";  Desc = "网页访问" }
    )

    foreach ($ext in $NpmExtensions) {
        $pkg = $ext.Name
        if (Should-Process "pi install npm:$pkg") {
            Write-Host "  正在安装扩展: $pkg（$($ext.Desc)）"
            & $piExe install "npm:$pkg" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "已安装: $pkg"
            } else {
                Write-Warn "安装失败: $pkg（可稍后手动执行 pi install npm:$pkg）"
            }
        }
    }

    # git 来源扩展（可选）：失败只警告，不阻塞
    $GitExtensionSources = @(
        "git:github.com/Blue-B/pi-custom-packages"
    )
    foreach ($src in $GitExtensionSources) {
        if (Should-Process "pi install $src") {
            Write-Host "  正在安装扩展: $src"
            & $piExe install $src 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Success "已安装: $src"
            } else {
                Write-Warn "安装失败（可忽略，属可选扩展）: $src"
            }
        }
    }

    if ($null -eq $prevAgentDir) { Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
    else { $env:PI_CODING_AGENT_DIR = $prevAgentDir }
}

# 自定义扩展目录：放自己写的 *.ts 扩展用，Pi 启动时会加载
$ExtensionsDir = "$PiHome\extensions"
if (Should-Process "创建扩展目录: $ExtensionsDir") {
    New-Item -ItemType Directory -Force -Path $ExtensionsDir | Out-Null
    Write-Success "已创建: $ExtensionsDir"
}

if (Test-Command "pip") {
    if ($SkipPythonDeps) {
        Write-Info "已指定 -SkipPythonDeps，跳过 Python 依赖安装"
    } elseif (Should-Process "pip install qdrant-client") {
        Write-Host "  正在安装 Python 依赖..."
        pip install qdrant-client 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Python 依赖安装完成"
        } else {
            Write-Warn "qdrant-client 安装失败，记忆管理功能将不可用"
        }
    }
} else {
    Write-Info "未找到 pip，跳过 Python 依赖（记忆管理功能需要 qdrant-client）"
}

# ============================================================
# 第 6 步: 启动 Qdrant（可选）
# ============================================================
if (-not $SkipQdrant) {
    $hasDocker = Test-Command "docker"
    if ($hasDocker) {
        Write-Step "第 6 步: 启动 Qdrant 向量库"

        $qdrantRunning = docker ps --filter name=qdrant --format "{{.Names}}" 2>&1
        if ($qdrantRunning -contains "qdrant") {
            Write-Success "Qdrant 已在运行"
        } else {
            Write-Host ""
            Write-Host "  正在准备 Qdrant 配置..."
            $composePath = "$DataDir\docker-compose.yml"

            $composeContent = @"
version: "3.8"
services:
  qdrant:
    image: docker.m.daocloud.io/qdrant/qdrant:latest
    container_name: qdrant
    ports:
      - "6333:6333"
      - "6334:6334"
    volumes:
      - ./qdrant_storage:/qdrant/storage
    restart: unless-stopped
"@
            if (Should-Process "写入 $composePath") {
                Set-Content -Path $composePath -Value $composeContent -Encoding UTF8
                Write-Success "已写入: $composePath"
            }

            Write-Host "  等待 Docker 就绪..."
            for ($i = 0; $i -lt 30; $i++) {
                $dockerInfo = docker info 2>&1
                if ($dockerInfo -notlike "*error*" -and $dockerInfo -notlike "*Connection refused*") { break }
                Start-Sleep -Seconds 2
            }

            if (Should-Process "docker compose up -d") {
                Push-Location $DataDir
                docker compose up -d 2>&1 | Out-Null
                $qdrantExit = $LASTEXITCODE
                Pop-Location

                if ($qdrantExit -eq 0) {
                    Write-Success "Qdrant 已启动"
                    Write-Host "  控制台: http://localhost:6333/dashboard"
                } else {
                    Write-Warn "Qdrant 启动失败，请确认 Docker Desktop 已运行"
                }
            }
        }
    } else {
        Write-Info "跳过 Qdrant（Docker 不可用；重启电脑后重跑本脚本即可）"
    }
}

# ============================================================
# 第 7 步: 验证安装
# ============================================================
Write-Step "第 7 步: 验证安装"

Write-Host ""

# 用脚本解析出的 pi 路径验证，而不是依赖 PATH
# 注意: 不要用 `| Select-Object -First 1` 取首行，它会提前掐断管道导致 $LASTEXITCODE 失真
$piVersion = $null
$piExit    = 1
if ($piExe) {
    $prevAgentDir7 = $env:PI_CODING_AGENT_DIR
    $env:PI_CODING_AGENT_DIR = $PiHome
    try {
        $verLines = @(& $piExe --version 2>&1)
        $piExit   = $LASTEXITCODE
        if ($verLines.Count -gt 0) { $piVersion = $verLines[0].ToString().Trim() }
    } catch {
        $piVersion = $null
        $piExit    = 1
    } finally {
        if ($null -eq $prevAgentDir7) { Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
        else { $env:PI_CODING_AGENT_DIR = $prevAgentDir7 }
    }
}

if ($piExit -eq 0 -and $piVersion) {
    Write-Success "Pi 版本: $piVersion"
} else {
    Write-Warn "Pi 命令不可用，请确认已安装 Pi（scripts\install-pi.ps1）"
}

if (Test-Path "$PiHome\settings.json") {
    Write-Success "配置文件已就位: $PiHome\settings.json"
} else {
    Write-Warn "未找到配置文件: $PiHome\settings.json"
}

if (Test-Command "docker") {
    try {
        $qdrantStatus = Invoke-WebRequest -Uri "http://localhost:6333/collections" -TimeoutSec 5 -UseBasicParsing
        if ($qdrantStatus.StatusCode -eq 200) {
            Write-Success "Qdrant 运行正常"
        } else {
            Write-Warn "Qdrant 状态异常"
        }
    } catch {
        Write-Info "Qdrant 未运行（可选；需要时执行 docker compose up -d 启动）"
    }
} else {
    Write-Info "Qdrant 未安装（可选）"
}

# ============================================================
# 第 7b 步: 安装 Ollama（本地 embedding，免费）
# ============================================================
Write-Step "第 7b 步: 安装 Ollama（本地 embedding）"
$ollamaScript = Join-Path $ScriptDir "install_ollama.ps1"
if ($SkipOllama) {
    Write-Info "已指定 -SkipOllama，跳过 Ollama 安装"
} elseif (Test-Path $ollamaScript) {
    if (Should-Process "运行 install_ollama.ps1") {
        # 用子进程调用：install_ollama.ps1 内部的 exit 不会带停本脚本
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ollamaScript
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Ollama 安装未成功（退出码 $LASTEXITCODE）。Ollama 属可选组件，不影响 Pi 主体功能"
            Write-Warn "可稍后手动重试: powershell -ExecutionPolicy Bypass -File scripts\install_ollama.ps1"
        }
    }
} else {
    Write-Info "未找到 install_ollama.ps1，跳过 Ollama 安装"
}

# ============================================================
# 第 7c 步: 提示配置 API Key
# ============================================================
Write-Step "第 7c 步: 配置 API Key"

$envExample = Join-Path $RepoRoot "config\settings.env.example"
if (Test-Path $envExample) {
    Write-Host ""
    Write-Host "  云端模型需要 API Key，本地 Ollama 部分无需密钥:" -ForegroundColor Yellow
    Write-Host "    Copy-Item config\settings.env.example config\settings.env" -ForegroundColor Yellow
    Write-Host "    notepad config\settings.env" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  申请地址:" -ForegroundColor Gray
    Write-Host "    - Agnes (Sapiens AI): https://api.sapiens.ai   免费额度" -ForegroundColor Gray
    Write-Host "    - 本地 Ollama: 无需 API Key（全免费）" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================
# 完成
# ============================================================
Write-Host ""
if ($script:PiInstallOk) {
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "           安装完成" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
} else {
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "    安装未完全成功：Pi 本体未装上" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  配置与规则已部署，但 pi 命令暂不可用。" -ForegroundColor Yellow
    Write-Host "  请解决上方报错后重试:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File scripts\install-pi.ps1" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  关键路径:" -ForegroundColor Gray
Write-Host "    Pi 配置: $PiHome"
Write-Host "    文档:    $DocsDir"
Write-Host "    脚本:    $ScriptsDir"
Write-Host "    日志:    $LogsDir"
Write-Host ""
Write-Host "  下一步:" -ForegroundColor Gray
Write-Host "    1. 运行 pi 启动会话"
Write-Host "    2. 阅读 $DocsDir\AGENTS.md"
Write-Host "    3. 初始化记忆库: python $ScriptsDir\memory_manager.py init"
Write-Host ""

# Pi 本体没装上时以非零退出码结束，让自动化判装能发现失败
if (-not $script:PiInstallOk) { exit 1 }
