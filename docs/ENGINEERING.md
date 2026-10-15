# 工程记录

macOS 菜单栏电池监控应用。实时读取电池与充电器的**全部**可获取参数，用图形界面展示，支持菜单栏图标 + 点击展开卡片。

全部数据来自本机只读接口，**不联网**。

```
make app       # 编译 + 打包 + 自检 → dist/BatteryScope.app
make run       # 打包并启动
make test      # 运行 296 项内置断言
```

---

## 一、为什么 `ioreg | grep` 拿不到你要的那些参数

你原来的命令：

```bash
ioreg -rn AppleSmartBattery | grep -E '"CycleCount"|"DesignCapacity"|"AppleRawMaxCapacity"|"Manufacturer"|"Serial"|"ManufactureDate"'
```

在 MacBookPro18,2 / macOS 27 上的实际结果（实测）：

| 你 grep 的键 | 结果 | 原因 |
|---|---|---|
| `CycleCount` | ✅ 114 | 在 `AppleSmartBattery` 顶层 |
| `Serial` | ✅（发布时隐去） | 顶层 |
| `DesignCapacity` | ⚠️ 匹配到了，但拿不到值 | 藏在 `BatteryData = {...}` 这一整行嵌套字典里，grep 只能给出整行 |
| `AppleRawMaxCapacity` | ❌ 完全匹配不到 | 它在**子节点** `AppleSmartBatteryPack` 里，不在这个节点 |
| `ManufactureDate` | ❌ 完全匹配不到 | 同上，在 Pack 里 |
| `Manufacturer` | ⚠️ 匹配到了充电器的 `Manufacturer` | 电池本身的厂商根本不在任何 `Manufacturer` 键里 |
| `Temperature`（你大概也想要） | ❌ 匹配不到 | 在 `AppleSmartBatteryPack.BatteryData` 里 |

用计数验证过：

```
AppleSmartBattery     节点含 Temperature:            0
AppleSmartBattery     节点含 AppleRawMaxCapacity:    0
AppleSmartBatteryPack 节点含 Temperature:            1
AppleSmartBatteryPack 节点含 AppleRawMaxCapacity:    1
AppleSmartBatteryPack 节点含 ManufactureDate:        1
```

**真正的数据分布长这样**（本机实测的完整结构）：

```
AppleSmartBattery
├── CurrentCapacity / MaxCapacity / CycleCount / Voltage / Amperage
├── IsCharging / ExternalConnected / FullyCharged / TimeRemaining
├── BatteryData                  ← 另一份容量数据（百分比 + mAh 混合）
│     DesignCapacity 8694 · FullChargeCapacity 7700
│     NominalChargeCapacity 7944 · RemainingCapacity 6074
├── AdapterDetails               ← 充电器（键会随时序消失！见第六节）
├── PowerTelemetryData           ← 真实功率流：SystemPowerIn / SystemLoad / BatteryPower
├── PowerDistribution            ← PMU 功率预算：IPDInputPower / IPDChargingAllowed
├── AppleChargerData
│     └── ChargerData            ← 充电器寄存器：ChargingVoltage / NotChargingReason
├── AppleSmartBatteryPack
│     └── BatteryData            ← 温度、实测容量、厂商、寿命统计都在这
│           Temperature 3350（百分之一 °C）· DesignCapacity 8694
│           AppleRawMaxCapacity 7700 · AppleRawCurrentCapacity 6074
│           NominalChargeCapacity 7944 · CycleCount 114
│           MfgData（厂商 / 批次）· ManufactureDate · StateOfCharge 79
│           LifetimeData（历史温度/电压/电流极值）
│     ├── AppleSmartBatteryBank × 3    ← 电芯组：CellVoltage / Qmax / WeightedRa
│     │     └── AppleSmartBatteryCell × 2  ← 电芯电流 CellCurrent
```

本应用把整棵子树抓下来、**展开所有嵌套字典**，因此能列出 **303 个键**，而你原来的命令只能看到其中约 20 个（且多数在整行嵌套里无法直接使用）。

自带的键值浏览器就是为替代这条命令做的：可搜索、按节点分组、显示类型，并能把筛选结果整段复制回命令行（右键单个键可复制「路径 = 值」）。

```bash
dist/batteryscope-cli raw --filter 'DesignCapacity|Temperature|ManufactureDate'
dist/batteryscope-cli raw --dump-tree      # 缩进树形
dist/batteryscope-cli keys                 # 只列键名
```

---

## 二、读取电池数据的各种方式（回答"还有什么其他方式"）

