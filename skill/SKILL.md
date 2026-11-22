---
name: wifi-change-runbook-v2
description: 环境无关的家庭/小型办公 Wi-Fi 统一执行手册（多 AP 收敛为单一 SSID、单一 DHCP/NAT、信道错开、漫游验收）。当用户说"换房/换设备后统一 Wi-Fi""多台路由改 AP""按阶段执行并设停点""检查上一阶段遗留与快照""算漫游断流时长""改路由器/光猫/AP 配置"时使用。只组织只读取证、命令、页面动作与检查点；不调用设备 API，不试默认口令，不写死任何品牌/IP/信道。
---

# wifi-change-runbook v2 执行手册

> 定位：把「改一台路由器」变成**有证据、可回读、可回滚、可续跑、可换环境复用**的固定流程。
> 本 Skill 只做流程与证据，不做设备自动配置。所有设备参数改动都由人在设备页面上完成。
> v2 的两项新增能力：**阶段停点闸门**（`Test-PhaseGate.ps1`）与**漫游/切换时延量化**（`Measure-RoamingGap.ps1`）。
> 方法论与判断依据见本仓库根下的 `playbook/PLAYBOOK.md`；本文件只讲「怎么执行、用什么命令」。
> v1→v2 的差异见 `CHANGELOG.md`。

---

## 0. 边界

**做**：只读盘点、参数化命令、字段级变更记录、回读比对、快照与 diff、BSSID 取证、漫游断流计算、阶段闸门、文档体检。
**不做**：登录设备、点保存、改配置、试默认口令、恢复出厂、刷固件、代替人做物理插拔。
**写操作**：本 Skill 的脚本只写「报告/记录/快照」到项目目录；任何设备侧写操作都由人完成。每个脚本头部都声明了影响范围与回滚方式。

---

## 1. 触发与不触发

**触发**（命中任一）

- 换房/换设备/换运营商后，要把多台无线设备收敛成一个网络；
- 已有多台 AP，出现手动切网、同名不同密、双 DHCP、双 NAT、漫游粘滞；
- 需要按阶段执行，并在阶段之间设停点、查遗留、查快照是否成对；
- 需要证明「漫游断流多少秒」，而不是靠体感；
- 需要把某台设备改成 AP，但不确定它有没有 AP 模式。

**不触发**

- 只改一个 Wi-Fi 密码，不涉及拓扑；
- 企业级 AC+AP/802.1X/VLAN 高密度方案（本 Skill 不覆盖）；
- 要求脚本直接登录设备并批量下发配置（本 Skill 明确不做）。

---

## 2. 输入参数（全部参数化）

开工前必须把下表填完；**空着的项不允许靠推断补**。

| 参数 | 占位符 | 从哪来 | 缺失后果 |
|---|---|---|---|
| 项目根目录 | `<PROJECT_ROOT>` | 用户指定 | 快照/报告散落，无法成对 |
| 主网关 | `<GATEWAY>` | 客户端 `ipconfig` 回读 | 一致性自检无法判定 |
| 网段 | `<SUBNET>` | 同上 | 无法规划 AP 固定地址 |
| 目标 SSID | `<SSID>` | 用户确认 | BSSID/SSID 判据缺失 |
| 加密方式 | `<ENC>` | 设备页面回读 | 客户端可能连不上 |
| AP 固定地址 | `<AP-IP>` | 池外人工规划 | 与 DHCP 池冲突 |
| 阶段/对象标识 | `<TAG>` | 如 `S1-AP-A` | 快照无法配对，闸门不过 |
| 设备清单 | `<DEVICE>` | 进场清点 | 漏改/改错设备 |
| 平台 | Windows / macOS / Linux / 仅手机 | 现场确认 | 选错取证方法 |
| 验收门限 | `<MAX_GAP_SEC>` | 开工前与住户确认 | 事后争论「多少算通过」 |

**规则**：所有示例中的 `192.0.2.x`、`<SSID>`、`AA:BB:CC:DD:EE:FF` 都是占位；替换为现场回读值后才可执行。
**不做会怎样**：把示例值当现场值，命令跑在错误网段上，结论全错。

---

## 3. 首次进入陌生环境的适配流程（v2 新增）

> 这一节回答：**到了一个新环境，先做什么、哪些必须实测、哪些绝对不能推断。**
> 顺序不能跳：没走完 1–4，不允许进入第 7 步的任何写操作。

