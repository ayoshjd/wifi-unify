<#
.SYNOPSIS
  扫描文档/脚本中可能存在的密码明文或可还原片段，输出自动脱敏的命中清单。

.用途
  落实 S1/S2 与 E09：敏感信息只允许写"长度/字符类别/是否一致"。
  本脚本只做**粗筛**，命中不等于一定泄露，需人工确认；未命中也不能替代人工检查。

.参数
  -Paths        要扫描的文件或目录；默认 `<ProjectRoot>\outputs`、`work`、`skills` 三处。
  -ProjectRoot  可选。项目根目录，默认当前目录。
  -IncludeCode  同时扫描 .ps1/.js/.ts（默认只扫文档类 .md/.json/.txt/.csv/.html）。
  -OutFile      结果写入文件。
  -MaxShow      每个文件最多列出的命中行数，默认 20。

.平台
  PowerShell 7+（`pwsh`）。纯文件操作，可在任意 OS 运行；不支持 Windows PowerShell 5.1。

.读写
  只读：只读文件内容；输出中**不打印命中值的原文**，只给长度。
  不修改任何文件。

.回滚
  无需回滚。

.示例
  .\Test-SensitiveLeak.ps1 -ProjectRoot "<PROJECT_ROOT>"
  .\Test-SensitiveLeak.ps1 -Paths ".\outputs",".\skills" -IncludeCode -OutFile ".\leak-scan.md"
#>
[CmdletBinding()]
param(
    [string[]]$Paths,
    [string]$ProjectRoot = (Get-Location).Path,
    [switch]$IncludeCode,
    [string]$OutFile,
    [int]$MaxShow = 20
)

$ErrorActionPreference = 'Continue'
if (-not $Paths -or $Paths.Count -eq 0) {
    $Paths = @(
        (Join-Path $ProjectRoot 'outputs'),
        (Join-Path $ProjectRoot 'work'),
        (Join-Path $ProjectRoot 'skills')
    ) | Where-Object { Test-Path $_ }
}

$exts = @('.md', '.json', '.txt', '.csv', '.html')
if ($IncludeCode) { $exts += @('.ps1', '.js', '.ts') }

$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($p in $Paths) {
    if (-not (Test-Path $p)) { continue }
    if (Test-Path $p -PathType Leaf) { $files.Add((Get-Item $p)); continue }
    Get-ChildItem $p -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $exts -contains $_.Extension.ToLower() } |
        ForEach-Object { $files.Add($_) }
}
$self = $MyInvocation.MyCommand.Path
$files = @($files | Sort-Object FullName -Unique | Where-Object { $_.FullName -ne $self })

# 键名 + 分隔符 + 疑似值；值至少 4 字符
$patterns = @(
    @{ Name = '键值型口令'; Regex = '(?i)(?:password|passwd|pwd|passphrase|psk|wpa[-_ ]?key|pre[-_ ]?shared[-_ ]?key)\s*(?:=|:|：)\s*["'']?([^\s"'',;；]{6,})' },
    @{ Name = '中文口令'; Regex = '(?:无线密码|WiFi密码|Wi-Fi密码|密码|口令|密钥)\s*(?:=|:|：)\s*["'']?([^\s"'',;；]{4,})' }
)
$placeholder = '^(?:\*{3,}|x{3,}|X{3,}|<.*>|\[.*\]|待.{0,8}|长度=\d+.*|类别=.*|---*|—|n/?a|none|masked|redacted|change.?me|your.+)$'

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 敏感信息粗筛（' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '）')
$md.Add('')
$md.Add("扫描文件数：$(@($files).Count)（扩展名：$($exts -join ', ')）")
$md.Add('')
$md.Add('| 文件 | 行 | 类型 | 命中值特征（已脱敏） |')
$md.Add('|---|---|---|---|')

$hitCount = 0
$fileHit = @{}
foreach ($f in $files) {
    $lineNo = 0
    $shown = 0
    foreach ($line in (Get-Content $f.FullName -ErrorAction SilentlyContinue)) {
        $lineNo++
        foreach ($pt in $patterns) {
            foreach ($m in [regex]::Matches($line, $pt.Regex)) {
                $val = $m.Groups[1].Value.Trim('"', "'")
                if ($val -match $placeholder) { continue }
                # 排除明显的变量/占位
                if ($val -match '^[$%(]|^=\{') { continue }
                $hitCount++
                $fileHit[$f.FullName] = $true
                if ($shown -lt $MaxShow) {
                    $shown++
                    $shape = "长度=$($val.Length)（原文不展示）"
                    $md.Add(('| {0} | {1} | {2} | {3} |' -f $f.Name, $lineNo, $pt.Name, $shape))
                }
            }
        }
    }
    if ($shown -ge $MaxShow) { $md.Add(("| {0} | … | 已达上限 {1} 条 | 其余省略 |" -f $f.Name, $MaxShow)) }
}

if ($hitCount -eq 0) { $md.Add('| — | — | — | 未命中 |') }
$md.Add('')
$md.Add('> 命中仅供参考：可能是规则/模板里的说明文字，也可能是真泄露。逐条打开原文确认，确认为真则按 S2 改为「长度/类别/是否一致」。')
$md.Add('> 本报告本身不含命中值原文。未命中也不等于绝对安全，发布前仍需人工通读。')

$text = $md -join "`n"
Write-Output $text
if ($OutFile) {
    $dir = Split-Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $text | Out-File $OutFile -Encoding utf8
    Write-Host "已写入 $OutFile" -ForegroundColor Cyan
}

if ($hitCount -gt 0) { exit 1 }
exit 0
