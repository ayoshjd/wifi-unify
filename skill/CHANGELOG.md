# CHANGELOG · wifi-change-runbook

## v2

> 基线：v1。v1 保持不动；v2 是其环境无关版本。
> 目标：去掉项目专属假设，补上「阶段停点闸门」与「漫游时延量化」，让同一套流程能直接用于新环境。

---

## 1. 为什么要升 v2

v1 是在一次具体部署里长出来的：路径、网关、SSID、设备编号、信道都写死在脚本与文档里。换一套房子后，直接复用会出现三类问题：

1. **默认值错误**：脚本把绝对路径、网关地址与旧 SSID 写死为默认值，换环境一跑就落在错网段；
2. **能力缺口**：阶段之间没有硬闸门，快照没成对、验收口径没写也能继续；漫游只能靠体感，无法输出断流秒数；
3. **平台假设未声明**：哪些脚本依赖 Windows、没有脚本时怎么做，文档里没有统一说明。

v2 对应解决这三点。

---

## 2. 新增能力

### 2.1 `scripts/Test-PhaseGate.ps1`（阶段停点闸门）

**解决**：上一阶段遗留没登记、快照没成对、验收口径没写、没人批准就进入下一阶段。

**检查**：

- 规格 JSON 可解析，`phase` / `previousPhase` 存在；
- `<tag>-*-before` 与 `<tag>-*-after` 成对；
- **快照非空**：before/after 各自至少 `minFiles`（默认 3）个文件，且至少一个文件非空；
- after 内有非空 `99-diff-*`；
- 验收文档含「判据 / 观察项 / 不作判据」且各有实质内容；
- **未复核结论**：判据章节中带「待复核 / B级 / C级 / 推测 / 未复测 / 未验证」且不含「已复核」的行，一律 FAIL——未复核的测量结果不得当作判据；
- 遗留清单每条有 `id/status/owner`，open 必须有 owner，ID 唯一，且 ID 必须符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$`；
- 可选 `mirrorFiles`：每个 ID 在指定文档中可检索；
- **上一阶段承接**（可选 `previousPhaseFile`）：上一阶段清单中的每个 ID 必须在本阶段清单出现，缺失即 FAIL；
- `00-快照说明.md` 含「停点」；
- `approval.required=true` 时必须有 `by` 与可解析的 `at`（脚本不代签）；
- 报告末尾输出「缺失项汇总」，逐条列出 FAIL 项并写明「拒绝进入下一阶段」。

**退出码**：0 PASS/仅 WARN；1 有 FAIL；3 规格不合法。

**为什么现在加**：v1 的阶段停点靠人记；过程复盘里多次出现「快照只有 after」「验收口径事后才写」「遗留项只在聊天里说过」。这些都不是设备问题，是流程没有硬边界。

### 2.2 `scripts/Measure-RoamingGap.ps1`（漫游/切换时延量化）

**解决**：漫游只能写「感觉没断」，无法与门限比对。

**算法**：

- 读 `Microsoft-Windows-WLAN-AutoConfig/Operational`；
- 配对 `11004`（安全停止）与 `11005`（安全成功），差值即断流；
- 统计 `8002`（真断线）、`8001`（失败）、`8003`（连接成功）；
- 只有 `11005` 无前置 `11004` → 首次连接，不计入；
- 0 条可配对事件 → `INVALID`（退出码 2），**不判 PASS**。

**判读**：<1 s 优；1–3 s 可接受；>3 s FAIL；无线回程 3–5 s 需注明；出现 8002 需人工确认。

**为什么现在加**：v1 只能记录 BSSID 与时间点，断流时长靠目测。复盘时无法回答「到底断了 0.8 s 还是 4 s」。

### 2.3 `scripts/Get-BssidList.ps1`（从 work 目录纳入 Skill）

v1 的 Skill 里没有主动扫描脚本，BSSID 取证依赖 `work/scripts` 下的临时文件。v2 把它纳入正式脚本，并修了两个问题：

1. **变量名冲突**：原脚本参数 `$Ssid` 与循环变量 `$ssid` 在 PowerShell 中大小写不敏感，循环会覆盖参数。v2 改为 `-SsidFilter` 与 `$ssidText`。
2. **无过滤时返回空列表**：`WlanGetNetworkBssList` 在 `pDot11Ssid=NULL` 时要求 `dot11BssType=any(3)`，原脚本固定传 1。v2 按是否有过滤动态选择。

### 2.4 新增资产模板

| 文件 | 用途 |
|---|---|
| `assets/phase-gate.example.json` | 闸门规格 |
| `assets/leftovers.example.json` | 遗留项清单 |
| `assets/field-spec.example.json` | 改为全占位、六个典型字段 |
| `assets/expect.example.json` | 改为文档保留段地址 |

---

## 3. 参数化改造

### 3.1 统一原则

- 不再写死项目绝对路径；统一用 `-ProjectRoot`（默认当前目录），相对路径以它为基准；
- 不再写死网关/SSID/禁网段；由 `-Gateway` / `-Ssids` / `-ForbiddenSubnets` 或 `-ExpectPath` 传入；
- 未提供时：能安全推断的才推断（如从默认路由推断网关），不能推断的**跳过并告警**，不编默认值；
- 所有示例值改为占位：`<SSID>`、`<AP-IP>`、`192.0.2.x`、`AA:BB:CC:DD:EE:FF`。

### 3.2 逐脚本变化

| 脚本 | v1 | v2 |
|---|---|---|
| `Get-NetSnapshot.ps1` | `-OutRoot` 写死项目路径；快照说明无停点节 | 新增 `-ProjectRoot`、`-StopNote`；`00-快照说明.md` 固定含「停点与遗留」节；Tag 非法字符校验 |
| `Test-NetConfigConsistency.ps1` | 默认网关/SSID/禁网段写死 | 新增 `-Gateway`/`-Ssids`/`-ForbiddenSubnets`；无 `-ExpectPath` 时从默认路由推断网关；无 SSID 时 WARN 跳过；禁网段为空时 PASS 跳过 |
| `Get-LinkQuality.ps1` | 只匹配单一厂商的网卡事件；10 Mbps 写死 | 新增 `-ProviderPattern`（覆盖常见厂商）、`-MinLinkMbps`（默认 100）；输出「低于阈值」列与告警表；速率解析支持 Gbps/Mbps/Kbps |
| `Compare-DocFacts.ps1` | 基线路径写死；默认旧表述含项目个案词 | 新增 `-ProjectRoot`、`-SkipScan`；默认文档目录相对项目根；旧表述改为通用词 |
| `New-FieldChangeRecord.ps1` | 默认输出目录写死；模板含项目设备 | 新增 `-ProjectRoot`；模板改为 `<设备名/位置>`、`192.0.2.10`、`<SSID>` |
| `New-MultiSaveChecklist.ps1` | 默认输出目录写死；示例含项目设备 | 新增 `-ProjectRoot`；示例改 `<设备名/位置>`、`S1-AP-A` |
| `Test-SensitiveLeak.ps1` | 默认扫描项目三处绝对路径 | 新增 `-ProjectRoot`；默认扫描其下 `outputs/work/skills`，不存在的跳过 |
| `Test-AdminSession.ps1` | 示例用项目地址 | 示例改 `192.0.2.10`；逻辑未变 |
| `Compare-FieldReadback.ps1` | 示例用项目地址 | 示例改占位；逻辑未变 |

### 3.3 兼容性

- v2 的脚本**不读取 v1 的任何配置**，也不依赖 v1 目录存在；
- 旧命令若要迁移，只需补 `-ProjectRoot` 或对应参数，行为与 v1 一致；
- v1 目录保留，便于对照历史记录。

---

## 4. 文档变化

| 文档 | 变化 |
|---|---|
| `SKILL.md` | 重写为环境无关版本；新增 §2 输入参数、§3 首次进入陌生环境的适配流程、**§3.5 跨品牌/跨代差异「遇到就怎么核实」**、§6 阶段闸门、§7 漫游量化、§10 平台限制与手工替代、§14 收尾检查 |
| `CHANGELOG.md` | 本文件 |
| v1 `SKILL.md` | 仅在顶部加一行指向 v2 |

**SKILL.md 新增的关键约束**：

- 「必须现场实测」16 项与「禁止推断」8 条；
- **跨品牌差异按「遇到 → 怎么核实 → 降级」写，不列死清单**：菜单命名不同、保存按钮数量不同、隐藏字段（显示可勾但不提交）、无 AP 模式、单频设备质量折损；核实不到 A 级证据只能写「待复核」，且不得进入判据；
- 每个脚本标注平台、读写范围、回滚方式；
- 明确「0 样本不判通过」；
- 明确「脚本不代签人工批准」。

---

## 5. 未改变的部分

- v1 目录及其中所有文件（除顶部一行指引）；
- 其他项目材料（方案、验收、复盘、规则、单次改造记录）；
- 脚本的只读优先原则：所有脚本只写报告/记录/快照，不修改设备或本机网络配置。

---

## 6. 已知限制

1. `Measure-RoamingGap.ps1` 仅 Windows；macOS/Linux/手机只能替代取证（见 SKILL.md §10）。
2. `Get-BssidList.ps1` 需要无线网卡处于已连接状态；部分驱动不返回隐藏 BSSID。
3. `Test-PhaseGate.ps1` 只校验「证据是否存在且格式正确」，不判断证据内容是否真实；真实性仍由人工复核。
4. 闸门依赖命名规范（`<TAG>-<时间戳>-before/after`、`99-diff-*`）；不按规范命名会被判 FAIL。
5. `Test-SensitiveLeak.ps1` 是粗筛，未命中不代表无泄露。

---

## 7. 迁移对照（v1 → v2）

| v1 用法 | v2 用法 |
|---|---|
| `.\Get-NetSnapshot.ps1 -Tag "<旧标签>"` | `.\Get-NetSnapshot.ps1 -Tag "S1-AP-A" -ProjectRoot "<PROJECT_ROOT>"` |
| `.\Test-NetConfigConsistency.ps1` | `.\Test-NetConfigConsistency.ps1 -Gateway "<GATEWAY>" -Ssids "<SSID>"` |
| `.\Get-LinkQuality.ps1` | `.\Get-LinkQuality.ps1 -MinLinkMbps 100` |
| `.\New-FieldChangeRecord.ps1 -Spec "<旧规格路径>"` | `.\New-FieldChangeRecord.ps1 -Spec .\work\specs\S1-AP-A.json -ProjectRoot "<PROJECT_ROOT>"` |
| `.\New-MultiSaveChecklist.ps1 -Tag "<旧标签>" -Device "<旧设备名>"` | `.\New-MultiSaveChecklist.ps1 -Tag "S1-AP-A" -Device "<设备名/位置>" -ProjectRoot "<PROJECT_ROOT>"` |
| 无 | `.\Test-PhaseGate.ps1 -GateSpec .\work\gates\P1-AP-A.json -ProjectRoot "<PROJECT_ROOT>"` |
| 无 | `.\Measure-RoamingGap.ps1 -SinceHours 4 -MaxGapSec 3 -OutFile .\outputs\roaming.md` |
| 无（在 work/scripts） | `.\Get-BssidList.ps1 -WaitSeconds 8 -OutFile .\outputs\scan.txt` |

---

## 8. 版本记录

- **v2**：参数化；新增阶段闸门与漫游量化；纳入 BSSID 扫描；补平台限制与手工替代；新增四份资产模板；闸门判据补「快照非空 / 未复核结论不得当判据 / 上一阶段遗留承接」；SKILL 增 §3.5 跨品牌差异核实法。
- **v1**：首版，9 个脚本 + 2 个模板；面向单次部署执行。
