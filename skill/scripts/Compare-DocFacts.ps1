<#
.SYNOPSIS
  文档中的事实字段（BSSID / 信道 / IP）与实机扫描结果核对，并做"旧错误表述"全文体检。

.用途
  把 G7（推测当事实写进文档）、E04（记录与实机不符）变成一次可重复的检查：
  1) 抓出文档里所有 MAC/BSSID，标出"当前扫描不到"的条目（提示，不一定是错）；
  2) 抓出"远位 / 无法保存 / 开放网络 / 整体验收通过 / 验收不通过"等已知旧表述，
     定位到 文件:行，供人工判断是"引用/更正块"还是"未改干净"。

.参数
  -Docs        要检查的 md 文件/目录；默认 `<ProjectRoot>\outputs` 及其 `measurements` 子目录。
  -ProjectRoot 可选。项目根目录，默认当前目录。
  -OutFile     结果写入文件。
  -LintPhrases 自定义旧表述列表（字符串数组），默认见脚本内 $defaultLint。
  -SkipScan    跳过无线扫描，只做文档体检（无 Wi-Fi 网卡或权限不足时用）。

.平台
  Windows（扫描依赖 `netsh wlan`）；加 -SkipScan 后可在任意平台做文本体检。

.读写
  只读：只读文档与无线扫描，不修改任何文件与配置。
  回滚：无需回滚。

.示例
  .\Compare-DocFacts.ps1 -ProjectRoot "<PROJECT_ROOT>"
  .\Compare-DocFacts.ps1 -Docs ".\outputs\measurements" -OutFile .\doc-lint.md
  .\Compare-DocFacts.ps1 -SkipScan -LintPhrases "整体验收通过","无需验证"
#>
[CmdletBinding()]
param(
    [string[]]$Docs,
    [string]$OutFile,
    [string[]]$LintPhrases,
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$SkipScan
)

$ErrorActionPreference = 'Continue'
if (-not $Docs -or $Docs.Count -eq 0) {
    $candidates = @(
        (Join-Path $ProjectRoot 'outputs'),
        (Join-Path $ProjectRoot 'outputs\measurements')
    )
    $Docs = @($candidates | Where-Object { Test-Path $_ })
    if ($Docs.Count -eq 0) { throw "未找到默认文档目录，请用 -Docs 指定要检查的 md 文件/目录" }
}

$files = foreach ($d in $Docs) {
    if (Test-Path $d -PathType Container) { Get-ChildItem $d -Filter *.md -File }
    elseif (Test-Path $d) { Get-Item $d }
}
$files = @($files | Sort-Object FullName -Unique | Where-Object { $_.Name -notmatch '^99-diff' })

# 实机可见 BSSID
if ($SkipScan) {
    $scan = ''
} else {
    $scan = (netsh wlan show networks mode=bssid) -join "`n"
}
$liveBssids = @([regex]::Matches($scan, '(?i)\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique)
$liveSsids = @([regex]::Matches($scan, '(?m)^\s*SSID\s+\d+\s*:\s*(.+)$') |
    ForEach-Object { $_.Groups[1].Value.Trim() } |
    Where-Object { $_ -and $_ -notmatch ':' -and $_.Length -le 32 } |
    Sort-Object -Unique)

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 文档事实核对（' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '）')
$md.Add('')
$md.Add('- 实机扫描：' + $(if ($SkipScan) { '已跳过（-SkipScan）' } else { '已完成' }))
$md.Add(('- 实机扫描到 BSSID 数：' + $liveBssids.Count))
$md.Add('')

# 1) 文档中的 BSSID vs 实机
$md.Add('## 1. 文档中提到的 BSSID 与当前扫描')
$md.Add('')
$md.Add('> “不可见”只是提示：设备关机、隐藏 SSID 或扫描被截断都会造成，不等于文档写错；需人工确认。')
$md.Add('')
$md.Add('| 文件 | 行 | BSSID | 当前是否可见 |')
$md.Add('|---|---|---|---|')
$unknown = 0
foreach ($f in $files) {
    $i = 0
    foreach ($line in (Get-Content $f.FullName -ErrorAction SilentlyContinue)) {
        $i++
        foreach ($m in [regex]::Matches($line, '(?i)\b([0-9a-f]{2}:){5}[0-9a-f]{2}\b')) {
            $b = $m.Value.ToLower()
            $seen = if ($liveBssids -contains $b) { '可见' } else { '不可见（可能已改名/关机，或文档写错）' }
            if ($liveBssids -notcontains $b) { $unknown++ }
            $md.Add(('| {0} | {1} | {2} | {3} |' -f $f.Name, $i, $b, $seen))
        }
    }
}
if ($unknown -eq 0 -and @($files).Count -gt 0) { $md.Add('| — | — | — | 全部可见或无 BSSID |') }

# 2) 旧错误表述体检
$defaultLint = @('整体验收通过', '验收不通过', '无法保存', '开放性网络', '开放网络', '应该支持', '一般来说', '肯定是', '无需验证')
if (-not $LintPhrases -or $LintPhrases.Count -eq 0) { $LintPhrases = $defaultLint }

$md.Add('')
$md.Add('## 2. 旧错误表述体检（命中不等于错，需人工判断是否在引用/更正块中）')
$md.Add('')
$md.Add('| 文件 | 行 | 命中词 | 原文片段 |')
$md.Add('|---|---|---|---|')
$hits = 0
foreach ($f in $files) {
    $i = 0
    foreach ($line in (Get-Content $f.FullName -ErrorAction SilentlyContinue)) {
        $i++
        foreach ($p in $LintPhrases) {
            if ($line -like ('*' + $p + '*')) {
                $hits++
                $snip = if ($line.Length -gt 60) { $line.Substring(0, 60) + '…' } else { $line }
                $md.Add(('| {0} | {1} | {2} | {3} |' -f $f.Name, $i, $p, $snip.Replace('|', '\|')))
            }
        }
    }
}
if ($hits -eq 0) { $md.Add('| — | — | — | 未命中 |') }

$md.Add('')
$md.Add(('> 共检查 {0} 个文件；BSSID 不可见 {1} 处；旧表述命中 {2} 处。' -f @($files).Count, $unknown, $hits))

$text = $md -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8 }
