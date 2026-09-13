# Pi-Work-Mode 安装流程测试（干跑）
#
# 与 tests\verify.ps1 的分工:
#   verify.ps1       —— 静态检查: 运行环境、配置文件、脚本编码、隐私痕迹
#   test_install.ps1 —— 动态检查: 真跑 setup.ps1 的 -DryRun，验证安装流程本身
#
# 用法:
#   powershell -ExecutionPolicy Bypass -File tests\test_install.ps1
#
# 全程使用 -DryRun，不会对系统产生任何实际改动。
# 全部通过时退出码 0，否则 1。

$ErrorActionPreference = "Continue"

$RepoRoot  = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$SetupPath = Join-Path $RepoRoot "scripts\setup.ps1"
$PiHome    = Join-Path $env:USERPROFILE ".pi\agent"

$script:Passed  = 0
$script:Failed  = 0
$script:Skipped = 0

# 注意: 函数参数名不能与调用方闭包里用到的变量同名
# （PowerShell 变量名不区分大小写，$Title 与 $title 是同一个变量）
function Test-Item {
    param(
        [string]$ItemTitle,
        [scriptblock]$Body
    )

    $outcome = $null
    try {
        $outcome = & $Body
    } catch {
        Write-Host "  [失败] $ItemTitle" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:Failed++
        return
    }

    if ($outcome -eq $true) {
        Write-Host "  [通过] $ItemTitle" -ForegroundColor Green
        $script:Passed++
    } elseif ($outcome -eq "skip") {
        Write-Host "  [跳过] $ItemTitle" -ForegroundColor DarkGray
        $script:Skipped++
    } else {
        Write-Host "  [失败] $ItemTitle" -ForegroundColor Red
        $script:Failed++
    }
}