| 方式 | 能拿到什么 | 需要 root | 本机实测 |
|---|---|---|---|
| **IOKit IORegistry**<br>`IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperties` | 几乎所有原始参数（本应用主用） | 否 | ✅ |
| **IOKit IOPowerSources**<br>`IOPSCopyPowerSourcesInfo` / `IOPSGetTimeRemainingEstimate` | 电池是否存在、供电状态、**插拔电源事件推送**、系统级剩余时间 | 否 | ✅ |
| **sysctl** | 机型标识、芯片名、内存、系统构建号 | 否 | ✅ |
| `pmset -g batt` | 供电来源、百分比、充放电状态 | 否 | ✅ 但不含容量/温度 |
| `system_profiler SPPowerDataType` | 上述 + 循环次数 + 健康度百分比 + 充电器信息 | 否 | ✅ 但慢（数百毫秒）且非实时 |
| **`AppleSMC` 用户客户端**<br>经典 SMC 键 `PSTR` / `PDTR` / `PPBR` / `TB0T` / `F0Ac` | **系统功率、适配器供电、电池功率（单位直接是瓦特）、电池温度、风扇转速** | 否（只读） | ✅ **可用，且约 1 Hz 刷新——本应用的主力功率来源** |

### AppleSMC：我一开始判定"已失效"，那是我的 bug

我最初写过一个 SMC 探针，所有键都返回 `result = 137`、`keyCount = 0`，据此写下"Apple Silicon 上经典 SMC 键表不再暴露给用户态"。

**这个结论是错的。** 修正后同一个 `AppleSMC` 用户客户端完全正常：

| 键 | 含义 | 本机实测值 | 10 秒内不同值 |
|---|---|---|---|
| `PSTR` | 系统功率 | 24.7 – 29.9 W | 10（≈1 Hz） |
| `PDTR` | 适配器 / DC-in 供电 | 32.3 – 37.3 W | 10（≈1 Hz） |
| `PPBR` | 电池功率 | 1.64 – 1.67 W | 10（≈1 Hz） |
| `TB0T` | 电池温度 | 34.9 °C | 2 |
| `F0Ac` | 风扇转速 | 1507 – 1541 rpm | 每次采样都变 |
| `B0AC` / `B0AV` / `B0FC` | 循环次数 / 电压 / 满充容量 | 503 / 12.947 V / 7,708 mAh | 慢 |

两个 bug，都很隐蔽：

1. **必须先 `kSMCGetKeyInfo`（`data8 = 9`）再 `kSMCReadKey`（`data8 = 5`）**，并把拿到的 `dataSize` / `dataType` 回填进读请求。跳过 GetKeyInfo 直接读，就会被拒。
2. **SMC 的数据类型是四个字符，`flt` 实际是 `"flt "`（带一个尾随空格）**。用 `== "flt"` 比较会把**所有**浮点键静默丢掉——这正是"读不到任何键"的真正原因。

所以老教程里那套 `IOServiceOpen("AppleSMC", type 0)` + `IOConnectCallStructMethod(selector 2, 80 字节 SMCKeyData_t)` 在 Apple Silicon 上**依然有效**。`TB0T` 能直接给出电池温度，不必绕道 IOKit 注册表。


**唯一真正不存在的**是 Intel 时代的充电控制键：`BCLM`、`CH0B`、`CH0C`、`VC0C`、`PCPR`、`PATC`、`PB0C` 全部返回 `result = 132`（`kSMCKeyNotFound`）。这一点在修正后的客户端上重新确认过，所以第八节关于充电限制的结论仍然成立——而且现在是更强的证据。

| 老方法（SMC） | 现在从哪读 |
|---|---|
| `TB0T` 电池温度 | `AppleSmartBatteryPack.BatteryData.Temperature`（百分之一 °C）+ `VirtualTemperature` |
| 历史温度极值 | `…BatteryData.LifetimeData` 的 `AverageTemperature` / `MinimumTemperature` / `MaximumTemperature` |
| 充电目标电压/电流 | `AppleChargerData.ChargerData.ChargingVoltage` / `ChargingCurrent` |
| 充电器输入 | `PowerTelemetryData.SystemPowerIn` / `SystemVoltageIn` / `SystemCurrentIn` |
| 电池电流 | `AppleSmartBatteryPack.BatteryData.Amperage` / `InstantAmperage`（注意第七节的坑） |

---

## 三、完整字段与单位对照表

所有容量单位 mAh，电压 mV→V，电流 mA→A，温度按标注换算。

### 标识

