import Foundation
import BatteryKit

/// A dependency-free replacement for `swift test`: the Command Line Tools toolchain does
/// not ship `XCTest.framework`, so the checks live here and are run with
/// `batteryscope-cli selftest`.
///
/// The parser tests use byte-for-byte dumps captured from real hardware, which makes them
/// genuine regression tests rather than synthetic smoke tests.
enum SelfTest {

    private static var failures: [String] = []
    private static var checks = 0

    static func run() -> Bool {
        failures = []
        checks = 0

        testValueCoercion()
        testManufacturerData()
        testManufactureDate()
        testHealthMath()
        testPowerMath()
        testLayeredProperties()
        testRegistryFlattening()
        testAdapterLayering()
        testSystemProfile()
        testSampleMetrics()
        testPowerSourceModes()
        testMenuBarPresentation()
        testDieTemperatures()
        testPowerSourcePrecedence()
        testSMCPowerKeys()
        testTrendEstimator()
        testHistoryDownsampling()
        testHistoryPersistence()
        testSyntheticSnapshot()
        testLiveHardware()

        print("")
        if failures.isEmpty {
            print("✅ 自检通过：\(checks) 项断言")
            return true
        }
        print("❌ 自检失败：\(failures.count) / \(checks) 项")
        for failure in failures { print("   • \(failure)") }
        return false
    }

