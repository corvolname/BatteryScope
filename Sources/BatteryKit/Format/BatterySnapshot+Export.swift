import Foundation

public struct ReportRow {
    public let label: String
    public let value: String
    public let note: String?

    public init(_ label: String, _ value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }
}

public struct ReportSection {
    public let title: String
    public let rows: [ReportRow]

    public init(_ title: String, _ rows: [ReportRow]) {
        self.title = title
        self.rows = rows
    }
}

extension BatterySnapshot {

    /// The section list the detail window draws, as a **fixed schema**.
    ///
    /// Distinct from `reportSections()`, which is the linear text report and keeps everything.
    ///
    /// The window's cards have a hard requirement the report does not: two cards sit side by side,
    /// their titles must be level and their rows must line up, so **the row list cannot depend on the
    /// machine's state**. Deriving the cards from the report made it depend on it — unplugging the
    /// charger removed the charger rows, and a shorter card in the same row leaves its neighbour's
    /// rows stranded mid-air. So each card's labels are listed here, a value is looked up for each,
    /// and anything unavailable renders as `—` rather than vanishing.
    ///
    /// That also settles the duplicate readings, which the report tolerates but a dashboard must not:
    ///
    /// * 标称功率 / 协商功率上限 / 输入功率上限（PMU 协商）all print the same number for an
    ///   adapter already at its top contract. Only 标称功率 is kept; the negotiated voltage and
    ///   current remain, from which the negotiated wattage is visible.
    /// * 整机负载 and 实际输入功率 (`SystemLoad` / `SystemPowerIn`) are the same reading whenever the
    ///   battery is contributing nothing. Only 整机负载 is kept, and it is the one that still has a
    ///   meaning on battery.
    /// * 电池序列号 is kept only in 标识 and 电量计芯片 only here in 总览, so each appears once.
    ///
    /// Other deliberate differences from the report: 概览 and 提示 are drawn by the window itself;
    /// **容量 is dropped** (the header ring, the health ring and the 真实容量 / 设计容量 caption
    /// already show it); notes are dropped, because they were register paths
    /// (`PowerTelemetryData.SystemPowerIn`) or unit restatements (`28000 mV · 4990 mA`); and
    /// USB-PD 档位 is summarised on one line, since listing every contract wraps to two lines and
    /// one two-line row shifts everything below it.
    public func detailSections() -> [ReportSection] {
        // Values come from the report so its formatting is reused rather than duplicated.
        var values: [String: String] = [:]
        for section in reportSections() {
            for row in section.rows where values[row.label] == nil { values[row.label] = row.value }
        }

        // One line of wattages per contract, e.g. "15 / 27 / 45 / 100 W".
        let contractWatts = (adapter?.contracts ?? [])
            .compactMap(\.watts)
            .map { String(format: "%.0f", $0) }
        if !contractWatts.isEmpty {
            values["USB-PD 档位"] = contractWatts.joined(separator: " / ") + " W"
        }
        // Only ever a note on the 充电器 row in the report; the window gives it a row of its own.
        if let maker = adapter?.manufacturer { values["充电器厂商"] = maker }

        // On battery there is no DC input, and the registers answer those two with 0 rather than
        // nothing: "0.00 V / 0 mA" and "0.00 W" read as measurements of something that does not
        // exist. Dropping the value makes the schema fill in `—`, which is what it means.
        if externalConnected != true {
            values["输入电压 / 电流"] = nil
            values["适配器转换损耗"] = nil
        }

        // Exactly three rows, whatever the pack reports: the count is part of the layout, so a pack
        // with fewer banks shows `—` rather than shortening the card and unbalancing the row.
        let bankRows = (0..<3).map { index -> ReportRow in
            let label = "电芯组 \(index)"
            let value = reportSections()
                .first { $0.title == "电芯组" }?
                .rows.first { $0.label == label }?
                .value
            return ReportRow(label, value ?? "—")
        }

        let cards: [(title: String, labels: [String])] = [
            ("电气与功耗", ["电池电压", "电池电流", "电池功率", "整机负载", "输入电压 / 电流"]),
            ("充电器与供电", ["充电器", "充电器厂商", "标称功率", "当前协商电压 / 电流", "USB-PD 档位",
                            "适配器转换损耗", "充电器序列号", "充电器固件"]),
            ("寿命统计（电芯记录）", ["累计运行时间", "历史平均温度", "历史温度区间", "历史电压区间",
                              "历史最大充电电流", "历史最大放电电流", "温度采样次数"]),
            ("标识", ["电池序列号", "电芯厂商", "批次码", "固件版本", "硬件版本", "电芯版本", "生产日期"]),
        ]

        return cards.map { card in
            let rows = card.labels.map { ReportRow($0, values[$0] ?? "—") }
            return ReportSection(card.title, card.title == "电气与功耗" ? rows + bankRows : rows)
        }
    }