| 参数 | 键路径（相对 `AppleSmartBattery`） | 说明 |
|---|---|---|
| 电池序列号 | `Serial` | |
| 电量计芯片 | `DeviceName` | 本机 `bq40z651` |
| 电芯厂商 | `AppleSmartBatteryPack.BatteryData.MfgData` | Pascal 字符串打包；本机解出 **ATL = Amperex Technology Limited**，macOS 自己不显示这个 |
| 批次码 | 同上 | 本机 `1916` / `002` |
| 固件 / 硬件 / 电芯版本 | 同上（前 12 字节） | `0b00` / `1.00` / `0a14` |
| 生产日期 | `…BatteryData.ManufactureDate` | ⚠️ 本机为 ASCII `"800192"`，**不是**标准日期，见第五节 |

### 容量与健康度

| 参数 | 键路径 | 本机实测值 |
|---|---|---|
| 电量百分比 | `CurrentCapacity`（0–100） | 80 |
| 电量计 SoC | `…BatteryData.StateOfCharge` | 79 |
| 设计容量 | `…BatteryData.DesignCapacity` | 8694 mAh |
| 实测满充容量 | `…BatteryData.AppleRawMaxCapacity`<br>（回退 `FccComp1` / `FccComp2` / `FullChargeCapacity`） | 7700–7752 mAh |
| 标称满充容量 | `…BatteryData.NominalChargeCapacity` | 7944–7996 mAh（电量计模型值，**不参与健康度计算**） |
| 当前剩余容量 | `…BatteryData.AppleRawCurrentCapacity`<br>（回退 `RemainingCapacity`） | 6074–6093 mAh |
| 循环次数 | `…BatteryData.CycleCount` | 114 |
| 设计循环上限 | `DesignCycleCount9C` | 1000 |
| 永久性故障标记 | `…BatteryData.PermanentFailureStatus` | 0 |

> 满充容量会随电量计重新计算而小幅变化（本机观察到 7700→7752、7944→7996），所以健康度不是常数。

### 电气

| 参数 | 键路径 | 换算 |
|---|---|---|
| 电池电压 | `…BatteryData.AppleRawBatteryVoltage` / `Voltage` | mV ÷ 1000 |
| 电池电流 | `…BatteryData.InstantAmperage` / `Amperage` | mA ÷ 1000，有符号 |
| 电池温度 | `AppleSmartBatteryPack.BatteryData.Temperature` | **百分之一 °C** ÷ 100（3350 → 33.50 °C） |
| 虚拟温度 | `…VirtualTemperature` | 同上 |
| 电池功率 | `PowerTelemetryData.BatteryPower` | mW ÷ 1000，有符号 |

### 充电器

| 参数 | 键路径 | 本机实测 |
|---|---|---|
| 型号 | `AdapterDetails.Name` | ⚠️ 时有时无 |
| 厂商 | `AdapterDetails.Manufacturer` | ⚠️ 时有时无 |
| 标称功率 | `AdapterDetails.Watts` | 140 W |
| 当前协商电压 | `AdapterDetails.AdapterVoltage` | 28000 mV |
| 当前协商电流 | `AdapterDetails.Current` | 4990 mA |
| 协商功率 | 上两项相乘 | 139.7 W |
| USB-PD 档位表 | `AdapterDetails.UsbHvcMenu[]` | 5V/2.96A、9V/2.98A、15V/2.99A、20V/4.99A |
| 实际输入功率 | `PowerTelemetryData.SystemPowerIn` | 11–36 W（随负载变化） |
| 输入电压 / 电流 | `SystemVoltageIn` / `SystemCurrentIn` | 27723 mV / 999 mA |
| PMU 输入功率上限 | `PowerDistribution.IPDInputPower` | 139720 mW（**等于协商值，不是实际值**） |
| PMU 是否允许充电 | `PowerDistribution.IPDChargingAllowed` | 0 / 1 |
| 充电目标电压 / 电流 | `AppleChargerData.ChargerData.ChargingVoltage` / `ChargingCurrent` | 4146 mV / 0 mA |
| 未充电原因 | `…ChargerData.NotChargingReason` | `0x01000000` = 已达上限或无需充电 |
| 累计限温时长 | `…ChargerData.TimeChargingThermallyLimited` | 秒 |
| 硬件限流回退原因 | `…ChargerData.ChargerHwIlimBackoffReason` | 本机 16 |

### 电芯组与寿命统计

