<#
.SYNOPSIS
  本机网络配置一致性自检：默认路由唯一、无双网卡同网段、无 169.254、无禁网段、网关可达、Wi-Fi 连到预期 SSID。

.用途
  把「无路由就判不可达」「断链残留地址」「单点验证」变成一次自检。
  在每次"断开/插上"网线之后、以及每次测速之前跑一次。

.参数
  -ExpectPath        可选。JSON 期望文件（字段见末尾示例）。
  -Gateway           可选。期望网关；覆盖文件/自动推断。
  -Ssids             可选。期望 SSID（前缀匹配）；为空则跳过 SSID 检查并告警。
  -ForbiddenSubnets  可选。禁止出现的网段（CIDR）；为空则跳过。
  -OutFile           可选。结果同时写入文件。
  -FailOnError       有 FAIL 时以退出码 1 结束，便于被别的脚本调用。

  未提供 -ExpectPath 且未提供 -Gateway 时，从当前在线网卡的默认路由自动推断网关；
  本脚本不写死任何项目 IP/SSID。

.平台
  Windows（依赖 Get-NetRoute / Get-NetAdapter / netsh）。

.读写
  只读：只读地址/路由/Wi-Fi 状态并 ping 网关，不修改任何配置。
  回滚：无需回滚。

.示例
  .\Test-NetConfigConsistency.ps1 -Gateway 192.0.2.1 -Ssids "<SSID>" -FailOnError
  .\Test-NetConfigConsistency.ps1 -ExpectPath .\expect.json -FailOnError
#>
[CmdletBinding()]
param(
    [string]$ExpectPath,
    [string]$Gateway,
    [string[]]$Ssids,
    [string[]]$ForbiddenSubnets,
    [string]$OutFile,
    [switch]$FailOnError
)

$exp = $null
if ($ExpectPath -and (Test-Path $ExpectPath)) {
    $exp = Get-Content $ExpectPath -Raw | ConvertFrom-Json
}

if (-not $exp) {
    $defaultGw = $null
    $upNamesForGw = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name)
    $drUp = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object { $upNamesForGw -contains $_.InterfaceAlias } |
        Sort-Object RouteMetric)
    if ($drUp.Count -gt 0) { $defaultGw = $drUp[0].NextHop }

    $exp = [pscustomobject]@{
        Gateway          = $(if ($Gateway) { $Gateway } elseif ($defaultGw) { $defaultGw } else { $null })
        Ssids            = @($Ssids | Where-Object { $_ })
        ForbiddenSubnets = @($ForbiddenSubnets | Where-Object { $_ })
    }
} else {
    if ($Gateway) { $exp.Gateway = $Gateway }
    if ($Ssids) { $exp.Ssids = @($Ssids) }
    if ($ForbiddenSubnets) { $exp.ForbiddenSubnets = @($ForbiddenSubnets) }
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Level, [string]$Item, [string]$Detail) {
    $results.Add([pscustomobject]@{ Level = $Level; Item = $Item; Detail = $Detail })
}

function ConvertTo-UInt32([string]$ip) {
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [Array]::Reverse($b)
    return [BitConverter]::ToUInt32($b, 0)
}
function Test-InSubnet([string]$ip, [string]$cidr) {
    $parts = $cidr.Split('/')
    $net = ConvertTo-UInt32 $parts[0]
    $len = [int]$parts[1]
    $mask = if ($len -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $len)) }
    return ((ConvertTo-UInt32 $ip) -band $mask) -eq ($net -band $mask)
}

# 1) 默认路由唯一（只在"在线网卡"之间判唯一；断链网卡残留单独告警）
$allDef = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$upNames0 = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name)
$def = @($allDef | Where-Object { $upNames0 -contains $_.InterfaceAlias })
$stale = @($allDef | Where-Object { $upNames0 -notcontains $_.InterfaceAlias })
if ($def.Count -eq 1) {
    Add-Result 'PASS' '默认路由唯一' ("via " + $def[0].NextHop + " on " + $def[0].InterfaceAlias)
} elseif ($def.Count -eq 0) {
    Add-Result 'FAIL' '默认路由唯一' '在线网卡上没有默认路由，外网必不通'
} else {
    Add-Result 'FAIL' '默认路由唯一' ("在线网卡有 " + $def.Count + " 条默认路由：" + (($def | ForEach-Object { $_.InterfaceAlias + '→' + $_.NextHop }) -join ', '))
}
if ($stale.Count -gt 0) {
    Add-Result 'WARN' '断链网卡残留路由' (($stale | ForEach-Object { $_.InterfaceAlias + '→' + $_.NextHop }) -join ', ') + '（链路已断但仍持有默认路由，插线前先清理）'
}

# 2) 在线网卡地址清单
$addrs = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne '127.0.0.1' }
$upNames = @(Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name)
$upAddrs = $addrs | Where-Object { $upNames -contains $_.InterfaceAlias }

# 3) 169.254（忽略蓝牙、Wi-Fi Direct 等虚拟/非承载网卡）
$virtualNames = @(Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -match 'Bluetooth|Wi-Fi Direct|Virtual|虚拟|TAP|WAN Miniport' -or $_.Name -match '蓝牙|本地连接\*'
    } | Select-Object -ExpandProperty Name)
$apipa = @($addrs | Where-Object {
        $_.IPAddress -like '169.254.*' -and $_.InterfaceAlias -notmatch '本地连接\*|蓝牙|Wi-Fi Direct'
    })