### 3.1 七步适配

| 步 | 做什么 | 产出 | 允许只读？ |
|---|---|---|---|
| 1 | 按 `01-首次进场核查清单.md` 清点物理与接入 | 设备清单、端口标签、入户方式 | 是 |
| 2 | 用客户端命令画逻辑拓扑：谁拨号、几层 NAT、谁发 DHCP | 拓扑图 + 一页现状 | 是 |
| 3 | 逐台登录（住户输密码）填能力矩阵：AP 模式、DHCP、LAN、信道、带宽、功率、保存按钮、暗坑 | 能力矩阵 | 是 |
| 4 | 判拓扑分支（独立路由/Mesh/FTTR/中继/混合）与受限分支（无口令/无 AP/单频/无备线/只有手机/不能断网） | 分支结论 | 是 |
| 5 | 写目标矩阵（设备×频段）+ 决策记录表 | 目标值/回滚方式 | 是 |
| 6 | 写验收口径三分法（判据/观察项/不作判据） | 验收文档 | 是 |
| 7 | 建带外通道 + before 快照 + 阶段计划，才开始改 | 通道验证 + 快照 | 否 |

### 3.2 必须现场实测的项（不允许推断）

| 项 | 为什么不能推断 | 实测方法 |
|---|---|---|
| 谁在拨号 | 同品牌光猫可能是路由模式也可能是桥接 | 看 WAN 状态 + `tracert` 私有跳数 |
| NAT 层数 | 户型/接线不同，层数不同 | `tracert` 数私有跳 |
| DHCP 服务器 | 可能有多台，页面看不全 | `ipconfig /all` 的 DHCP 服务器字段 |
| 有无 AP 模式 | 同品牌不同固件/运营商定制可能没有 | 逐级菜单找 |
| 能否关 DHCP | 有的页面隐藏或灰置 | 实际点开看 |
| 能否改 LAN | 有的运营商锁死 | 实际看输入框 |
| 信道可选项 | 地区/固件不同，149 可能不存在 | 页面下拉列表 |
| 带宽可选项 | 有的只到 80MHz | 页面下拉列表 |
| 功率是否分频段 | 有的只能整机调 | 页面看是否有 2.4G/5G 独立功率 |
| 保存按钮数量 | 分频段/分区块，页面不同 | 进页面先数按钮 |
| 链路速率/双工 | 线材/端口问题常见 | 两端 `LinkSpeed` |
| BSSID 清单 | 隐藏/远距离/邻居同名 | 三路交叉（扫描 + 页面 + 拓扑） |
| 邻居信道占用 | 只能现场扫 | 扫描 2 轮 |
| 端口/VLAN/IPTV | 运营商专口 | 看光猫端口 + 实际业务 |
| 设备在线判据 | 管理 IP 可能不响应 | BSSID 广播 + 拓扑 |
| 是否 TR-069 | 决定改完会不会被改回 | 问运营商/看远程管理页 |

### 3.3 禁止推断清单

1. **同型号 ≠ 同菜单**：运营商定制固件可能删功能。
2. **上一套房子同品牌 ≠ 这一套支持**：AP 模式、功率档位、保存按钮都可能不同。
3. **SSID 名 ≠ 设备归属**：同名可能是邻居/旧设备/隐藏回程。
4. **`ping` 管理 IP 不通 ≠ 设备离线**：从机常见。
5. **一次扫描 ≠ 全部 BSSID**：需多点多轮。
6. **页面显示已保存 ≠ 已持久化**：需强刷/重进/回读。
7. **指示灯正常 ≠ 配置正确**：需客户端实测。
8. **能上网 ≠ 业务可用**：打印/IPTV/监控要单独验。

**不做会怎样**：把上一环境的结论套到新环境，第一步就改错设备；返工成本远大于多测 10 分钟。

### 3.4 适配完成判据

- 能力矩阵每台设备至少 5 项关键能力有 A 级证据；
- 拓扑分支与受限分支各有一句结论；
- 目标矩阵逐台逐频段；
- 验收三分法已写；
- 带外通道实测可用；
- before 快照成对。

### 3.5 跨品牌/跨代差异：遇到就怎么核实

> 不背清单，只记「遇到某现象时，用什么动作把它变成事实」。
> 以下每条都按 **遇到什么 → 怎么核实 → 核实不过怎么降级** 写。