| 参数 | 键路径 | 换算 |
|---|---|---|
| 电芯组电压 | `Bank.BatteryData.CellVoltage` | mV ÷ 1000（本机 4.095 / 4.093 / 4.096 V） |
| Qmax | `Bank.BatteryData.Qmax` | mAh（本机 8492–8540） |
| 加权内阻 | `Bank.BatteryData.WeightedRa` | |
| 电芯电流 | `Cell.CellData.CellCurrent` | mA ÷ 1000 |
| 累计运行时间 | `…LifetimeData.TotalOperatingTime` | **分钟** |
| 历史平均温度 | `…LifetimeData.AverageTemperature` | **十分之一 °C** ÷ 10（224 → 22.4 °C） |
| 历史最低/最高温度 | `…LifetimeData.MinimumTemperature` / `MaximumTemperature` | **整 °C**（9 / 46）⚠️ 与平均值刻度不同 |
| 历史电压区间 | `…LifetimeData.MinimumPackVoltage` / `MaximumPackVoltage` | mV ÷ 1000 |
| 历史最大充电电流 | `…LifetimeData.MaximumChargeCurrent` | mA ÷ 1000 |
| 历史最大放电电流 | `…LifetimeData.MaximumDischargeCurrent` | **无符号字段存负值**，需 `Int64(bitPattern:)` 回绕 |

---

## 四、健康度只用实测值

健康度 = **实测满充容量 / 设计容量** = `AppleRawMaxCapacity / DesignCapacity`。

本机：`7752 / 8694 = 89.2%`。

不使用 `NominalChargeCapacity`（标称满充容量）。那是电量计的模型值而不是测量值，把它算进健康度等于把一个推算结果当成电池的真实状态展示。标称值仍然可以在 `raw` 输出里查到，作为一个独立字段，但不参与任何计算。

> 满充容量会随电量计重新计算而变化（本机观察到 7700→7752），所以健康度不是常数。

## 五、几个真实的系统坑（都已在代码里处理）

1. **嵌套字典**——见第一节。程序化读取时若把 `Any?` 直接传进 `Any` 参数，Swift 会装箱成 `Optional<Dictionary<...>>`，类型判断失败，嵌套字典永远不会被展开，最终静默读到空值。这是一个只在运行时才暴露的 bug，已在 `ValueCoercion.typeName(of:)` 接受 `Any?` 后修复并有回归测试。

2. **`ManufactureDate` 不是日期**——本机读到 `0x383030313932`，即 ASCII `"800192"`。macOS 自己也因此完全不显示生产日期。应用会：能解出标准 Smart Battery 打包日期（bit0-4 日 / bit5-8 月 / bit9-15 年-1980）时显示日期，否则显示原始编码，并额外从 `MfgData` 里解出**真实厂商 ATL** 与批次码。

3. **无符号回绕**——`AdapterDetails.FamilyCode` 被 `ioreg` 打印成 `18446744073172697098`，实际是 `Int64(-536854518)`；`LifetimeData.MaximumDischargeCurrent` 同理。需要 `uint64Value` + `Int64(bitPattern:)`。

4. **`LifetimeData` 温度混合刻度**——平均值是十分之一度（224 → 22.4 °C），而极值是整度（9 / 46）。如果统一除以 100 会得到 2.2 °C / 0.1 °C / 0.5 °C 这种明显自相矛盾的结果（最大值小于平均值）。代码按"数值 > 100 视为缩放值"处理并附有说明。

5. **充电器的身份键会消失**——相隔几分钟的两次抓取，`AdapterDetails` 第一次有 `Name`/`Manufacturer`/`SerialString`/`FwVersion`，第二次只剩 `Watts`/`Current`/`AdapterVoltage`。所以 `AdapterDetails` 与 `AppleRawAdapterDetails` 必须**逐键合并**，否则整个充电器会显示成"无名"。应用还会在厂商未提供名称时合成 `pd charger（140W）` 这样的标签。

6. **本地化版本号**——`ProcessInfo.operatingSystemVersionString` 在中文系统上返回 `版本 27.0.1 (版号 26A434)`，带**全角括号**，按 `" ("` 切分会失败并拼出 `macOS 版本 27.0.1 (版号 26A434) (26A434)`。改用 `operatingSystemVersion` 的数值分量，与语言无关。

7. **列表视图的 AppKit 重入警告**——`List` 在 macOS 上由 `NSTableView` 支撑，放进 `TabView` 会让 AppKit 每次启动都打印 `Application performed a reentrant operation in its NSTableView delegate`（AppKit 声明将来会变成断言）。键值浏览器因此改用 `ScrollView + LazyVStack`，同时把 300 行的展开结果缓存在 `@State` 里按 5 秒刷新，而不是每次 `body` 求值都重建。

8. **噪声被放大成剧烈波动**——自动缩放会把 ±0.2 °C 的传感器抖动画成满幅波动，看起来像出了大事。每个指标都有最小量程（温度 4 °C、功率 20 W、电量 4 个百分点、电压 0.3 V 等），并且功率图始终包含 0 基线。

---

## 六、充电功率到底怎么算（Apple Silicon 的重要坑）

按优先级链推导，并且**在界面上标注数据来源**，不把推算值伪装成实测值：

