<#
.SYNOPSIS
  从 Windows WLAN 事件日志计算漫游/重关联的断流时长，并按门限给出结论。

.用途
  把「漫游感觉还行」变成可复核的数字：配对 11004（安全停止）与 11005（安全成功），
  差值即该次重关联的断流时长；同时统计 8002（真断线）、8001（连接失败）、8003（连接成功）。
  0 条样本时判「无效」，不判「通过」，避免把「没测到」当成「没问题」。

.参数
  -SinceHours   回看小时数，默认 4。
  -Since        可选。显式起始时间，优先于 SinceHours。
  -MaxGapSec    断流门限（秒），默认 3；超过判 FAIL。
  -LogName      事件日志名，默认 Microsoft-Windows-WLAN-AutoConfig/Operational。
  -OutFile      输出 Markdown 报告。
  -CsvFile      输出逐条 gap 的 CSV。
  -FailOnExceed 有 FAIL 时退出码 1；无样本时退出码 2；日志不可读时退出码 3。

.算法
  对每条 11004，找其后最近的 11005（中间若出现新的 11004，则前一条判「未完成」）；
  gap = 11005 时间 - 11004 时间；期间出现 8002 则标记「真断线」。
  只有 11005、没有前置 11004 的，记为首次连接，不计入漫游。

.平台
  Windows 专用（Get-WinEvent + WLAN-AutoConfig 日志）。
  非 Windows 替代：
    macOS  : log stream --predicate 'subsystem == "com.apple.wifi"'（或秒表 + 录屏）
    Linux  : iw event / dmesg -w，观察 "disconnected" 与 "connected" 的时间差
    仅手机 : 1 s 间隔 ping 工具，数连续丢失编号；录屏记录 BSSID 变化时刻

.读写
  只读：只读事件日志；输出只写 OutFile/CsvFile（若指定）。
  不修改任何网络配置，不连接/断开 Wi-Fi。

.回滚
  删除生成的报告/CSV 即可；系统状态无变化。

.示例
  .\Measure-RoamingGap.ps1 -SinceHours 2
  .\Measure-RoamingGap.ps1 -SinceHours 4 -MaxGapSec 3 -OutFile .\roaming.md -CsvFile .\roaming.csv -FailOnExceed
#>
[CmdletBinding()]
param(
    [int]$SinceHours = 4,
    [datetime]$Since,
    [double]$MaxGapSec = 3,
    [string]$LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational',
    [string]$OutFile,
    [string]$CsvFile,
    [switch]$FailOnExceed
)

$ErrorActionPreference = 'Continue'
if (-not $PSBoundParameters.ContainsKey('Since')) { $Since = (Get-Date).AddHours(-1 * $SinceHours) }

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 漫游/重关联断流报告')
$md.Add('')
$md.Add("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- 统计窗口：$($Since.ToString('yyyy-MM-dd HH:mm:ss')) 起")
$md.Add("- 事件日志：$LogName")
$md.Add("- 断流门限：$MaxGapSec s")
$md.Add('')

try {
    $events = Get-WinEvent -FilterHashtable @{ LogName = $LogName; StartTime = $Since } -ErrorAction Stop |
        Sort-Object TimeCreated
} catch {
    $md.Add('## 结果：日志不可读')
    $md.Add('')
    $md.Add("错误：$($_.Exception.Message)")
    $md.Add('')
    $md.Add('手工替代：')
    $md.Add('1. 手机装 1 s 间隔 ping 工具，走固定路线，数连续丢失的编号；')
    $md.Add('2. 全程录屏，记录 BSSID 变化时刻；')
    $md.Add('3. 结论标注「手机粗验（B/C 级）」，不要写成精确断流。')
    $text = $md -join "`n"
    Write-Output $text
    if ($OutFile) { $text | Out-File $OutFile -Encoding utf8 }
    exit 3
}

$gaps = New-Object System.Collections.Generic.List[object]
$pending = $null
$count8002 = 0
$count8001 = 0
$count8003 = 0
$count11004 = 0
$count11005 = 0

foreach ($e in $events) {
    switch ([int]$e.Id) {
        11004 {
            $count11004++
            if ($null -ne $pending) {
                $pending.Status = '未完成（无 11005）'
                $gaps.Add($pending)
            }
            $pending = [pscustomobject]@{
                Start   = $e.TimeCreated
                End     = $null
                GapSec  = $null
                Had8002 = $false
                Status  = '进行中'
            }
        }
        8002 {
            $count8002++
            if ($null -ne $pending) { $pending.Had8002 = $true }
        }
        8001 { $count8001++ }
        8003 { $count8003++ }
        11005 {
            $count11005++
            if ($null -ne $pending) {
                $pending.End = $e.TimeCreated
                $pending.GapSec = [math]::Round(($e.TimeCreated - $pending.Start).TotalSeconds, 3)
                $pending.Status = '完成'
                $gaps.Add($pending)
                $pending = $null
            }
        }
    }
}
if ($null -ne $pending) {
    $pending.Status = '未完成（到窗口结束仍无 11005）'
    $gaps.Add($pending)
}