**A. 菜单命名不同（同一功能叫法不一样）**

- 遇到：找不到「AP 模式 / 接入点模式 / 桥接 / 无线中继 / 交换机模式」，或「DHCP」被叫作「DHCP 服务器 / LAN DHCP / 地址池」。
- 怎么核实：先看**功能语义**而不是名字——找「是否给下游分配地址」「WAN 是否参与 NAT」「上联接 WAN 还是 LAN」。用 `tracert` 看是否多一层私有跳，用 `ipconfig /all` 看 DHCP 服务器是谁；改前先只读进页面把一级/二级路径抄进能力矩阵。
- 降级：语义确认不了就不改，按「无 AP 模式」走三件套（关 DHCP → 改 LAN 到池外 → 上联插 LAN）；仍不行则该设备只做无线客户端，不做分发。

**B. 保存按钮数量不同（一个页面多个保存 / 分频段保存 / 只有全局保存）**

- 遇到：改完一个字段，页面显示成功，但换个页面看还是旧值；或 2.4G 和 5G 各有一个保存。
- 怎么核实：**进页面先数保存按钮**，用 `New-MultiSaveChecklist.ps1` 逐段列清单；每次保存后**退出再重进**该页回读；多频段必须逐段保存、逐段回读，缺一段视为未完成。
- 降级：若只有全局保存且回读不一致，先记录「该固件保存行为」，按单项回滚；连续两次不一致就停手，不连试。

**C. 隐藏字段 / 页面显示可勾但实际不提交**

- 遇到：勾了「关闭 DHCP」「AP 隔离」「WMM」等，保存后仍生效旧行为；或字段灰置但仍显示勾选。
- 怎么核实：不看设置项，看**当前状态页/运行状态**；用客户端实测（如 AP 隔离：两台客户端互 ping）；用 `Compare-FieldReadback.ps1` 把回读值写进记录，回读≠写入即判未生效；必要时换浏览器/无痕/强刷再读一次。
- 降级：确认「显示可勾但不提交」后，把它列为**该设备的已知限制**，不写进判据；改用等价手段（如旁路 ACL、客户端侧策略）或接受并登记遗留。

**D. 个别设备无 AP 模式**

- 遇到：菜单里完全没有接入点/桥接选项，只有「路由模式」和「中继」。
- 怎么核实：先确认没有隐藏的「高级/更多」入口；再确认能否关 DHCP、能否改 LAN 地址、上联能否插 LAN 口——这三件能成，就等价于 AP。
- 降级：三件缺一，则该设备**只能当路由**：必须给它独立网段并接受双层 NAT，或降级为「不参与统一 SSID 的边缘设备」；不允许把它硬接进主网段导致双 DHCP。

**E. 单频设备的质量折损**

- 遇到：老设备只有 2.4G，或 5G 只到 80MHz / 无 160MHz，或功率不可分频段调。
- 怎么核实：看页面下拉列表确认真实可选项（不是宣传参数）；用 `Get-BssidList.ps1` 看它实际广播的频段与信道；用 `Get-LinkQuality.ps1` 看客户端实际协商速率。
- 降级：单频设备只承担覆盖补盲，不承担高吞吐判据；把「该点位速率」写进**观察项**而非判据；射频规划时 2.4G 只排 1/6/11，不与 5G 指标混算。

**统一规则**：以上任一项核实不到 A 级证据（命令/日志/页面回读），就只能写「待复核」，且**不得进入判据**；阶段闸门会因未复核结论直接 FAIL。

---

## 4. 三条铁律（通用化）

1. **先留通道**：动任何设备前，必须有一条**与待改设备无关**的、能到主网关的通路。
   - 物理带外：主路由空闲 LAN 口拉线到操作位（插线前先断开 Wi-Fi）。
   - 第二设备：另一部手机/平板连主网做「看门狗」。
   - 手机热点不算带外：拿不到主网网段。
   - **不做会怎样**：改错时既进不去设备，也无法确认主网是否还活着。
2. **一次只改一项**：改完立刻回读，不对就单项回滚，不带病进入下一步。
   - **不做会怎样**：多项同时改，故障无法定位，回滚面扩大。
3. **改动前后各一份基线**：同一台设备、同一格式导出，逐项比对，只允许计划内差异。
   - **不做会怎样**：无法区分「新问题」与「历史残留」，也无法证明只改了计划内项。

---

## 5. 执行序列（P0–P6）