| 优先级 | 来源 | 条件 | 界面标注 |
|---|---|---|---|
| 1 | `PowerTelemetryData.BatteryPower` | 绝对值 > 0.05 W | PMU 遥测 |
| 2 | 电压 × 电流 | 电流绝对值 > 1 mA | 电压 × 电流 |
| 3 | **整机负载取负** | 未接电源且以上都为 0 | 由整机负载推算 |
| 4 | 0 W | 已接电源且电流为 0 | 无电流 |

**为什么需要第 3 条**：本机实测在**真的在放电**时（`pmset -g batt` 报 `discharging`），

```
AppleSmartBattery.Amperage                       0
AppleSmartBattery.InstantAmperage                0
AppleSmartBatteryPack.BatteryData.Amperage        0
AppleSmartBatteryPack.BatteryData.InstantAmperage 0
PowerTelemetryData.BatteryPower                   0
PowerTelemetryData.SystemPowerIn              36313   ← 36.3 W
PowerTelemetryData.SystemLoad                 36313
```

也就是说"电压 × 电流"会算出 **0 W**，而机器明明在以约 36 W 放电。此时唯一可靠的量是 `SystemPowerIn`/`SystemLoad`，而电池是唯一电源，所以电池功率 ≈ −36.3 W。应用会显示 `−36.31 W（放电中 · 由整机负载推算）`。

另外注意三个功率口径完全不同，不能混用：

* **标称功率** `AdapterDetails.Watts` = 充电器铭牌（140 W）
* **协商功率** `AdapterVoltage × Current` = 当前 PD 合约上限（139.7 W）
* **实际输入功率** `PowerTelemetryData.SystemPowerIn` = 真正流入的功率（11–36 W）

而 `PowerDistribution.IPDInputPower`（139720 mW）等于**协商值**，是 PMU 的功率预算，不是实际消耗——很容易被误当成"实际输入"。

界面上这三个数是**三条互不相干的独立寄存器读数**，没有任何一个由另外两个加减得出：

| 界面项 | 寄存器 | 性质 |
|---|---|---|
| 电池功率 | `PowerTelemetryData.BatteryPower` | PMU 实测 |
| 电池功率（另一路） | `Voltage × InstantAmperage` | 电量计实测 |
| 整机功耗 | `PowerTelemetryData.SystemLoad` | PMU 实测 |
| 适配器供电 | `PowerTelemetryData.SystemPowerIn` | PMU 实测（等于 `SystemVoltageIn × SystemCurrentIn`） |

它们之所以看起来"满足 A = B + C"，是因为能量守恒本来就该成立——那是我用来**交叉验证**两组独立测量的方法，不是计算方式。实测数据里 `BatteryPower` 与 `Voltage × Amperage` 会有第三位小数的差异（40.757 W vs 40.796 W），正说明它们是两条独立通路。

**唯一的例外**是放电时的兜底：某些情况下电量计的电流寄存器会读 0（见第七节的快照粒度，以及下面这种情况），此时会自动用 `−SystemLoad` 反推电池功率。这是真正的加减法，所以：

偏好设置里有 **功率数据来源** 选项：

| 选项 | 行为 |
|---|---|
| 自动（测量优先） | 遥测 → 电压 × 电流 → 最后由整机负载反推 |
| 电压 × 电流 | 只用寄存器乘积，能看到最原始的抖动 |
| **仅实测（禁止推算）** | 只显示独立测量值；寄存器为 0 时显示 `—`，绝不凑数 |

选「仅实测」可以确保屏幕上的每个数字都是量出来的。

---

## 七、数据刷新节奏：为什么数值看起来"卡住"了（**重要**）

这一条解释了使用中最容易困惑的现象：**卡片显示 22.7 W，而适配器实际已经在 70 W**。

`AppleSmartBattery` 的 `UpdateTime` 是驱动**最后一次整体重新发布该节点**的 Unix 时间戳。实测（MacBookPro18,2 / macOS 27）：

```
现在 date +%s = 1791911288  (01:08:08)
UpdateTime    = 1791911255  -> 01:07:35    差 33 秒
```

连续观测 `UpdateTime` 的变化间隔：**+60 秒、+28 秒、+60 秒**。

更关键的是，在该节点重新发布的那一刻，**所有值是一起变的**。18 秒内的逐秒采样（同一段数据里 `UpdateTime` 只前进了一次）：

```
01:04:31 … 01:04:39   UpdateTime=1791911053
                      Voltage=12825  InstantAmperage=3178  Temperature=3509
                      SystemPowerIn=62840  SystemLoad=22083  CellVoltage=4275/4271/4277
01:04:40              UpdateTime=1791911080   ← 整块一起变
                      Voltage=12837  InstantAmperage=3178  Temperature=3519
                      SystemPowerIn=61901  SystemLoad=21125  CellVoltage=4280/4275/4282
```