if ($apipa.Count -gt 0) {
    Add-Result 'FAIL' '无 169.254 地址' (($apipa | ForEach-Object { $_.InterfaceAlias + '=' + $_.IPAddress }) -join ', ')
} else {
    Add-Result 'PASS' '无 169.254 地址' ('仅忽略虚拟网卡：' + ($virtualNames -join ', '))
}

# 4) 双网卡同网段（只对在线网卡）
$conflict = @()
for ($i = 0; $i -lt @($upAddrs).Count; $i++) {
    for ($j = $i + 1; $j -lt @($upAddrs).Count; $j++) {
        $a = @($upAddrs)[$i]; $b = @($upAddrs)[$j]
        if ($a.PrefixLength -eq $b.PrefixLength -and
            (Test-InSubnet $a.IPAddress ("$($a.IPAddress)/$($a.PrefixLength)")) -and
            ($a.PrefixLength -eq $b.PrefixLength)) {
            $mask = [uint32]([uint32]::MaxValue -shl (32 - $a.PrefixLength))
            if (((ConvertTo-UInt32 $a.IPAddress) -band $mask) -eq ((ConvertTo-UInt32 $b.IPAddress) -band $mask)) {
                $conflict += ($a.InterfaceAlias + '(' + $a.IPAddress + ') 与 ' + $b.InterfaceAlias + '(' + $b.IPAddress + ')')
            }
        }
    }
}
if ($conflict.Count -gt 0) {
    Add-Result 'FAIL' '无双网卡同网段' ($conflict -join '; ')
} else {
    Add-Result 'PASS' '无双网卡同网段' ('在线网卡：' + ($upNames -join ', '))
}

# 5) 禁网段
$hit = @()
if (@($exp.ForbiddenSubnets).Count -eq 0) {
    Add-Result 'PASS' '无禁网段地址' '未配置禁网段（跳过）'
} else {
    foreach ($cidr in @($exp.ForbiddenSubnets)) {
        foreach ($a in $upAddrs) {
            if (Test-InSubnet $a.IPAddress $cidr) { $hit += ($a.InterfaceAlias + '=' + $a.IPAddress + ' ∈ ' + $cidr) }
        }
    }
    if ($hit.Count -gt 0) {
        Add-Result 'FAIL' '无禁网段地址' ($hit -join '; ')
    } else {
        Add-Result 'PASS' '无禁网段地址' ((@($exp.ForbiddenSubnets)) -join ', ')
    }
}

# 6) 网关可达（3 次）
$gw = $exp.Gateway
if ($gw) {
    $ok = 0
    foreach ($n in 1..3) {
        if (Test-Connection -TargetName $gw -Count 1 -Quiet -ErrorAction SilentlyContinue) { $ok++ }
    }
    if ($ok -eq 3) { Add-Result 'PASS' '网关可达' ("$gw 3/3") }
    elseif ($ok -gt 0) { Add-Result 'WARN' '网关可达' ("$gw $ok/3，丢包") }
    else { Add-Result 'FAIL' '网关可达' "$gw 0/3" }
} else {
    Add-Result 'WARN' '网关可达' '未配置期望网关'
}

# 7) Wi-Fi 是否连到预期 SSID（前缀匹配）
$wifi = (netsh wlan show interfaces) -join "`n"
$ssid = if ($wifi -match 'SSID\s*:\s*(.+)') { $Matches[1].Trim() } else { '' }
$bssid = if ($wifi -match 'BSSID\s*:\s*([0-9a-fA-F:]{17})') { $Matches[1] } else { '' }
if (-not $ssid) {
    Add-Result 'WARN' 'Wi-Fi SSID' '未连接（若本阶段走有线可忽略）'
} elseif (@($exp.Ssids).Count -eq 0) {
    Add-Result 'WARN' 'Wi-Fi SSID' ("当前 $ssid；未配置期望 SSID，已跳过比对")
} else {
    $match = @(@($exp.Ssids) | Where-Object { $ssid -like ($_ + '*') })
    if ($match.Count -gt 0) { Add-Result 'PASS' 'Wi-Fi SSID' ("$ssid / BSSID " + $bssid) }
    else { Add-Result 'FAIL' 'Wi-Fi SSID' ("当前 $ssid 不在预期 " + (@($exp.Ssids) -join ', ')) }
}

# 输出
$lines = @('# 网络配置一致性自检（' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '）', '',
           '| 结果 | 项目 | 详情 |', '|---|---|---|')
foreach ($r in $results) { $lines += ('| {0} | {1} | {2} |' -f $r.Level, $r.Item, $r.Detail) }
$totalCount = $results.Count
$failCount = 0
$warnCount = 0
foreach ($r in $results) {
    if ($r.Level -eq 'FAIL') { $failCount++ }
    elseif ($r.Level -eq 'WARN') { $warnCount++ }
}
$lines += ''
$passCount = $totalCount - $failCount - $warnCount
$lines = $lines + ('汇总：FAIL ' + $failCount + ' 项，WARN ' + $warnCount + ' 项，PASS ' + $passCount + ' 项')

$text = $lines -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8 }
if ($FailOnError -and $failCount -gt 0) { exit 1 }

<#
expect.json 示例（全部使用占位值；实际值必须现场回读）：
{
  "Gateway": "192.0.2.1",
  "Ssids": ["<SSID>"],
  "ForbiddenSubnets": ["198.51.100.0/24"]
}
#>
