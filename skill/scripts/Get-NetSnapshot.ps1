<#
.SYNOPSIS
  变更前后本机网络快照导出（7 个核心文件 + 链路质量），并可选与另一份快照做文本 diff。

.用途
  替代"手动一条条敲 ipconfig/route/netsh"的命令集合，避免漏项；把「无性能基线」与
  「before/after 不成对」变成一条命令。额外输出 19-adapter-link.txt（链路速率/双工/错误计数），
  用于补上"只备份配置、不量化性能"的缺口。

.参数
  -Tag         必填。快照对象标识，建议 "S<阶段号>-<对象>"，如 "S1-AP-A"；不得含路径分隔符。
  -Phase       before | after，默认 before。目录名以此结尾，保证成对。
  -ProjectRoot 可选。项目根目录，默认当前目录；快照写到 `<ProjectRoot>\backup\snapshots`。
  -OutRoot     可选。显式指定快照根目录，优先于 ProjectRoot。
  -CompareWith 可选。给另一份快照目录做逐文件 diff，结果写入 99-diff-vs-<目录名>.txt。
  -StopNote    可选。写入 00-快照说明.md 的停点说明，例如「本阶段到此为止，禁止自动进入下一阶段」。

.平台
  Windows（依赖 ipconfig / route / netsh / Get-NetAdapter / reg）。
  非 Windows 请手工采集等价项，格式与 7 个核心文件一致。

.读写
  可写：只在 OutRoot 下新建一个目录并写文件；**不修改任何网络配置**。
  回滚：删除本次生成的 `<Tag>-<时间戳>-<Phase>` 目录即可，系统状态无变化。

.示例
  .\Get-NetSnapshot.ps1 -Tag "S1-AP-A" -Phase before -ProjectRoot "<PROJECT_ROOT>"
  .\Get-NetSnapshot.ps1 -Tag "S1-AP-A" -Phase after -CompareWith ".\outputs\snapshots\<BEFORE_DIR>"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,
    [ValidateSet('before', 'after')][string]$Phase = 'before',
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$OutRoot,
    [string]$CompareWith,
    [string]$StopNote
)

if (-not $OutRoot) { $OutRoot = Join-Path $ProjectRoot 'backup\snapshots' }
if ($Tag -match '[\\/:*?"<>|]') { throw "Tag 不能包含路径分隔符或 Windows 非法字符：$Tag" }
if (-not (Test-Path $OutRoot)) { New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null }

$ErrorActionPreference = 'Continue'
$ts  = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir = Join-Path $OutRoot "$Tag-$ts-$Phase"
New-Item -ItemType Directory -Path $dir -Force | Out-Null
Write-Host "快照目录: $dir" -ForegroundColor Cyan

function Save-Text([string]$Name, [scriptblock]$Action) {
    try {
        $text = & $Action 2>&1 | Out-String
        $text | Out-File (Join-Path $dir $Name) -Encoding utf8
        Write-Host ("  [+] " + $Name)
    } catch {
        ("[导出失败] " + $_.Exception.Message) | Out-File (Join-Path $dir $Name) -Encoding utf8
        Write-Host ("  [!] " + $Name + " 失败: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

# --- 7 个核心文件（编号不变） ---
Save-Text '01-ipconfig-all.txt'        { ipconfig /all }
Save-Text '02-route-ipv4.txt'          { route print -4 }
Save-Text '08-dns.txt'                 { Get-DnsClientServerAddress }
Save-Text '09-wlan-profiles.txt'       { netsh wlan show profiles }
Save-Text '10-wlan-interfaces.txt'     { netsh wlan show interfaces }
Save-Text '11-ip-interface.txt'        { Get-NetIPInterface -AddressFamily IPv4 }
try {
    reg export "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" (Join-Path $dir '15-tcpip-interfaces.reg') /y | Out-Null
    Write-Host "  [+] 15-tcpip-interfaces.reg"
} catch {
    Write-Host "  [!] 15-tcpip-interfaces.reg 失败（可能需管理员）" -ForegroundColor Yellow
}

# --- 补充文件：链路质量（不替代 7 个核心文件，仅补性能基线） ---
Save-Text '19-adapter-link.txt' {
    Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, FullDuplex, MediaConnectionState |
        Format-Table -AutoSize
    Get-NetAdapterStatistics | Select-Object Name, ReceivedPacketErrors, ReceivedDiscardedPackets, OutboundDiscardedPackets |
        Format-Table -AutoSize
}

# --- 00 说明（自动生成；人工可再补充） ---
$wifi = (netsh wlan show interfaces) -join "`n"
$ssid = if ($wifi -match 'SSID\s*:\s*(.+)') { $Matches[1].Trim() } else { '未连接' }
$bssid = if ($wifi -match 'BSSID\s*:\s*([0-9a-fA-F:]{17})') { $Matches[1] } else { '无' }
$routes = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
$defaultCount = @($routes).Count
$defGw = (@($routes) | ForEach-Object { $_.NextHop }) -join ', '
$upAdapters = (Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty Name) -join ', '

@"
# 快照说明（自动生成）

| 项目 | 内容 |
|---|---|
| 对象标识 | $Tag |
| 阶段 | $Phase |
| 导出时间 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |
| 目录 | $(Split-Path $dir -Leaf) |
| 在线网卡 | $upAdapters |
| Wi-Fi | SSID=$ssid / BSSID=$bssid |
| 默认路由条数 | $defaultCount |
| 默认网关 | $defGw |
| 补充文件 | 19-adapter-link.txt（链路速率/双工/错误计数） |

## 停点与遗留（人工补充）

- 停点说明：$(if ($StopNote) { $StopNote } else { '（未填写。若本快照是阶段收口，请写明「停点：不得自动进入下一阶段」）' })
- 遗留事项：
- 异常与人工判断：

> 本文件由 Get-NetSnapshot.ps1 生成；遗留事项、异常与人工判断请追加在下方。
"@ | Out-File (Join-Path $dir '00-快照说明.md') -Encoding utf8

# --- 可选 diff ---
if ($CompareWith) {
    if (-not (Test-Path $CompareWith)) {
        Write-Host "CompareWith 不存在，跳过 diff: $CompareWith" -ForegroundColor Yellow
    } else {
        $out = Join-Path $dir ("99-diff-vs-" + (Split-Path $CompareWith -Leaf) + ".txt")
        $lines = @("# diff: " + (Split-Path $CompareWith -Leaf) + "  ->  " + (Split-Path $dir -Leaf), '')
        Get-ChildItem $CompareWith -File | Where-Object { $_.Name -match '^\d{2}-' } | ForEach-Object {
            $other = Join-Path $dir $_.Name
            if (-not (Test-Path $other)) { $lines += "[仅基线有] " + $_.Name; return }
            $d = Compare-Object (Get-Content $_.FullName) (Get-Content $other)
            if ($d) {
                $lines += ("## " + $_.Name + "  (" + $d.Count + " 行差异)")
                $d | ForEach-Object { $lines += ("  " + $_.SideIndicator + " " + $_.InputObject) }
                $lines += ''
            }
        }
        if ($lines.Count -le 2) { $lines += '无差异（仅比对文件内容）' }
        $lines | Out-File $out -Encoding utf8
        Write-Host ("  [diff] " + $out) -ForegroundColor Cyan
    }
}

Write-Host "完成。请人工补充 00-快照说明.md 中的遗留项与异常。" -ForegroundColor Green