### 用驱动自己的推送独立验证

轮询可能有偏差，所以又注册了 `kIOGeneralInterest`，让**驱动主动通知**它何时变化：

```
IOServiceAddInterestNotification -> 0 (成功)
起始 UpdateTime=1791912728  SystemPowerIn=41401  SystemLoad=28161
监听 60 秒…
  [51.50s] interest #1  UpdateTime=1791912788  SystemPowerIn=40634  SystemLoad=27325  ← 数据变了
结果：interest 触发 1 次，其中数据真正变化 1 次
```

60 秒内驱动只推送了 **1 次**。三种互相独立的方法（轮询时间戳、整块属性同变、驱动主动推送）结论一致。

### 更正：真正的秒级源存在，而且有两个

我最初排查了 IOReport、注册表之后就下结论说"1 秒级的源不存在"。**这个结论是错的，而且错了两次**：一次是漏查 HID 事件路径，一次是把 `AppleSMC` 误判为失效（见第二节，那是我的探针 bug）。

真正能用的秒级源有两个：

1. **`AppleSMC` 用户客户端** —— `PSTR` / `PDTR` / `PPBR` 直接给出瓦特，约 1 Hz。**这是本应用三条功率曲线的数据来源。**
2. **PMU HID 事件** —— 26 个 die/设备温度通道，亚秒级。用于"实时传感器"分组。


这里我又错了一次：我第一次在二进制里搜 `PSTR` / `PDTR` 这些字符串**没搜到**，就以为它不用 SMC。实际上 Swift 里 4 字符的字面量是「小字符串」，直接编码进指令立即数、不进 cstring 段，所以 `strings` 根本搜不到。反汇编 `PowerSampler` 才看到它调用 `SMCClient.key` + `SMCClient.readValue`，而 `SMCClient.init` 的打开方式与我逐条相同。

而注册表里本来就有一大批 `AppleARMPMUPowerSensor` / `AppleARMPMUTempSensor`——我之前只把它们当成"IORegistry 属性是静态元数据的 HID 服务"就跳过了，**没去读它们的 HID 事件**。读了之后：

```
PMU 通道数 = 156
26 个温度通道，48 个电压/电流通道

第 1 次读取 → 第 2 次读取：变化的温度通道 = 21 / 26
第 2 次读取 → 第 3 次读取：变化的温度通道 = 22 / 26
第 3 次读取 → 第 4 次读取：变化的温度通道 = 21 / 26
第 4 次读取 → 第 5 次读取：变化的温度通道 = 25 / 26
结论：5 次读取之间，24 / 26 个温度通道发生变化
```

电流/电压轨也一样：**80 个通道里 68 个在 5.5 秒内变化**，最多的一个在 11 次采样里出现了 15 个不同值——**亚秒级**。

事件格式（通过转储字段布局确定）：

| 事件类型 | 字段偏移 0 | 字段偏移 1 |
|---|---|---|
| `15`（Temperature） | 摄氏温度 | — |
| `25`（Power） | 数值 | 量纲：`1` = 电流，`2` = 电压 |

**所以两者都对**：

* `AppleSmartBattery` 节点确实是 **60 秒**才发布一次——电池百分比、健康度、循环次数、`SystemPowerIn` 这些天生就慢。
* **PMU 传感器是另一条独立的、亚秒级的路径**——CPU/GPU/各 die 温度、PMIC 各轨电压电流。


### 本应用现在的做法

新增 `PMUHIDReader`，并把卡片分成两组，如实标注：

```
供电                     ← AppleSmartBattery，约 60 秒一次
  电池功率 / 整机功耗 / 适配器供电
──────────────────────────────
实时传感器（秒级）        ← PMU HID 事件，亚秒级
  芯片温度（PMU 最高）
──────────────────────────────
电池                     ← AppleSmartBattery
  健康度 / 循环次数 / 温度 / 容量 / 电压电流
```

同一张卡片里同时采样两条折线的实测结果：

| 折线 | 7 帧中不同帧数 |
|---|---|
| 芯片温度（实时分组） | **7 / 7** |
| 电池功率（供电分组） | **1 / 7** |

差别来自数据源，不是界面。

**关于电压/电流轨**：值是实时的，但**每个通道的工程单位没有公开且并不统一**——`vldo4` 读数 `3.30`（像伏特），`vbuck1` 读数 `16206`（不是伏特）。所以我只把单位确定的**温度**放上界面，轨道以原始值暴露给诊断命令，绝不换算成瓦特。要把轨道的实时形状用起来，正确做法是用慢而准的 `SystemPowerIn` 去标定快而相对的轨道之和（实时形状 × 慢速绝对刻度），这需要一次拟合，我还没有做。

