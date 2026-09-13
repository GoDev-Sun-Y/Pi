# Pi-Work-Mode - Pi 本体一键安装脚本
# 版本: v1.0.1
#
# 用途: 把 Pi 本体（@earendil-works/pi-coding-agent）装到指定目录，并生成可直接运行的启动器。
#
# 设计原则:
#   默认装到 <仓库>\.pi-runtime\ —— 自包含。不写全局 npm 目录、不改 PATH、不动用户主目录。
#   需要全局可用时加 -Global（等价于官方 npm install -g 方式）。
#
# 用法:
#   .\scripts\install-pi.ps1                          默认装到 <仓库>\.pi-runtime
#   .\scripts\install-pi.ps1 -InstallDir "D:\Pi"      装到指定目录
#   .\scripts\install-pi.ps1 -Global                  装到 npm 全局目录（官方方式）
#   .\scripts\install-pi.ps1 -Version 0.85.1          钉死版本
#   .\scripts\install-pi.ps1 -Force                   已装也重装
#   .\scripts\install-pi.ps1 -DryRun                  干跑预览，不做任何改动
#   .\scripts\install-pi.ps1 -Uninstall               卸载（删除安装目录或全局包）
#
# 说明:
#   1) npm 的 -g --prefix <dir> 会在 <dir> 下生成 node_modules 与 pi / pi.cmd / pi.ps1 三个
#      标准启动器，路径全部相对定位，不硬编码，可直接整体拷贝到别的机器。
#   2) 本脚本刻意不做 UAC 自动提权。权限不足时直接报错并给出手动方案，
#      避免在用户不知情的情况下改写系统级路径。
#   3) 验证时会把 PI_CODING_AGENT_DIR 指向临时目录，绝不在 ~\.pi\agent 留痕。

param(
    [string]$InstallDir,
    [string]$Version = "latest",
    [string]$AgentDir,
    [switch]$Global,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Uninstall,
    # 默认跑完停在最后等用户看完；被 setup.ps1 调用时会传 -NoPause
    [switch]$NoPause
)

$ErrorActionPreference = "Continue"

# 引入公共函数（暂停/下载）
. (Join-Path $PSScriptRoot "common.ps1")

$PackageName   = "@earendil-works/pi-coding-agent"
$PackageDirRel = "node_modules\@earendil-works\pi-coding-agent"
$EntryRel      = "dist\bundle\cli.js"

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
function Write-Success { param([string]$Message) Write-Host "  [OK] $Message"   -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "  [警告] $Message" -ForegroundColor Yellow }
function Write-Failure { param([string]$Message) Write-Host "  [失败] $Message" -ForegroundColor Red }
function Write-Info    { param([string]$Message) Write-Host "  [信息] $Message" -ForegroundColor Blue }