> 每阶段结束必须设停点；停点闸门不过，不进入下一阶段。

### P0 进场侦察（只读）

```powershell
# 1) 主动扫描全部 BSSID（Windows）
.\Get-BssidList.ps1 -WaitSeconds 8 -OutFile .\outputs\scan-P0.txt

# 2) 结构自检：未给 Gateway 时自动从默认路由推断；未给 SSID 则跳过并告警
.\Test-NetConfigConsistency.ps1

# 3) 人工：填能力矩阵、拓扑、暗坑、禁区
```

**退出**：一页现状 + 能力矩阵 + 决策记录表 + 禁区清单。

### P1 通道与基线

```powershell
.\Get-NetSnapshot.ps1 -Tag "S0-BASELINE" -Phase before -ProjectRoot "<PROJECT_ROOT>" -StopNote "P1 停点：通道与基线完成"
.\Get-LinkQuality.ps1 -MinLinkMbps 100 -OutFile .\outputs\link-baseline.md
.\Test-AdminSession.ps1 -Target "<AP-IP>" -OutFile .\outputs\session-<TAG>.md
```

**退出**：断开待改设备+断开 Wi-Fi 仍能到主网关；before 快照成对；链路 ≥100 Mbps 或已登记；非目标 SSID 改手动。

### P2 主出口收口

```powershell
.\New-FieldChangeRecord.ps1 -Init .\work\specs\P2-main.json
# 人工改主路由：地址池、基准 SSID/加密/PSK、关自动信道优化；逐项回读
.\Compare-FieldReadback.ps1 -Record .\outputs\measurements\<记录>.json -Set "DHCP 池=...","SSID=<SSID>"
```

**退出**：网关唯一；池与 AP 固定地址不冲突；基准参数已定；主路由配置已备份或手工清单完成。

### P3 逐台 AP 化（一次一台）

```powershell
# 每台开始前
.\New-FieldChangeRecord.ps1 -Init .\work\specs\S1-AP-A.json
.\New-MultiSaveChecklist.ps1 -Tag "S1-AP-A" -Device "<设备名/位置>" `
    -Segments "2.4G::保存","5G::保存","安全::保存" -Fields "SSID","加密","信道","密码"

# 人工严格按序：拔 WAN → 关 DHCP → 改 LAN → 上联插 LAN → 统一 SSID/加密/PSK → 设信道
# 每段保存后立即回读
.\Compare-FieldReadback.ps1 -Record .\outputs\measurements\<记录>.json -Set "LAN IP=<AP-IP>","DHCP 服务=关闭","SSID=<SSID>"
.\Test-NetConfigConsistency.ps1 -Gateway "<GATEWAY>" -Ssids "<SSID>" -FailOnError

# 本标准收口
.\Get-NetSnapshot.ps1 -Tag "S1-AP-A" -Phase after -CompareWith "<before 目录>" -StopNote "S1-AP-A 停点"
```

**退出**：新地址从主网可达；DHCP 关；WAN 空置；回读=写入；客户端能关联并上网。
**停手**：改 LAN 后新地址不通、回读不一致两次、出现双网关/双网段、设备反复重启。

### P4 射频收口

```powershell
.\Get-BssidList.ps1 -WaitSeconds 8 -OutFile .\outputs\scan-P4-before.txt
# 人工：2.4G 1/6/11 鸽笼；5G 非重叠 80MHz；带宽/功率；先关自动优化再固定
.\Get-BssidList.ps1 -WaitSeconds 8 -OutFile .\outputs\scan-P4-after.txt
```

**退出**：受管 BSSID 全同名；2.4G 同频对最少；5G 不重叠；关键点位达标；无旧 SSID。

### P5 验收取证

```powershell
# 漫游断流（先记测试起止时间，再按窗口统计）
.\Measure-RoamingGap.ps1 -SinceHours 2 -MaxGapSec 3 -OutFile .\outputs\roaming.md -CsvFile .\outputs\roaming.csv -FailOnExceed

# BSSID 归属（扫描 + 页面 + 拓扑，三路交叉）
.\Get-BssidList.ps1 -OutFile .\outputs\scan-P5.txt

# 结构与质量
.\Test-NetConfigConsistency.ps1 -Gateway "<GATEWAY>" -Ssids "<SSID>" -FailOnError
.\Get-LinkQuality.ps1 -MinLinkMbps 100