### 因此应用改成了"推送驱动"

既然变不了数据源的频率，就消除应用这一侧的延迟：注册 `kIOGeneralInterest`，驱动一发布就立刻重读，而不是等下一次轮询（原本最多晚一个轮询周期）。轮询定时器保留作为兜底，并驱动基于时间的估算。

打开卡片时也会**立即重读一次**，所以你看到的是这一刻能取到的最新快照。

### 意味着什么

* 在 `AppleSmartBattery` 这个节点里，**没有任何一个电源相关键是逐秒更新的**，连 `InstantAmperage`、每个 `CellVoltage` 都不是——它们是同一个快照的一部分。
* 因此基于这个节点的折线（供电、电池两组）会是 **30–60 秒的平台 + 一次阶跃**。那不是"卡住"，那就是这个信号真实的形状；把它画得更活跃只会是假的。
* 但这**不**代表整台机器没有秒级数据——PMU 传感器走的是另一条 HID 路径，见下面的更正。

界面上一度放过一个"数据 X 秒前"的计时器来标注新鲜度，后来去掉了：它只解释现象，不解决问题。真正该做的是消除应用这一侧的延迟，也就是上面那节「推送驱动」。

## 八、充电限制：为什么第三方应用做不到

你要求"支持电池充电限制功能"。**结论：在 Apple Silicon 上第三方应用无法真正控制充电上限。** 以下是实测证据，不是猜测。

| 可能的接口 | 实测结果 |
|---|---|
| 经典 SMC 键 `BCLM` / `CH0B` / `CH0C`（Intel 时代第三方充电限制工具用的就是这些） | ❌ 全部返回 `result = 132` = `kSMCKeyNotFound`。**这是用修好之后的 SMC 客户端重新确认的**（同一次运行里 `PSTR` / `PPBR` 都正常返回瓦特），所以不是探针问题，是这些键真的不存在 |
| `AppleSMCChargerUtil` / `AppleSmartBatteryManager` 内核对象 | 存在，但 `IOUserClientClass` 未公开，无文档化的 user-client API |
| `pmset` 开关 | ❌ 无任何 charge / limit 选项 |
| `defaults` / `nvram` | ❌ `com.apple.powerd`、`com.apple.BatteryHealth` 域都不存在；`nvram` 无相关项 |
| macOS 自带的充电上限 | ✅ 存在，但实现在 `BatterySettingsIntentsExtension` + powerd + 固件内部，只通过「系统设置 › 电池」暴露 |

补充说明：Apple Silicon 上 `AppleSMC` 用户客户端**依然可用**（见第二节），所以上面这些"键不存在"是逐键核实的结果，而不是"整个 SMC 都读不了"。可读的键（功率、温度、风扇）与不可读的键（充电控制）来自同一个客户端、同一次运行。

**结论：这件事本应用不做。** 曾经实现过一个「上限看护」（到达设定电量时通知你拔掉电源），后来整体移除了——它只是把系统限制转嫁给用户，并不解决问题。想要真正的充电上限只能用 macOS 自带的那一个（系统设置 › 电池）。

这也解释了为什么偏好设置里没有充电相关的开关。

## 九、构建

### 为什么不能直接用 `swift build`

本机只有 Command Line Tools（无 Xcode），而 **macOS 27 SDK 把 SwiftUI 的 `@State` 改成了宏**，需要 Xcode 才附带的 `SwiftUIMacros` 编译器插件。默认 SDK 下每个 SwiftUI 视图都会编译失败：

```
error: external macro implementation type 'SwiftUIMacros.StateMacro'
       could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```

本机实测各 SDK：

| SDK | `@State` | 结果 |
|---|---|---|
| MacOSX27.0（默认） | 宏，需要 `SwiftUIMacros` | ❌ |
| **MacOSX26.5** | 仍是普通属性包装器（只有 `@Entry`/`@Animatable`/`@Preview` 是宏） | ✅ |
| MacOSX15.2 | 同上 | ✅ |

`Scripts/resolve-sdk.sh` 自动挑出最新可用的 SDK，Makefile 与 `Scripts/build-app.sh` 把它导出为 `SDKROOT`。**所有构建都要走 Makefile**，裸跑 `swift build` 会用默认 SDK 而编译失败。

> 试过用 `.unsafeFlags(["-sdk", ...])` 绕过：不行。SwiftPM 仍会为部分编译单元传入自己的 `-sdk`，结果是两个 SDK 混用。`SDKROOT` 环境变量才能真正统一（实测 10/10 编译单元一致）。

