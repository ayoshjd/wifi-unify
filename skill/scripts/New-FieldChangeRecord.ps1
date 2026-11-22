<#
.SYNOPSIS
  生成"字段级变更留证"记录（Markdown + JSON），供逐字段回读比对使用。

.用途
  把 G8（回读靠肉眼、无留证）与 G12（敏感字段整页倾倒）变成固定动作：
  1) 开工前把每个字段的 before / target / 证据等级 / 来源写成一份规格 JSON；
  2) secret=true 的字段只允许写"长度=N / 类别=… / 一致=…"，出现明文直接报错；
  3) 生成字段表，现场照着逐项核对；回读值由 Compare-FieldReadback.ps1 回填并比对。

.参数
  -Spec     必填。变更规格 JSON 路径（模板用 -Init 生成）。
  -Init     生成模板到指定路径后退出，不写任何记录。
  -ProjectRoot 可选。项目根目录，默认当前目录。
  -OutRoot  记录输出目录，默认 `<ProjectRoot>\outputs\measurements`。
  -Stamp    可选。时间戳（yyyyMMdd-HHmmss），用于复现文件名。
  -Force    同名文件已存在时覆盖。

.平台
  PowerShell 7+（`pwsh`）。纯文件操作，可在任意 OS 运行；不支持 Windows PowerShell 5.1。

.读写
  可写：只在 OutRoot 下写 `<Tag>-<时间戳>-字段变更记录.md/.json`。
  不修改任何网络配置，不接触设备。

.回滚
  删除本次生成的两个同名文件即可；系统状态无变化。

.示例
  .\New-FieldChangeRecord.ps1 -Init .\work\specs\S1-AP-A.json
  .\New-FieldChangeRecord.ps1 -Spec .\work\specs\S1-AP-A.json -ProjectRoot "<PROJECT_ROOT>"
#>
[CmdletBinding()]
param(
    [string]$Spec,
    [string]$Init,
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$OutRoot,
    [string]$Stamp,
    [switch]$Force
)

if (-not $OutRoot) { $OutRoot = Join-Path $ProjectRoot 'outputs\measurements' }

$ErrorActionPreference = 'Stop'

$template = @'
{
  "_note": "before/target 必须是实机回读值；secret=true 的字段只允许写『长度=N / 类别=… / 一致=…』。layer 只能填 L1/L2/L3/DNS/代理 之一。示例值均为占位，不得照抄。",
  "tag": "S1-AP-A",
  "device": "<设备名/位置>",
  "managementUrl": "http://192.0.2.10",
  "operator": "",
  "layer": "L2",
  "phase": "before",
  "fields": [
    {
      "page": "<设备页面路径，如 网络参数/LAN 设置>",
      "field": "LAN IP",
      "before": "待回读",
      "target": "192.0.2.10",
      "secret": false,
      "evidence": "A",
      "source": "页面回读",
      "note": ""
    },
    {
      "page": "<设备页面路径，如 无线设置/安全>",
      "field": "无线密码",
      "before": "长度=待填 / 类别=待填",
      "target": "长度=待填 / 类别=待填 / 与基准一致=待确认",
      "secret": true,
      "evidence": "A",
      "source": "人工两次录入",
      "note": "禁止写明文"
    }
  ]
}
'@

if ($Init) {
    if ((Test-Path $Init) -and -not $Force) { throw "模板已存在：$Init（加 -Force 覆盖）" }
    $initDir = Split-Path $Init -Parent
    if ($initDir) { New-Item -ItemType Directory -Path $initDir -Force | Out-Null }
    $template | Out-File $Init -Encoding utf8
    Write-Host "已生成模板：$Init" -ForegroundColor Cyan
    return
}

if (-not $Spec -or -not (Test-Path $Spec)) { throw "缺少 -Spec 或文件不存在：$Spec" }

# 敏感字段允许的写法：长度= / 类别= / 一致= / 与X一致= / 是否一致=
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

$specObj = Get-Content $Spec -Raw -Encoding utf8 | ConvertFrom-Json
$tag = [string]$specObj.tag
if ([string]::IsNullOrWhiteSpace($tag)) { throw "规格缺少 tag" }
if ([string]::IsNullOrWhiteSpace([string]$specObj.device)) { throw "规格缺少 device" }
if ($specObj.layer -and $specObj.layer -notin @('L1', 'L2', 'L3', 'DNS', '代理')) {
    throw "layer 只能是 L1/L2/L3/DNS/代理，当前为：$($specObj.layer)"
}

$fieldsIn = @($specObj.fields)
if ($fieldsIn.Count -eq 0) { throw "规格 fields 为空" }

