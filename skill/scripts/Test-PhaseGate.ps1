<#
.SYNOPSIS
  阶段停点闸门：检查上一阶段的证据是否齐全，不齐则阻止进入下一阶段。

.用途
  把「快照没成对」「验收口径没写」「遗留项没登记」「没人批准」变成一道可执行的闸门。
  在每阶段结束时跑一次；PASS 才允许开始下一阶段，FAIL 必须补证或回滚。

.检查项
  1. 规格文件可解析，phase / previousPhase 存在；
  2. 快照成对：`<tag>-*-before` 与 `<tag>-*-after` 均存在（requirePair）；
  3. 快照非空：before/after 目录各自至少有 minFiles 个文件，且至少一个文件非空；
  4. 快照差异：after 目录内存在 99-diff-* 且非空（requireDiff）；
  5. 验收口径：文件存在，且包含「判据 / 观察项 / 不作判据」三节，每节有实质内容；
  6. 未复核结论：判据章节中带未复核标记（待复核/B级/C级/推测/未复测/未验证）
     且未标注「已复核」的行，一律判 FAIL——未复核的测量结果不得当作判据；
  7. 遗留清单：文件存在，每条有 id/status/owner；open 必须有 owner；ID 不重复；
     ID 必须符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$`；
     可选 mirrorFiles：每个 ID 必须在指定文档中可检索到；
     可选 previousPhaseFile：上一阶段每个 ID 必须在本阶段清单中出现（承接检查）；
  8. 停点声明：00-快照说明.md 含指定关键词（默认「停点」）；
  9. 人工批准：approval.required=true 时，必须有 by 与可解析的 at。

  末尾额外输出「缺失项汇总」，逐条列出 FAIL 项，并明确写出「拒绝进入下一阶段」。

.参数
  -GateSpec    必填。闸门规格 JSON（模板见 assets/phase-gate.example.json）。
  -ProjectRoot 可选。项目根目录，默认当前目录；规格中的相对路径以此为基准。
  -OutFile     可选。输出 Markdown 报告。
  -NoExitCode  只输出报告，不因 FAIL 返回非零。

.平台
  PowerShell 7+（`pwsh`）。纯文件操作，可在任意 OS 运行；不支持 Windows PowerShell 5.1。

.读写
  只读：只读规格、快照目录、验收/遗留文档；不修改任何文件与设备。
  唯一写入是 -OutFile 指定的报告。

.回滚
  删除报告即可；系统状态无变化。

.示例
  .\Test-PhaseGate.ps1 -GateSpec .\work\gates\P1-AP-A.json
  .\Test-PhaseGate.ps1 -GateSpec .\work\gates\P1-AP-A.json -OutFile .\outputs\gate-P1.md

退出码
  0 = PASS 或仅 WARN；1 = 有 FAIL；3 = 规格不可读/不合法。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GateSpec,
    [string]$ProjectRoot = (Get-Location).Path,
    [string]$OutFile,
    [switch]$NoExitCode
)

$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.Generic.List[object]

function Add-Gate([string]$level, [string]$item, [string]$detail) {
    $results.Add([pscustomobject]@{ Level = $level; Item = $item; Detail = $detail })
}

function Resolve-ProjectPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $ProjectRoot $p)
}

function Test-SectionHasContent([string]$file, [string]$keyword) {
    $lines = @(Get-Content $file -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $false }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s{0,3}#{1,6}\s' -and $lines[$i] -like "*$keyword*") { $idx = $i; break }
    }
    if ($idx -lt 0) { return $false }
    for ($j = $idx + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^\s{0,3}#{1,6}\s') { break }
        $t = $lines[$j].Trim()
        if ($t -and $t -notmatch '^[-*]\s*$' -and $t -notmatch '^（?待(填|补|确认)）?$' -and $t -notmatch '^TBD$') { return $true }
    }
    return $false
}

function Get-UnreviewedCriterionLines([string]$file, [string[]]$markers, [string]$reviewedMarker) {
    $bad = New-Object System.Collections.Generic.List[string]
    $lines = @(Get-Content $file -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return @() }
    $inSection = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^\s{0,3}#{1,6}\s') {
            $inSection = ($line -like '*判据*')
            continue
        }
        if (-not $inSection) { continue }
        $t = $line.Trim()
        if (-not $t) { continue }
        # 表头与分隔行不算判据
        if ($t -match '^\|?\s*-{3,}') { continue }
        if ($t -match '^\|\s*#?\s*\|') { continue }
        $hitMarker = $false
        foreach ($m in $markers) { if ($t -like "*$m*") { $hitMarker = $true; break } }
        if ($hitMarker -and ($t -notlike "*$reviewedMarker*")) {
            $bad.Add("行 $($i + 1)：$t")
        }
    }
    return @($bad)
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# 阶段停点闸门报告')
$md.Add('')
$md.Add("- 生成时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$md.Add("- 项目根目录：$ProjectRoot")
$md.Add("- 规格文件：$GateSpec")
$md.Add('')

# 0) 规格
if (-not (Test-Path $GateSpec)) {
    $md.Add('## 结果：FAIL')
    $md.Add('')
    $md.Add("规格文件不存在：$GateSpec")
    $text = $md -join "`n"
    Write-Output $text
    if ($OutFile) { $text | Out-File $OutFile -Encoding utf8 }
    exit 3
}

