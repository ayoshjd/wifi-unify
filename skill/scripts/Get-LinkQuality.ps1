<#
.SYNOPSIS
  采集本机每块网卡的链路质量 + 最近链路协商事件统计，输出 Markdown 表。

.用途
  把「上联只有 10 Mbps 却长期未被发现」变成每次施工前 10 秒钟的一次检查。
  同时给出"同一块网卡最近协商过哪些速率/双工"的历史，用于区分"设置锁速"与"线材劣化"。

.参数
  -OutFile         可选。把结果同时写入该文件（UTF-8）。
  -Days            统计最近几天的事件，默认 1（今天）。
  -MinLinkMbps     链路速率下限，默认 100。低于该值的在线网卡会被标红提示。
  -ProviderPattern 可选。网卡驱动事件 Provider 的正则；默认覆盖常见有线网卡厂商。
                   不同平台/驱动名称不同，现场用 `Get-WinEvent -ListProvider *` 查。

.平台
  Windows（依赖 Get-NetAdapter / Get-NetAdapterAdvancedProperty / Get-WinEvent）。
  非 Windows 请手工记录 `ethtool <if>` 或系统网络详情中的速率/双工，并跳过事件统计。

.读写
  只读：只读网卡状态与事件日志，不修改任何设置。
  回滚：无需回滚。

.示例
  .\Get-LinkQuality.ps1
  .\Get-LinkQuality.ps1 -Days 2 -MinLinkMbps 1000 -OutFile .\link-quality.md
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [int]$Days = 1,
    [int]$MinLinkMbps = 100,
    [string]$ProviderPattern = '(?i)e1d|e1i|e1q|rt6|rtl|netwtw|intel|killer|broadcom|realtek|marvell|atheros|nvidia'
)

function ConvertTo-Mbps([string]$speed) {
    if (-not $speed) { return $null }
    if ($speed -match '([\d\.]+)\s*Gbps') { return [double]$Matches[1] * 1000 }
    if ($speed -match '([\d\.]+)\s*Mbps') { return [double]$Matches[1] }
    if ($speed -match '([\d\.]+)\s*Kbps') { return [double]$Matches[1] / 1000 }
    return $null
}

$since = (Get-Date).Date.AddDays(-1 * ($Days - 1))
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# 链路质量快照（$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')）")
$md.Add('')
$md.Add("> 速率下限：$MinLinkMbps Mbps；低于该值的在线链路视为异常，先查线材/端口，不要开始测速。")
$md.Add('')
$md.Add('| 网卡 | 状态 | 速率 | 双工 | 速度和双工设置 | Rx错误 | Rx丢弃 | Tx丢弃 | 低于阈值 |')
$md.Add('|---|---|---|---|---|---|---|---|---|')

$lowLinks = New-Object System.Collections.Generic.List[object]
foreach ($a in (Get-NetAdapter | Sort-Object Name)) {
    $duplexSetting = 'n/a'
    $adv = Get-NetAdapterAdvancedProperty -Name $a.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.RegistryKeyword -eq '*SpeedDuplex' }
    if ($adv) { $duplexSetting = $adv.DisplayValue }

    $st = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
    $mbps = ConvertTo-Mbps ([string]$a.LinkSpeed)
    $isLow = ($a.Status -eq 'Up' -and $null -ne $mbps -and $mbps -lt $MinLinkMbps)
    if ($isLow) { $lowLinks.Add([pscustomobject]@{ Name = $a.Name; Speed = $a.LinkSpeed; Mbps = $mbps }) }
    $flag = if ($isLow) { '**是**' } else { '否' }

    $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
        $a.Name, $a.Status, $a.LinkSpeed, $a.FullDuplex, $duplexSetting,
        $st.ReceivedPacketErrors, $st.ReceivedDiscardedPackets, $st.OutboundDiscardedPackets, $flag))
}

$md.Add('')
if ($lowLinks.Count -gt 0) {
    $md.Add(('> **警告：{0} 块在线网卡低于 {1} Mbps。按规则先查线材/水晶头/端口，未达标前吞吐不得作为验收判据。**' -f $lowLinks.Count, $MinLinkMbps))
    $md.Add('')
    $md.Add('| 网卡 | 速率 | 折算 Mbps |')
    $md.Add('|---|---|---|')
    foreach ($l in $lowLinks) { $md.Add(('| {0} | {1} | {2} |' -f $l.Name, $l.Speed, $l.Mbps)) }
} else {
    $md.Add("> 所有在线网卡均不低于 $MinLinkMbps Mbps。")
}

$md.Add('')
$md.Add("## 最近 $Days 天链路协商事件（ProviderPattern：$ProviderPattern）")
$md.Add('')

try {
    $ev = Get-WinEvent -LogName System -MaxEvents 5000 -ErrorAction Stop |
        Where-Object { $_.ProviderName -match $ProviderPattern -and $_.TimeCreated -ge $since }
} catch {
    $ev = @()
}

if (-not $ev -or @($ev).Count -eq 0) {
    $md.Add('> 无相关事件（或需要管理员权限读取系统日志，或 ProviderPattern 与现场驱动不匹配）。')
} else {
    $rows = foreach ($e in $ev) {
        $m = $e.Message -replace "`r?`n", ' '
        $rate = if ($m -match '(\d+(\.\d+)?\s*Gbps)') { $Matches[1] }
                elseif ($m -match '(\d+)\s*Mbps') { $Matches[1] + ' Mbps' }
                else { '未知' }
        $mbps = ConvertTo-Mbps $rate
        $duplex = if ($m -match '半双工') { '半双工' } elseif ($m -match '全双工') { '全双工' } else { '-' }
        [pscustomobject]@{ 时间 = $e.TimeCreated; 速率 = $rate; Mbps = $mbps; 双工 = $duplex }
    }
    $rows | Group-Object 速率, 双工 | Sort-Object Count -Descending |
        ForEach-Object { $md.Add(('- {0} × {1} 次' -f $_.Name, $_.Count)) }

    $bad = @($rows | Where-Object { $null -ne $_.Mbps -and $_.Mbps -lt $MinLinkMbps })
    $md.Add('')
    if ($bad.Count -gt 0) {
        $md.Add(('> **警告：最近 {0} 天出现 {1} 次低于 {2} Mbps 的协商，视为异常，先查线材/端口，不要开始测速。**' -f $Days, $bad.Count, $MinLinkMbps))
        $md.Add('')
        $md.Add('| 时间 | 速率 | 双工 |')
        $md.Add('|---|---|---|')
        $bad | Sort-Object 时间 | ForEach-Object { $md.Add(('| {0} | {1} | {2} |' -f $_.时间, $_.速率, $_.双工)) }
    } else {
        $md.Add("> 最近 $Days 天未出现低于 $MinLinkMbps Mbps 的协商。")
    }
}

$md.Add('')
$md.Add('## 默认路由')
$md.Add('')
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    ForEach-Object { $md.Add(('- {0} via {1}  ifIndex={2}  metric={3}' -f $_.DestinationPrefix, $_.NextHop, $_.ifIndex, $_.RouteMetric)) }

$text = $md -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8; Write-Host "已写入 $OutFile" -ForegroundColor Cyan }