    // MARK: - Assertions

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { failures.append(message) }
    }

    private static func expectEqual<T: Equatable>(_ actual: T?, _ expected: T, _ message: String) {
        checks += 1
        if actual != expected {
            failures.append("\(message)：期望 \(expected)，实际 \(String(describing: actual))")
        }
    }

    private static func expectClose(_ actual: Double?, _ expected: Double, tolerance: Double = 0.001, _ message: String) {
        checks += 1
        guard let actual else {
            failures.append("\(message)：值为 nil")
            return
        }
        if abs(actual - expected) > tolerance {
            failures.append("\(message)：期望 \(expected)±\(tolerance)，实际 \(actual)")
        }
    }

    // MARK: - Tests

    private static func testValueCoercion() {
        expectEqual(ValueCoercion.int(42 as Any), 42, "int(Int)")
        expectEqual(ValueCoercion.int(NSNumber(value: 8694)), 8694, "int(NSNumber)")
        expectEqual(ValueCoercion.int("123" as Any), 123, "int(String)")
        expectEqual(ValueCoercion.bool(1 as Any), true, "bool(1)")
        expectEqual(ValueCoercion.bool(0 as Any), false, "bool(0)")
        expectEqual(ValueCoercion.bool(true as Any), true, "bool(true)")
        expectEqual(ValueCoercion.bool("Yes" as Any), true, "bool(\"Yes\")")
        // ioreg prints huge unsigned values; the raw field is a signed Int64 under the hood.
        // 18446744073172697098 is the value ioreg shows for AdapterDetails.FamilyCode.
        expectEqual(ValueCoercion.uint64(NSNumber(value: Int64(-536_854_518))),
                    18_446_744_073_172_697_098, "uint64 负数回绕")
        expectClose(ValueCoercion.double(33.5 as Any), 33.5, "double(Double)")
        expectEqual(ValueCoercion.typeName(of: NSNumber(value: true)), "Boolean", "typeName(Bool)")
        expectEqual(ValueCoercion.typeName(of: NSNumber(value: 1)), "Number", "typeName(Int)")
        expectEqual(ValueCoercion.typeName(of: "hi" as Any), "String", "typeName(String)")
        expectEqual(ValueCoercion.typeName(of: Data([1, 2, 3])), "Data", "typeName(Data)")
        expectEqual(Data([0x0a, 0x14]).hexString, "0a14", "Data.hexString")
    }

    private static func testManufacturerData() {
        // Captured verbatim from a MacBookPro18,2.
        let blob = Data(hexString: "000000000b0001000a1400000431393136033030320341544c00ff0000000000")!
        guard let decoded = ManufacturerData.decode(blob) else {
            expect(false, "ManufacturerData 解码返回 nil")
            return
        }
        expectEqual(decoded.vendorCode, "ATL", "MfgData 厂商码")
        expectEqual(decoded.vendorName, "Amperex Technology Limited (ATL)", "MfgData 厂商名")
        expectEqual(decoded.lotCodes, ["1916", "002"], "MfgData 批次码")
        expectEqual(decoded.firmwareVersion, "0b00", "MfgData 固件版本")
        expectEqual(decoded.cellRevision, "0a14", "MfgData 电芯版本")
        expectEqual(decoded.packLotCode, 0, "MfgData pack lot code")
        expect(ManufacturerData.decode(nil) == nil, "MfgData nil 输入")
        expect(ManufacturerData.decode(Data([1, 2])) == nil, "MfgData 过短输入")
    }

    private static func testManufactureDate() {
        // Real value from hardware: ASCII "800192", explicitly *not* a packed date.
        guard let decoded = ManufactureDateDecoder.decode(61_779_618_117_938) else {
            expect(false, "ManufactureDate 解码返回 nil")
            return
        }
        expectEqual(decoded.displayString, "800192", "ManufactureDate ASCII 编码")
        expect(!decoded.isRealDate, "ManufactureDate 不应被当成真实日期")

        // A genuine Smart Battery packed date: 2016-05-19 -> day 19, month 5, year 36.
        let packed: UInt64 = 19 | (5 << 5) | (36 << 9)
        guard let real = ManufactureDateDecoder.decode(packed) else {
            expect(false, "packed ManufactureDate 解码返回 nil")
            return
        }
        expectEqual(real.displayString, "2016-05-19", "ManufactureDate 标准打包日期")
        expect(real.isRealDate, "packed 日期应被识别为真实日期")
        expect(ManufactureDateDecoder.decode(0) == nil, "ManufactureDate 0 应为 nil")
    }

    private static func testHealthMath() {
        // Numbers captured from the dev machine.
        var snapshot = BatterySnapshot()
        snapshot.designCapacityMAh = 8694
        snapshot.maxCapacityMAh = 7700
        snapshot.nominalCapacityMAh = 7944
        snapshot.currentCapacityMAh = 6074
        snapshot.cycleCount = 114
        snapshot.designCycleCount = 1000

        // Health is the measured ratio only: 7700 achieved / 8694 designed.
        expectClose(snapshot.healthPercent, 88.57, tolerance: 0.01, "实测健康度")
        expectEqual(snapshot.capacityFadeMAh, 994, "实测衰减 mAh")
        expect(snapshot.healthPercent != nil, "健康度可计算")
        expectClose(snapshot.cycleUsagePercent, 11.4, tolerance: 0.01, "循环占用")
        expectEqual(snapshot.condition as BatteryCondition?, BatteryCondition.normal, "电池状况")

        snapshot.permanentFailureStatus = 1
        expectEqual(snapshot.condition as BatteryCondition?, BatteryCondition.serviceRecommended, "永久故障 -> 建议维修")

        // Health now derives from the measured full-charge capacity, so that is what has to
        // degrade for the condition to flip.
        var degraded = BatterySnapshot()
        degraded.designCapacityMAh = 8694
        degraded.maxCapacityMAh = 6000
        expectClose(degraded.healthPercent, 69.0, tolerance: 0.1, "劣化电池健康度")
        expectEqual(degraded.condition as BatteryCondition?, BatteryCondition.serviceRecommended, "健康度 <80% -> 建议维修")

        // The 80 % boundary itself, since the detail window's health ring colour is keyed to the
        // same number: below it yellow, at or above it green. macOS uses this threshold too — under
        // 80 % is when System Settings reports the battery as needing service. A three-way split
        // (red under 80, amber under 90) used to paint a healthy 89 % battery amber.
        var exactly80 = BatterySnapshot()
        exactly80.designCapacityMAh = 8000
        exactly80.maxCapacityMAh = 6400
        expectClose(exactly80.healthPercent, 80.0, tolerance: 0.01, "健康度正好 80%")
        expectEqual(exactly80.condition as BatteryCondition?, BatteryCondition.normal,
                    "健康度 80% 整 -> 正常（阈值取 <80，不是 <=80）")

        var justUnder80 = BatterySnapshot()
        justUnder80.designCapacityMAh = 8000
        justUnder80.maxCapacityMAh = 6320
        expectClose(justUnder80.healthPercent, 79.0, tolerance: 0.01, "健康度 79%")
        expectEqual(justUnder80.condition as BatteryCondition?, BatteryCondition.serviceRecommended,
                    "健康度 79% -> 建议维修")

        let empty = BatterySnapshot()
        expectEqual(empty.condition as BatteryCondition?, BatteryCondition.unknown, "无数据 -> 未知")
        expect(empty.healthPercent == nil, "无设计容量时健康度应为 nil")
        // 空快照仍有「标识」一节（设备名/序列号等字段在读不到时是空串，但行还在），
        // 所以这里断言的是策略而非数量。
        let emptyTitles = empty.detailSections().map(\.title)
        expect(!emptyTitles.contains("容量") && !emptyTitles.contains("概览") && !emptyTitles.contains("提示"),
               "窗口：无数据时同样不渲染概览/提示/容量")

        // 窗口是固定 schema：卡片标题、卡片顺序、每张卡的行数都与数据无关。
        // 这是「绝对对称」的机械定义——结构不随电源状态变化，两列才可能逐行对齐。
        let report = snapshot.reportSections()
        let detail = snapshot.detailSections()
        let reportTitles = report.map(\.title)
        let detailTitles = detail.map(\.title)
        let counts = detail.map { $0.rows.count }

        expectEqual(detailTitles,
                    ["电气与功耗", "充电器与供电", "寿命统计（电芯记录）", "标识"],
                    "窗口：固定四张卡片且顺序固定")
        expectEqual(counts, [8, 8, 7, 7], "窗口：固定行数（9/9→8/8 与 7/7）")

        // 每一行两张卡片行数必须相等
        for index in stride(from: 0, to: counts.count - 1, by: 2) {
            expectEqual(counts[index], counts[index + 1],
                        "窗口：第 \(index / 2 + 1) 行两张卡片行数相等"
                        + "（\(detail[index].title) \(counts[index]) vs \(detail[index + 1].title) \(counts[index + 1])）")
        }

        // 无数据时结构不变——只是值变成 —。这正是拔掉电源后布局不动的保证。
        let emptySections = empty.detailSections()
        expectEqual(emptySections.map(\.title), detailTitles, "窗口：无数据时卡片结构不变")
        expectEqual(emptySections.map { $0.rows.count }, counts, "窗口：无数据时行数不变")
        expect(emptySections.flatMap(\.rows).allSatisfy { $0.value == "—" },
               "窗口：无数据时每个值都是 —（而不是空串或消失）")

        for hidden in ["概览", "提示", "容量"] where reportTitles.contains(hidden) {
            expect(!detailTitles.contains(hidden), "窗口：不渲染「\(hidden)」卡片")
        }
        expect(reportTitles.contains("容量"), "文本报告：容量一节仍然保留")

        // 容量一律取实测值：窗口里不得出现电量计的模型值（标称满充容量）。
        // 文本报告保留它——那里是诊断用途。
        let capacityRowLabels = snapshot.detailSections().flatMap(\.rows).map(\.label)
        expect(!capacityRowLabels.contains { $0.contains("模型") },
               "窗口：不显示任何模型值（实际 \(capacityRowLabels.filter { $0.contains("模型") })）")
        expect(!capacityRowLabels.contains { $0.contains("标称满充容量") },
               "窗口：不显示标称满充容量")
        expect(snapshot.reportSections().flatMap(\.rows).contains { $0.label.contains("标称满充容量") },
               "文本报告：标称满充容量仍然保留")

        // 三块功率必须来自同一个来源，否则会在变化时互相矛盾；而它们又必须满足守恒律
        // （适配器 = 整机 + 电池）。这里断言不变量，而不是断言"用哪个键"——键的选择换过两次，
        // 而这条等式始终成立。
        var smcSourced = snapshot
        smcSourced.externalConnected = true
        smcSourced.isCharging = true
        var smcReading = SMCPowerReading()
        smcReading.systemWatts = 25.75
        smcReading.adapterWatts = 32.91
        smcReading.batteryWatts = 7.16          // 即 B0AC × B0AV 的乘积
        smcSourced.smcPower = smcReading
        expectClose(smcSourced.liveSystemLoadWatts ?? 0, 25.75, tolerance: 0.01, "功率：整机取 SMC")
        expectClose(smcSourced.liveAdapterInputWatts ?? 0, 32.91, tolerance: 0.01, "功率：适配器取 SMC")
        expectClose(smcSourced.liveBatteryPowerWatts ?? 0, 7.16, tolerance: 0.01, "功率：电池取 SMC")
        expectClose((smcSourced.liveSystemLoadWatts ?? 0) + (smcSourced.liveBatteryPowerWatts ?? 0),
                    smcSourced.liveAdapterInputWatts ?? 0, tolerance: 0.01,
                    "功率：三块来自同一来源时必须满足 整机 + 电池 = 适配器")

        // 用电池时没有适配器，电池必须正好是整机的相反数——用户看到的
        // "整机 9.37 / 电池 −20.32" 之所以不可能，就是因为这条。
        var dischargeCase = smcSourced
        dischargeCase.externalConnected = false
        dischargeCase.isCharging = false
        var discharge = SMCPowerReading()
        discharge.systemWatts = 21.80
        discharge.adapterWatts = 0
        discharge.batteryWatts = -21.80
        dischargeCase.smcPower = discharge
        expectClose((dischargeCase.liveSystemLoadWatts ?? 0) + (dischargeCase.liveBatteryPowerWatts ?? 0),
                    0, tolerance: 0.01, "功率：用电池时 整机 + 电池 = 0")

        // SMC 没有电池键时退回电池节点，数值仍然可用
        var nodeFallbackCase = snapshot
        nodeFallbackCase.smcPower = nil
        nodeFallbackCase.externalConnected = false
        var nodeTelemetry = PowerTelemetry()          // 单位毫瓦
        nodeTelemetry.systemLoadMW = 25_750
        nodeTelemetry.batteryPowerMW = 7_160
        nodeFallbackCase.telemetry = nodeTelemetry
        expectClose(nodeFallbackCase.liveBatteryPowerWatts ?? 0, 7.16, tolerance: 0.01,
                    "功率：SMC 无电池键时退回节点值")
        expect(nodeFallbackCase.hasLiveBatteryPower == false, "功率：退回节点时标记为非 SMC 来源")

        // 实时/趋势的分组必须覆盖全部指标，且互不重叠——漏掉一个指标会让它从选择器里消失。
        expectEqual(SampleMetric.realtimeCases.count + SampleMetric.trendCases.count,
                    SampleMetric.allCases.count, "图表分组：实时 + 趋势 = 全部指标")
        expect(SampleMetric.realtimeCases.allSatisfy(\.isRealtime), "图表分组：实时组标记正确")
        expect(SampleMetric.trendCases.allSatisfy { !$0.isRealtime }, "图表分组：趋势组标记正确")
        expect(SampleMetric.realtimeCases.contains(.power)
                && SampleMetric.realtimeCases.contains(.systemLoad),
               "图表分组：两个快速功率信号属于实时组")
        expect(SampleMetric.trendCases.contains(.chargePercent)
                && SampleMetric.trendCases.contains(.healthPercent),
               "图表分组：电量与健康度属于趋势组（40 秒内零变化）")

        // 新增的实时指标必须真的能取到值，而且分类要自洽——否则选择器里会出现永远空白的图。
        expect(SampleMetric.allCases.allSatisfy { !$0.displayName.isEmpty }, "指标：都有名称")
        expect(SampleMetric.allCases.allSatisfy { !$0.unit.isEmpty }, "指标：都有单位")
        for category in MetricCategory.allCases {
            let members = SampleMetric.cases(in: category)
            expect(!members.isEmpty, "分类：\(category.title) 非空")
            expect(members.allSatisfy { $0.category == category }, "分类：\(category.title) 成员一致")
        }
        expectEqual(MetricCategory.allCases.flatMap { SampleMetric.cases(in: $0) }.count,
                    SampleMetric.allCases.count, "分类：各分类覆盖全部指标且不重复")
        expect(SampleMetric.cases(in: .trend).allSatisfy { !$0.isRealtime },
               "分类：趋势组不含实时指标")

        // 负载类指标来自 BatterySample 的新字段，端到端验证一次取值。
        var loaded = BatterySample(timestamp: Date())
        loaded.cpuLoadPercent = 37
        loaded.gpuLoadPercent = 59
        loaded.memoryUsedPercent = 46
        loaded.fanRPM = 1520
        loaded.batteryCurrentAmps = -1.79
        expectClose(SampleMetric.cpuLoad.value(from: loaded) ?? 0, 37, tolerance: 0.01, "指标：CPU 占用取值")
        expectClose(SampleMetric.gpuLoad.value(from: loaded) ?? 0, 59, tolerance: 0.01, "指标：GPU 占用取值")
        expectClose(SampleMetric.memory.value(from: loaded) ?? 0, 46, tolerance: 0.01, "指标：内存取值")
        expectClose(SampleMetric.fanRPM.value(from: loaded) ?? 0, 1520, tolerance: 0.01, "指标：风扇取值")
        expectClose(SampleMetric.batteryCurrent.value(from: loaded) ?? 0, -1.79, tolerance: 0.01, "指标：电流取值")
        expect(SampleMetric.allCases.allSatisfy { $0.value(from: BatterySample(timestamp: Date())) == nil },
               "指标：空采样全部取不到值，不留假零")

        // 时间范围：新增的长范围必须真的存在、有正确的时长，并且出现在选择器里。
        expectEqual(ChartRange.offered.map(\.title),
                    ["5 分钟", "1 小时", "本次会话", "24 小时", "7 天", "30 天"],
                    "范围：选择器给出的六项")
        expectClose(ChartRange.day.duration ?? 0, 24 * 3600, tolerance: 1, "范围：24 小时")
        expectClose(ChartRange.week.duration ?? 0, 7 * 24 * 3600, tolerance: 1, "范围：7 天")
        expectClose(ChartRange.archive.duration ?? 0, 30 * 24 * 3600, tolerance: 1, "范围：30 天")
        expect(ChartRange.session.duration == nil, "范围：本次会话没有固定时长")
        // 24 小时及以上超出内存保留期（6 小时），必须走归档；会话必须走内存。
        expect(ChartRange.day.usesArchive && ChartRange.week.usesArchive && ChartRange.archive.usesArchive,
               "范围：24 小时/7 天/30 天使用归档")
        expect(!ChartRange.session.usesArchive && !ChartRange.oneHour.usesArchive
                && !ChartRange.fiveMinutes.usesArchive,
               "范围：会话与 1 小时以内使用内存缓冲")
        expect(HistoryStore().archiveRetention >= 30 * 24 * 3600,
               "范围：归档保留期覆盖 30 天")

        // 归档降采样：30 天每分钟一条约 43,200 点，必须压到上限之内且保持顺序。
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let dense = (0..<43_200).map { (start.addingTimeInterval(Double($0) * 60), Double($0 % 50)) }
        let reduced = HistoryStore.downsample(dense, limit: 700)
        expect(reduced.count <= 700, "归档降采样：点数不超过上限（实际 \(reduced.count)）")
        expect(reduced.count > 100, "归档降采样：点数不至于过少（实际 \(reduced.count)）")
        expect(zip(reduced, reduced.dropFirst()).allSatisfy { $0.date <= $1.date },
               "归档降采样：时间顺序保持")

        // CPU 温度的选择顺序：封装热点（TCMz）优先，核心最大值回退。
        let sensors: [(key: String, value: Double)] = [("Tp02", 59.72), ("Te02", 63.09), ("Tp06", 58.92)]
        let withHotspot = SMCThermalReader.pickCPUTemperature(hotspot: 63.40, sensors: sensors)
        expectEqual(withHotspot?.celsius, 63.40, "CPU 温度：有 TCMz 时取热点")
        expectEqual(withHotspot?.source, "TCMz", "CPU 温度：来源标记为 TCMz")
        let noHotspot = SMCThermalReader.pickCPUTemperature(hotspot: nil, sensors: sensors)
        expectEqual(noHotspot?.celsius, 63.09, "CPU 温度：无 TCMz 时回退到最热核心")
        expectEqual(noHotspot?.source, "Te02", "CPU 温度：回退时记录实际键名")
        // 读不到 / 越界的 TCMz 不得胜出——否则一个坏读数会顶掉正确的核心值
        expectEqual(SMCThermalReader.pickCPUTemperature(hotspot: 0, sensors: sensors)?.source, "Te02",
                    "CPU 温度：TCMz 为 0 时回退")
        expectEqual(SMCThermalReader.pickCPUTemperature(hotspot: 999, sensors: sensors)?.source, "Te02",
                    "CPU 温度：TCMz 越界时回退")
        expect(SMCThermalReader.pickCPUTemperature(hotspot: nil, sensors: []) == nil,
               "CPU 温度：两者都缺时返回 nil，不编造数值")

        // 窗口的行不带注解；文本报告保留。
        let reportRows = report.flatMap(\.rows)
        let windowRows = detail.flatMap(\.rows)
        let reportLabels = reportRows.map(\.label)
        let windowLabels = windowRows.map(\.label)

        expect(windowRows.allSatisfy { $0.note == nil },
               "窗口：所有行都不带注解（寄存器路径、单位重复、编码说明都只在文本报告里）")
        expect(windowRows.allSatisfy { !$0.value.isEmpty },
               "窗口：每行都有值（取不到时是 —，不留空）")

        // 用电池时"输入侧"读数必须变成 —（寄存器给的是 0）
        var onBattery = snapshot
        onBattery.externalConnected = false
        let batteryRows = onBattery.detailSections().flatMap(\.rows)
        for label in ["输入电压 / 电流", "适配器转换损耗"] {
            let value = batteryRows.first { $0.label == label }?.value
            expect(value == "—", "窗口：用电池时「\(label)」显示 —（实际 \(value ?? "缺行")）")
        }
        // 接电源时它们必须有真实值（否则上面那条会因数据缺失而假通过）
        var onAC = snapshot
        onAC.externalConnected = true
        let acValues = onAC.detailSections().flatMap(\.rows)
            .filter { ["输入电压 / 电流", "适配器转换损耗"].contains($0.label) }
            .map(\.value)
        expect(acValues.count == 2, "窗口：接电源时两行都存在")

        for dropped in ["PMU 允许充电", "未充电原因", "电量计芯片"] where reportLabels.contains(dropped) {
            expect(!windowLabels.contains(dropped), "窗口：不显示「\(dropped)」")
            expect(reportLabels.contains(dropped), "文本报告：仍保留「\(dropped)」")
        }

        // 窗口里同一个标签不能出现两次——这正是「电池序列号在总览和标识里各有一个」那类问题
        let duplicated = Dictionary(grouping: windowLabels, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        expect(duplicated.isEmpty, "窗口：没有重复的行标签（重复的是 \(duplicated)）")

        // 每一行必须只有一行高：两列并排时，只要有一行的值换行，它下面的所有行就会错位。
        // USB-PD 档位逐档列出曾是这样，窗口现在给单行摘要。
        let wrapped = windowRows.filter { $0.value.contains("\n") || $0.label.contains("\n") }
        expect(wrapped.isEmpty,
               "窗口：没有多行的值或标签（会打乱两列对齐，实际有 \(wrapped.map(\.label))）")
        if let menuRow = windowRows.first(where: { $0.label.hasPrefix("USB-PD 档位") }) {
            expect(!menuRow.value.contains("\n"), "窗口：USB-PD 档位是单行摘要")
            expect(!menuRow.label.contains("HVC"), "窗口：标签不带内部术语 HVC")
        }

        // 注解是窗口专属策略——文本报告里注解必须还在，否则说明剥错了地方
        let reportNoteCount = reportRows.compactMap(\.note).count
        let windowNoteCount = windowRows.compactMap(\.note).count
        expect(windowNoteCount == 0, "窗口：注解数为 0")
        if reportNoteCount > 0 {
            expect(reportNoteCount > windowNoteCount, "文本报告：注解未被连带剥离")
        }
    }

    private static func testPowerMath() {
        var snapshot = BatterySnapshot()
        snapshot.voltageVolts = 12.299
        snapshot.amperageAmps = 2.5
        expectClose(snapshot.chargePowerWatts, 30.7475, tolerance: 0.001, "充电功率 = V × A")

        snapshot.amperageAmps = -1.2
        expectClose(snapshot.chargePowerWatts, -14.7588, tolerance: 0.001, "放电功率为负")

        var telemetry = PowerTelemetry()
        telemetry.systemPowerInMW = 27_714
        telemetry.systemLoadMW = 27_714
        telemetry.batteryPowerMW = 0
        snapshot.telemetry = telemetry
        expectClose(snapshot.adapterInputWatts, 27.714, tolerance: 0.001, "实际输入功率")
        expectClose(snapshot.systemLoadWatts, 27.714, tolerance: 0.001, "系统负载")

        // Telemetry should win when it carries a real magnitude.
        telemetry.batteryPowerMW = 15_000
        snapshot.telemetry = telemetry
        expectClose(snapshot.effectiveBatteryPowerWatts, 15.0, tolerance: 0.001, "遥测优先于电流推算")
        expectEqual(snapshot.effectiveBatteryPower?.source.rawValue, "PMU 遥测", "功率来源标注：遥测")
        expect(!snapshot.isBatteryPowerDerived, "遥测读数不算推算")

        // The Apple Silicon discharging case: amperage *and* BatteryPower read 0 while the
        // machine is genuinely pulling power from the battery.
        var discharging = BatterySnapshot()
        discharging.voltageVolts = 12.299
        discharging.amperageAmps = 0
        discharging.externalConnected = false
        discharging.isCharging = false
        var zeroTelemetry = PowerTelemetry()
        zeroTelemetry.batteryPowerMW = 0
        zeroTelemetry.systemLoadMW = 36_313
        zeroTelemetry.systemPowerInMW = 36_313
        discharging.telemetry = zeroTelemetry
        expectClose(discharging.effectiveBatteryPowerWatts, -36.313, tolerance: 0.001,
                    "放电时由整机负载推算电池功率")
        expect(discharging.isBatteryPowerDerived, "推算得出的功率应被标记")
        expectEqual(discharging.effectiveBatteryPower?.source.rawValue, "整机负载推算", "功率来源标注：推算")

        // Plugged in and idle must NOT be turned into a fake discharge.
        var pluggedIdle = discharging
        pluggedIdle.externalConnected = true
        expectClose(pluggedIdle.effectiveBatteryPowerWatts, 0, tolerance: 0.001,
                    "接电源且无电流时功率为 0，不应推算")
        expect(!pluggedIdle.isBatteryPowerDerived, "接电源时不应标记为推算")

        // Real current still takes precedence over the load-derived value.
        var realCurrent = discharging
        realCurrent.amperageAmps = -2.0
        expectClose(realCurrent.effectiveBatteryPowerWatts, -24.598, tolerance: 0.001,
                    "有真实电流时优先使用电压 × 电流")

        var adapter = AdapterSnapshot()
        adapter.ratedWatts = 140
        adapter.negotiatedVoltageVolts = 28.0
        adapter.negotiatedCurrentAmps = 4.99
        let expected = 28.0 * 4.99
        expectClose(adapter.negotiatedWatts ?? adapter.negotiatedVoltageVolts! * adapter.negotiatedCurrentAmps!,
                    expected, tolerance: 0.001, "PD 协商功率")

        expectEqual(ChargingDiagnostics.hex(0x0100_0000), "0x01000000", "NotChargingReason 十六进制")
        expect(ChargingDiagnostics.notChargingReasonLabel(0x0100_0000) != nil, "已知未充电原因有解释")
        expect(ChargingDiagnostics.notChargingReasonLabel(0xDEAD_BEEF) == nil, "未知未充电原因不猜测")
        expectEqual(ChargingDiagnostics.notChargingReasonLabel(0), "充电未被阻止", "0 表示未被阻止")
    }

    private static func testLayeredProperties() {
        let pack: [String: Any] = ["Temperature": 3350, "DesignCapacity": 8694]
        let topData: [String: Any] = ["DesignCapacity": 8694, "RemainingCapacity": 6074]
        let top: [String: Any] = ["CycleCount": 114, "CurrentCapacity": 80]
        let p = LayeredProperties([pack, topData, top])

        expectEqual(p.int("Temperature"), 3350, "分层读取：仅存在于 pack")
        expectEqual(p.int("CycleCount"), 114, "分层读取：仅存在于顶层")
        expectEqual(p.int("RemainingCapacity"), 6074, "分层读取：仅存在于 BatteryData")
        expectEqual(p.firstInt(["AppleRawMaxCapacity", "DesignCapacity"]), 8694, "firstInt 回退")
        expectEqual(p.minutes("AvgTimeToEmpty"), nil, "65535 视为未知")
        expect(p.raw("Missing") == nil, "缺失键返回 nil")
    }

    private static func testRegistryFlattening() {
        let node = RegistryNode(
            className: "AppleSmartBattery",
            properties: [
                "CycleCount": 114,
                "IsCharging": false,
                "BatteryData": ["DesignCapacity": 8694, "Nested": ["Deep": 1]],
            ],
            children: [
                RegistryNode(className: "AppleSmartBatteryPack",
                             properties: ["BatteryData": ["Temperature": 3350]],
                             children: [])
            ]
        )
        let rows = node.flattened()
        let paths = Set(rows.map(\.pathString))
        expect(paths.contains("AppleSmartBattery.BatteryData.DesignCapacity"), "展开嵌套字典")
        expect(paths.contains("AppleSmartBattery.BatteryData.Nested.Deep"), "展开两层嵌套")
        expect(paths.contains("AppleSmartBattery.IsCharging"), "包含标量键")
        expect(paths.contains("AppleSmartBattery.AppleSmartBatteryPack.BatteryData.Temperature"), "包含子节点")
        expectEqual(rows.count, 5, "平铺条目总数")
        // keyPath is relative to the owning node, which is how the browser groups rows.
        let temperature = rows.first { $0.key == "Temperature" }
        expectEqual(temperature?.nodeClass, "AppleSmartBatteryPack", "keyPath 归属节点")
        expectEqual(temperature?.keyPath, "BatteryData.Temperature", "keyPath 相对节点")
    }

    /// The adapter's identity keys are published intermittently.
    ///
    /// A live dump taken minutes after the first one had `AdapterDetails` with `Watts`,
    /// `Current` and `AdapterVoltage` but **no** `Name`, `Manufacturer` or `SerialString`,
    /// which used to make the whole adapter look nameless. These cases pin down the per-key
    /// layering that fixes it.
    private static func testAdapterLayering() {
        let partialAndRaw = RegistryNode(className: "AppleSmartBattery", properties: [
            "CurrentCapacity": 80,
            "ExternalConnected": 1,
            "AdapterDetails": ["Watts": 140, "Current": 4990, "AdapterVoltage": 28000],
            "AppleRawAdapterDetails": [[
                "Watts": 140, "Current": 4990, "AdapterVoltage": 28000,
                "Name": "140W USB-C Power Adapter", "Manufacturer": "Apple Inc.",
                "SerialString": "ADAPTER-SERIAL-EXAMPLE", "FwVersion": "01040090",
            ]],
        ], children: [])
        let s = BatteryReader.makeSnapshot(from: partialAndRaw)
        expectEqual(s.adapter?.name, "140W USB-C Power Adapter", "适配器：Name 从 AppleRawAdapterDetails 逐键回退")
        expectEqual(s.adapter?.manufacturer, "Apple Inc.", "适配器：Manufacturer 回退")
        expectEqual(s.adapter?.serial, "ADAPTER-SERIAL-EXAMPLE", "适配器：序列号回退")
        expectEqual(s.adapter?.ratedWatts, 140, "适配器：Watts 取自 AdapterDetails")
        expectEqual(s.adapter?.displayName, "140W USB-C Power Adapter", "适配器：displayName 使用真实名称")
        expectClose(s.adapter?.negotiatedWatts, 139.72, tolerance: 0.01, "适配器：协商功率")

        // No Name anywhere: a useful label must still be produced.
        let nameless = RegistryNode(className: "AppleSmartBattery", properties: [
            "ExternalConnected": 1,
            "AdapterDetails": ["Watts": 140, "Current": 4990, "AdapterVoltage": 28000,
                               "Description": "pd charger"],
        ], children: [])
        let n = BatteryReader.makeSnapshot(from: nameless)
        expectEqual(n.adapter?.name, nil, "适配器：固件未提供 Name 时为 nil")
        expectEqual(n.adapter?.displayName, "pd charger（140W）", "适配器：displayName 合成")
        expectEqual(n.adapter?.effectiveRatedWatts, 140, "适配器：标称功率")

        // Neither a Name nor a Description: fall through to the wattage.
        let bare = RegistryNode(className: "AppleSmartBattery", properties: [
            "ExternalConnected": 1,
            "AdapterDetails": ["Watts": 96],
        ], children: [])
        expectEqual(BatteryReader.makeSnapshot(from: bare).adapter?.displayName,
                    "96W 电源适配器", "适配器：仅有功率时的 displayName")

        // AdapterDetails absent entirely.
        let onlyRaw = RegistryNode(className: "AppleSmartBattery", properties: [
            "ExternalConnected": 1,
            "AppleRawAdapterDetails": [["Watts": 96, "Name": "96W USB-C Power Adapter"]],
        ], children: [])
        let r = BatteryReader.makeSnapshot(from: onlyRaw)
        expectEqual(r.adapter?.ratedWatts, 96, "适配器：仅 AppleRawAdapterDetails 时可解析")
        expectEqual(r.adapter?.name, "96W USB-C Power Adapter", "适配器：仅 raw 时的名称")

        // No adapter at all must not produce an empty snapshot object.
        let none = RegistryNode(className: "AppleSmartBattery",
                                properties: ["CurrentCapacity": 50], children: [])
        expect(BatteryReader.makeSnapshot(from: none).adapter == nil, "适配器：未接电源时为 nil")
    }

    /// `ProcessInfo.operatingSystemVersionString` is localised, and on a Chinese system it
    /// contains full-width brackets, which broke the old string parsing.
    private static func testSystemProfile() {
        let profile = SystemInfoReader.read()
        expect(!profile.osVersion.contains("版本"),
               "系统信息：版本号不被本地化字符串污染（实际 “\(profile.osVersion)”）")
        expect(!profile.osVersion.contains("(") && !profile.osVersion.contains("（"),
               "系统信息：版本号不含括号（实际 “\(profile.osVersion)”）")
        expect(profile.osVersion.split(separator: ".").count >= 2,
               "系统信息：版本号形如 x.y.z（实际 “\(profile.osVersion)”）")
        expectEqual(profile.osDescription, "macOS \(profile.osVersion) (\(profile.osBuild))",
                    "系统信息：osDescription 组装")
        expect(!profile.chipName.isEmpty, "系统信息：芯片名称非空")
        expect(profile.physicalMemoryBytes > 0, "系统信息：内存容量可读")
        expect(profile.osBuild != "—", "系统信息：构建版本可读")
        expect(!profile.modelMarketingName.isEmpty, "系统信息：机型名称非空")
    }

    /// Exercises the whole reader against a synthetic tree shaped exactly like the real
    /// Apple Silicon layout (values copied from a MacBookPro18,2). This is the test that
    /// catches the "interesting keys are nested one level down" class of bug without
    /// depending on the machine the tests run on.
    private static func testSyntheticSnapshot() {
        let blob = Data(hexString: "000000000b0001000a1400000431393136033030320341544c00ff0000000000")!

        let cell = RegistryNode(className: "AppleSmartBatteryCell",
                                properties: ["CellID": 0, "BankID": 0,
                                             "CellData": ["CellCurrent": 1779]],
                                children: [])
        let bank = RegistryNode(className: "AppleSmartBatteryBank",
                                properties: ["BankID": 0, "PackID": 0,
                                             "BatteryData": ["CellVoltage": 4100, "Qmax": 8540,
                                                             "WeightedRa": 75, "PresentDOD": 21]],
                                children: [cell])
        let pack = RegistryNode(className: "AppleSmartBatteryPack",
                                properties: [
                                    "BankCount": 3,
                                    "BatteryData": [
                                        "DesignCapacity": 8694,
                                        "AppleRawMaxCapacity": 7700,
                                        "AppleRawCurrentCapacity": 6074,
                                        "NominalChargeCapacity": 7944,
                                        "Temperature": 3350,
                                        "VirtualTemperature": 3350,
                                        "CycleCount": 114,
                                        "StateOfCharge": 79,
                                        "Voltage": 12299,
                                        "Amperage": 1500,
                                        "InstantAmperage": 1500,
                                        "FullyCharged": 0,
                                        "PermanentFailureStatus": 0,
                                        "ManufactureDate": 61_779_618_117_938,
                                        "MfgData": blob,
                                        "LifetimeData": [
                                            "TotalOperatingTime": 9642,
                                            "AverageTemperature": 224,
                                            "MinimumTemperature": 9,
                                            "MaximumTemperature": 46,
                                            "MinimumPackVoltage": 9136,
                                            "MaximumPackVoltage": 13016,
                                            "MaximumChargeCurrent": 9328,
                                            "MaximumDischargeCurrent": Int64(-8547),
                                        ],
                                    ],
                                ],
                                children: [bank])
        let root = RegistryNode(
            className: "AppleSmartBattery",
            properties: [
                "CurrentCapacity": 80,
                "MaxCapacity": 100,
                "CycleCount": 114,
                "IsCharging": 1,
                "FullyCharged": 0,
                "ExternalConnected": 1,
                "ExternalChargeCapable": 1,
                "DesignCycleCount9C": 1000,
                "Serial": "BATTERY-SERIAL-EXAMPLE",
                "DeviceName": "bq40z651",
                "AdapterDetails": [
                    "Name": "140W USB-C Power Adapter",
                    "Manufacturer": "Apple Inc.",
                    "Watts": 140,
                    "Current": 4990,
                    "AdapterVoltage": 28000,
                    "FamilyCode": Int64(-536_854_518),
                    // 两档：逐档列出会占两行，窗口必须给出单行摘要
                    "UsbHvcMenu": [["Index": 2, "MaxCurrent": 2990, "MaxVoltage": 15000],
                                   ["Index": 3, "MaxCurrent": 4990, "MaxVoltage": 20000]],
                ],
                "PowerTelemetryData": ["SystemPowerIn": 27_714, "SystemLoad": 27_714,
                                       "SystemVoltageIn": 27_723, "SystemCurrentIn": 999,
                                       "BatteryPower": 18_500, "AdapterEfficiencyLoss": -91],
                "PowerDistribution": ["IPDInputPower": 139_720, "IPDInputCurrent": 4990,
                                      "IPDInputVoltage": 28000, "IPDChargingAllowed": 1],
                // Non-zero on purpose: the synthetic input stands in for a pack that is fully
                // charged while the charger IC has backed its input limit off — the state in which
                // the old "限流回退" note used to fire. It must not produce an advisory, and the
                // slow-charging note must not leak the raw reason code into its text.
                "ChargerData": ["NotChargingReason": 0, "SlowChargingReason": 7,
                                "ChargerHwIlimBackoffReason": 16, "ChargerInhibitReason": 3],
            ],
            children: [pack]
        )

        let s = BatteryReader.makeSnapshot(from: root)

        // Nested-lookup regression guards.
        expectEqual(s.designCapacityMAh, 8694, "合成：DesignCapacity 来自 Pack.BatteryData")
        expectEqual(s.maxCapacityMAh, 7700, "合成：AppleRawMaxCapacity 来自 Pack.BatteryData")
        expectEqual(s.currentCapacityMAh, 6074, "合成：AppleRawCurrentCapacity 来自 Pack.BatteryData")
        expectEqual(s.nominalCapacityMAh, 7944, "合成：NominalChargeCapacity")
        expectClose(s.temperatureCelsius, 33.5, tolerance: 0.001, "合成：温度 /100")

        // 提示：只用人能读懂的话，且不回显固件寄存器里的原始代码
        let advisories = s.advisories
        expect(!advisories.contains { $0.contains("限流回退") },
               "提示：ChargerHwIlimBackoffReason 不再产生提示（它在满电时正常触发）")
        expect(!advisories.contains { $0.contains("SlowChargingReason") },
               "提示：不回显 SlowChargingReason 原始代码")
        expect(!advisories.contains { $0.contains("ChargerInhibitReason") },
               "提示：不回显 ChargerInhibitReason 原始代码")
        expect(!advisories.contains { $0.contains("16") || $0.contains("= 7") || $0.contains("= 3") },
               "提示：正文里不含原始寄存器取值")
        expect(advisories.contains { $0.contains("充电速度较慢") },
               "提示：充电缓慢仍以可读的话报告")
        expectEqual(s.chargePercent, 80, "合成：电量百分比来自顶层")
        expectEqual(s.stateOfChargePercent, 79, "合成：电量计 SoC")
        expectEqual(s.cycleCount, 114, "合成：循环次数")
        expectEqual(s.designCycleCount, 1000, "合成：设计循环次数 DesignCycleCount9C")
        expect(s.isCharging, "合成：充电中")
        expect(s.externalConnected, "合成：已接电源")

        // Electrical: 12299 mV x 1500 mA = 18.45 W
        expectClose(s.voltageVolts, 12.299, tolerance: 0.0001, "合成：电压")
        expectClose(s.amperageAmps, 1.5, tolerance: 0.0001, "合成：电流")
        expectClose(s.chargePowerWatts, 18.4485, tolerance: 0.0001, "合成：充电功率")
        expectClose(s.effectiveBatteryPowerWatts, 18.5, tolerance: 0.001, "合成：遥测优先")

        // Adapter
        expectEqual(s.adapter?.ratedWatts, 140, "合成：适配器标称功率")
        expectClose(s.adapter?.negotiatedVoltageVolts, 28.0, tolerance: 0.0001, "合成：协商电压")
        expectClose(s.adapter?.negotiatedWatts, 139.72, tolerance: 0.01, "合成：协商功率")
        expectClose(s.adapter?.maxMenuWatts, 99.8, tolerance: 0.001, "合成：PD 菜单最大功率")
        expectEqual(s.adapter?.familyCode, 18_446_744_073_172_697_098, "合成：FamilyCode 无符号")

        // Telemetry + distribution
        expectClose(s.adapterInputWatts, 27.714, tolerance: 0.001, "合成：实际输入功率")
        expectClose(s.telemetry?.efficiencyLossWatts, 0, tolerance: 0.0001, "合成：负损耗钳位为 0")
        expectClose(s.powerDistribution?.inputWatts, 139.72, tolerance: 0.01, "合成：PMU 输入功率")
        expectEqual(s.powerDistribution?.chargingAllowed, true, "合成：PMU 允许充电")

        // Banks
        expectEqual(s.banks.count, 1, "合成：电芯组数量")
        expectClose(s.banks.first?.cellVoltageVolts, 4.1, tolerance: 0.0001, "合成：电芯电压")
        expectEqual(s.banks.first?.qmaxMAh, 8540, "合成：Qmax")
        expectEqual(s.banks.first?.cellCurrentAmps.first, 1.779, "合成：电芯电流")

        // Lifetime — the mixed-scale temperature records are the subtle part.
        expectEqual(s.lifetime?.totalOperatingTimeMinutes, 9642, "合成：累计运行时间")
        expectClose(s.lifetime?.averageTemperatureCelsius, 22.4, tolerance: 0.001, "合成：历史平均温度（十分之一度）")
        expectClose(s.lifetime?.minimumTemperatureCelsius, 9, tolerance: 0.001, "合成：历史最低温度（整度）")
        expectClose(s.lifetime?.maximumTemperatureCelsius, 46, tolerance: 0.001, "合成：历史最高温度（整度）")
        expectClose(s.lifetime?.maximumChargeCurrentAmps, 9.328, tolerance: 0.001, "合成：历史最大充电电流")
        expectClose(s.lifetime?.maximumDischargeCurrentAmps, -8.547, tolerance: 0.001, "合成：历史最大放电电流（负数回绕）")

        // Identity
        expectEqual(s.serial, "BATTERY-SERIAL-EXAMPLE", "合成：序列号")
        expectEqual(s.manufacturerData?.vendorCode, "ATL", "合成：电芯厂商")
        expectEqual(s.manufactureDate?.displayString, "800192", "合成：生产日期编码")

        // Charger diagnostics
        expectEqual(s.charger?.notChargingReason, 0, "合成：未充电原因 0")

        // Health
        expectClose(s.healthPercent, 88.57, tolerance: 0.01, "合成：实测健康度（7752/8694 系本机值，此处用合成值）")

        // The raw browser must be able to see the nested keys.
        let flat = s.registryTree?.flattened() ?? []
        expect(flat.contains { $0.keyPath == "BatteryData.Temperature" && $0.nodeClass == "AppleSmartBatteryPack" },
               "合成：原始键浏览器可见 Pack.BatteryData.Temperature")
        expect(flat.contains { $0.keyPath == "BatteryData.DesignCapacity" && $0.value == "8694" },
               "合成：原始键浏览器可见设计容量")

        // A battery on DC power can never be charging: the sign must be normalised negative.
        var dcRoot = root
        dcRoot = RegistryNode(className: root.className,
                              properties: ["CurrentCapacity": 50, "ExternalConnected": 0, "IsCharging": 0],
                              children: [pack])
        let dc = BatteryReader.makeSnapshot(from: dcRoot)
        expect(dc.amperageAmps ?? 0 < 0, "合成：未接电源时电流符号被纠正为放电")
        expectClose(dc.chargePowerWatts, -18.4485, tolerance: 0.001, "合成：放电功率为负")
    }

    /// The hardware's own time estimates read `65535` ("unknown") on the dev machine, so the
    /// ETA the app shows comes from measuring the capacity slope. These cases pin down that
    /// maths, including the refusal to guess when the battery is effectively idle.
    private static func testTrendEstimator() {
        let now = Date()

        func ramp(from start: Double, to end: Double, seconds: Double, steps: Int,
                  charging: Bool, maxCapacity: Double? = nil) -> [BatterySample] {
            (0..<steps).map { step in
                let fraction = Double(step) / Double(steps - 1)
                return BatterySample(
                    timestamp: now.addingTimeInterval(-seconds + seconds * fraction),
                    chargePercent: 50,
                    currentCapacityMAh: start + (end - start) * fraction,
                    maxCapacityMAh: maxCapacity,
                    voltage: 12.0,
                    isCharging: charging,
                    externalConnected: charging
                )
            }
        }

        // Discharging 100 mAh over 300 s = -1200 mAh/h. From 5900 mAh that is 4.92 h = 295 min.
        let discharge = ramp(from: 6000, to: 5900, seconds: 300, steps: 60, charging: false)
        let dischargeEstimate = TrendEstimator.estimate(from: discharge, window: 300, now: now)
        expectClose(dischargeEstimate.capacityRateMAhPerHour, -1200, tolerance: 1, "趋势：放电速率")
        expectEqual(dischargeEstimate.minutesToEmpty, 295, "趋势：预计可用时间")
        expect(dischargeEstimate.minutesToFull == nil, "趋势：放电时不应给充满时间")
        expect(dischargeEstimate.isReliable, "趋势：放电估算应可信")
        expectClose(dischargeEstimate.impliedPowerWatts, -14.4, tolerance: 0.01, "趋势：推算功率")

        // Charging 100 mAh over 300 s = +1200 mAh/h. From 5100 to 7700 mAh = 2.17 h = 130 min.
        let charge = ramp(from: 5000, to: 5100, seconds: 300, steps: 60, charging: true, maxCapacity: 7700)
        let chargeEstimate = TrendEstimator.estimate(from: charge, window: 300, now: now)
        expectClose(chargeEstimate.capacityRateMAhPerHour, 1200, tolerance: 1, "趋势：充电速率")
        expectEqual(chargeEstimate.minutesToFull, 130, "趋势：预计充满时间")
        expect(chargeEstimate.minutesToEmpty == nil, "趋势：充电时不应给可用时间")

        // Too few samples must not produce a number.
        let sparse = TrendEstimator.estimate(from: Array(discharge.prefix(3)), window: 300, now: now)
        expect(!sparse.isReliable, "趋势：样本不足时不可信")
        expectEqual(sparse.minutesToEmpty, nil, "趋势：样本不足时无估算")

        // A flat battery must not project an infinite ETA.
        let flat = ramp(from: 6000, to: 6000, seconds: 300, steps: 60, charging: false)
        let flatEstimate = TrendEstimator.estimate(from: flat, window: 300, now: now)
        expect(!flatEstimate.isReliable, "趋势：电量不变时不可信")
        expect(flatEstimate.minutesToEmpty == nil, "趋势：电量不变时无估算")

        // Sub-threshold drift (below 40 mAh/h) is noise, not a trend.
        let drift = ramp(from: 6000, to: 6001, seconds: 300, steps: 60, charging: false)
        expect(!TrendEstimator.estimate(from: drift, window: 300, now: now).isReliable,
               "趋势：低于阈值的漂移不算趋势")

        expect(TrendEstimator.leastSquaresSlope([]) == nil, "趋势：空数组斜率")
        expect(TrendEstimator.leastSquaresSlope([(1, 1), (1, 5)]) == nil, "趋势：时间不变化时斜率为 nil")
    }

    private static func testHistoryDownsampling() {
        let now = Date()
        // A 1000-point ramp, bucketed down to 10 points: the endpoints' shape must survive.
        let raw: [(Date, Double)] = (0..<1000).map {
            (now.addingTimeInterval(Double($0)), Double($0))
        }
        let reduced = HistoryStore.downsample(raw, limit: 10)
        expectEqual(reduced.count, 10, "降采样：桶数量")
        expect(reduced.first!.value < 100, "降采样：首个桶取平均")
        expect(reduced.last!.value > 899, "降采样：末个桶取平均")
        expect(reduced[0].value < reduced[1].value, "降采样：保持单调形状")

        // Under the limit, every point is preserved.
        let small = HistoryStore.downsample(Array(raw.prefix(5)), limit: 10)
        expectEqual(small.count, 5, "降采样：少于上限时全部保留")

        let empty = HistoryStore.downsample([], limit: 10)
        expect(empty.isEmpty, "降采样：空输入")
    }

    /// Round-trips the history archive through a real file.
    ///
    /// This is the one code path with no other runtime coverage: the JSONL append, the
    /// ISO-8601 decoding and the retention filter all only run when the app starts a second
    /// time, so a bug here would silently leave the 30-day chart permanently empty.
    private static func testHistoryPersistence() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("batteryscope-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")

        let start = Date().addingTimeInterval(-3600)
        let store = HistoryStore(fileURL: url)
        // Two-minute spacing so every sample crosses the 60 s archive interval.
        for index in 0..<10 {
            store.append(BatterySample(timestamp: start.addingTimeInterval(Double(index) * 120),
                                       chargePercent: 80 - Double(index),
                                       currentCapacityMAh: 6000 - Double(index) * 10,
                                       maxCapacityMAh: 7700,
                                       voltage: 12.3,
                                       temperature: 34 + Double(index) * 0.1,
                                       healthPercent: 91.4))
        }
        expectEqual(store.live.count, 10, "历史：内存缓冲收到全部采样")
        expectEqual(store.archive.count, 10, "历史：每个采样都被归档")
        expectEqual(store.series(.chargePercent, from: .archive, limit: 600).count, 10,
                    "历史：归档可绘制为曲线")

        // Writes happen on a background queue, so wait for them to land.
        var wroteBytes = 0
        for _ in 0..<60 {
            wroteBytes = (try? Data(contentsOf: url))?.count ?? 0
            if wroteBytes > 0 { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        expect(wroteBytes > 0, "历史：归档已写入磁盘")

        let reloaded = HistoryStore(fileURL: url)
        expectEqual(reloaded.archive.count, 10, "历史：重新加载归档条目数")
        expectEqual(reloaded.archive.first?.chargePercent, 80, "历史：归档首条内容")
        expectEqual(reloaded.archive.last?.chargePercent, 71, "历史：归档末条内容")
        expect(reloaded.live.isEmpty, "历史：重新加载不会伪造实时缓冲")

        let reloadedSeries = reloaded.series(.healthPercent, from: .archive, limit: 700)
        expectEqual(reloadedSeries.count, 10, "历史：健康度历史曲线来自磁盘")
        expectClose(reloadedSeries.first?.value, 91.4, tolerance: 0.001, "历史：健康度数值往返一致")

        // A corrupt line must be skipped, not fatal.
        if var text = try? String(contentsOf: url, encoding: .utf8) {
            text += "{ this is not json }\n"
            text += "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let tolerant = HistoryStore(fileURL: url)
        expectEqual(tolerant.archive.count, 10, "历史：损坏行被跳过而不是中断加载")

        // Disabling persistence must stop disk writes.
        let disabledURL = directory.appendingPathComponent("disabled.jsonl")
        let disabled = HistoryStore(fileURL: disabledURL)
        disabled.isPersistenceEnabled = false
        disabled.append(BatterySample(timestamp: Date(), chargePercent: 50))
        Thread.sleep(forTimeInterval: 0.15)
        expect(!FileManager.default.fileExists(atPath: disabledURL.path),
               "历史：关闭持久化后不写磁盘")
        expectEqual(disabled.live.count, 1, "历史：关闭持久化仍保留内存缓冲")
    }

    /// Every plottable metric must read its own field, and the pickers must not contain two
    /// entries with the same label. A copy-paste slip here would silently plot the same series
    /// under two names, which is exactly the kind of bug that looks like "the chart is broken".
    private static func testSampleMetrics() {
        let sample = BatterySample(timestamp: Date(),
                                   chargePercent: 80,
                                   currentCapacityMAh: 6093,
                                   maxCapacityMAh: 7752,
                                   voltage: 12.29,
                                   amperage: -1.5,
                                   batteryPowerWatts: -12.5,
                                   systemLoadWatts: 24.8,
                                   adapterInputWatts: 25.1,
                                   temperature: 34.4,
                                   healthPercent: 89.2)

        expectClose(SampleMetric.chargePercent.value(from: sample), 80, tolerance: 0.001, "指标：电量")
        expectClose(SampleMetric.power.value(from: sample), -12.5, tolerance: 0.001, "指标：电池功率")
        expectClose(SampleMetric.systemLoad.value(from: sample), 24.8, tolerance: 0.001, "指标：整机功耗读 SystemLoad")
        expectClose(SampleMetric.adapterPower.value(from: sample), 25.1, tolerance: 0.001, "指标：适配器供电读适配器输入")
        expectClose(SampleMetric.temperature.value(from: sample), 34.4, tolerance: 0.001, "指标：温度")
        expectClose(SampleMetric.capacity.value(from: sample), 6093, tolerance: 0.001, "指标：容量")
        expectClose(SampleMetric.voltage.value(from: sample), 12.29, tolerance: 0.001, "指标：电压")
        expectClose(SampleMetric.healthPercent.value(from: sample), 89.2, tolerance: 0.001, "指标：健康度")

        // 整机功耗与适配器供电必须是两个不同的数据源
        expect(sample.systemLoadWatts != sample.adapterInputWatts, "测试数据：整机功耗与适配器供电应有区分度")

        let names = SampleMetric.allCases.map(\.displayName)
        expectEqual(Set(names).count, names.count, "指标显示名不重复（选择器会出现重名项）")
        expect(SampleMetric.allCases.allSatisfy { !$0.unit.isEmpty }, "指标单位非空")
        expect(SampleMetric.allCases.allSatisfy { $0.minimumSpan > 0 }, "指标最小量程为正")
        expectEqual(SampleMetric.allCases.filter(\.isSigned).map(\.displayName), ["电池功率"],
                    "只有电池功率是有符号量（其余功率不出现负值）")

        // 缺失字段必须返回 nil 而不是 0：0 W 与"没有数据"在图上含义完全不同
        let empty = BatterySample(timestamp: Date())
        expect(SampleMetric.systemLoad.value(from: empty) == nil, "指标：缺数据返回 nil")
        expect(SampleMetric.adapterPower.value(from: empty) == nil, "指标：缺适配器数据返回 nil")
        expect(SampleMetric.allCases.allSatisfy { $0.value(from: empty) == nil },
               "指标：空样本对所有指标都返回 nil")
    }

    /// The power-source option exists because the two independent battery-power measurements do
    /// disagree, and because the load-derived fallback is arithmetic rather than measurement.
    /// These cases pin down that "measured only" never adds or subtracts.
    private static func testPowerSourceModes() {
        // The real state observed on this machine while discharging: both registers read 0.
        var discharging = BatterySnapshot()
        discharging.voltageVolts = 12.246
        discharging.amperageAmps = 0
        discharging.externalConnected = false
        var telemetry = PowerTelemetry()
        telemetry.batteryPowerMW = 0
        telemetry.systemLoadMW = 36_313
        telemetry.systemPowerInMW = 36_313
        discharging.telemetry = telemetry

        expectClose(discharging.batteryPower(using: .automatic)?.watts, -36.313, tolerance: 0.001,
                    "自动：两个寄存器为 0 时回退到整机负载推算")
        expectEqual(discharging.batteryPower(using: .automatic)?.source.rawValue, "整机负载推算",
                    "自动：推算结果被标注出来")
        expect(discharging.batteryPower(using: .measuredOnly) == nil,
               "仅实测：寄存器为 0 时不凑数（这正是加这个选项的原因）")
        expect(discharging.batteryPower(using: .registers) == nil,
               "电压×电流：寄存器为 0 时同样没有值")

        // Both independent sources present and disagreeing slightly.
        var both = BatterySnapshot()
        both.voltageVolts = 12.837
        both.amperageAmps = 3.178
        both.externalConnected = true
        var telemetry2 = PowerTelemetry()
        telemetry2.batteryPowerMW = 40_757
        both.telemetry = telemetry2

        expectClose(both.batteryPower(using: .measuredOnly)?.watts, 40.757, tolerance: 0.001,
                    "仅实测：优先 PMU 遥测")
        expectEqual(both.batteryPower(using: .measuredOnly)?.source.rawValue, "PMU 遥测",
                    "仅实测：来源标注为遥测")
        expectClose(both.batteryPower(using: .registers)?.watts, 12.837 * 3.178, tolerance: 0.001,
                    "电压×电流：返回寄存器乘积本身")
        expectEqual(both.batteryPower(using: .registers)?.source.rawValue, "电压 × 电流",
                    "电压×电流：来源标注")

        let telemetryWatts = both.batteryPower(using: .measuredOnly)?.watts ?? 0
        let registerWatts = both.batteryPower(using: .registers)?.watts ?? 0
        expect(abs(telemetryWatts - registerWatts) > 0.01,
               "两个来源是独立测量，数值不应完全相同（差 \(telemetryWatts - registerWatts) W）")

        // 折线是否值得显示：既不充也不放时不应画一条恒为 0 的线
        expect(!BatterySnapshot().isBatteryActivelyMovingCharge, "折线显示判据：无数据时不显示")
        var idleOnAC = BatterySnapshot()
        idleOnAC.externalConnected = true
        idleOnAC.voltageVolts = 12.3
        idleOnAC.amperageAmps = 0
        expect(!idleOnAC.isBatteryActivelyMovingCharge, "折线显示判据：接电源未充电（0 W）不显示")
        var charging = BatterySnapshot()
        charging.externalConnected = true
        charging.voltageVolts = 12.837
        charging.amperageAmps = 3.178
        expect(charging.isBatteryActivelyMovingCharge, "折线显示判据：充电时显示")
        var onBattery = BatterySnapshot()
        onBattery.voltageVolts = 12.4
        onBattery.amperageAmps = -2.0
        expect(onBattery.isBatteryActivelyMovingCharge, "折线显示判据：放电时显示")
        var tiny = BatterySnapshot()
        tiny.voltageVolts = 12.4
        tiny.amperageAmps = 0.01
        expect(!tiny.isBatteryActivelyMovingCharge, "折线显示判据：小于阈值视为静止")

        // Data freshness comes from the driver's own republish timestamp.
        var aged = BatterySnapshot()
        aged.registryUpdateTime = Date().addingTimeInterval(-42)
        expectClose(aged.dataAge, 42, tolerance: 1.5, "数据新鲜度：由 UpdateTime 计算")
        expect(BatterySnapshot().dataAge == nil, "数据新鲜度：没有 UpdateTime 时为 nil")

        let names = BatterySnapshot.BatteryPowerSource.allCases.map(\.displayName)
        expectEqual(Set(names).count, names.count, "功率来源选项名称不重复")
    }

    /// The menu bar title and the bolt are pure functions, so they are pinned down here instead
    /// of only being eyeballed in the status bar.
    private static func testMenuBarPresentation() {
        // 紧凑时间：4h 30m 写法，小时与分钟分开，不再用小数小时
        expectEqual(MenuBarPresentation.compactTime(30), "30m", "菜单栏时间：30 分钟")
        expectEqual(MenuBarPresentation.compactTime(45), "45m", "菜单栏时间：45 分钟")
        expectEqual(MenuBarPresentation.compactTime(59), "59m", "菜单栏时间：59 分钟")
        expectEqual(MenuBarPresentation.compactTime(60), "1h", "菜单栏时间：整一小时省略分钟")
        expectEqual(MenuBarPresentation.compactTime(90), "1h 30m", "菜单栏时间：一小时半")
        expectEqual(MenuBarPresentation.compactTime(270), "4h 30m", "菜单栏时间：4h 30m 写法")
        expectEqual(MenuBarPresentation.compactTime(240), "4h", "菜单栏时间：整四小时")
        expectEqual(MenuBarPresentation.compactTime(120), "2h", "菜单栏时间：整两小时")
        expectEqual(MenuBarPresentation.compactTime(605), "10h 5m", "菜单栏时间：十小时零五分")
        expect(MenuBarPresentation.compactTime(nil) == nil, "菜单栏时间：无估算时为 nil")
        expect(MenuBarPresentation.compactTime(0) == nil, "菜单栏时间：0 视为无估算")
        expect(MenuBarPresentation.compactTime(-5) == nil, "菜单栏时间：负值视为无估算")
        expect(!MenuBarPresentation.compactTime(270)!.contains("."), "菜单栏时间：不再使用小数小时")
        expect(!MenuBarPresentation.compactTime(270)!.contains(":"), "菜单栏时间：不再使用 H:MM 写法")

        // 接电源时图标内只有居中闪电：既不带百分比，也不显示剩余时间
        let onAC = MenuBarPresentation.readings(externalConnected: true, showsPercent: true,
                                                showsTime: true, percent: 90,
                                                minutesRemaining: 270)
        expect(onAC.iconText == nil, "菜单栏：接电源时图标内不放百分比（只留闪电）")
        expect(onAC.trailingText == nil, "菜单栏：接电源时不显示剩余时间")

        // 用电池时：百分比在图标内，剩余时间在图标后，各由自己的开关控制
        let percentOnly = MenuBarPresentation.readings(externalConnected: false, showsPercent: true,
                                                       showsTime: false, percent: 90,
                                                       minutesRemaining: 270)
        expectEqual(percentOnly.iconText, "90%", "菜单栏：用电池且开百分比时，百分比在图标内")
        expect(percentOnly.trailingText == nil, "菜单栏：未开剩余时间时图标后为空")

        let timeOnly = MenuBarPresentation.readings(externalConnected: false, showsPercent: false,
                                                    showsTime: true, percent: 90,
                                                    minutesRemaining: 270)
        expect(timeOnly.iconText == nil, "菜单栏：只开剩余时间时图标内为空")
        expectEqual(timeOnly.trailingText, "4h 30m", "菜单栏：剩余时间显示在图标之后")

        let bothOn = MenuBarPresentation.readings(externalConnected: false, showsPercent: true,
                                                  showsTime: true, percent: 90,
                                                  minutesRemaining: 270)
        expectEqual(bothOn.iconText, "90%", "菜单栏：两个都开时百分比仍在图标内")
        expectEqual(bothOn.trailingText, "4h 30m", "菜单栏：两个都开时剩余时间在图标后")

        let noneOn = MenuBarPresentation.readings(externalConnected: false, showsPercent: false,
                                                  showsTime: false, percent: 90,
                                                  minutesRemaining: 270)
        expect(noneOn.iconText == nil && noneOn.trailingText == nil,
               "菜单栏：两个都关时图标内和图标后都不放文字")
        expectEqual(MenuBarPresentation.percentText(80), "80%", "菜单栏：百分比文字用于图标内部")
        expect(MenuBarPresentation.percentText(nil) == nil, "菜单栏：无电量时百分比为 nil")

        // 系统符号样式塞不进数字，此时百分比退回图标右侧
        // 图标像素回归：闪电必须是从填充里挖掉的洞
        //
        // 模板图像只认 alpha，所以"闪电可见吗"等价于"闪电是否减少了不透明面积"。修复前
        // 闪电是被涂成不透明白色画在同样不透明的填充上的，两者融为一体——接电源和用电池
        // 在单色模式下看起来完全一样。这个断言就是那次 bug 的回归测试。
        func opaqueReport(onAC: Bool, iconText: String?) -> (opaque: Int, fraction: Double,
                                                            size: NSSize, white: Int) {
            let image = MenuBarIconRenderer.image(percent: 97,
                                                  isCharging: onAC,
                                                  externalConnected: onAC,
                                                  iconText: iconText)
            let report = transparentPixelReport(image)
            return (report.opaque, report.fraction, image.size, report.white)
        }
        let batteryPlain = opaqueReport(onAC: false, iconText: nil)
        let acPlain = opaqueReport(onAC: true, iconText: nil)
        expect(batteryPlain.opaque > 0 && acPlain.opaque > 0, "图标：两种状态都渲染出内容")

        // 闪电是渲染器唯一画出的近白色形状，所以"有没有闪电"就看有没有白色像素。
        //
        // （早先闪电是从填充里挖洞的，那时判据是"不透明像素减少"；改成水平闪电画在电池内部
        //   之后它变成叠加，挖洞判据自然失效——断言必须跟着设计走。）
        expectEqual(batteryPlain.white, 0, "图标：用电池时不该有白色像素")
        expect(acPlain.white > 0, "图标：接电源时画出了闪电（\(acPlain.white) 个白色像素）")

        // 核心不变量：图标尺寸恒定。
        //
        // 状态栏项目宽度若随内容变化，插拔电源会让项目（以及它左边所有项目）位移，而已展开的
        // 弹窗仍然锚在旧矩形上——这正是"接电源时卡片不跟随"的原因。
        let batteryPercent = opaqueReport(onAC: false, iconText: "97%")
        let batteryFull = opaqueReport(onAC: false, iconText: "100%")
        let sizes = [batteryPlain.size, batteryPercent.size, batteryFull.size, acPlain.size]
        expect(sizes.allSatisfy { $0 == sizes[0] },
               "图标：无标识/百分比/满格/接电源 四种情况尺寸完全一致（\(Int(sizes[0].width))×\(Int(sizes[0].height))）")
        // 数字是从填充里挖出来的，所以不透明像素只会减少
        expect(batteryPercent.opaque <= batteryPlain.opaque,
               "图标：百分比是从填充里挖出来的洞，不会增加不透明像素")

        // 配色：接着外接电源即为绿色（不要求正在充电），低电量仍为琥珀/红，其余保持单色
        expect(MenuBarIconRenderer.accentColor(percent: 50, isCharging: false,
                                               externalConnected: true, lowBatteryThreshold: 20) != nil,
               "图标：接电源但未在充电时也是绿色")
        expect(MenuBarIconRenderer.accentColor(percent: 50, isCharging: true,
                                               externalConnected: true, lowBatteryThreshold: 20) != nil,
               "图标：正在充电时为绿色")
        expect(MenuBarIconRenderer.accentColor(percent: 50, isCharging: false,
                                               externalConnected: false, lowBatteryThreshold: 20) == nil,
               "图标：用电池且电量正常时无强调色（跟随菜单栏单色）")
        expect(MenuBarIconRenderer.accentColor(percent: 8, isCharging: false,
                                               externalConnected: true, lowBatteryThreshold: 20) != nil,
               "图标：低电量优先于接电源，仍有警示色")
        // 这一条很关键：模板图像只保留 alpha，颜色会被菜单栏自身的颜色覆盖——绿色会消失
        let chargingIcon = MenuBarIconRenderer.image(percent: 50, isCharging: true,
                                                     externalConnected: true, iconText: nil)
        expect(!chargingIcon.isTemplate, "图标：接电源时的图标不是模板图像（否则绿色会被覆盖掉）")
        let onBatteryIcon = MenuBarIconRenderer.image(percent: 50, isCharging: false,
                                                      externalConnected: false, iconText: nil)
        expect(onBatteryIcon.isTemplate, "图标：用电池时仍是模板图像，自动适配浅色/深色")

        // 闪电跟随充电器，而不是跟随“正在充电”
        expect(MenuBarIconState.showsBolt(externalConnected: true, isCharging: true),
               "闪电：边充边用要显示")
        expect(MenuBarIconState.showsBolt(externalConnected: true, isCharging: false),
               "闪电：已接电源但未充电（例如已充满）也要显示")
        expect(!MenuBarIconState.showsBolt(externalConnected: false, isCharging: false),
               "闪电：使用电池时不显示")
    }

    /// The PMU HID path is the one genuinely fast data source on Apple Silicon, and it is what
    /// the card's "实时传感器（秒级）" group is built on. It is also the correction to an earlier
    /// wrong conclusion of mine, so it is pinned down by tests rather than assumed.
    /// The SMC is the app's live power source, and pinning it down matters because an earlier
    /// version of this project wrongly concluded the SMC was unusable on Apple Silicon. That was a
    /// bug in the probe: `kSMCGetKeyInfo` must precede `kSMCReadKey`, and the float data type is
    /// the four characters `"flt "` with a trailing space.
    private static func testSMCPowerKeys() {
        guard let client = SMCClient() else {
            print("ℹ️  此机器无法打开 AppleSMC，跳过 SMC 检查。")
            return
        }
        expect(client.isOpen, "SMC：用户客户端已打开")

        // 四个字符的数据类型必须按四字符比较，否则会静默丢掉所有浮点键
        if let info = client.keyInfo(for: "TB0T") {
            expectEqual(info.dataType, "flt", "SMC：TB0T 类型为 flt（已去掉尾随空格）")
            expectEqual(Int(info.dataSize), 4, "SMC：TB0T 为 4 字节")
        }
        // 解码器本身
        expectClose(SMCClient.decode([0x98, 0x99, 0x0B, 0x42], type: "flt"), 34.9, tolerance: 0.05,
                    "SMC：flt 解码（TB0T 实测字节 → 34.9 °C）")
        // 有符号 8.8 定点：小端字节 40 00 → 0x0040 = 64 → 64/256 = 0.25
        expectClose(SMCClient.decode([0x40, 0x00], type: "sp78"), 0.25, tolerance: 0.001,
                    "SMC：sp78 定点解码")
        expectClose(SMCClient.decode([0xC0, 0xFF], type: "sp78"), -0.25, tolerance: 0.001,
                    "SMC：sp78 负值解码")
        expectClose(SMCClient.decode([0x10, 0x27], type: "si16"), 10000, tolerance: 0.001,
                    "SMC：si16 解码")
        expect(SMCClient.decode([0x00], type: "unknown") == nil, "SMC：未知类型返回 nil 而不是瞎猜")

        guard let reader = SMCPowerReader(client: client) else {
            print("ℹ️  此机器没有 SMC 功率键，跳过刷新率检查。")
            return
        }
        expect(!reader.availableKeys.isEmpty, "SMC：可用功率键 = \(reader.availableKeys.joined(separator: " "))")

        let reading = reader.read()
        expect(!reading.isEmpty, "SMC：至少读到一个功率键")
        if let watts = reading.systemWatts {
            expect(watts > 0 && watts < 300, "SMC：系统功率在合理区间（\(String(format: "%.2f", watts)) W）")
        }
        if let watts = reading.adapterWatts {
            // 未接电源时 PDTR 合法地为 0，所以下界是 0 而不是正数
            expect(watts >= 0 && watts < 400, "SMC：适配器功率在合理区间（\(String(format: "%.2f", watts)) W）")
        }
        if let watts = reading.batteryWatts {
            expect(abs(watts) < 200, "SMC：电池功率在合理区间（\(String(format: "%.2f", watts)) W）")
        }
        if let celsius = reading.batteryTemperatureCelsius {
            expect(celsius > 0 && celsius < 80, "SMC：电池温度在合理区间（\(String(format: "%.1f", celsius)) °C）")
        }

        // 核心断言：SMC 是秒级源。3 秒内功率读数必须有变化。
        // 用三个功率键的并集判断，因为完全空闲时某一个键可能暂时恒定。
        var seen = Set<String>()
        for _ in 0..<7 {
            let sample = reader.read()
            for (key, value) in [("PSTR", sample.systemWatts), ("PDTR", sample.adapterWatts),
                                 ("PPBR", sample.batteryWatts)] {
                if let value { seen.insert("\(key)=\(Int((value * 1000).rounded()))") }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        expect(seen.count > 3, "SMC：约 1 Hz 刷新（3 秒内功率读数出现 \(seen.count) 种取值）")
        _ = client.allKeyNames()   // 枚举不应崩溃
    }

    /// 电源状态必须以 IOPS 为准，而不是电池节点。
    ///
    /// `ExternalConnected` / `IsCharging` 住在 AppleSmartBattery 节点里，驱动每 30–60 秒才整体
    /// 重新发布一次——所以信任它们会让菜单栏的闪电在拔线后最多多留一分钟。IOPS 由 powerd 在电源
    /// 变化的当下更新，而我们的 IOPS 通知也在那一刻触发，所以这里 IOPS 必须覆盖寄存器。
    private static func testPowerSourcePrecedence() {
        // 刚拔掉电源：寄存器还停留在旧值
        var stale = BatterySnapshot()
        stale.externalConnected = true
        stale.isCharging = true
        var unplugged = PowerSourceReading()
        unplugged.powerSourceState = "Battery Power"
        unplugged.isCharging = false
        BatteryReader.apply(unplugged, to: &stale)
        expect(!stale.externalConnected, "IOPS：拔线后立即覆盖寄存器里滞后的 ExternalConnected")
        expect(!stale.isCharging, "IOPS：拔线后立即清除滞后的 IsCharging")

        // 刚插上电源：寄存器同样还没更新
        var stale2 = BatterySnapshot()
        stale2.externalConnected = false
        stale2.isCharging = false
        var plugged = PowerSourceReading()
        plugged.powerSourceState = "AC Power"
        plugged.isCharging = true
        BatteryReader.apply(plugged, to: &stale2)
        expect(stale2.externalConnected, "IOPS：插电后立即生效")
        expect(stale2.isCharging, "IOPS：插电后立即报告正在充电")

        // IOPS 什么都没说时，寄存器仍然是兜底
        var registryOnly = BatterySnapshot()
        registryOnly.externalConnected = true
        BatteryReader.apply(PowerSourceReading(), to: &registryOnly)
        expect(registryOnly.externalConnected, "IOPS：没有电源状态时保留寄存器值")

        // 顺序回归：apply() 必须在寄存器赋值之后运行。
        //
        // 之前它被放在 makeSnapshot() 之前，于是 IOPS 的覆盖立刻被寄存器里滞后的值回写掉——
        // 拔电源要等 30–60 秒才反映出来。单看"某一刻快照与 IOPS 是否一致"是抓不到的（那一刻
        // 寄存器恰好是新的就会通过），所以这里直接验证合并顺序。
        //
        // 用的是合成快照而不是实机：早先这里读实时 IORegistry 并断言"寄存器报告已接电源"，
        // 那是把一次观察当成了不变量——拔掉电源自检就会失败（并因此挡住打包）。
        var registry = BatterySnapshot()
        registry.externalConnected = true          // 寄存器说"接着电源"（滞后值）
        var unplugged2 = PowerSourceReading()
        unplugged2.powerSourceState = "Battery Power"
        unplugged2.isCharging = false
        // 模拟真实顺序：makeSnapshot 先写寄存器，apply 后合并 IOPS
        BatteryReader.apply(unplugged2, to: &registry)
        expect(!registry.externalConnected,
               "顺序：合并 IOPS 之后，滞后的寄存器值不能覆盖它（拔电源应立即生效）")

        // 反向：IOPS 说接着电源时也要覆盖寄存器的否定值
        var registryOff = BatterySnapshot()
        registryOff.externalConnected = false
        var pluggedForOrder = PowerSourceReading()
        pluggedForOrder.powerSourceState = "AC Power"
        pluggedForOrder.isCharging = false
        BatteryReader.apply(pluggedForOrder, to: &registryOff)
        expect(registryOff.externalConnected, "顺序：IOPS 说接电源时同样覆盖寄存器（插电立即生效）")
    }

    private static func testDieTemperatures() {
        guard let reader = SMCThermalReader() else {
            print("ℹ️  此机器没有可用的 SMC 温度键，跳过 CPU/GPU 温度检查。")
            return
        }
        // 分组依据是负载实验：Tp/Te 跟 CPU 走，Tg 跟 GPU 走（详见 SMCThermalReader 注释）
        expect(reader.cpuKeyCount >= 3, "温度：CPU 键数量充足（\(reader.cpuKeyCount) 个 Tp/Te）")
        expect(reader.gpuKeyCount >= 2, "温度：GPU 键数量充足（\(reader.gpuKeyCount) 个 Tg）")

        let first = reader.read()
        if let cpu = first.cpuCelsius {
            expect(cpu > 10 && cpu < 120, "温度：CPU 合理（\(first.cpuChannel ?? "?") = \(String(format: "%.1f", cpu)) °C）")
        } else {
            expect(false, "温度：读不到 CPU 温度")
        }
        if let gpu = first.gpuCelsius {
            expect(gpu > 10 && gpu < 120, "温度：GPU 合理（\(first.gpuChannel ?? "?") = \(String(format: "%.1f", gpu)) °C）")
        } else {
            expect(false, "温度：读不到 GPU 温度")
        }
        // 两个读数必须来自不同的键，否则说明分组没生效
        expect(first.cpuChannel != first.gpuChannel, "温度：CPU 与 GPU 取自不同传感器")
        if let channel = first.cpuChannel {
            // 热点优先，核心最大值回退——两者都合法，但不能是别的组。
            expect(channel == SMCThermalReader.hotspotKey
                    || channel.hasPrefix("Tp") || channel.hasPrefix("Te"),
                   "温度：CPU 取自 TCMz 或 Tp/Te 组（\(channel)）")
        }
        if let channel = first.gpuChannel {
            expect(channel.hasPrefix("Tg"), "温度：GPU 取自 Tg 组（\(channel)）")
        }

        // 挂到快照上之后必须可用
        var snapshot = BatterySnapshot()
        snapshot.thermal = first
        expect(snapshot.cpuTemperatureCelsius != nil, "温度：快照可给出 CPU 温度")
        expect(snapshot.gpuTemperatureCelsius != nil, "温度：快照可给出 GPU 温度")
    }

    private static func testLiveHardware() {
        guard let snapshot = BatteryReader.read() else {
            print("ℹ️  未检测到电池，跳过实机检查。")
            return
        }
        let ageText = snapshot.dataAge.map { String(format: "%.0f 秒", $0) } ?? "未知"
        print("ℹ️  实机读数：电量 \(UnitFormat.percent(snapshot.chargePercent))，"
              + "设计容量 \(UnitFormat.milliampHours(snapshot.designCapacityMAh))，"
              + "温度 \(UnitFormat.celsius(snapshot.temperatureCelsius))，"
              + "数据年龄 \(ageText)")
        print("ℹ️  注意：AppleSmartBattery 由驱动每隔约 30–60 秒整体重新发布一次，"
              + "因此这些数值不是逐秒变化的。")

        expect(snapshot.designCapacityMAh != nil, "实机：设计容量可读")
        expect(snapshot.maxCapacityMAh != nil, "实机：最大容量可读")
        expect(snapshot.currentCapacityMAh != nil, "实机：当前容量可读")
        expect(snapshot.voltageVolts != nil, "实机：电压可读")
        expect(snapshot.cycleCount != nil, "实机：循环次数可读")
        expect(snapshot.manufacturerData?.vendorCode != nil, "实机：电芯厂商可读")
        expect(snapshot.registryTree != nil, "实机：注册表树已捕获")
        expect((snapshot.registryTree?.flattened().count ?? 0) > 40, "实机：注册表键数量充足")
        expect(snapshot.registryUpdateTime != nil, "实机：可读到驱动的发布时间戳 UpdateTime")

        // 驱动推送路径：注册 kIOGeneralInterest，让变化发生的瞬间就能被读到，而不是等下一次轮询
        let registryWatcher = BatteryRegistryWatcher { }
        expect(registryWatcher.start(), "驱动推送：kIOGeneralInterest 注册成功")
        expect(registryWatcher.isWatching, "驱动推送：处于监听状态")
        registryWatcher.stop()
        expect(!registryWatcher.isWatching, "驱动推送：可以正常停止")
        if let age = snapshot.dataAge {
            expect(age >= -5 && age < 600, "实机：数据年龄落在合理区间（\(Int(age)) 秒）")
        }

        if let design = snapshot.designCapacityMAh {
            expect(design > 1000 && design < 200_000, "实机：设计容量数值合理 (\(design) mAh)")
        }
        if let health = snapshot.healthPercent {
            expect(health > 20 && health <= 110, "实机：健康度数值合理 (\(health)%)")
        }
        if let percent = snapshot.chargePercent {
            expect(percent >= 0 && percent <= 100, "实机：电量百分比合理 (\(percent))")
        }
        if let temperature = snapshot.temperatureCelsius {
            expect(temperature > -20 && temperature < 90, "实机：温度数值合理 (\(temperature)°C)")
        }
        // Regression guard for the nested-lookup bug this whole reader exists to avoid.
        if snapshot.registryTree?.child(className: "AppleSmartBatteryPack") != nil {
            expect(snapshot.temperatureCelsius != nil, "实机：Apple Silicon 上温度必须从 Pack.BatteryData 解析出来")
            expect(snapshot.maxCapacityMAh != 7700 || snapshot.designCapacityMAh != nil, "实机：容量键解析一致")
        }
    }
}

private extension Data {
    init?(hexString: String) {
        let clean = hexString.filter { $0.isHexDigit }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