try {
    $spec = Get-Content $GateSpec -Raw | ConvertFrom-Json
} catch {
    $md.Add('## 结果：FAIL')
    $md.Add('')
    $md.Add("规格 JSON 解析失败：$($_.Exception.Message)")
    $text = $md -join "`n"
    Write-Output $text
    if ($OutFile) { $text | Out-File $OutFile -Encoding utf8 }
    exit 3
}

if (-not $spec.phase) { Add-Gate 'FAIL' '规格 phase' '缺少 phase 字段' } else { Add-Gate 'PASS' '规格 phase' $spec.phase }
if (-not $spec.previousPhase) { Add-Gate 'WARN' '规格 previousPhase' '未填写，视为首阶段' } else { Add-Gate 'PASS' '规格 previousPhase' $spec.previousPhase }

$tag = $null
if ($spec.snapshot) {
    $tag = [string]$spec.snapshot.tag
    $snapRootRaw = [string]$spec.snapshot.root
    if (-not $snapRootRaw) { $snapRootRaw = 'backup/snapshots' }
    $snapRoot = Resolve-ProjectPath $snapRootRaw
    $requirePair = $true
    if ($null -ne $spec.snapshot.requirePair) { $requirePair = [bool]$spec.snapshot.requirePair }
    $requireDiff = $true
    if ($null -ne $spec.snapshot.requireDiff) { $requireDiff = [bool]$spec.snapshot.requireDiff }

    if (-not $tag) {
        Add-Gate 'FAIL' '快照 tag' 'snapshot.tag 为空，无法定位快照'
    } elseif ($tag -match '[\\/:*?"<>|\[\]\*\?]') {
        Add-Gate 'FAIL' '快照 tag' "tag 含非法字符：$tag"
    } elseif (-not (Test-Path $snapRoot)) {
        Add-Gate 'FAIL' '快照目录' "不存在：$snapRoot"
    } else {
        $before = @(Get-ChildItem $snapRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$tag-*-before" } | Sort-Object Name)
        $after = @(Get-ChildItem $snapRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$tag-*-after" } | Sort-Object Name)

        if ($requirePair) {
            if ($before.Count -eq 0) { Add-Gate 'FAIL' 'before 快照' "未找到 $tag-*-before" }
            else { Add-Gate 'PASS' 'before 快照' $before[-1].Name }
            if ($after.Count -eq 0) { Add-Gate 'FAIL' 'after 快照' "未找到 $tag-*-after" }
            else { Add-Gate 'PASS' 'after 快照' $after[-1].Name }
        } else {
            Add-Gate 'WARN' '快照成对' 'requirePair=false，跳过'
        }

        if ($after.Count -gt 0 -and $requireDiff) {
            $diff = @(Get-ChildItem $after[-1].FullName -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like '99-diff-*' })
            if ($diff.Count -eq 0) {
                Add-Gate 'FAIL' '快照差异' "after 目录缺少 99-diff-*：$($after[-1].FullName)"
            } elseif ($diff[-1].Length -le 0) {
                Add-Gate 'FAIL' '快照差异' "99-diff 为空：$($diff[-1].FullName)"
            } else {
                Add-Gate 'PASS' '快照差异' $diff[-1].Name
            }
        }

        # 快照非空：目录里至少 minFiles 个文件，且至少一个非空
        $minFiles = 3
        if ($null -ne $spec.snapshot.minFiles) { $minFiles = [int]$spec.snapshot.minFiles }
        foreach ($pair in @(@{ Name = 'before'; Dirs = $before }, @{ Name = 'after'; Dirs = $after })) {
            if ($pair.Dirs.Count -eq 0) { continue }
            $d = $pair.Dirs[-1]
            $files = @(Get-ChildItem $d.FullName -File -ErrorAction SilentlyContinue)
            $nonEmpty = @($files | Where-Object { $_.Length -gt 0 })
            if ($files.Count -lt $minFiles) {
                Add-Gate 'FAIL' "$($pair.Name) 快照内容" "只有 $($files.Count) 个文件，少于 minFiles=$minFiles：$($d.FullName)"
            } elseif ($nonEmpty.Count -eq 0) {
                Add-Gate 'FAIL' "$($pair.Name) 快照内容" "所有文件均为空，不能作为证据：$($d.FullName)"
            } else {
                Add-Gate 'PASS' "$($pair.Name) 快照内容" "$($files.Count) 个文件，其中 $($nonEmpty.Count) 个非空"
            }
        }

        if ($before.Count -gt 0 -and $after.Count -gt 0 -and $after[-1].Name -lt $before[-1].Name) {
            Add-Gate 'WARN' '快照时序' 'after 名称排序早于 before，请确认是否复用了旧快照'
        }

        # 停点声明：优先规格路径，否则用最新 after 的 00-快照说明.md
        $stopFile = $null
        if ($spec.stopNotice -and $spec.stopNotice.file) { $stopFile = Resolve-ProjectPath ([string]$spec.stopNotice.file) }
        elseif ($after.Count -gt 0) { $stopFile = Join-Path $after[-1].FullName '00-快照说明.md' }

        if (-not $stopFile -or -not (Test-Path $stopFile)) {
            $why = if (-not $stopFile) { '缺少 after 快照且未指定 stopNotice.file' } else { "路径不存在：$stopFile" }
            Add-Gate 'FAIL' '停点声明' "找不到 00-快照说明.md（$why）"
        } else {
            $keys = @('停点')
            if ($spec.stopNotice -and $spec.stopNotice.mustContain) { $keys = @($spec.stopNotice.mustContain) }
            $content = Get-Content $stopFile -Raw -ErrorAction SilentlyContinue
            $missing = @($keys | Where-Object { $content -notlike "*$_*" })
            if ($missing.Count -gt 0) {
                Add-Gate 'FAIL' '停点声明' ("$stopFile 缺少关键词：" + ($missing -join ', '))
            } else {
                Add-Gate 'PASS' '停点声明' ("$stopFile 含 " + ($keys -join ', '))
            }
        }
    }
} else {
    Add-Gate 'FAIL' '快照配置' '规格缺少 snapshot 段'
}

# 验收口径
if (-not $spec.acceptance -or -not $spec.acceptance.file) {
    Add-Gate 'FAIL' '验收口径' '规格缺少 acceptance.file'
} else {
    $accFile = Resolve-ProjectPath ([string]$spec.acceptance.file)
    if (-not (Test-Path $accFile)) {
        Add-Gate 'FAIL' '验收口径' "文件不存在：$accFile"
    } else {
        $sections = @('判据', '观察项', '不作判据')
        if ($spec.acceptance.requireSections) { $sections = @($spec.acceptance.requireSections) }
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($s in $sections) {
            if (-not (Test-SectionHasContent $accFile $s)) { $missing.Add($s) }
        }
        if ($missing.Count -gt 0) {
            Add-Gate 'FAIL' '验收口径' ("缺少或为空的章节：" + ($missing -join ' / '))
        } else {
            Add-Gate 'PASS' '验收口径' ("含 " + ($sections -join ' / ') + "，且均有内容")
        }

        # 未复核结论不得当作判据
        $markers = @('待复核', 'B 级', 'B级', 'C 级', 'C级', '推测', '未复测', '未验证')
        if ($spec.acceptance.unreviewedMarkers) { $markers = @($spec.acceptance.unreviewedMarkers) }
        $reviewedMarker = '已复核'
        if ($spec.acceptance.reviewedMarker) { $reviewedMarker = [string]$spec.acceptance.reviewedMarker }
        $critFile = $accFile
        if ($spec.acceptance.criteriaFile) { $critFile = Resolve-ProjectPath ([string]$spec.acceptance.criteriaFile) }
        if (-not (Test-Path $critFile)) {
            Add-Gate 'FAIL' '未复核结论' "判据文件不存在：$critFile"
        } else {
            $unreviewed = @(Get-UnreviewedCriterionLines $critFile $markers $reviewedMarker)
            if ($unreviewed.Count -gt 0) {
                Add-Gate 'FAIL' '未复核结论' ("判据章节存在未复核标记且无『$reviewedMarker』：" + ($unreviewed -join '；'))
            } else {
                Add-Gate 'PASS' '未复核结论' '判据章节未见未复核标记'
            }
        }
    }
}

# 遗留清单
if (-not $spec.leftovers -or -not $spec.leftovers.file) {
    Add-Gate 'WARN' '遗留清单' '未配置，跳过（建议登记，否则下一阶段无法追溯）'
} else {
    $leftFile = Resolve-ProjectPath ([string]$spec.leftovers.file)
    if (-not (Test-Path $leftFile)) {
        Add-Gate 'FAIL' '遗留清单' "文件不存在：$leftFile"
    } else {
        try {
            $data = Get-Content $leftFile -Raw | ConvertFrom-Json
            if ($data -is [System.Array]) { $items = @($data) }
            elseif ($null -ne $data.items) { $items = @($data.items) }
            else { $items = @() }

            if ($items.Count -eq 0) {
                Add-Gate 'WARN' '遗留清单' '清单为空（若无遗留可接受，但需人工确认）'
            }

            $allowed = @('closed', 'accepted', 'open', 'deferred')
            if ($spec.leftovers.allowedStatus) { $allowed = @($spec.leftovers.allowedStatus) }

            $ids = @()
            $bad = New-Object System.Collections.Generic.List[string]
            $openNoOwner = New-Object System.Collections.Generic.List[string]
            foreach ($it in $items) {
                if (-not $it.id) { $bad.Add('存在无 id 的条目'); continue }
                $idStr = [string]$it.id
                if ($idStr -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                    $bad.Add("$idStr 格式非法（须字母或数字开头，仅含字母数字 . _ -）")
                }
                $ids += $idStr
                if (-not $it.status) { $bad.Add("$($it.id) 缺 status"); continue }
                if ($allowed -notcontains ([string]$it.status).ToLower()) { $bad.Add("$($it.id) status=$($it.status) 不在允许值") }
                if (([string]$it.status).ToLower() -eq 'open' -and [string]::IsNullOrWhiteSpace([string]$it.owner)) {
                    $openNoOwner.Add([string]$it.id)
                }
            }
            $dup = @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object { $_.Name })
            if ($bad.Count -gt 0) { Add-Gate 'FAIL' '遗留清单字段' ($bad -join '; ') } else { Add-Gate 'PASS' '遗留清单字段' "$($items.Count) 条均含 id/status" }
            if ($openNoOwner.Count -gt 0) { Add-Gate 'FAIL' '遗留项责任人' ("open 但无 owner：" + ($openNoOwner -join ', ')) }
            if ($dup.Count -gt 0) { Add-Gate 'FAIL' '遗留项 ID 唯一' ("重复：" + ($dup -join ', ')) }

            if ($spec.leftovers.mirrorFiles) {
                $mirrors = @($spec.leftovers.mirrorFiles)
                foreach ($m in $mirrors) {
                    $mf = Resolve-ProjectPath ([string]$m)
                    if (-not (Test-Path $mf)) { Add-Gate 'FAIL' '遗留项镜像' "文件不存在：$mf"; continue }
                    $miss = @($ids | Where-Object { -not (Select-String -Path $mf -SimpleMatch -Pattern $_ -Quiet) })
                    if ($miss.Count -gt 0) { Add-Gate 'FAIL' '遗留项镜像' ("$mf 缺少：" + ($miss -join ', ')) }
                    else { Add-Gate 'PASS' '遗留项镜像' "$mf 覆盖全部 ID" }
                }
            }

            # 上一阶段遗留必须在本阶段清单中承接
            if ($spec.leftovers.previousPhaseFile) {
                $pf = Resolve-ProjectPath ([string]$spec.leftovers.previousPhaseFile)
                if (-not (Test-Path $pf)) {
                    Add-Gate 'FAIL' '上一阶段承接' "上一阶段清单不存在：$pf"
                } else {
                    try {
                        $prev = Get-Content $pf -Raw | ConvertFrom-Json
                        if ($prev -is [System.Array]) { $prevItems = @($prev) }
                        elseif ($null -ne $prev.items) { $prevItems = @($prev.items) }
                        else { $prevItems = @() }
                        $prevIds = @($prevItems | Where-Object { $_.id } | ForEach-Object { [string]$_.id })
                        if ($prevIds.Count -eq 0) {
                            Add-Gate 'WARN' '上一阶段承接' '上一阶段清单无 ID，无法核对承接'
                        } else {
                            $notCarried = @($prevIds | Where-Object { $ids -notcontains $_ })
                            if ($notCarried.Count -gt 0) {
                                Add-Gate 'FAIL' '上一阶段承接' ("上一阶段遗留未在当前清单出现：" + ($notCarried -join ', '))
                            } else {
                                Add-Gate 'PASS' '上一阶段承接' "$($prevIds.Count) 条上一阶段遗留均已承接"
                            }
                        }
                    } catch {
                        Add-Gate 'FAIL' '上一阶段承接' ("上一阶段清单解析失败：" + $_.Exception.Message)
                    }
                }
            }
        } catch {
            Add-Gate 'FAIL' '遗留清单解析' $_.Exception.Message
        }
    }
}

