# install_ollama.ps1 - Ollama 一键安装 + 默认 embedding 模型
# 用法: 在 Windows 上以管理员身份运行  powershell -ExecutionPolicy Bypass -File scripts\install_ollama.ps1

$ErrorActionPreference = "Stop"

function Write-Success { param([string]$m) Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Info    { param([string]$m) Write-Host "  [INFO] $m" -ForegroundColor Blue }
function Write-ErrorCustom { param([string]$m) Write-Host "  [ERROR] $m" -ForegroundColor Red }

# 1. 检测是否已安装
$ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($ollamaCmd) {
    Write-Success "Ollama 已安装: $($ollamaCmd.Source)"
} else {
    Write-Info "下载 Ollama 安装包..."
    $url = "https://ollama.com/download/OllamaSetup.exe"
    $tmp = "$env:TEMP\OllamaSetup.exe"
    Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    Write-Info "安装 Ollama (静默)..."
    Start-Process $tmp -ArgumentList "/quiet" -Wait
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollamaCmd) {
        Write-Success "Ollama 安装完成"
    } else {
        Write-ErrorCustom "安装后 ollama 命令仍不可用，请重启电脑后再试"
        exit 1
    }
}

# 2. 检查 Ollama 服务是否运行
$serverOk = $false
try {
    $r = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -TimeoutSec 3
    Write-Success "Ollama 服务运行中 (v$($r.version))"
    $serverOk = $true
} catch {
    Write-Info "Ollama 服务未启动，尝试启动..."
    # 注意：可执行文件名是 ollama，serve 是参数；写成 "Ollama serve" 整串会被当作文件名而启动失败
    Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
    Start-Sleep -Seconds 5
    try {
        $r = Invoke-RestMethod -Uri "http://localhost:11434/api/version" -TimeoutSec 3
        Write-Success "Ollama 服务已启动 (v$($r.version))"
        $serverOk = $true
    } catch {
        Write-ErrorCustom "Ollama 服务启动失败，请手动运行 'Ollama serve'"
        exit 1
    }
}

# 3. 拉取 embedding 模型 (按需)
$models = @("all-minilm:33m")
foreach ($m in $models) {
    Write-Info "检查模型: $m ..."
    $list = & ollama list 2>&1 | Out-String
    if ($list -match [regex]::Escape($m)) {
        Write-Success "模型 $m 已存在"
    } else {
        Write-Info "拉取模型 $m (约 67MB)..."
        & ollama pull $m
        if ($LASTEXITCODE -eq 0) {
            Write-Success "模型 $m 拉取完成"
        } else {
            Write-ErrorCustom "模型 $m 拉取失败，请检查网络后手动运行: ollama pull $m"
        }
    }
}

# 4. 验证（直接调 HTTP API；不要用 ollama run —— 对 embedding 模型会挂起等输入）
Write-Info "验证 embedding 能力..."
$r = Invoke-RestMethod -Uri "http://localhost:11434/api/embeddings" -Method POST `
    -Body (@{ model = "all-minilm:33m"; prompt = "test" } | ConvertTo-Json) `
    -ContentType "application/json"
Write-Success "Ollama 就绪! 向量维度: $($r.embedding.Count) (all-minilm:33m)"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Ollama 安装完成!" -ForegroundColor Green
Write-Host ""
Write-Host "  可选: 拉取更精确的双语模型 (bge-m3, 1.2GB):" -ForegroundColor Yellow
Write-Host "    ollama pull bge-m3" -ForegroundColor Yellow
Write-Host "  拉取后修改 config/settings.json 的 embeddingModel 为 bge-m3, embeddingDim 改为 1024" -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Cyan
