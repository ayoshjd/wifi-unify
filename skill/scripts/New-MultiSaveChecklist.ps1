<#
.SYNOPSIS
  生成"多保存按钮 / 多频段逐段保存"检查清单（Markdown，可打印勾选）。

.用途
  落实 V2 与 E05/E12：设备 UI 常见 2.4G、5G 各一个独立"保存"按钮，
  只点一个就以为全部生效，是返工高发点。本脚本把"段 → 保存按钮 → 字段 → 回读"
  固化成一张必须逐项勾选的纸，避免漏段。

.参数
  -Tag           必填。阶段对象标识，例 "S1-AP-A"。
  -Device        必填。设备名/位置，例 "<品牌型号/房间>"。
  -ManagementUrl 可选。管理地址。
  -Segments      段定义，格式 "段名::保存按钮文字"；可重复。默认 2.4G/5G 各一个"保存"。
  -Fields        可选。需要回读的字段名，可重复。
  -ProjectRoot   可选。项目根目录，默认当前目录。
  -OutRoot       输出目录，默认 `<ProjectRoot>\outputs\measurements`。
  -OutFile       可选。直接指定输出文件。

.平台
  PowerShell 7+（`pwsh`）。纯文件操作，可在任意 OS 运行；不支持 Windows PowerShell 5.1。

.读写
  可写：只写一份清单 Markdown。不修改任何设备与网络配置。

.回滚
  删除生成的清单文件即可；系统状态无变化。

.示例
  .\New-MultiSaveChecklist.ps1 -Tag "S1-AP-A" -Device "<设备名/位置>" `
      -Segments "2.4G::保存","5G::保存","无线安全::保存" `
      -Fields "SSID","信道","加密方式","无线密码"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$Device,
    [string]$ManagementUrl = '',
    [string[]]$Segments = @('2.4G::保存', '5G::保存'),
    [string[]]$Fields = @('SSID', '信道', '加密方式', '无线密码'),
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$OutRoot,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $OutRoot) { $OutRoot = Join-Path $ProjectRoot 'outputs\measurements' }

$segList = New-Object System.Collections.Generic.List[object]
foreach ($s in $Segments) {
    $idx = $s.IndexOf('::')
    if ($idx -gt 0) {
        $name = $s.Substring(0, $idx).Trim()
        $btn = $s.Substring($idx + 2).Trim()
    } else {
        $name = $s.Trim(); $btn = '保存'
    }
    if (-not $name) { continue }
    $segList.Add([pscustomobject]@{ Name = $name; Button = $(if ($btn) { $btn } else { '保存' }) })
}
if ($segList.Count -eq 0) { throw "-Segments 为空" }
if (-not $Fields -or $Fields.Count -eq 0) { throw "-Fields 为空" }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutFile) {
    if (-not (Test-Path $OutRoot)) { New-Item -ItemType Directory -Path $OutRoot -Force | Out-Null }
    $OutFile = Join-Path $OutRoot "$Tag-$ts-多保存清单.md"
}

$esc = { param($s) (([string]$s) -replace '\|', '\|') }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 多保存按钮 / 多频段逐段保存清单：$Tag")
$lines.Add('')
$lines.Add('| 项目 | 内容 |')
$lines.Add('|---|---|')
$lines.Add("| 设备 | $(& $esc $Device) |")
if ($ManagementUrl) { $lines.Add("| 管理地址 | $ManagementUrl |") }
$lines.Add("| 生成时间 | $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') |")
$lines.Add("| 段数 | $($segList.Count) |")
$lines.Add('')
$lines.Add('## 1. 逐段保存（每段都必须点自己的保存按钮）')
$lines.Add('')
$lines.Add('| # | 段 | 保存按钮文字 | 已点保存 | 保存后是否重进页面 | 回读时间 | 备注 |')
$lines.Add('|---|---|---|---|---|---|---|')
$i = 0
foreach ($s in $segList) {
    $i++
    $lines.Add("| $i | $(& $esc $s.Name) | $(& $esc $s.Button) | [ ] | [ ] | | |")
}
$lines.Add('')
$lines.Add('## 2. 逐段字段回读（回读值必须等于写入值）')
$lines.Add('')
$lines.Add('| 段 | 字段 | 写入值 | 回读值 | 一致 | 证据 |')
$lines.Add('|---|---|---|---|---|---|')
foreach ($s in $segList) {
    foreach ($f in $Fields) {
        $lines.Add("| $(& $esc $s.Name) | $(& $esc $f) | | | [ ] 是 / [ ] 否 | |")
    }
}
$lines.Add('')
$lines.Add('## 3. 完成判据（缺一条即视为未完成）')
$lines.Add('')
$lines.Add('- [ ] 每个段都点了**本段**的保存按钮，不是只点第一个')
$lines.Add('- [ ] 每段保存后都重新进入该页面回读，不是凭记忆')
$lines.Add('- [ ] 每个字段的回读值 = 写入值')
$lines.Add('- [ ] 无线类字段用第二来源复核（本机 `netsh wlan show networks mode=bssid` 或手机 Wi-Fi 列表）')
$lines.Add('- [ ] 涉及密码的字段只记录「长度/类别/是否一致」，本文件无明文')
$lines.Add('')
$lines.Add('## 4. 失败处理')
$lines.Add('')
$lines.Add('- 某段回读不一致：视为**未生效**，回写该段原值并重新保存，再回读一次。')
$lines.Add('- 连续两次不一致：停手，记录页面实际表现（按钮位置/提示语），报告，不得连续试。')
$lines.Add('- 只保存了一段就继续：属于 V2 违规，必须回退到未保存状态重做本清单。')

$text = $lines -join "`n"
$text | Out-File $OutFile -Encoding utf8
Write-Output $text
Write-Host "清单已写入：$OutFile" -ForegroundColor Cyan
Write-Host "打印后在现场逐项勾选，填写后归档到 outputs\measurements。" -ForegroundColor Green