# 文档与脱敏体检
.\Test-SensitiveLeak.ps1 -ProjectRoot "<PROJECT_ROOT>" -OutFile .\outputs\leak-scan.md
.\Compare-DocFacts.ps1 -ProjectRoot "<PROJECT_ROOT>" -OutFile .\outputs\doc-lint.md
```

**退出**：判据逐条有证据；观察项/不作判据单列；遗留有编号；after 快照成对。

### P6 观察期与交接

```powershell
.\Test-PhaseGate.ps1 -GateSpec .\work\gates\P5.json -ProjectRoot "<PROJECT_ROOT>" -OutFile .\outputs\gate-P5.md
```

**退出**：观察期无新增故障；遗留闭环或有接受理由；第二人能照文档回滚。

---

## 6. 阶段停点闸门（v2 新增）

### 6.1 它解决什么

阶段之间最容易出的问题是：快照没成对、验收口径没写、遗留项没登记、没人批准就继续。闸门把这些变成可执行检查，**不齐就阻止进入下一阶段**。

### 6.2 命令

```powershell
.\Test-PhaseGate.ps1 -GateSpec .\work\gates\P1-AP-A.json -ProjectRoot "<PROJECT_ROOT>"
```

### 6.3 规格

模板：`assets/phase-gate.example.json`。最小字段：

```json
{
  "phase": "P1-AP-A",
  "previousPhase": "P0",
  "snapshot": { "root": "backup/snapshots", "tag": "S1-AP-A", "requirePair": true, "requireDiff": true },
  "acceptance": { "file": "outputs/acceptance-P1.md", "requireSections": ["判据", "观察项", "不作判据"] },
  "leftovers": { "file": "outputs/leftovers.json", "allowedStatus": ["closed","accepted","open","deferred"], "mirrorFiles": ["outputs/plan.md"] },
  "stopNotice": { "mustContain": ["停点"] },
  "approval": { "required": true, "by": "<approver>", "at": "2026-01-01T12:00:00" }
}
```

### 6.4 检查逻辑

| 检查 | 判定 | 不过怎么办 |
|---|---|---|
| 快照成对 | `<tag>-*-before` 与 `*-after` 都存在 | 补导快照；不允许只留 after |
| 快照非空 | before/after 各有 ≥`minFiles`（默认 3）个文件，且至少一个非空 | 重新导出；空文件不能当证据 |
| 快照差异 | after 内有非空 `99-diff-*` | 用 `-CompareWith` 重新生成 |
| 验收口径 | 三个章节存在且非空 | 回到 P1 前补写 |
| 未复核结论 | 判据章节中带「待复核/B级/C级/推测/未复测/未验证」且无「已复核」的行一律 FAIL | 补做实测并标「已复核」，或移出判据改列观察项 |
| 遗留清单 | 每条有 id/status/owner；open 必须有 owner；ID 唯一且符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$` | 补编号/owner 或改状态 |
| 遗留镜像 | 每个 ID 在指定文档可检索 | 同步到方案/清单 |
| 上一阶段承接 | `previousPhaseFile` 中的每个 ID 都出现在本阶段清单 | 没承接的必须补登记或写明关闭理由 |
| 停点声明 | `00-快照说明.md` 含「停点」 | 补写停点说明 |
| 人工批准 | `by` 与可解析的 `at` | 由人填写，脚本不代签 |

> 报告末尾会输出「缺失项汇总」，逐条列出 FAIL 项并写明「拒绝进入下一阶段」，便于直接照着补。

### 6.5 退出码

- `0`：PASS 或仅 WARN；
- `1`：有 FAIL，禁止进入下一阶段；
- `3`：规格不可读/不合法。

**不做会怎样**：阶段之间没有硬边界，上一阶段的小问题被带进下一阶段，最后无法定位是哪一步引入的。

---

## 7. 漫游/切换时延量化（v2 新增）

### 7.1 命令

```powershell
.\Measure-RoamingGap.ps1 -SinceHours 4 -MaxGapSec 3 -OutFile .\outputs\roaming.md -CsvFile .\outputs\roaming.csv -FailOnExceed
```

### 7.2 算法