    /// The single source of truth for "what do we show", shared by the CLI, the popover
    /// card, the detail window and the "copy report" action.
    public func reportSections() -> [ReportSection] {
        var sections: [ReportSection] = []

        // MARK: Overview
        var overview: [ReportRow] = [
            ReportRow("电量", UnitFormat.percent(chargePercent)),
            ReportRow("供电状态", powerSourceDescription),
        ]
        if let health = healthPercent {
            overview.append(ReportRow("健康度", UnitFormat.percent(health, fractionDigits: 1)))
        }
        overview.append(ReportRow("电池状况", condition.displayName))
        overview.append(ReportRow("循环次数",
                                  cycleCount.map { "\($0) 次" } ?? "—",
                                  note: designCycleCount.map { "设计上限 \($0) 次" }))
        if let usage = cycleUsagePercent {
            overview.append(ReportRow("循环次数占用", UnitFormat.percent(usage, fractionDigits: 1)))
        }
        overview.append(ReportRow("电池温度", UnitFormat.celsius(temperatureCelsius)))
        // While charging the interesting estimate is time-to-full; otherwise time-to-empty.
        // The origin of the number is labelled because the system estimate and the gauge's
        // own estimate can disagree substantially.
        if isCharging, let full = systemTimeToFullMinutes ?? gaugeTimeToFullMinutes {
            overview.append(ReportRow("预计充满时间", UnitFormat.minutes(full),
                                      note: systemTimeToFullMinutes != nil ? "系统估算" : "电量计估算"))
        } else if let remaining = systemTimeToEmptyMinutes ?? gaugeTimeToEmptyMinutes {
            overview.append(ReportRow("预计可用时间", UnitFormat.minutes(remaining),
                                      note: systemTimeToEmptyMinutes != nil ? "系统估算" : "电量计估算"))
        }
        sections.append(ReportSection("概览", overview))

        // MARK: Capacity
        var capacity: [ReportRow] = [
            ReportRow("设计容量", UnitFormat.milliampHours(designCapacityMAh)),
            ReportRow("当前最大容量（实测满充）",
                      UnitFormat.capacityDual(maxCapacityMAh, reference: designCapacityMAh),
                      note: "AppleRawMaxCapacity / FullChargeCapacity"),
            ReportRow("标称满充容量（电量计模型值，非实测）",
                      UnitFormat.capacityDual(nominalCapacityMAh, reference: designCapacityMAh),
                      note: "NominalChargeCapacity"),
            ReportRow("当前剩余容量",
                      UnitFormat.capacityDual(currentCapacityMAh, reference: maxCapacityMAh),
                      note: "AppleRawCurrentCapacity / RemainingCapacity"),
        ]
        if let fade = capacityFadeMAh {
            capacity.append(ReportRow("相对设计容量的衰减", "\(UnitFormat.grouped(fade)) mAh"))
        }
        if let absolute = absoluteCapacityMAh, absolute > 0 {
            capacity.append(ReportRow("绝对容量", UnitFormat.milliampHours(absolute)))
        }
        sections.append(ReportSection("容量", capacity))

        // MARK: Electrical
        var electrical: [ReportRow] = [
            ReportRow("电池电压", UnitFormat.volts(voltageVolts, fractionDigits: 3)),
            ReportRow("电池电流", UnitFormat.signedAmps(amperageAmps),
                      note: amperageAmps.map { $0 > 0 ? "流入电池（充电）" : ($0 < 0 ? "流出电池（放电）" : "无电流") }),
            ReportRow("电池功率", UnitFormat.signedWatts(effectiveBatteryPowerWatts),
                      note: effectiveBatteryPower.map { powerNote(for: $0) }),
        ]
        // The second source is only worth a row when it actually disagrees. With `automatic`
        // preferring the PMU reading the two are usually identical, and printing the same number
        // twice reads like a bug.
        if let telemetryPower = telemetryBatteryPowerWatts,
           let shown = effectiveBatteryPowerWatts,
           abs(telemetryPower - shown) > 0.05 {
            electrical.append(ReportRow("电池功率（PMU 遥测）", UnitFormat.signedWatts(telemetryPower),
                                        note: "PowerTelemetryData.BatteryPower"))
        }
        if isBatteryPowerDerived {
            electrical.append(ReportRow("说明", "电量计的电流寄存器读数为 0，电池功率由整机负载推算",
                                        note: "Apple Silicon 上放电时 Amperage / InstantAmperage / BatteryPower 可能均为 0"))
        }
        if let virtual = virtualTemperatureCelsius, virtual != temperatureCelsius {
            electrical.append(ReportRow("虚拟温度", UnitFormat.celsius(virtual)))
        }
        sections.append(ReportSection("电气", electrical))

        // MARK: Charger
        if externalConnected || adapter != nil {
            var chargerRows: [ReportRow] = []
            if let adapter {
                chargerRows.append(ReportRow("充电器", adapter.displayName ?? "—",
                                             note: [adapter.manufacturer, adapter.model].compactMap { $0 }.joined(separator: " · ")))
                chargerRows.append(ReportRow("标称功率", UnitFormat.watts(adapter.effectiveRatedWatts, fractionDigits: 0)))
                if let v = adapter.negotiatedVoltageVolts, let a = adapter.negotiatedCurrentAmps {
                    chargerRows.append(ReportRow("当前协商电压 / 电流",
                                                 "\(UnitFormat.volts(v)) / \(UnitFormat.amps(a))",
                                                 note: "\(UnitFormat.millivolts(v)) · \(String(format: "%.0f mA", a * 1000))"))
                }
                chargerRows.append(ReportRow("协商功率上限", UnitFormat.watts(adapter.negotiatedWatts)))
                if let menuMax = adapter.maxMenuWatts, let negotiated = adapter.negotiatedWatts, menuMax > negotiated + 0.5 {
                    chargerRows.append(ReportRow("协议可提供的最大功率", UnitFormat.watts(menuMax)))
                }
                if !adapter.contracts.isEmpty {
                    let menu = adapter.contracts.map { contract in
                        let v = contract.maxVoltageVolts.map { String(format: "%.0fV", $0) } ?? "?"
                        let a = contract.maxCurrentAmps.map { String(format: "%.2fA", $0) } ?? "?"
                        let w = contract.watts.map { String(format: "%.0fW", $0) } ?? "?"
                        return "\(v)×\(a)=\(w)"
                    }.joined(separator: "  ")
                    chargerRows.append(ReportRow("USB-PD 档位（HVC 菜单）", menu))
                }
                if let serial = adapter.serial {
                    chargerRows.append(ReportRow("充电器序列号", serial))
                }
                if let firmware = adapter.firmwareVersion {
                    chargerRows.append(ReportRow("充电器固件", firmware))
                }
                if adapter.isWireless == true {
                    chargerRows.append(ReportRow("无线充电", "是"))
                }
            }
            if let inputWatts = adapterInputWatts {
                chargerRows.append(ReportRow("实际输入功率", UnitFormat.watts(inputWatts),
                                             note: "PowerTelemetryData.SystemPowerIn"))
            }
            if let distribution = powerDistribution {
                if let inputWatts = distribution.inputWatts {
                    chargerRows.append(ReportRow("输入功率上限（PMU 协商）", UnitFormat.watts(inputWatts),
                                                 note: "PowerDistribution.IPDInputPower，等于当前 PD 协商上限"))
                }
                if let allowed = distribution.chargingAllowed {
                    chargerRows.append(ReportRow("PMU 允许充电", allowed ? "是" : "否"))
                }
            }
            if let charger {
                if let target = charger.targetChargePowerWatts, target > 0 {
                    chargerRows.append(ReportRow("充电目标电压 / 电流",
                                                 "\(UnitFormat.volts(charger.chargingVoltageVolts)) / \(UnitFormat.amps(charger.chargingCurrentAmps))",
                                                 note: "AppleChargerData"))
                }
                if let vbus = charger.vbusVolts, vbus > 0 {
                    chargerRows.append(ReportRow("充电器 VBUS / IBUS",
                                                 "\(UnitFormat.volts(vbus)) / \(UnitFormat.amps(charger.ibusAmps))"))
                }
                if let power = charger.chargerPowerWatts, power > 0 {
                    chargerRows.append(ReportRow("充电器功率寄存器", UnitFormat.watts(power)))
                }
                if let reason = charger.notChargingReason, reason != 0 {
                    chargerRows.append(ReportRow("未充电原因",
                                                 ChargingDiagnostics.hex(reason) ?? "—",
                                                 note: ChargingDiagnostics.notChargingReasonLabel(reason)))
                }
                if let temperature = charger.timeChargingThermallyLimitedSeconds, temperature > 0 {
                    chargerRows.append(ReportRow("累计限温时长", UnitFormat.duration(Double(temperature))))
                }
            }
            sections.append(ReportSection("充电器与供电", chargerRows))
        }

        // MARK: System
        if let load = systemLoadWatts {
            sections.append(ReportSection("系统功耗", [
                ReportRow("整机负载", UnitFormat.watts(load), note: "PowerTelemetryData.SystemLoad"),
                ReportRow("输入电压 / 电流",
                          "\(UnitFormat.volts(telemetry?.systemVoltageInMV.map { Double($0) / 1000 })) / \(UnitFormat.amps(telemetry?.systemCurrentInMA.map { Double($0) / 1000 }))"),
                ReportRow("适配器转换损耗", UnitFormat.watts(telemetry?.efficiencyLossWatts)),
            ]))
        }

        // MARK: Cells
        if !banks.isEmpty {
            let rows = banks.map { bank -> ReportRow in
                let cells = bank.cellCurrentAmps.map { String(format: "%.2fA", $0) }.joined(separator: " / ")
                var value = UnitFormat.volts(bank.cellVoltageVolts, fractionDigits: 3)
                if let qmax = bank.qmaxMAh { value += " · Qmax \(qmax) mAh" }
                if let ra = bank.weightedRa { value += String(format: " · Ra %.0f", ra) }
                if !cells.isEmpty { value += " · 电芯电流 \(cells)" }
                return ReportRow("电芯组 \(bank.bankID ?? 0)", value)
            }
            sections.append(ReportSection("电芯组", rows))
        }

        // MARK: Lifetime
        if let lifetime {
            var rows: [ReportRow] = []
            if let total = lifetime.totalOperatingHours {
                rows.append(ReportRow("累计运行时间", String(format: "%.1f 小时", total)))
            }
            if let average = lifetime.averageTemperatureCelsius {
                rows.append(ReportRow("历史平均温度", UnitFormat.celsius(average)))
            }
            if let min = lifetime.minimumTemperatureCelsius, let max = lifetime.maximumTemperatureCelsius {
                rows.append(ReportRow("历史温度区间",
                                      "\(UnitFormat.celsius(min, fractionDigits: 1)) ~ \(UnitFormat.celsius(max, fractionDigits: 1))"))
            }
            if let min = lifetime.minimumPackVoltageVolts, let max = lifetime.maximumPackVoltageVolts {
                rows.append(ReportRow("历史电压区间", "\(UnitFormat.volts(min)) ~ \(UnitFormat.volts(max))"))
            }
            if let charge = lifetime.maximumChargeCurrentAmps {
                rows.append(ReportRow("历史最大充电电流", UnitFormat.amps(charge)))
            }
            if let discharge = lifetime.maximumDischargeCurrentAmps {
                rows.append(ReportRow("历史最大放电电流", UnitFormat.amps(discharge)))
            }
            if let samples = lifetime.temperatureSampleCount {
                rows.append(ReportRow("温度采样次数", UnitFormat.grouped(samples)))
            }
            sections.append(ReportSection("寿命统计（电芯记录）", rows))
        }

        // MARK: Identity
        var identity: [ReportRow] = [
            ReportRow("电池序列号", serial ?? "—"),
            ReportRow("电量计芯片", deviceName ?? "—"),
        ]
        if let manufacturer = manufacturerData {
            identity.append(ReportRow("电芯厂商", manufacturer.vendorName ?? "—",
                                      note: manufacturer.vendorCode))
            if !manufacturer.lotCodes.isEmpty {
                identity.append(ReportRow("批次码", manufacturer.lotCodes.joined(separator: " / ")))
            }
            if let firmware = manufacturer.firmwareVersion {
                identity.append(ReportRow("固件版本", firmware))
            }
            if let hardware = manufacturer.hardwareRevision {
                identity.append(ReportRow("硬件版本", hardware))
            }
            if let cell = manufacturer.cellRevision {
                identity.append(ReportRow("电芯版本", cell))
            }
        }
        identity.append(ReportRow("生产日期",
                                 manufactureDate?.displayString ?? "—",
                                 note: manufactureDate?.isRealDate == true ? nil : "固件未提供标准日期，此处为原始编码"))
        sections.append(ReportSection("标识", identity))

        // MARK: Advisories
        if !advisories.isEmpty {
            sections.append(ReportSection("提示", advisories.map { ReportRow("•", $0) }))
        }

        return sections
    }

