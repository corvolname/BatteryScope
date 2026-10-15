import Foundation
import AppKit
import BatteryKit

// MARK: - Argument handling

let arguments = Array(CommandLine.arguments.dropFirst())

func flagValue(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? arguments[next] : nil
}

func hasFlag(_ name: String) -> Bool { arguments.contains(name) }

func printUsage() {
    print("""
    batteryscope-cli — 读取并展示 macOS 电池 / 充电器的全部可获取参数

    用法:
      batteryscope-cli [summary]              人类可读的完整报告（默认）
      batteryscope-cli json [--compact]       输出 JSON
      batteryscope-cli raw [--filter REGEX]   平铺列出全部 IOKit 注册表键值
      batteryscope-cli raw --dump-tree        以缩进树形列出注册表
      batteryscope-cli watch [--interval 2]   持续刷新报告
      batteryscope-cli keys                   仅列出键名（等价于 grep 友好输出）
      batteryscope-cli selftest               对解析与计算逻辑做自检
      batteryscope-cli export-icon --out DIR  生成应用图标 iconset（打包脚本使用）

    选项:
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("错误: " + message + "\n").utf8))
    exit(1)
}

func requireSnapshot() -> BatterySnapshot {
    guard let snapshot = BatteryReader.read() else {
        fail("未能从 IOKit 读取到 AppleSmartBattery。此设备可能没有内置电池（例如 Mac mini / Mac Studio）。")
    }
    return snapshot
}

func printReport(_ snapshot: BatterySnapshot) {
    print(snapshot.textReport())
}

// MARK: - Commands

let command = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "summary"

switch command {

case "summary", "report", "s":
    printReport(requireSnapshot())

case "json":
    let snapshot = requireSnapshot()
    print(snapshot.jsonString(pretty: !hasFlag("--compact")))

case "keys":
    let snapshot = requireSnapshot()
    let entries = snapshot.registryTree?.flattened() ?? []
    for entry in entries { print(entry.pathString) }

case "raw":
    let snapshot = requireSnapshot()
    guard let tree = snapshot.registryTree else { fail("无注册表数据") }

    if hasFlag("--dump-tree") {
        func dump(_ node: RegistryNode, indent: Int) {
            let pad = String(repeating: "  ", count: indent)
            print("\(pad)\(node.className)  [\(node.properties.count) 个键]")
            for key in node.properties.keys.sorted() {
                print("\(pad)  \(key) = \(ValueCoercion.display(node.properties[key]))")
            }
            for child in node.children { dump(child, indent: indent + 1) }
        }
        dump(tree, indent: 0)
        break
    }

    var entries = tree.flattened()
    if let pattern = flagValue("--filter") {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            fail("无效的正则表达式: \(pattern)")
        }
        entries = entries.filter { entry in
            let range = NSRange(entry.pathString.startIndex..., in: entry.pathString)
            return regex.firstMatch(in: entry.pathString, range: range) != nil
        }
    }
    guard !entries.isEmpty else {
        print("（没有匹配的键）")
        break
    }
    let widest = entries.map(\.pathString.count).max() ?? 0
    for entry in entries {
        // Only pad; never truncate, or the leaf key name (the part you actually want) is lost.
        let path = entry.pathString.count >= widest
            ? entry.pathString
            : entry.pathString.padding(toLength: widest, withPad: " ", startingAt: 0)
        print("\(path)  \(entry.value)   [\(entry.typeName)]")
    }
    print("\n共 \(entries.count) 个键（已展开嵌套字典，因此比 `ioreg | grep` 能看到更多）")

case "watch":
    let interval = Double(flagValue("--interval") ?? "2") ?? 2
    let frames = Int(flagValue("--frames") ?? "0") ?? 0
    var iteration = 0
    while true {
        let snapshot = BatteryReader.read()
        print("\u{1B}[2J\u{1B}[H", terminator: "")
        if let snapshot {
            printReport(snapshot)
        } else {
            print("未检测到电池。")
        }
        iteration += 1
        if frames > 0 && iteration >= frames { break }
        Thread.sleep(forTimeInterval: max(0.25, interval))
    }

case "fields":
    // Dumps every parsed field plus the raw IOPS reading. This is the tool to reach for when
    // a displayed number looks wrong: it shows exactly which field carries which value.
    let snapshot = requireSnapshot()
    print("── 解析后的 BatterySnapshot 字段 ──")
    for child in Mirror(reflecting: snapshot).children {
        guard let label = child.label, label != "registryTree" else { continue }
        print("\(label) = \(child.value)")
    }
    print("\n── 系统信息 ──")
    let profile = SystemInfoReader.read()
    print("modelIdentifier = \(profile.modelIdentifier)")
    print("modelMarketingName = \(profile.modelMarketingName)")
    print("chipName = \(profile.chipName)")
    print("memory = \(profile.memoryDescription)")
    print("osVersion = \(profile.osVersion)")
    print("osBuild = \(profile.osBuild)")

    print("\n── IOPS 电源信息 ──")
    if let powerSource = PowerSourceReader.read() {
        for child in Mirror(reflecting: powerSource).children {
            guard let label = child.label else { continue }
            print("\(label) = \(child.value)")
        }
    } else {
        print("(无)")
    }

case "power":
    // Prints every candidate power source side by side, once per interval. This exists because
    // the PMU telemetry counters and the gauge registers disagree, and only a live comparison
    // shows which one actually tracks the adapter.
    let interval = Double(flagValue("--interval") ?? "1") ?? 1
    let sampleCount = Int(flagValue("--samples") ?? "20") ?? 20
    let header = ["时刻", "Pin", "Vin*Iin", "Load", "Bpmu", "V*A", "IPDin", "充电", "适配器标称", "Wall", "损耗", "VBUS*IBUS"]
    var widths = header.map { $0.count }
    func fmt(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "—" }
    func fmtInt(_ v: Int?) -> String { v.map { String(format: "%.2f", Double($0) / 1000) } ?? "—" }

    func row(_ s: BatterySnapshot) -> [String] {
        let inputFromVI = (s.telemetry?.systemVoltageInMV != nil && s.telemetry?.systemCurrentInMA != nil)
            ? Double(s.telemetry!.systemVoltageInMV!) * Double(s.telemetry!.systemCurrentInMA!) / 1_000_000
            : nil
        let vbusIbus = (s.charger?.vbusVolts != nil && s.charger?.ibusAmps != nil)
            ? s.charger!.vbusVolts! * s.charger!.ibusAmps!
            : nil
        return [
            UnitFormat.timeOnly(s.timestamp),
            fmt(s.telemetry?.actualInputWatts),
            fmt(inputFromVI),
            fmt(s.telemetry?.systemLoadWatts),
            fmt(s.telemetry?.batteryPowerWatts),
            fmt(s.chargePowerWatts),
            fmt(s.powerDistribution?.inputWatts),
            s.isCharging ? "是" : "否",
            fmt(s.adapter?.ratedWatts),
            fmtInt(s.telemetry?.wallEnergyEstimateMW),
            fmt(s.telemetry?.efficiencyLossWatts),
            fmt(vbusIbus),
        ]
    }

    print("（单位：W，除“充电”列。Pin=SystemPowerIn，Vin*Iin=输入电压×电流，Load=SystemLoad，")
    print("  Bpmu=PowerTelemetryData.BatteryPower，V*A=电池电压×电流，IPDin=PowerDistribution.IPDInputPower，")
    print("  Wall=WallEnergyEstimate，损耗=AdapterEfficiencyLoss，VBUS*IBUS=AppleChargerData）")
    print("")
    for index in 0..<sampleCount {
        guard let snapshot = BatteryReader.read() else { fail("未能读取电池") }
        let cells = row(snapshot)
        for (i, cell) in cells.enumerated() { widths[i] = max(widths[i], cell.count) }
        if index == 0 {
            print(zip(header, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  "))
            print(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        }
        print(zip(cells, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }.joined(separator: "  "))
        if index < sampleCount - 1 { Thread.sleep(forTimeInterval: max(0.2, interval)) }
    }

case "pmu":
    // Lists the HID PMU sensor channels. Unlike everything in the AppleSmartBattery node these
    // update continuously, which is why the app can show a live temperature.
    guard let reader = PMUHIDReader() else {
        fail("此机器上无法使用 PMU HID 传感器路径")
    }
    let interval = Double(flagValue("--interval") ?? "1") ?? 1
    let sampleCount = Int(flagValue("--samples") ?? "3") ?? 3
    print("PMU 通道数 = \(reader.channelCount)")

    func readings(_ t: PMUTelemetry) -> [String] {
        t.temperatures.keys.sorted().map { "\($0)=\(String(format: "%.2f", t.temperatures[$0]!))" }
    }
    var previous: [String]?
    var first: [String]?
    for index in 0..<sampleCount {
        let telemetry = reader.read()
        let lines = readings(telemetry)
        if first == nil { first = lines }
        print("\n── 第 \(index + 1) 次读取：\(telemetry.temperatures.count) 个温度通道，\(telemetry.rails.count) 个电压/电流通道")
        if let hottest = telemetry.hottest {
            print(String(format: "   最高：%@ = %.2f °C", hottest.channel, hottest.celsius))
        }
        if let previous {
            print("   与上次相比，变化的温度通道 = \(zip(previous, lines).filter { $0 != $1 }.count) / \(lines.count)")
        }
        if index == 0 {
            for line in lines {
                let isCalibration = PMUTelemetry.calibrationChannels.contains(String(line.split(separator: "=").first ?? ""))
                print("     " + line + (isCalibration ? "   ← 标定参考值，不计入「最高」" : ""))
            }
        } else if let previous {
            let changed = zip(previous, lines).filter { $0 != $1 }.map(\.1)
            if !changed.isEmpty { print("   本次变化：" + changed.joined(separator: "  ")) }
        }
        previous = lines
        if index < sampleCount - 1 { Thread.sleep(forTimeInterval: max(0.2, interval)) }
    }
    if let first, let previous {
        print("\n结论：\(sampleCount) 次读取之间，\(zip(first, previous).filter { $0 != $1 }.count) / \(first.count) 个温度通道发生变化。")
    }

case "smc":
    // Inspects the SMC power keys directly. These refresh about once per second and report real
    // watts, which is why they are the app's primary power source.
    guard let client = SMCClient() else { fail("无法打开 AppleSMC 用户客户端") }
    print("AppleSMC 已打开；可枚举键数 = \(client.allKeyNames().count)")

    let candidates = ["PSTR", "PDTR", "PPBR", "TB0T", "F0Ac", "PCPR", "PATC", "PB0C",
                      "BCLM", "CH0B", "CH0C", "B0AC", "B0AV", "B0FC"]
    print("\n键信息：")
    for name in candidates {
        if let info = client.keyInfo(for: name) {
            let value = client.readDouble(name).map { String(format: "%.3f", $0) } ?? "不可解码"
            print("  \(name)  存在  dataSize=\(info.dataSize) type=\(info.dataType)  值=\(value)")
        } else {
            print("  \(name)  不存在（kSMCKeyNotFound = \(SMCClient.keyNotFound)）")
        }
    }

    guard let reader = SMCPowerReader(client: client) else {
        fail("此机器没有可用的 SMC 功率键")
    }
    print("\n可用功率键：\(reader.availableKeys.joined(separator: " "))")

    let samples = Int(flagValue("--samples") ?? "12") ?? 12
    let interval = Double(flagValue("--interval") ?? "0.5") ?? 0.5
    var history: [String: [Double]] = [:]
    for _ in 0..<samples {
        let reading = reader.read()
        func record(_ key: String, _ value: Double?) { if let value { history[key, default: []].append(value) } }
        record("PSTR", reading.systemWatts)
        record("PDTR", reading.adapterWatts)
        record("PPBR", reading.batteryWatts)
        record("TB0T", reading.batteryTemperatureCelsius)
        record("F0Ac", reading.fanRPM)
        Thread.sleep(forTimeInterval: interval)
    }
    let window = Double(samples) * interval
    print(String(format: "\n刷新率（%.1f 秒内采样 %d 次）：", window, samples))
    for key in ["PSTR", "PDTR", "PPBR", "TB0T", "F0Ac"] {
        let values = history[key] ?? []
        guard !values.isEmpty else { continue }
        let distinct = Set(values.map { ($0 * 1000).rounded() }).count
        print(String(format: "  %@: %d 个不同值  范围 %.2f…%.2f  末值 %.2f",
                     key, distinct, values.min()!, values.max()!, values.last!))
    }

case "menu-icon":
    // Renders the menu-bar glyph in each power state so the difference between "on battery" and
    // "plugged in" can be inspected without a charger, and so the percentage-inside layout can be
    // checked at real size.
    let directory = flagValue("--out") ?? "/tmp/batteryscope-menu-icons"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let states: [(String, Double, Bool, Bool, String?)] = [
        ("电池-无标识", 97, false, false, nil),
        ("电池-百分比", 97, false, false, "97%"),
        ("电池-满格", 97, false, false, "100%"),
        ("电池-低电量（琥珀）", 15, false, false, "15%"),
        ("电池-严重不足（红）", 8, false, false, "8%"),
        ("接电源-绿色闪电", 97, true, true, nil),
        ("接电源-绿色（未充电也是绿色）", 97, false, true, nil),
        ("接电源-低电量（红）", 8, true, true, nil),
    ]
    for (name, percent, charging, onAC, iconText) in states {
        let image = MenuBarIconRenderer.image(percent: percent,
                                              isCharging: charging,
                                              externalConnected: onAC,
                                              iconText: iconText)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { continue }
        let path = "\(directory)/\(name).png"
        try? png.write(to: URL(fileURLWithPath: path))
        let alpha = transparentPixelReport(image)
        print("  \(name): 不透明像素 \(alpha.opaque)/\(alpha.total)  右上角留白 \(alpha.gapAtRight)")
        // Also write a preview composited the way the menu bar shows it: a template image is
        // filled with the bar's own label colour over the bar background.
        if let preview = previewOnMenuBar(image) {
            try? preview.write(to: URL(fileURLWithPath: "\(directory)/\(name)-预览.png"))
        }
    }
    print("已输出到 \(directory)")

case "export-icon":
    // Renders the .iconset the packaging script feeds to `iconutil`. Doing it here (rather
    // than shipping PNGs) keeps the icon resolution-independent and the repo blob-free.
    let outPath = flagValue("--out") ?? "AppIcon.iconset"
    let directory = URL(fileURLWithPath: outPath)
    do {
        let count = try AppIconRenderer.writeIconset(to: directory)
        print("已生成 \(count) 个 PNG 到 \(directory.path)")
    } catch {
        fail("生成图标失败: \(error.localizedDescription)")
    }

case "selftest":
    exit(SelfTest.run() ? 0 : 1)

case "help", "-h", "--help":
    printUsage()

default:
    printUsage()
    exit(1)
}


/// Alpha statistics for a rendered menu-bar glyph. A template image is masked by its alpha
/// channel, so "is the bolt visible" reduces to "does the bolt reduce the opaque area".
func transparentPixelReport(_ image: NSImage) -> (opaque: Int, total: Int, gapAtRight: Int,
                                                  fraction: Double, white: Int) {
    let width = Int(image.size.width)
    let height = Int(image.size.height)
    guard width > 0, height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: width * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return (0, 0, 0, 0, 0) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.bitmapData else { return (0, 0, 0, 0, 0) }
    var opaque = 0
    var gapAtRight = 0
    var white = 0
    for y in 0..<height {
        for x in 0..<width {
            let base = y * rep.bytesPerRow + x * 4
            let alpha = data[base + 3]
            guard alpha > 128 else { continue }
            opaque += 1
            // At 97 % the fill stops just short of the right wall.
            if x >= width - 4 { gapAtRight += 1 }
            // The bolt is the only near-white thing this renderer draws.
            if data[base] > 200, data[base + 1] > 200, data[base + 2] > 200 { white += 1 }
        }
    }
    let total = width * height
    return (opaque, total, gapAtRight, total > 0 ? Double(opaque) / Double(total) : 0, white)
}

/// Composites a template glyph the way the menu bar does — filled with the label colour over the
/// bar background — so the rendered result can be judged rather than imagined.
func previewOnMenuBar(_ image: NSImage) -> Data? {
    let scale: CGFloat = 8
    let padding: CGFloat = 5
    let glyph = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    let width = Int(glyph.width + padding * 2 * scale)
    let height = Int(glyph.height + padding * 2 * scale)
    guard width > 0, height > 0 else { return nil }

    // A template image is masked to the bar's label colour, so it is tinted on a transparent layer
    // first (doing it on top of an already-painted background would just fill the whole rect). An
    // image that carries its own colour — the green charging icon — is drawn untouched.
    let tinted = NSImage(size: glyph, flipped: false) { rect in
        image.draw(in: rect)
        if image.isTemplate {
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
        }
        return true
    }

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: width * 4, bitsPerPixel: 32),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(calibratedRed: 0.32, green: 0.30, blue: 0.36, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
    tinted.draw(in: NSRect(x: padding * scale, y: padding * scale, width: glyph.width, height: glyph.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}
