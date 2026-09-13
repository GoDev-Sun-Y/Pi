# Pi-Work-Mode 安装验证脚本
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tests\verify.ps1
#   powershell -ExecutionPolicy Bypass -File tests\verify.ps1 -SkipServices
#   或 npm run verify
#
# 只读检查，不会修改任何文件。全部通过时退出码为 0。
#
# 参数:
#   -SkipServices  跳过 Qdrant / Ollama 连通性探测（约省 6 秒）。
#                  供 git pre-commit 钩子使用: 提交时不需要知道服务在不在跑。

param(
    [switch]$SkipServices
)

# 输出编码统一为 UTF-8。在 Git Bash 与 CI 环境中，如果沿用系统 ANSI 代码页，
# 脚本里的中文提示会显示成乱码。设置失败不影响检查结果，所以只做兜底。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = "Continue"

$RepoRoot = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent

$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0

# 注意: 函数参数名不能与调用方闭包里用到的变量同名
# （PowerShell 变量名不区分大小写，$Title 与 $title 是同一个变量）
function Test-Item {
    param(
        [string]$Title,
        [scriptblock]$Body
    )

    $outcome = $null
    try {
        $outcome = & $Body
    } catch {
        Write-Host "  [失败] $Title" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:Failed++
        return
    }

    if ($outcome -eq $true) {
        Write-Host "  [通过] $Title" -ForegroundColor Green
        $script:Passed++
    } elseif ($outcome -eq "skip") {
        Write-Host "  [跳过] $Title" -ForegroundColor DarkGray
        $script:Skipped++
    } else {
        Write-Host "  [失败] $Title" -ForegroundColor Red
        $script:Failed++
    }
}

function Get-FirstLine {
    param([scriptblock]$Body)
    $output = & $Body 2>&1 | Select-Object -First 1
    if ($null -eq $output) { return "" }
    return $output.ToString().Trim()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Pi-Work-Mode 安装验证" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  仓库位置: $RepoRoot" -ForegroundColor Gray

# ------------------------------------------------------------
Write-Host ""
Write-Host "运行环境" -ForegroundColor Yellow

Test-Item "Git 已安装" {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    Write-Host "         $(Get-FirstLine { git --version })" -ForegroundColor Gray
    return $true
}

Test-Item "Node.js >= 22.19.0" {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { return $false }
    $ver = Get-FirstLine { node --version }
    if ($ver -match 'v?(\d+)\.(\d+)') {
        Write-Host "         $ver" -ForegroundColor Gray
        $maj = [int]$Matches[1]; $min = [int]$Matches[2]
        return (($maj -gt 22) -or ($maj -eq 22 -and $min -ge 19))
    }
    return $false
}

Test-Item "Python 已安装" {
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) { return $false }
    Write-Host "         $(Get-FirstLine { python --version })" -ForegroundColor Gray
    return $true
}

Test-Item "Docker 已安装（可选）" {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return "skip" }
    Write-Host "         $(Get-FirstLine { docker --version })" -ForegroundColor Gray
    return $true
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "配置文件" -ForegroundColor Yellow

foreach ($relPath in @("config\settings.json", "config\models-store.json", "config\presets.json", "package.json")) {
    Test-Item "$relPath 是合法 JSON" {
        $full = Join-Path $RepoRoot $relPath
        if (-not (Test-Path $full)) { return $false }
        $null = Get-Content $full -Raw -Encoding UTF8 | ConvertFrom-Json
        return $true
    }
}

Test-Item "config\presets.json 引用的工具名无笔误" {
    $full = Join-Path $RepoRoot "config\presets.json"
    if (-not (Test-Path $full)) { return $false }
    # 已知工具名：8 个内置 + 已确认的扩展工具名。
    # 注意：本项只能拦截拼写错误，不能证明扩展工具一定存在
    # （扩展未安装时 Pi 的 applyPreset 会自动过滤并提示，属预期行为）。
    $known = @(
        "read", "bash", "powershell", "edit", "write", "grep", "find", "ls",
        "web_search", "web_fetch",
        "gui_read", "gui_click", "gui_right_click", "gui_double_click", "gui_hover",
        "gui_drag", "gui_scroll", "gui_type", "gui_keypress", "gui_hotkey", "gui_batch",
        "ctx_read", "ctx_shell", "ctx_search", "ctx_glob"
    )
    $cfg = Get-Content $full -Raw -Encoding UTF8 | ConvertFrom-Json
    $unknown = @()
    foreach ($presetName in $cfg.PSObject.Properties.Name) {
        $tools = $cfg.$presetName.tools
        if ($tools) {
            foreach ($t in $tools) {
                if ($known -notcontains $t) { $unknown += "$presetName/$t" }
            }
        }
    }
    $count = @($cfg.PSObject.Properties.Name).Count
    if ($unknown.Count -gt 0) {
        Write-Host "         未知工具名: $($unknown -join ', ')" -ForegroundColor Gray
        return $false
    }
    Write-Host "         $count 个预设，工具名全部有效" -ForegroundColor Gray
    return $true
}

Test-Item "docker\docker-compose.yml 结构完整" {
    $full = Join-Path $RepoRoot "docker\docker-compose.yml"
    if (-not (Test-Path $full)) { return $false }
    $text = Get-Content $full -Raw
    return ($text -match "services:" -and $text -match "qdrant:")
}