# 独立子进程调用 setup.ps1 的干跑模式，避免污染当前会话
function Invoke-SetupDryRun {
    param([string[]]$ExtraArgs = @())

    $tmpDir = Join-Path $env:TEMP ("pi-dryrun-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $callArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $SetupPath,
        "-DataDir", $tmpDir,
        "-DryRun"
    ) + $ExtraArgs

    $text = (& powershell @callArgs 2>&1 | Out-String)
    return [pscustomobject]@{
        Output   = $text
        ExitCode = $LASTEXITCODE
        DataDir  = $tmpDir
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Pi-Work-Mode 安装流程测试（干跑）" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  仓库位置: $RepoRoot" -ForegroundColor Gray

# ------------------------------------------------------------
Write-Host ""
Write-Host "脚本静态检查" -ForegroundColor Yellow

Test-Item "scripts\setup.ps1 存在" {
    return (Test-Path $SetupPath)
}

Test-Item "setup.ps1 语法正确" {
    if (-not (Test-Path $SetupPath)) { return $false }
    $null = [scriptblock]::Create((Get-Content $SetupPath -Raw))
    return $true
}

Test-Item "Node 版本解析不再使用被插值的双引号替换" {
    if (-not (Test-Path $SetupPath)) { return $false }
    $src = Get-Content $SetupPath -Raw
    # 原版致命 bug: -replace "v(\d+)\..*", "$1"
    # PowerShell 会把 "$1" 当成变量插值展开成空串，导致版本号永远解析为 0
    if ($src -match '\$1"') {
        Write-Host '         检测到 $1 出现在双引号内，会被 PowerShell 插值成空串' -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "settings.json 采用合并写入（不覆盖 Pi 原有配置）" {
    if (-not (Test-Path $SetupPath)) { return $false }
    $src = Get-Content $SetupPath -Raw
    # 必须是「读出原有键 -> 合并 pi 块 -> 写回」，而不是直接覆盖，
    # 否则会把 Pi 自己的 theme / lastChangelogVersion 等键抹掉。
    $hasMerge  = $src -match '\$merged\["pi"\]'
    $hasBackup = $src -match '\.bak-\$\(Get-Date'
    $hasTpl    = $src -match '\$tpl\.dataDir'
    return ($hasMerge -and $hasBackup -and $hasTpl)
}

Test-Item "规则文档部署到 Pi 主目录（否则规则不生效）" {
    if (-not (Test-Path $SetupPath)) { return $false }
    $src = Get-Content $SetupPath -Raw
    # Pi 只从 ~/.pi/agent/ 加载 AGENTS.md，只复制进数据目录等于没装
    return ($src.Contains('Join-Path $PiHome $rule') -and $src.Contains('"AGENTS.md"'))
}

Test-Item "UAC 提权参数透传已保留" {
    if (-not (Test-Path $SetupPath)) { return $false }
    $src = Get-Content $SetupPath -Raw
    return ($src -match 'elevateArgs' -and $src -match '\-SkipQdrant')
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "干跑执行" -ForegroundColor Yellow

$dry = Invoke-SetupDryRun

Test-Item "setup.ps1 -DryRun 退出码为 0" {
    if ($dry.ExitCode -ne 0) {
        Write-Host "         实际退出码: $($dry.ExitCode)" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "干跑覆盖第 0 至第 7 步全部流程" {
    $missing = @()
    foreach ($marker in @("第 0 步", "第 1 步", "第 2 步", "第 3 步", "第 4 步", "第 5 步", "第 7 步")) {
        if ($dry.Output -notmatch [regex]::Escape($marker)) { $missing += $marker }
    }
    if ($missing.Count -gt 0) {
        Write-Host "         缺少步骤: $($missing -join ', ')" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "干跑模式确实生效（出现 [干跑] 标记）" {
    return ($dry.Output -match '\[干跑\]')
}

Test-Item "干跑中 settings.json 走合并路径" {
    if ($dry.Output -notmatch [regex]::Escape('合并 config\settings.json')) {
        Write-Host "         未看到合并提示，可能仍在直接覆盖" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "干跑中包含规则文档部署" {
    if ($dry.Output -notmatch [regex]::Escape('部署规则文档 AGENTS.md')) {
        Write-Host "         未看到规则文档部署，Pi 可能加载不到规则" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "干跑全程无失败输出" {
    if ($dry.Output -match '\[失败\]') {
        $lines = ($dry.Output -split "`r?`n" | Select-String -Pattern '\[失败\]' | Select-Object -First 3)
        foreach ($l in $lines) { Write-Host "         $($l.ToString().Trim())" -ForegroundColor Gray }
        return $false
    }
    return $true
}

Test-Item "-DataDir 参数被正确接收" {
    if ($dry.Output -notmatch [regex]::Escape($dry.DataDir)) {
        Write-Host "         输出中未回显: $($dry.DataDir)" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "干跑未修改真实 Pi 主目录" {
    $existedBefore = Test-Path $PiHome
    $null = Invoke-SetupDryRun
    $existsAfter = Test-Path $PiHome
    if ($existedBefore -ne $existsAfter) {
        Write-Host "         $PiHome 的存在状态发生了变化" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "重复干跑具备幂等性" {
    $again = Invoke-SetupDryRun
    if ($again.ExitCode -ne 0) {
        Write-Host "         第二次退出码: $($again.ExitCode)" -ForegroundColor Gray
        return $false
    }
    return $true
}

Test-Item "-SkipQdrant 参数可正常接受" {
    $skipRun = Invoke-SetupDryRun -ExtraArgs @("-SkipQdrant")
    if ($skipRun.ExitCode -ne 0) {
        Write-Host "         退出码: $($skipRun.ExitCode)" -ForegroundColor Gray
        return $false
    }
    return $true
}

# ------------------------------------------------------------
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  通过 $script:Passed 项 / 跳过 $script:Skipped 项 / 失败 $script:Failed 项" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($script:Failed -gt 0) {
    Write-Host "安装流程测试未全部通过。" -ForegroundColor Red
    exit 1
}

Write-Host "安装流程测试全部通过。" -ForegroundColor Green
exit 0