- 事件日志：`Microsoft-Windows-WLAN-AutoConfig/Operational`；
- `11004` 安全停止 → `11010` 安全开始 → `11005` 安全成功；
- 断流 = `11005` 时间 − `11004` 时间；
- 期间出现 `8002` = 真断线，需人工确认是漫游还是手动断开/睡眠；
- 只有 `11005` 没有前置 `11004` = 首次连接，不计入漫游；
- 有 `11004` 没有 `11005` = 未完成/可能掉线，单独告警。

### 7.3 判读

| 结果 | 含义 | 结论 |
|---|---|---|
| gap < 1 s | 优 | PASS |
| 1–3 s | 可接受（有线回程） | PASS |
| > 3 s | 超门限 | FAIL |
| 无线回程 3–5 s | 受回程限制 | 需在口径中注明 |
| 0 条可配对事件 | 没测到，不等于没断流 | INVALID，退出码 2 |
| 出现 8002 | 真断线 | WARN/FAIL，人工确认 |

### 7.4 平台限制与替代

| 平台 | 方法 | 限制 |
|---|---|---|
| Windows | 本脚本 | 依赖 WLAN 事件日志；需网卡驱动上报 |
| macOS | `log stream --predicate 'subsystem == "com.apple.wifi"'` 或秒表+录屏 | 无同名事件 ID |
| Linux | `iw event` / `dmesg -w` 观察 disconnected/connected | 需权限与驱动支持 |
| 仅手机 | 1 s ping + 录屏 + 秒表 | 只能粗验，标注 B/C 级 |

**不做会怎样**：用体感代替量化，把 4–5 s 的断流写成「基本无缝」，验收结论不可复核。

---

## 8. 脚本清单

| 脚本 | 作用 | 平台 | 读写 | 回滚 |
|---|---|---|---|---|
| `Get-NetSnapshot.ps1` | 7 核心文件 + 链路质量 + 可选 diff | Windows | 只写快照目录 | 删除本次快照目录 |
| `Test-NetConfigConsistency.ps1` | 单路由/单 DHCP/无 169.254/禁网段/SSID | Windows | 只读 | 无需 |
| `Get-LinkQuality.ps1` | 速率/双工/错误/协商事件 | Windows | 只读（可选写报告） | 无需 |
| `Get-BssidList.ps1` | 主动扫描全部 BSSID | Windows | 只读 | 无需 |
| `Measure-RoamingGap.ps1` | 漫游断流计算 | Windows | 只读（可选写报告/CSV） | 删除报告 |
| `New-FieldChangeRecord.ps1` | 生成字段级变更记录 | pwsh 7+（纯文件） | 只写记录 | 删除记录 |
| `Compare-FieldReadback.ps1` | 回读值与写入值比对 | pwsh 7+（纯文件） | 回写记录 JSON + 报告 | 版本控制/备份恢复 |
| `New-MultiSaveChecklist.ps1` | 多保存按钮逐段清单 | pwsh 7+（纯文件） | 只写清单 | 删除清单 |
| `Test-AdminSession.ps1` | 管理页可达/占用检测 | Windows（pwsh 7+） | 只读 | 无需 |
| `Test-SensitiveLeak.ps1` | 密码明文粗筛（不打印原文） | pwsh 7+（纯文件） | 只读 | 无需 |
| `Compare-DocFacts.ps1` | 文档 BSSID/旧表述体检 | Windows（可 -SkipScan） | 只读 | 无需 |
| `Test-PhaseGate.ps1` | 阶段停点闸门 | pwsh 7+（纯文件） | 只读（可选写报告） | 删除报告 |

**运行环境**：Windows + PowerShell 7+（`pwsh`），不支持 Windows PowerShell 5.1；标「pwsh 7+（纯文件）」的脚本只读写项目目录，可在任意装有 `pwsh` 7 的系统上运行。
**写操作声明**：上表所有「写」都只写项目目录内的报告/记录/快照；**没有任何脚本修改设备或本机网络配置**。
**不做会怎样**：没有只读/写操作边界，脚本可能在无人值守时改配置，违背「一次只改一项、人确认」的原则。

---

## 9. 模板与资产

| 文件 | 用途 |
|---|---|
| `assets/field-spec.example.json` | 字段级变更规格（before/target/secret/evidence） |
| `assets/expect.example.json` | 一致性自检的期望网关/SSID/禁网段 |
| `assets/phase-gate.example.json` | 阶段闸门规格 |
| `assets/leftovers.example.json` | 遗留项清单（id/status/owner/next/basis） |

**规则**：模板中的值全部是占位；复制后先替换为现场回读值，再执行。