$md.Add('## 汇总')
$md.Add('')
$md.Add("| 项 | 值 |")
$md.Add("|---|---|")
$md.Add("| 11004 安全停止 | $count11004 |")
$md.Add("| 11005 安全成功 | $count11005 |")
$md.Add("| 8002 真断线 | $count8002 |")
$md.Add("| 8001 连接失败 | $count8001 |")
$md.Add("| 8003 连接成功 | $count8003 |")
$md.Add("| 可配对的重关联 | $(@($gaps | Where-Object { $_.Status -eq '完成' }).Count) |")
$md.Add('')

$completed = @($gaps | Where-Object { $_.Status -eq '完成' -and $null -ne $_.GapSec })
$verdict = 'WARN'
$reasons = New-Object System.Collections.Generic.List[string]

if ($completed.Count -eq 0) {
    $verdict = 'INVALID'
    $reasons.Add('窗口内没有可配对的 11004→11005，无法计算断流；这不等于「无断流」。')
    $reasons.Add('请确认：测试期间是否真的走动并发生重关联；日志是否被清理；网卡驱动是否上报这些事件。')
} else {
    $maxGap = ($completed | Measure-Object -Property GapSec -Maximum).Maximum
    $avgGap = [math]::Round((($completed | Measure-Object -Property GapSec -Average).Average), 3)
    $md.Add("| 最大断流 | $maxGap s |")
    $md.Add("| 平均断流 | $avgGap s |")
    $md.Add('')

    if ($maxGap -gt $MaxGapSec) {
        $verdict = 'FAIL'
        $reasons.Add("最大断流 $maxGap s 超过门限 $MaxGapSec s。")
    } else {
        $verdict = 'PASS'
    }
    if ($count8002 -gt 0) {
        if ($verdict -eq 'PASS') { $verdict = 'WARN' }
        $reasons.Add("出现 $count8002 次 8002（真断线）：需人工确认是漫游、手动断开、睡眠还是驱动重载。")
    }
    $unfinished = @($gaps | Where-Object { $_.Status -ne '完成' })
    if ($unfinished.Count -gt 0) {
        if ($verdict -eq 'PASS') { $verdict = 'WARN' }
        $reasons.Add("有 $($unfinished.Count) 条 11004 没有对应 11005，可能掉线未恢复或日志截断。")
    }
}

$md.Add('## 逐条明细')
$md.Add('')
if ($gaps.Count -eq 0) {
    $md.Add('（无 11004/11005 事件）')
} else {
    $md.Add('| # | 11004 时间 | 11005 时间 | 断流(s) | 8002 | 状态 | 判定 |')
    $md.Add('|---|---|---|---|---|---|---|')
    $k = 0
    foreach ($g in $gaps) {
        $k++
        $isFail = ($g.Status -eq '完成' -and $null -ne $g.GapSec -and $g.GapSec -gt $MaxGapSec)
        $v = if ($g.Status -ne '完成') { 'WARN' } elseif ($isFail) { 'FAIL' } elseif ($g.Had8002) { 'WARN' } else { 'PASS' }
        $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
            $k,
            $g.Start.ToString('HH:mm:ss.fff'),
            $(if ($g.End) { $g.End.ToString('HH:mm:ss.fff') } else { '-' }),
            $(if ($null -ne $g.GapSec) { $g.GapSec } else { '-' }),
            $(if ($g.Had8002) { '是' } else { '否' }),
            $g.Status, $v))
    }
}

$md.Add('')
$md.Add('## 结论')
$md.Add('')
$md.Add("**$verdict**")
$md.Add('')
foreach ($r in $reasons) { $md.Add("- $r") }
if ($reasons.Count -eq 0) { $md.Add("- 窗口内 $($completed.Count) 次重关联，最大断流未超过门限，且未出现 8002。") }
$md.Add('')
$md.Add('> 判读提醒：11004→11010→11005 在同一秒内，通常是无缝重关联；出现 8002 说明客户端先真断线再重连，即使 gap 很短，体验上也会有一次明显卡顿。')

$text = $md -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8; Write-Host "已写入 $OutFile" -ForegroundColor Cyan }
if ($CsvFile) {
    $gaps | Select-Object @{n = 'Start'; e = { $_.Start.ToString('yyyy-MM-dd HH:mm:ss.fff') } },
        @{n = 'End'; e = { if ($_.End) { $_.End.ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' } } },
        GapSec, Had8002, Status | Export-Csv $CsvFile -NoTypeInformation -Encoding utf8
    Write-Host "已写入 $CsvFile" -ForegroundColor Cyan
}

if ($FailOnExceed) {
    if ($verdict -eq 'FAIL') { exit 1 }
    if ($verdict -eq 'INVALID') { exit 2 }
}
exit 0
