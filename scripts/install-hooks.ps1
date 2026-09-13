<#
  Pi-Work-Mode 本地钩子安装脚本

  作用: 把本仓库的 git 钩子目录指向 .githooks/，让每次 git commit 之前自动运行
  tests\verify.ps1 的静态检查 —— 相当于把 GitHub 上的 CI 搬到本地执行。

  用法:
    powershell -ExecutionPolicy Bypass -File scripts\install-hooks.ps1
    powershell -ExecutionPolicy Bypass -File scripts\install-hooks.ps1 -Uninstall

  说明:
    - 只写仓库级配置（.git/config），不使用 --global，不影响其他仓库
    - 幂等，可重复运行
    - 临时跳过检查: git commit --no-verify
    - 卸载: -Uninstall，或手动 git config --unset core.hooksPath
#>

param(
    [switch]$Uninstall
)

$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$RepoRoot  = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent
$HooksPath = ".githooks"
$HookFile  = "pre-commit"

function Write-Ok   { param([string]$Text) Write-Host "  [完成] $Text" -ForegroundColor Green }
function Write-Err  { param([string]$Text) Write-Host "  [失败] $Text" -ForegroundColor Red }
function Write-Note { param([string]$Text) Write-Host "         $Text" -ForegroundColor Gray }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Pi-Work-Mode 本地钩子安装" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  仓库位置: $RepoRoot" -ForegroundColor Gray
Write-Host ""

$failed = $false

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "未找到 git 命令"
        $failed = $true
    }
    else {
        & git rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Err "当前目录不是 git 仓库"
            $failed = $true
        }
        elseif ($Uninstall) {
            $current = (& git config --get core.hooksPath) 2>$null
            if ([string]::IsNullOrWhiteSpace($current)) {
                Write-Note "当前未配置 core.hooksPath，无需卸载"
            }
            else {
                & git config --unset core.hooksPath
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "已取消 core.hooksPath（原值 $current）"
                } else {
                    Write-Err "取消 core.hooksPath 失败"
                    $failed = $true
                }
            }
        }
        else {
            $hookRel  = Join-Path $HooksPath $HookFile
            if (-not (Test-Path $hookRel)) {
                Write-Err "未找到 $hookRel"
                $failed = $true
            }
            else {
                & git config core.hooksPath $HooksPath
                if ($LASTEXITCODE -ne 0) {
                    Write-Err "写入 core.hooksPath 失败"
                    $failed = $true
                }
                else {
                    $applied = (& git config --get core.hooksPath) 2>$null
                    if ($applied -eq $HooksPath) {
                        Write-Ok "core.hooksPath = $applied（仓库级，仅对本仓库生效）"
                    } else {
                        Write-Err "配置回读值不符（读到 $applied）"
                        $failed = $true
                    }
                }
            }
        }
    }
}
finally {
    Pop-Location
}

Write-Host ""
if ($failed) {
    Write-Host "安装未完成，请按上方提示处理。" -ForegroundColor Red
    exit 1
}

if ($Uninstall) {
    Write-Host "已卸载。git commit 不再触发本地检查。" -ForegroundColor Green
}
else {
    Write-Host "安装完成。" -ForegroundColor Green
    Write-Host ""
    Write-Note "每次 git commit 前自动运行 tests\verify.ps1 -SkipServices（约 2 秒）"
    Write-Note "检查不通过会中止提交；临时跳过用: git commit --no-verify"
    Write-Note "查看当前配置: git config --get core.hooksPath"
}
exit 0