也选用了 Swift 5 语言模式、`ObservableObject` 而非 `@Observable`、自绘图表组件而非依赖宏的 API，以最大限度降低对 Xcode 的依赖。

### 命令

```bash
make            # 同 make app
make sdk        # 显示会使用的 SDK
make build      # 只编译（debug）
make app        # 编译 + 打包 + 自检 → dist/BatteryScope.app
make run        # 打包并启动
make test       # 运行内置断言
make stop       # 退出正在运行的应用
make clean      # 删除 .build
make distclean  # 删除 .build 与 dist
```

产物：

```
dist/BatteryScope.app      菜单栏应用（双击即可运行，LSUIElement，无 Dock 图标）
dist/batteryscope-cli      命令行工具
```

### 命令行工具

```bash
dist/batteryscope-cli                  # 完整人类可读报告
dist/batteryscope-cli watch --interval 2
dist/batteryscope-cli json             # 输出 JSON
dist/batteryscope-cli raw --filter Temperature
dist/batteryscope-cli raw --dump-tree
dist/batteryscope-cli fields           # 每个解析后字段 + 系统信息 + IOPS 原始值
dist/batteryscope-cli selftest         # 296 项断言
dist/batteryscope-cli export-icon --out DIR
```

`fields` 是排查"某个数看着不对"的第一站：它把解析后的字段和 IOPS 原始字典全部列出，能直接看出是哪个字段带着哪个值。

---

## 十、内置自检

`swift test` 不可用——CLT 工具链不含 `XCTest.framework`。自检因此放在 CLI 里，用真机抓取的字节级数据做回归测试：

```bash
make test      # ✅ 自检通过：296 项断言
```

覆盖范围：

* 类型强转、无符号回绕、`Data` → hex
* `MfgData` 解码（用真机 blob `000000000b0001000a1400000431393136033030320341544c...`）
* `ManufactureDate` 的 ASCII 与标准打包日期两种形态
* 实测健康度 / 衰减 / 条件判断的数值
* 分层键查找与 `65535` "未知"哨兵
* 嵌套字典平铺与 `keyPath` 归属
* 适配器逐键合并（含键缺失、仅 raw、完全无适配器三种情况）
* 系统信息不/localized 污染
* 趋势估算（放电/充电/样本不足/电量不变/低于阈值）
* 降采样保形
* **历史归档的磁盘往返**（含损坏行容错、关闭持久化不写盘）
* **用与真机同构的合成注册表树跑完整 reader**（这是捕获"关键值藏在下一层"这类 bug 的关键测试）
* 真机合理性检查（设计容量区间、温度区间、健康度区间…）

---

## 十一、目录结构

```
Package.swift                         SwiftPM 清单
Makefile                              构建入口（导出 SDKROOT）
Scripts/
  resolve-sdk.sh                      挑选可用的 macOS SDK（含原因说明）
  build-app.sh                        编译 + 自检 + 打包 .app + 生成图标 + 临时签名
  Info.plist.template                 包信息模板（LSUIElement 等）
Sources/BatteryKit/                   数据层（无 UI 依赖，仅 IOKit/CoreGraphics）
  Support/  ValueCoercion · RegistryTree · ManufacturerDataDecoder · AppIconRenderer
  Model/    BatterySnapshot · BatteryComponents · SystemProfile
  Reading/  BatteryReader · PowerSourceReader · BatteryRegistryWatcher
            · SMCClient · SMCPowerReader · SMCThermalReader · PMUHIDReader（仅诊断）
  Analysis/ TrendEstimator · BatteryEventDetector · RemainingTimeStabilizer
  Monitor/  BatteryMonitor · HistoryStore
  Format/   UnitFormat · BatterySnapshot+Export · MenuBarPresentation
            · MenuBarIconRenderer（放在 BatteryKit 里才能做像素级测试）
Sources/BatteryScope/                 菜单栏应用（SwiftUI + AppKit）
  main.swift · AppDelegate · StatusItemController · Preferences · Notifier · LoginItem
  Format/MenuBarIconRenderer          自绘电池图标（在 BatteryKit 里，便于做像素级测试）
  Popover/CardView                    点击图标展开的卡片（纯实时视图）
  Settings/SettingsWindowController   偏好设置窗口（只有设置项）
  Detail/  DetailView · ChartsView · RawKeysView · DetailWindowController
  Theme/   Theme · RingGauge
Sources/BatteryScopeCLI/              命令行工具 + 自检
```

数据层（`BatteryKit`）不依赖 SwiftUI，可单独在别的项目里引用。

---