# 人工批准
if ($spec.approval -and [bool]$spec.approval.required) {
    $by = [string]$spec.approval.by
    $at = [string]$spec.approval.at
    if ([string]::IsNullOrWhiteSpace($by)) {
        Add-Gate 'FAIL' '人工批准' 'required=true 但 approval.by 为空'
    } elseif ([string]::IsNullOrWhiteSpace($at)) {
        Add-Gate 'FAIL' '人工批准' 'required=true 但 approval.at 为空'
    } else {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse($at, [ref]$parsed)) {
            Add-Gate 'PASS' '人工批准' "$by @ $at"
        } else {
            Add-Gate 'FAIL' '人工批准' "approval.at 无法解析：$at"
        }
    }
} else {
    Add-Gate 'WARN' '人工批准' '未要求人工批准（不建议在跨阶段时关闭）'
}

# 输出
$fail = @($results | Where-Object Level -eq 'FAIL')
$warn = @($results | Where-Object Level -eq 'WARN')
$verdict = if ($fail.Count -gt 0) { 'FAIL' } elseif ($warn.Count -gt 0) { 'PASS（有告警）' } else { 'PASS' }

$md.Add('## 结果')
$md.Add('')
$md.Add("**$verdict**")
$md.Add('')
$md.Add('| 检查项 | 结果 | 详情 |')
$md.Add('|---|---|---|')
foreach ($r in $results) { $md.Add(('| {0} | {1} | {2} |' -f $r.Item, $r.Level, $r.Detail)) }
$md.Add('')
if ($fail.Count -gt 0) {
    $md.Add('## 缺失项汇总（必须补齐）')
    $md.Add('')
    $n = 0
    foreach ($r in $fail) { $n++; $md.Add("$n. **$($r.Item)**：$($r.Detail)") }
    $md.Add('')
    $md.Add("> **结论：拒绝进入下一阶段。** 上述 $($fail.Count) 项未满足；补齐证据、登记遗留、写入停点声明并取得人工批准后重跑本闸门。")
} elseif ($warn.Count -gt 0) {
    $md.Add('> 无阻断项，但存在告警；请人工确认告警是否可接受后再进入下一阶段。')
} else {
    $md.Add('> 全部通过，可以进入下一阶段；进入前仍需人工确认一次。')
}

$text = $md -join "`n"
Write-Output $text
if ($OutFile) { $text | Out-File $OutFile -Encoding utf8; Write-Host "已写入 $OutFile" -ForegroundColor Cyan }

if (-not $NoExitCode -and $fail.Count -gt 0) { exit 1 }
exit 0