    /// Explains where a battery power figure came from, so a derived number is never presented
    /// as if it were a direct measurement.
    private func powerNote(for measurement: PowerMeasurement) -> String {
        let direction: String
        switch measurement.watts {
        case 0.05...: direction = "流入电池（充电）"
        case ..<(-0.05): direction = "流出电池（放电）"
        default: direction = "无电流"
        }
        switch measurement.source {
        case .telemetry: return "\(direction) · PMU 遥测"
        case .amperage: return "\(direction) · 电压 × 电流"
        case .systemLoad: return "\(direction) · 由整机负载推算"
        case .unavailable: return direction
        }
    }

    public func textReport(includeTimestamp: Bool = true) -> String {
        var lines: [String] = ["BatteryScope 电池报告"]
        if includeTimestamp {
            lines.append("采集时间: \(UnitFormat.dateTime(timestamp))")
        }
        for section in reportSections() {
            lines.append("")
            lines.append("── \(section.title) ──")
            for row in section.rows {
                var line = "\(row.label): \(row.value)"
                if let note = row.note, !note.isEmpty { line += "   (\(note))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    public func jsonObject() -> [String: Any] {
        var root: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "chargePercent": chargePercent as Any,
            "isCharging": isCharging,
            "fullyCharged": fullyCharged,
            "externalConnected": externalConnected,
            "isPresent": isPresent,
            "condition": condition.rawValue,
        ]
        func put(_ key: String, _ value: Any?) { if let value { root[key] = value } }

        put("stateOfChargePercent", stateOfChargePercent)
        put("designCapacityMAh", designCapacityMAh)
        put("maxCapacityMAh", maxCapacityMAh)
        put("nominalCapacityMAh", nominalCapacityMAh)
        put("currentCapacityMAh", currentCapacityMAh)
        put("voltageVolts", voltageVolts)
        put("amperageAmps", amperageAmps)
        put("chargePowerWatts", chargePowerWatts)
        put("temperatureCelsius", temperatureCelsius)
        put("cycleCount", cycleCount)
        put("designCycleCount", designCycleCount)
        put("healthPercentNominal", nominalCapacityMAh.flatMap { nominal in designCapacityMAh.map { Double(nominal) / Double($0) * 100 } })
        put("healthPercentRawMaximum", healthPercent)
        put("healthFormulaUsed", "measured")
        put("serial", serial)
        put("deviceName", deviceName)
        put("manufactureDateRaw", manufactureDate?.displayString)
        put("systemTimeToEmptyMinutes", systemTimeToEmptyMinutes)
        put("systemTimeToFullMinutes", systemTimeToFullMinutes)

        if let manufacturerData {
            var m: [String: Any] = [:]
            m["vendorCode"] = manufacturerData.vendorCode
            m["vendorName"] = manufacturerData.vendorName
            m["lotCodes"] = manufacturerData.lotCodes
            m["firmwareVersion"] = manufacturerData.firmwareVersion
            m["hardwareRevision"] = manufacturerData.hardwareRevision
            m["cellRevision"] = manufacturerData.cellRevision
            root["manufacturer"] = m
        }
        if let adapter {
            var a: [String: Any] = [:]
            a["name"] = adapter.displayName
            a["reportedName"] = adapter.name
            a["manufacturer"] = adapter.manufacturer
            a["model"] = adapter.model
            a["serial"] = adapter.serial
            a["firmwareVersion"] = adapter.firmwareVersion
            a["ratedWatts"] = adapter.effectiveRatedWatts
            a["negotiatedVoltageVolts"] = adapter.negotiatedVoltageVolts
            a["negotiatedCurrentAmps"] = adapter.negotiatedCurrentAmps
            a["negotiatedWatts"] = adapter.negotiatedWatts
            a["maxMenuWatts"] = adapter.maxMenuWatts
            a["isWireless"] = adapter.isWireless
            a["contracts"] = adapter.contracts.map { contract -> [String: Any] in
                ["index": contract.index as Any,
                 "maxVoltageVolts": contract.maxVoltageVolts as Any,
                 "maxCurrentAmps": contract.maxCurrentAmps as Any,
                 "watts": contract.watts as Any]
            }
            root["adapter"] = a
        }
        if let telemetry {
            root["telemetry"] = [
                "systemPowerInMW": telemetry.systemPowerInMW as Any,
                "systemLoadMW": telemetry.systemLoadMW as Any,
                "systemVoltageInMV": telemetry.systemVoltageInMV as Any,
                "systemCurrentInMA": telemetry.systemCurrentInMA as Any,
                "batteryPowerMW": telemetry.batteryPowerMW as Any,
                "adapterEfficiencyLossMW": telemetry.adapterEfficiencyLossMW as Any,
            ]
        }
        if let charger {
            root["charger"] = [
                "chargerID": charger.chargerID as Any,
                "chargingVoltageVolts": charger.chargingVoltageVolts as Any,
                "chargingCurrentAmps": charger.chargingCurrentAmps as Any,
                "chargerPowerWatts": charger.chargerPowerWatts as Any,
                "notChargingReason": ChargingDiagnostics.hex(charger.notChargingReason) as Any,
                "slowChargingReason": charger.slowChargingReason as Any,
            ]
        }
        if !banks.isEmpty {
            root["banks"] = banks.map { bank -> [String: Any] in
                ["bankID": bank.bankID as Any,
                 "cellVoltageVolts": bank.cellVoltageVolts as Any,
                 "qmaxMAh": bank.qmaxMAh as Any,
                 "weightedRa": bank.weightedRa as Any,
                 "cellCurrentAmps": bank.cellCurrentAmps]
            }
        }
        if let lifetime {
            root["lifetime"] = [
                "totalOperatingTimeMinutes": lifetime.totalOperatingTimeMinutes as Any,
                "averageTemperatureCelsius": lifetime.averageTemperatureCelsius as Any,
                "minimumTemperatureCelsius": lifetime.minimumTemperatureCelsius as Any,
                "maximumTemperatureCelsius": lifetime.maximumTemperatureCelsius as Any,
                "maximumChargeCurrentAmps": lifetime.maximumChargeCurrentAmps as Any,
                "maximumDischargeCurrentAmps": lifetime.maximumDischargeCurrentAmps as Any,
            ]
        }
        return root
    }

    public func jsonString(pretty: Bool = true) -> String {
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject(), options: options),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