$fieldsOut = New-Object System.Collections.Generic.List[object]
foreach ($f in $fieldsIn) {
    if ([string]::IsNullOrWhiteSpace([string]$f.field)) { throw "存在 field 为空的条目" }
    $isSecret = [bool]$f.secret
    foreach ($k in 'before', 'target') {
        $v = [string]$f.$k
        if ($isSecret -and -not (Test-SecretForm $v)) {
            throw ("字段『{0}』的 {1} 含疑似明文。敏感字段只允许写：长度=N / 类别=… / 一致=…" -f $f.field, $k)
        }
    }
    if (-not $isSecret -and ([string]$f.field -match '密码|口令|密钥|password|passwd|psk|key')) {
        Write-Warning ("字段『{0}』名字像密钥类，但 secret=false；若值确实敏感请改为 true" -f $f.field)
    }
    if ([string]$f.evidence -and [string]$f.evidence -notin @('A', 'B', 'C')) {
        throw ("字段『{0}』的 evidence 只能是 A/B/C" -f $f.field)
    }
    $fieldsOut.Add([pscustomobject]@{
        page           = [string]$f.page
        field          = [string]$f.field
        before         = [string]$f.before
        target         = [string]$f.target
        secret         = $isSecret
        evidence       = [string]$f.evidence
        source         = [string]$f.source
        note           = [string]$f.note
        readback       = $null
        readbackStatus = '待回读'
    })
}

if (-not $Stamp) { $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss' }
$record = [pscustomobject]@{
    tag           = $tag
    device        = [string]$specObj.device
    managementUrl = [string]$specObj.managementUrl
    operator      = [string]$specObj.operator
    layer         = [string]$specObj.layer
    phase         = [string]$specObj.phase
    createdAt     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    specPath      = (Resolve-Path $Spec).Path
    fields        = $fieldsOut.ToArray()
}

if (-not (Test-Path $OutRoot)) { New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null }
$baseName = "$tag-$Stamp-字段变更记录"
$jsonPath = Join-Path $OutRoot "$baseName.json"
$mdPath = Join-Path $OutRoot "$baseName.md"
if (((Test-Path $jsonPath) -or (Test-Path $mdPath)) -and -not $Force) {
    throw "记录已存在：$baseName（换 -Stamp 或加 -Force）"
}

# --- Markdown ---
$esc = { param($s) (([string]$s) -replace '\|', '\|') }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 字段变更记录：$tag")
$lines.Add('')
$lines.Add('| 项目 | 内容 |')
$lines.Add('|---|---|')
$lines.Add("| 设备 | $($record.device) |")
$lines.Add("| 管理地址 | $($record.managementUrl) |")
$lines.Add("| 本次只改一层 | $($record.layer) |")
$lines.Add("| 操作者 | $($record.operator) |")
$lines.Add("| 规格文件 | $($record.specPath) |")
$lines.Add("| 生成时间 | $($record.createdAt) |")
$lines.Add('')
$lines.Add('## 字段清单')
$lines.Add('')
$lines.Add('| # | 页面/路径 | 字段 | 变更前 | 写入值 | 证据 | 来源 | 回读值 | 回读结果 |')
$lines.Add('|---|---|---|---|---|---|---|---|---|')
$i = 0
foreach ($f in $fieldsOut) {
    $i++
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
        $i, (& $esc $f.page), (& $esc $f.field), (& $esc $f.before), (& $esc $f.target),
        $f.evidence, (& $esc $f.source), '(待填)', $f.readbackStatus))
}
$lines.Add('')
$lines.Add('> 回读值不要手改本文件；用 `Compare-FieldReadback.ps1 -Record <本文件同名 .json> -Set "字段=回读值"` 回填并比对。')
$lines.Add('> 敏感字段只写"长度/类别/是否一致"；本文件不得出现密码明文或可还原片段（S2）。')
$lines.Add('')
$lines.Add('## 回滚值（逐项）')
$lines.Add('')
$lines.Add('| # | 字段 | 回滚到 | 回滚后必须回读到 |')
$lines.Add('|---|---|---|---|')
$i = 0
foreach ($f in $fieldsOut) {
    $i++
    $lines.Add(('| {0} | {1} | {2} | {3} |' -f $i, (& $esc $f.field), (& $esc $f.before), (& $esc $f.before)))
}

$lines -join "`n" | Out-File $mdPath -Encoding utf8
$record | ConvertTo-Json -Depth 8 | Out-File $jsonPath -Encoding utf8

Write-Host "已生成：$mdPath" -ForegroundColor Cyan
Write-Host "已生成：$jsonPath" -ForegroundColor Cyan
Write-Host "下一步：实施变更后运行 Compare-FieldReadback.ps1 回填并比对。" -ForegroundColor Green