Test-Item "version.txt 版本号格式正确" {
    $full = Join-Path $RepoRoot "version.txt"
    if (-not (Test-Path $full)) { return $false }
    $ver = (Get-Content $full -Raw).Trim()
    if ($ver -match '^\d+\.\d+\.\d+$') {
        Write-Host "         $ver" -ForegroundColor Gray
        return $true
    }
    Write-Host "         实际内容: '$ver'（应为 x.y.z）" -ForegroundColor Gray
    return $false
}

Test-Item "必需目录与文件齐全" {
    $missing = @()
    foreach ($item in @("config", "docs", "scripts", "tests", "templates", "extensions", "README.md", "version.txt",
                        "scripts\setup.ps1", "scripts\install-pi.ps1", "tests\verify.ps1",
                        "extensions\preset.ts", "config\presets.json")) {
        if (-not (Test-Path (Join-Path $RepoRoot $item))) { $missing += $item }
    }
    if ($missing.Count -gt 0) {
        Write-Host "         缺少: $($missing -join ', ')" -ForegroundColor Gray
        return $false
    }
    return $true
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "脚本可解析" -ForegroundColor Yellow

foreach ($relPath in @("scripts\setup.ps1", "scripts\install_ollama.ps1", "scripts\install-pi.ps1")) {
    Test-Item "$relPath 语法正确" {
        $full = Join-Path $RepoRoot $relPath
        if (-not (Test-Path $full)) { return $false }
        $null = [scriptblock]::Create((Get-Content $full -Raw))
        return $true
    }
}

foreach ($relPath in @("tests\test_memory_search.py", "scripts\memory_manager.py")) {
    Test-Item "$relPath 语法正确" {
        $full = Join-Path $RepoRoot $relPath
        if (-not (Test-Path $full)) { return $false }
        if (-not (Get-Command python -ErrorAction SilentlyContinue)) { return "skip" }
        & python -m py_compile $full
        return ($LASTEXITCODE -eq 0)
    }
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "编码与隐私" -ForegroundColor Yellow

Test-Item "含中文的 PowerShell 脚本已保存为 UTF-8 BOM" {
    $missing = @()
    foreach ($relPath in @("scripts\setup.ps1", "scripts\install_ollama.ps1", "scripts\install-pi.ps1", "scripts\install-hooks.ps1", "tests\verify.ps1", "tests\test_install.ps1")) {
        $full = Join-Path $RepoRoot $relPath
        if (-not (Test-Path $full)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if (($text -match '[\u4e00-\u9fff]') -and -not $hasBom) { $missing += (Split-Path $relPath -Leaf) }
    }
    if ($missing.Count -gt 0) {
        Write-Host "         缺少 BOM: $($missing -join ', ')" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "git 钩子脚本为 LF 行尾且无 BOM" {
    $hookFull = Join-Path $RepoRoot ".githooks\pre-commit"
    if (-not (Test-Path $hookFull)) { return "skip" }
    $bytes = [System.IO.File]::ReadAllBytes($hookFull)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasCr = $false
    foreach ($byte in $bytes) { if ($byte -eq 0x0D) { $hasCr = $true; break } }
    if ($hasBom) { Write-Host "         含 BOM: sh 会把 BOM 当成命令名" -ForegroundColor Gray }
    if ($hasCr)  { Write-Host "         含 CR: sh 会把 \r 当成命令名的一部分" -ForegroundColor Gray }
    return (-not $hasBom -and -not $hasCr)
}

Test-Item "源码中无硬编码个人路径" {
    $pattern = '[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.\u4e00-\u9fff-]+'
    $hits = @()
    $files = Get-ChildItem -Path $RepoRoot -Recurse -Include *.md, *.ps1, *.py, *.json -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -notmatch '\\tests\\' -and $_.FullName -notmatch '\\\.git\\' }
    foreach ($f in $files) {
        $text = Get-Content $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $text) { continue }
        foreach ($m in [regex]::Matches($text, $pattern)) { $hits += "$($f.Name): $($m.Value)" }
    }
    if ($hits.Count -gt 0) {
        foreach ($h in ($hits | Select-Object -Unique)) { Write-Host "         $h" -ForegroundColor Gray }
        return $false
    }
    return $true
}

# ------------------------------------------------------------
Write-Host ""
if ($SkipServices) {
    Write-Host "运行时服务（已跳过，-SkipServices）" -ForegroundColor DarkGray
} else {
    Write-Host "运行时服务（可选）" -ForegroundColor Yellow

    Test-Item "Qdrant 可访问" {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:6333/collections" -TimeoutSec 3 -UseBasicParsing
            return ($resp.StatusCode -eq 200)
        } catch {
            return "skip"
        }
    }

    Test-Item "Ollama 可访问" {
        try {
            $resp = Invoke-WebRequest -Uri "http://localhost:11434/api/version" -TimeoutSec 3 -UseBasicParsing
            return ($resp.StatusCode -eq 200)
        } catch {
            return "skip"
        }
    }
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  通过 $script:Passed 项 / 跳过 $script:Skipped 项 / 失败 $script:Failed 项" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($script:Failed -gt 0) {
    Write-Host "存在未通过项，请按上方提示修复。" -ForegroundColor Red
    exit 1
}

Write-Host "全部检查通过。" -ForegroundColor Green
exit 0
