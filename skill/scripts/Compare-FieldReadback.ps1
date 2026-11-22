<#
.SYNOPSIS
  把字段回读值与写入值逐字段比对，输出一致/不一致/待回读，并把结果写回记录 JSON。

.用途
  落实 V1（保存后立刻逐字段回读）与 V2（多保存按钮逐段回读）：
  - 未回读 = 未完成，默认判失败；
  - 不一致 = 按"未生效"处理，不得往下走；
  - 敏感字段只比较掩码串（长度/类别/一致），不接触明文。

.参数
  -Record        必填。New-FieldChangeRecord.ps1 生成的记录 JSON。
  -Set           可选。回读值列表，逗号分隔，如 `"LAN IP=192.0.2.10","DHCP服务=关闭"`；只按第一个等号切分。
  -OutFile       可选。比对报告输出路径；默认与记录同目录的 `<记录名>-回读比对.md`。
  -AllowPartial  允许存在"待回读"（仍不允许"不一致"）。

.读写
  可写：回写记录 JSON 的 readback/readbackStatus 字段，并写一份比对报告。
  不修改任何网络配置，不接触设备。

.回滚
  用版本控制或备份恢复该 JSON；删除比对报告即可；系统状态无变化。

.示例
  .\Compare-FieldReadback.ps1 -Record .\outputs\measurements\S1-AP-A-20260101-090000-字段变更记录.json `
      -Set "LAN IP=192.0.2.10","DHCP服务=关闭"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Record,
    [string[]]$Set,
    [string]$OutFile,
    [switch]$AllowPartial
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Record)) { throw "记录不存在：$Record" }

function Test-SecretForm([string]$v) {
    if ([string]::IsNullOrWhiteSpace($v)) { return $true }
    foreach ($t in ($v -split '[/／,，;；]')) {
        $t = $t.Trim()
        if (-not $t) { continue }
        if ($t -match '^长度=(\d+|待填|待确认|待回读)$') { continue }
        if ($t -match '^类别=[^\s]+$') { continue }
        if ($t -match '^(一致|是否一致)=(是|否|未知|待确认|待填)$') { continue }
        if ($t -match '^与.+一致=(是|否|未知|待确认|待填)$') { continue }
        return $false
    }
    return $true
}

# 敏感字段按"属性集合"比较：顺序、空格、分隔符不同不算差异
function ConvertTo-SecretShape([string]$v) {
    $tokens = @()
    foreach ($t in ($v -split '[/／,，;；]')) {
        $t = $t.Trim()
        if ($t) { $tokens += $t.ToLower() }
    }
    return (($tokens | Sort-Object) -join '|')
}

$obj = Get-Content $Record -Raw -Encoding utf8 | ConvertFrom-Json
$fields = @($obj.fields)
if ($fields.Count -eq 0) { throw "记录中没有 fields" }

if ($Set) {
    foreach ($pair in $Set) {
        $idx = $pair.IndexOf('=')
        if ($idx -lt 1) { Write-Warning "忽略无法解析的 -Set：$pair"; continue }
        $name = $pair.Substring(0, $idx).Trim()
        $value = $pair.Substring($idx + 1).Trim()
        $hit = @($fields | Where-Object { $_.field -eq $name })
        if ($hit.Count -eq 0) { Write-Warning "记录里没有字段：$name"; continue }
        $f = $hit[0]
        if ($f.secret -and -not (Test-SecretForm $value)) {
            throw ("字段『{0}』是敏感字段，只允许写：长度=N / 类别=… / 一致=…" -f $name)
        }
        $f.readback = $value
    }
}

$rows = New-Object System.Collections.Generic.List[object]
$same = 0; $diff = 0; $pending = 0; $secretCount = 0
foreach ($f in $fields) {
    if ($f.secret) { $secretCount++ }
    $rb = [string]$f.readback
    if ([string]::IsNullOrWhiteSpace($rb)) {
        $status = '待回读'; $pending++
    } elseif ($f.secret) {
        if ((ConvertTo-SecretShape $rb) -eq (ConvertTo-SecretShape ([string]$f.target))) { $status = '一致'; $same++ }
        else { $status = '不一致'; $diff++ }
    } elseif ($rb.Trim() -eq ([string]$f.target).Trim()) {
        $status = '一致'; $same++
    } else {
        $status = '不一致'; $diff++
    }
    $f.readbackStatus = $status
    $rows.Add([pscustomobject]@{
        Page = [string]$f.page; Field = [string]$f.field; Before = [string]$f.before
        Target = [string]$f.target; Readback = $(if ($rb) { $rb } else { '(空)' })
        Status = $status; Evidence = [string]$f.evidence
    })
}

# 回写记录
$obj | ConvertTo-Json -Depth 8 | Out-File $Record -Encoding utf8

# 报告
if (-not $OutFile) {
    $dir = Split-Path $Record -Parent
    $base = [IO.Path]::GetFileNameWithoutExtension($Record)
    $OutFile = Join-Path $dir "$base-回读比对.md"
}
$esc = { param($s) (([string]$s) -replace '\|', '\|') }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 字段回读比对：$($obj.tag)")
$lines.Add('')
$lines.Add("| 设备 | 时间 | 一致 | 不一致 | 待回读 |")
$lines.Add('|---|---|---|---|---|')
$lines.Add("| $(& $esc $obj.device) | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $same | $diff | $pending |")
$lines.Add('')
$lines.Add('| 页面/路径 | 字段 | 变更前 | 写入值 | 回读值 | 结果 | 证据 |')
$lines.Add('|---|---|---|---|---|---|---|')
foreach ($r in $rows) {
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
        (& $esc $r.Page), (& $esc $r.Field), (& $esc $r.Before), (& $esc $r.Target),
        (& $esc $r.Readback), $r.Status, $r.Evidence))
}
$lines.Add('')
if ($diff -gt 0) {
    $lines.Add('> **结论：不通过。** 存在回读不一致，按"未生效"处理，先回写原值并重新保存回读，不得进入下一步。')
} elseif ($pending -gt 0 -and -not $AllowPartial) {
    $lines.Add('> **结论：不通过。** 存在未回读字段；回读完成前视为未完成。')
} else {
    $lines.Add('> **结论：通过**（本记录范围内）。仍需完成一致性自检与链路检查。')
}
$lines.Add("> 本次记录含敏感字段 $secretCount 个；报告只保留掩码值。")

$lines -join "`n" | Out-File $OutFile -Encoding utf8
$lines -join "`n" | Write-Output
Write-Host "报告已写入：$OutFile" -ForegroundColor Cyan

if ($diff -gt 0) { exit 1 }
if ($pending -gt 0 -and -not $AllowPartial) { exit 1 }
exit 0
