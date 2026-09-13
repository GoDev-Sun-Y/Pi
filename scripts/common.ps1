# common.ps1 —— 公共工具：带真实进度条的文件下载
#
# 引入方式（setup.ps1 / install_ollama.ps1 顶部）：
#     . (Join-Path $PSScriptRoot "common.ps1")
#
# 为什么不用 Invoke-WebRequest：
#   1) 它在 GB 级大文件下载完成后会长时间卡在收尾阶段，界面停在最后一行不动，像死机；
#   2) 它只显示已写入字节数，不显示总量、百分比、速度和剩余时间，用户无法判断还要等多久。
# 这里改用 HttpWebRequest 分块读取，自己算进度，并支持整体超时与大小校验。

function Format-FileSize {
    param([double]$Bytes)

    if ($Bytes -lt 0) { return "未知" }
    $units = @("B", "KB", "MB", "GB", "TB")
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt 4) {
        $Bytes = $Bytes / 1024
        $i++
    }
    if ($i -eq 0) { return "$([int]$Bytes) B" }
    return ("{0:N1} {1}" -f $Bytes, $units[$i])
}

function Invoke-FileDownloadOnce {
    param(
        [string]$Uri,
        [string]$OutFile,
        [string]$Description = "文件",
        [int]$TimeoutSec = 1800
    )

    $request = $null
    $response = $null
    $target = $null
    $received = 0
    $total = -1

    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = "GET"
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 60000
        $request.AllowAutoRedirect = $true
        $request.UserAgent = "pi-work-mode"

        $response = $request.GetResponse()
        $total = $response.ContentLength

        if ($total -gt 0) {
            Write-Host ("    大小: {0}" -f (Format-FileSize $total)) -ForegroundColor DarkGray
        } else {
            Write-Host "    大小: 服务器未提供，将只显示已下载量" -ForegroundColor DarkGray
        }

        $stream = $response.GetResponseStream()
        $target = [System.IO.File]::Create($OutFile)
        $buffer = New-Object byte[] 262144
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastPaint = [System.Diagnostics.Stopwatch]::StartNew()

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $target.Write($buffer, 0, $read)
            $received += $read

            if ($lastPaint.Elapsed.TotalMilliseconds -ge 300) {
                $elapsed = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)
                $speed = $received / $elapsed
                if ($total -gt 0) {
                    $percent = [Math]::Min(100, [int](($received / $total) * 100))
                    $remainSec = if ($speed -gt 0) { [int](($total - $received) / $speed) } else { -1 }
                    $eta = if ($remainSec -ge 0) { ("{0:00}:{1:00}" -f [int]($remainSec / 60), ($remainSec % 60)) } else { "计算中" }
                    $status = ("{0} / {1}  ({2}%)  {3}/s  剩余 {4}" -f `
                        (Format-FileSize $received), (Format-FileSize $total), $percent, (Format-FileSize $speed), $eta)
                    Write-Progress -Activity "下载 $Description" -Status $status -PercentComplete $percent
                } else {
                    $status = ("{0}  {1}/s" -f (Format-FileSize $received), (Format-FileSize $speed))
                    Write-Progress -Activity "下载 $Description" -Status $status
                }
                $lastPaint.Restart()
            }

            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                Write-Progress -Activity "下载 $Description" -Completed
                Write-Host ("    下载超时（超过 {0} 秒），已放弃" -f $TimeoutSec) -ForegroundColor Red
                return $false
            }
        }

        Write-Progress -Activity "下载 $Description" -Completed
        $target.Close(); $target = $null
        $response.Close(); $response = $null

        # 大小校验：防止拿到半截文件或错误页面
        if ($total -gt 0) {
            $actual = (Get-Item $OutFile).Length
            if ($actual -ne $total) {
                Write-Host ("    文件大小不符（应得 {0}，实得 {1}）" -f $total, $actual) -ForegroundColor Red
                return $false
            }
        }

        Write-Host ("    完成: {0}（用时 {1:N1} 秒）" -f (Format-FileSize $received), $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Progress -Activity "下载 $Description" -Completed -ErrorAction SilentlyContinue
        Write-Host "    下载出错: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        if ($target)   { try { $target.Close() }   catch {} }
        if ($response) { try { $response.Close() } catch {} }
    }
}

# 让窗口停在最后，用户看完结果再手动关。
# 场景：脚本常被"右键 -> 用 PS 运行"或直接双击启动，跑完就自动关窗，
#       下载进度和成功/失败反馈根本来不及看。
# 只在交互式控制台里暂停；CI / 自动化场景传 -NoPause 跳过。
function Stop-ForReview {
    param([string]$Message = "按任意键关闭本窗口...")

    if ($Host.Name -ne "ConsoleHost") { return }

    # 自动化场景（CI、管道调用、被别的脚本 & 起来）输入是重定向的，此时绝不能停，
    # 否则会把调用方挂死——test_install.ps1 的干跑就曾因此卡住。
    try { if ([Console]::IsInputRedirected) { return } } catch {}
    try { if (-not [Environment]::UserInteractive) { return } } catch {}
    if ($env:PI_WORK_MODE_NO_PAUSE -eq "1") { return }

    Write-Host ""
    Write-Host "  $Message" -ForegroundColor Gray
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } catch {
        Read-Host "  按回车键关闭本窗口" | Out-Null
    }
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [string]$Description = "文件",
        [int]$TimeoutSec = 1800,
        [int]$MaxRetries = 2
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if (Invoke-FileDownloadOnce -Uri $Uri -OutFile $OutFile -Description $Description -TimeoutSec $TimeoutSec) {
            return $true
        }
        if ($attempt -lt $MaxRetries) {
            Write-Host "    3 秒后重试（第 $attempt/$MaxRetries 次）..." -ForegroundColor Yellow
            Start-Sleep -Seconds 3
        }
    }
    return $false
}