function Test-Command {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

# ============================================================
# 第 0 步: 确认安装位置
# ============================================================
Write-Step "第 0 步: 确定安装位置"

if ($Global) {
    if (-not (Test-Command "npm")) {
        Write-Failure "未找到 npm，无法安装。请先安装 Node.js（>= 22.19.0）"
        exit 1
    }
    $npmGlobalRoot = (& npm root -g 2>&1 | Select-Object -First 1).ToString().Trim()
    $targetPkgDir  = Join-Path $npmGlobalRoot "@earendil-works\pi-coding-agent"
    $launcherDir   = Split-Path $npmGlobalRoot -Parent
    $piExe         = "pi"
    Write-Host ""
    Write-Host "  安装模式: 全局" -ForegroundColor Cyan
    Write-Host "  包目录:   $targetPkgDir" -ForegroundColor Cyan
} else {
    if (-not $InstallDir) {
        $InstallDir = Join-Path $RepoRoot ".pi-runtime"
    }
    $InstallDir   = $InstallDir.TrimEnd("\").TrimEnd("/")
    $targetPkgDir = Join-Path $InstallDir $PackageDirRel
    $launcherDir  = $InstallDir
    $piExe        = Join-Path $InstallDir "pi.cmd"
    Write-Host ""
    Write-Host "  安装模式: 自包含（仓库内，不碰全局目录与 PATH）" -ForegroundColor Cyan
    Write-Host "  安装目录: $InstallDir" -ForegroundColor Cyan
}

$targetEntry = Join-Path $targetPkgDir $EntryRel

# ============================================================
# 卸载分支
# ============================================================
if ($Uninstall) {
    Write-Step "卸载 Pi"
    if ($Global) {
        if ($DryRun) { Write-Host "  [干跑] npm uninstall -g $PackageName" -ForegroundColor DarkGray }
        else {
            npm uninstall -g $PackageName 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Success "已从全局卸载 $PackageName" }
            else { Write-Failure "卸载失败（退出码 $LASTEXITCODE）" }
        }
    } else {
        if (Test-Path $InstallDir) {
            if ($DryRun) { Write-Host "  [干跑] 删除目录: $InstallDir" -ForegroundColor DarkGray }
            else {
                Remove-Item -LiteralPath $InstallDir -Recurse -Force
                Write-Success "已删除安装目录: $InstallDir"
            }
        } else {
            Write-Info "安装目录不存在，无需卸载: $InstallDir"
        }
    }
    Write-Host ""
    Write-Host "  注意: 配置文件目录不受影响（默认 ~\.pi\agent），需要时手动删除。" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# ============================================================
# 第 1 步: 检测环境
# ============================================================
Write-Step "第 1 步: 检测环境"

if (-not (Test-Command "node")) {
    Write-Failure "未找到 Node.js。Pi 需要 Node.js >= 22.19.0"
    Write-Host "    安装: winget install OpenJS.NodeJS.LTS   或   https://nodejs.org/" -ForegroundColor Yellow
    exit 1
}

$nodeVer = (& node --version 2>&1 | Select-Object -First 1).ToString().Trim()
# 注意: -replace 的替换模板必须用单引号，双引号里的 $1 会被 PowerShell 展开成空串
if ($nodeVer -match 'v?(\d+)\.(\d+)\.') {
    $nodeMajor = [int]$Matches[1]
    $nodeMinor = [int]$Matches[2]
} else {
    $nodeMajor = 0
    $nodeMinor = 0
}

$nodeOk = ($nodeMajor -gt 22) -or (($nodeMajor -eq 22) -and ($nodeMinor -ge 19))
if ($nodeOk) {
    Write-Success "Node.js: $nodeVer"
} else {
    Write-Failure "Node.js 版本过低: $nodeVer（Pi 要求 >= 22.19.0）"
    exit 1
}

if (-not (Test-Command "npm")) {
    Write-Failure "未找到 npm（通常随 Node.js 一起安装）"
    exit 1
}
Write-Success "npm: $(& npm --version 2>&1)"

# ============================================================
# 第 2 步: 检查已有安装
# ============================================================
Write-Step "第 2 步: 检查已有安装"

$alreadyInstalled = Test-Path $targetEntry
$installedVersion = "未知"

if ($alreadyInstalled) {
    $pkgJson = Join-Path $targetPkgDir "package.json"
    if (Test-Path $pkgJson) {
        try {
            $installedVersion = (Get-Content $pkgJson -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } catch { $installedVersion = "未知" }
    }
    Write-Info "检测到已安装: 版本 $installedVersion"
    Write-Info "位置: $targetPkgDir"
} else {
    Write-Info "未检测到 Pi 安装，将执行全新安装"
}

$skipInstall = $false
if ($alreadyInstalled -and -not $Force) {
    if ($Version -ne "latest" -and $installedVersion -ne $Version) {
        Write-Info "已装版本($installedVersion) 与指定版本($Version) 不一致，执行安装"
    } else {
        Write-Success "已安装且未指定 -Force，跳过下载"
        $skipInstall = $true
    }
}

# ============================================================
# 第 3 步: 安装
# ============================================================
if (-not $skipInstall) {
    Write-Step "第 3 步: 安装 Pi 本体"

    if ($Version -eq "latest") { $pkgSpec = $PackageName } else { $pkgSpec = "$PackageName@$Version" }

    if ($Global) {
        $npmArgs = @("install", "-g", "--ignore-scripts", "--no-fund", "--no-audit", $pkgSpec)
    } else {
        if (-not (Test-Path $InstallDir)) {
            if ($DryRun) { Write-Host "  [干跑] 创建目录: $InstallDir" -ForegroundColor DarkGray }
            else {
                New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
                Write-Success "已创建安装目录: $InstallDir"
            }
        }
        # -g 与 --prefix 必须同时给：只有 -g 才会在 prefix 下生成 pi / pi.cmd / pi.ps1 启动器
        $npmArgs = @("install", "-g", "--prefix", $InstallDir, "--ignore-scripts", "--no-fund", "--no-audit", $pkgSpec)
    }

    $cmdLine = "npm " + ($npmArgs -join " ")

    if ($DryRun) {
        Write-Host "  [干跑] $cmdLine" -ForegroundColor DarkGray
    } else {
        Write-Host "  执行: $cmdLine" -ForegroundColor Gray
        Write-Host "  正在下载并安装（首次约需 1-6 分钟，取决于网络）..." -ForegroundColor Gray

        & npm @npmArgs 2>&1 | Out-Null
        $npmExit = $LASTEXITCODE

        if ($npmExit -ne 0) {
            Write-Failure "npm 安装失败（退出码 $npmExit）"
            Write-Host ""
            Write-Host "  常见原因与处理:" -ForegroundColor Yellow
            Write-Host "    - 网络慢/超时:    npm config set registry https://registry.npmmirror.com" -ForegroundColor Gray
            Write-Host "    - 权限不足:       换用默认的仓库内安装（去掉 -Global），或用管理员终端重试" -ForegroundColor Gray
            Write-Host "    - 版本不存在:     检查 -Version 参数，不填即为 latest" -ForegroundColor Gray
            Write-Host ""
            exit 1
        }
        Write-Success "npm 安装完成"
    }
}

# ============================================================
# 第 4 步: 核对启动器
# ============================================================
if (-not $DryRun) {
    Write-Step "第 4 步: 核对启动器"

    if (-not $Global) {
        $shims = @("pi.cmd", "pi.ps1", "pi")
        $found = 0
        foreach ($s in $shims) {
            $p = Join-Path $launcherDir $s
            if (Test-Path $p) {
                Write-Success "启动器就位: $s"
                $found++
            } else {
                Write-Warn "未生成启动器: $s（不影响通过 node 直接调用）"
            }
        }
        if ($found -eq 0) {
            Write-Warn "npm 未生成任何启动器，可用 node 直接运行："
            Write-Host "    node `"$targetEntry`"" -ForegroundColor Gray
        }
    } else {
        Write-Info "全局模式由 npm 管理启动器，跳过检查"
    }
}

# ============================================================
# 第 5 步: 验证
# ============================================================
Write-Step "第 5 步: 验证安装"

if ($DryRun) {
    Write-Host "  [干跑] 跳过验证" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

if (-not (Test-Path $targetEntry)) {
    Write-Failure "安装入口不存在: $targetEntry"
    exit 1
}
Write-Success "入口文件就位: $EntryRel"

# 验证时必须隔离配置目录，否则 pi 启动会在 ~\.pi\agent 留痕
$verifyAgentDir = $AgentDir
$tmpVerifyDir   = $null
if (-not $verifyAgentDir) {
    $tmpVerifyDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("pi-verify-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
    $verifyAgentDir = $tmpVerifyDir
}

$oldAgentDir = $env:PI_CODING_AGENT_DIR
$oldOffline  = $env:PI_OFFLINE
$env:PI_CODING_AGENT_DIR   = $verifyAgentDir
$env:PI_OFFLINE            = "1"
$env:PI_SKIP_VERSION_CHECK = "1"
$env:PI_TELEMETRY          = "0"

try {
    $verLines = @(& node $targetEntry --version 2>&1)
    $verExit  = $LASTEXITCODE
    $verOut   = ($verLines -join " ").Trim()
    if ($verExit -eq 0 -and $verOut) {
        Write-Success "Pi 可执行，版本: $verOut"
    } else {
        Write-Warn "pi --version 返回异常（退出码 $verExit）: $verOut"
    }
} catch {
    Write-Failure "执行验证失败: $_"
} finally {
    if ($null -eq $oldAgentDir) { Remove-Item Env:\PI_CODING_AGENT_DIR -ErrorAction SilentlyContinue }
    else { $env:PI_CODING_AGENT_DIR = $oldAgentDir }
    if ($null -eq $oldOffline) { Remove-Item Env:\PI_OFFLINE -ErrorAction SilentlyContinue }
    else { $env:PI_OFFLINE = $oldOffline }
    Remove-Item Env:\PI_SKIP_VERSION_CHECK -ErrorAction SilentlyContinue
    Remove-Item Env:\PI_TELEMETRY -ErrorAction SilentlyContinue
    if ($tmpVerifyDir -and (Test-Path $tmpVerifyDir)) { Remove-Item -LiteralPath $tmpVerifyDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ============================================================
# 完成
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "           Pi 安装完成" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

if ($Global) {
    Write-Host "  调用方式: pi" -ForegroundColor Gray
} else {
    Write-Host "  调用方式:" -ForegroundColor Gray
    Write-Host "    CMD:         $InstallDir\pi.cmd" -ForegroundColor Gray
    Write-Host "    PowerShell:  $InstallDir\pi.ps1" -ForegroundColor Gray
    Write-Host "    Git Bash:    $InstallDir/pi" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  提示: 把 $InstallDir 加入 PATH 即可直接使用 pi 命令。" -ForegroundColor Gray
    Write-Host "        （本脚本不会自动修改 PATH）" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  下一步:" -ForegroundColor Gray
Write-Host "    1. 运行 scripts\setup.ps1 部署工作模式配置与规则" -ForegroundColor Gray
Write-Host "    2. 配置模型 API Key（见 config\settings.env.example）" -ForegroundColor Gray
Write-Host ""

# 停在这里，让你看清安装结果与下一步指引（被 setup.ps1 调用时不暂停）
if (-not $NoPause) { Stop-ForReview }
