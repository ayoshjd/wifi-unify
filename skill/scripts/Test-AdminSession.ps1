<#
.SYNOPSIS
  单设备单会话占用检查：管理页可达性 + 页面锁提示 + 本机到该设备的已建立连接数。

.用途
  落实 W1（同一设备同一时刻只允许一个管理会话）与 E11：
  开工前先判定"这台设备现在能不能独占"，避免自动化与人工抢同一个会话。
  注意：本脚本**无法枚举其他终端的登录状态**，只能提示，最终必须人工确认。

.参数
  -Target      必填。设备地址，可写 `192.0.2.10` 或 `http://192.0.2.10`。
  -TimeoutSec  可选。HTTP 超时秒数，默认 5。
  -OutFile     可选。结果同时写入该文件。
  -FailOnBusy  检测到锁提示时以退出码 2 结束。
               退出码：0=可继续（含"需人工确认"）、1=不可达、2=疑似被占用。

.读写
  只读：只做 ping / TCP 连接测试 / HTTP GET 与关键词判断 / 读本机连接表。
  不登录、不提交表单、不打印页面正文、不修改任何配置。

.回滚
  无需回滚；本脚本不产生持久状态。

.示例
  .\Test-AdminSession.ps1 -Target 192.0.2.10
  .\Test-AdminSession.ps1 -Target http://192.0.2.10 -FailOnBusy -OutFile .\session.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Target,
    [int]$TimeoutSec = 5,
    [string]$OutFile,
    [switch]$FailOnBusy
)

$ErrorActionPreference = 'Continue'

$raw = $Target.Trim()
if ($raw -notmatch '^https?://') { $raw = 'http://' + $raw + '/' }
try { $uri = [Uri]$raw } catch { throw "无法解析 -Target：$Target" }
$hostName = $uri.Host

# 1) ping
$pingOk = 0
foreach ($n in 1..3) {
    if (Test-Connection -TargetName $hostName -Count 1 -Quiet -ErrorAction SilentlyContinue) { $pingOk++ }
}

# 2) TCP
$ports = @(80, 443)
if (-not $uri.IsDefaultPort -and $uri.Port -gt 0 -and $ports -notcontains $uri.Port) { $ports += $uri.Port }
$tcp = @()
foreach ($p in $ports) {
    $ok = $false
    try { $ok = Test-NetConnection -ComputerName $hostName -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue } catch { $ok = $false }
    $tcp += [pscustomobject]@{ Port = $p; Open = $ok }
}

# 3) 本机到该设备的已建立连接（提示"可能有本机浏览器会话"）
$ips = @()
try { $ips = @([System.Net.Dns]::GetHostAddresses($hostName) | ForEach-Object { $_.IPAddressToString }) } catch { }
$connCount = 0
$connPorts = @()
foreach ($ip in $ips) {
    $c = @(Get-NetTCPConnection -RemoteAddress $ip -State Established -ErrorAction SilentlyContinue)
    $connCount += $c.Count
    $connPorts += @($c | ForEach-Object { $_.RemotePort })
}

# 4) HTTP 抓锁提示（只看关键词，不输出正文）
$httpOk = $false
$statusText = '(未获取)'
$lockHits = @()
$bodyLen = 0
$errorText = ''
$lockPhrases = @(
    '其他用户正在设置', '其他用户正在', '另一用户正在', '另一个用户正在',
    '正在配置设备', '设备正忙', '正在被管理',
    'another user', 'is being configured', 'device is busy'
)
try {
    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 3 -SkipCertificateCheck -ErrorAction Stop
    $httpOk = $true
    $statusText = [string][int]$resp.StatusCode
    $bodyLen = [int]$resp.RawContentLength
    $text = [string]$resp.Content
    foreach ($p in $lockPhrases) { if ($text -like "*$p*") { $lockHits += $p } }
} catch {
    $r = $_.Exception.Response
    if ($r) {
        $httpOk = $true
        $statusText = [string][int]$r.StatusCode + '（需登录或拒绝访问，属正常）'
    } else {
        $errorText = $_.Exception.Message
    }
}

# 5) 判定
if ($lockHits.Count -gt 0) { $verdict = '疑似被占用（BUSY）' }
elseif ($pingOk -eq 0 -and -not ($tcp | Where-Object Open)) { $verdict = '不可达（UNREACHABLE）' }
else { $verdict = '可继续，但必须人工确认无他人登录（NEED_HUMAN_CONFIRM）' }

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 管理会话占用检查（' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '）')
$md.Add('')
$md.Add('| 项目 | 结果 |')
$md.Add('|---|---|')
$md.Add("| 目标 | $hostName |")
$md.Add("| ping | $pingOk/3 |")
$md.Add("| TCP | " + (($tcp | ForEach-Object { "$($_.Port)=$(if ($_.Open) { 'open' } else { 'closed' })" }) -join ', ') + ' |')
$md.Add("| HTTP | $statusText$(if ($bodyLen) { "，正文 $bodyLen 字节（未展示）" } else { '' }) |")
$md.Add("| 本机已建立连接数 | $connCount$(if ($connCount) { '（远端端口 ' + (($connPorts | Sort-Object -Unique) -join ',') + '；可能是本机浏览器）' }) |")
$md.Add("| 页面锁提示 | $(if ($lockHits.Count) { '命中：' + ($lockHits -join ' / ') } else { '未命中' }) |")
$md.Add("| **判定** | **$verdict** |")
if ($errorText) { $md.Add("| 错误 | $errorText |") }
$md.Add('')
$md.Add('> 本脚本不能证明"其他终端没有登录"。必须在页面上看到无占用提示，并由现场人员口头确认。')
$md.Add('> 若判定 BUSY：停手，等占用者退出，不得反复刷新或重复登录（E01/E11）。')

$text = $md -join "`n"
Write-Output $text
if ($OutFile) {
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text | Out-File $OutFile -Encoding utf8
    Write-Host "已写入 $OutFile" -ForegroundColor Cyan
}

if ($verdict -like '不可达*') { exit 1 }
if ($lockHits.Count -gt 0 -and $FailOnBusy) { exit 2 }
exit 0