---

## 10. 平台限制与手工替代

| 能力 | Windows | macOS | Linux | 仅手机 |
|---|---|---|---|---|
| 快照（地址/路由/DNS） | 脚本 | `ifconfig`/`netstat -rn`/`scutil --dns` | `ip a`/`ip r`/`resolvectl` | 系统网络详情截图 |
| BSSID 扫描 | 脚本 | `wdutil scan` 或分析仪 | `iw scan` | Wi-Fi 分析仪 App |
| 漫游断流 | 事件日志脚本 | `log stream` + 秒表 | `iw event` | 1 s ping + 录屏 |
| 链路速率 | 脚本 | `ifconfig`/`networksetup` | `ethtool` | 系统详情 |
| 字段回读比对 | 脚本 | 脚本（生成 Markdown） | 脚本 | 手工表 |
| 阶段闸门 | 脚本 | 脚本 | 脚本 | 手工勾选 |

**必须**在报告里写明用了哪种平台与替代方法。
**不做会怎样**：把手机粗验写成精确断流，结论置信度与事实不符。

---

## 11. 禁止事项

1. 不试默认口令；失败一次即停（可能触发锁定）。
2. 不恢复出厂（会丢宽带账号/IPTV/端口绑定）。
3. 不在唯一管理通道上执行会切断自身的动作；必须改后台脚本+落盘，或先建带外通道。
4. 不一次改多台/多项；不连续点多个保存按钮而不回读。
5. 不在 10 Mbps 链路上测吞吐并下结论。
6. 不把 `ping` 管理 IP 作为设备在线判据。
7. 不把密码明文写入文档/日志/脚本参数；只记长度/类别/是否一致。
8. 不修改住户未授权的设备；不拔 IPTV/电话专口。
9. 不在页面与方案不符时自行发挥；停手、记录、报告。
10. 不用「整体验收通过」这类概括句代替逐条判据。

**不做会怎样**：每一条都对应实际部署中已发生的事故；违反其中一条，返工概率显著上升。

---

## 12. 分工与时耗

| 只能人做 | 可自动 |
|---|---|
| 插拔线、换端口 | 快照、diff、一致性自检 |
| 页面输密码/PSK | BSSID 扫描、链路质量 |
| 物理走动测漫游 | 漫游断流计算 |
| 看指示灯/温度 | 字段回读比对 |
| 业务验证（打印/IPTV） | 多保存清单、脱敏扫描 |
| 确认禁区与授权 | 阶段闸门、文档体检 |

**轮次**：单台 AP 化 6–10 轮；3–4 台常见 45–70 轮；每发生一次事故 +3–6 轮。
**不做会怎样**：把自动化当成「无人值守」，省掉人的确认，最终在物理/权限/业务语义上出错。

详细分工与成本判断见 `05-分工与时耗.md`。

---

## 13. 输出物

```text
<PROJECT_ROOT>/
├─ outputs/
│  ├─ 00-进场现状-<日期>.md
│  ├─ 01-能力矩阵-<日期>.md
│  ├─ 02-决策记录-<日期>.md
│  ├─ 03-验收口径-<日期>.md
│  ├─ acceptance-<phase>.md
│  ├─ leftovers.json
│  ├─ roaming.md / roaming.csv
│  └─ gate-<phase>.md
├─ work/
│  ├─ specs/*.json
│  └─ gates/*.json
└─ backup/snapshots/
   ├─ <TAG>-<时间戳>-before/
   └─ <TAG>-<时间戳>-after/
      └─ 99-diff-vs-<before>.txt
```

---

## 14. 收尾检查

- [ ] 目标矩阵逐台逐频段，无「统一 SSID」这类概括句；
- [ ] 每个受管 BSSID 都能归属到已知设备，未归属项有说明；
- [ ] 每条判据有证据文件，观察项/不作判据单列；
- [ ] before/after 快照成对，diff 只有计划内差异；
- [ ] 遗留项有 id/status/owner，且在方案/清单/验收三处可检索；
- [ ] 停点声明已写入，阶段闸门 PASS；
- [ ] 漫游有量化数据，无样本时标 INVALID 而非 PASS；
- [ ] 敏感信息未落盘，脱敏扫描通过；
- [ ] 交接文档能让第二人完成回滚。

**不做会怎样**：少一项，下一位执行者就要重新摸现场；开源/分享时也可能泄露敏感信息。
