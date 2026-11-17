import AppKit
import Carbon.HIToolbox

extension SelfTest {
    static func runHistoryChecks() {
        print("== Battery history")
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "macmate-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let history = BatteryHistory(fileURL: file)
        let start = Date().addingTimeInterval(-6 * 3600)
        var info = BatteryInfo()
        info.hasBattery = true
        info.percent = 90
        info.systemLoadW = 8

        // Six hours on battery, one percent every 4 minutes, then a 2-hour gap, then charging.
        for i in 0..<90 {
            info.percent = 90 - i
            history.record(info, at: start.addingTimeInterval(Double(i) * 240))
        }
        history.record(info, at: start.addingTimeInterval(89 * 240 + 60))   // same level, 1 min later: skipped
        check("unchanged readings are skipped", history.samples.count == 90, "\(history.samples.count) samples")
        info.isPluggedIn = true
        info.isCharging = true
        for i in 0..<10 {
            info.percent = 1 + i * 5
            history.record(info, at: start.addingTimeInterval(90 * 240 + 7200 + Double(i) * 300))
        }
        let now = start.addingTimeInterval(90 * 240 + 7200 + 3000)
        let points = history.points(for: .day, now: now)
        check("chart breaks at gaps", Set(points.map(\.run)) == [0, 1], "runs \(Set(points.map(\.run)).sorted())")
        let drain = history.drain(for: .day, now: now)
        check("drain counts only time on battery", drain.percent == 89 && abs(drain.hours - 89 * 240 / 3600.0) < 0.01,
              "\(drain.percent)% over \(String(format: "%.2f", drain.hours)) h")
        check("week view thins points", history.points(for: .week, now: now).count < points.count)

        let hourA = start.addingTimeInterval(600), hourB = start.addingTimeInterval(4200)
        history.addEnergy([EnergySlice(key: "/Applications/Safari.app", name: "Safari", bundlePath: "/Applications/Safari.app", joules: 900),
                           EnergySlice(key: "proc:helper", name: "helper", bundlePath: nil, joules: 40)], at: hourA)
        history.addEnergy([EnergySlice(key: "/Applications/Safari.app", name: "Safari", bundlePath: "/Applications/Safari.app", joules: 300)], at: hourA)
        history.addEnergy([EnergySlice(key: "/Applications/Mail.app", name: "Mail", bundlePath: "/Applications/Mail.app", joules: 2000)], at: hourB)
        let top = history.topApps(for: .day, now: now)
        check("energy grouped by hour", history.hours.count == 2, "\(history.hours.count) hours")
        check("top apps ranked by energy", top.map(\.name) == ["Mail", "Safari", "helper"] && top[1].joules == 1200,
              top.map { "\($0.name) \(Int($0.joules)) J" }.joined(separator: ", "))

        history.save()
        let reloaded = BatteryHistory(fileURL: file)
        reloaded.load()
        check("history survives a relaunch", reloaded.samples == history.samples && reloaded.hours == history.hours
              && reloaded.apps["/Applications/Mail.app"]?.name == "Mail")

        print("== Energy alerts")
        let alerts = EnergyAlerts()
        func app(_ watts: Double) -> AppUsage {
            AppUsage(id: "hot", name: "Hot App", bundlePath: nil, pids: [1], watts: watts, cpuPercent: 99, memBytes: 0, sessionJoules: 0, isApp: true)
        }
        let t0 = Date()
        let limit: (String) -> Double = { _ in 3 }
        var fired = alerts.evaluate([app(5)], now: t0, onBattery: true, enabled: true, threshold: limit)
        check("no alert for a short spike", fired.isEmpty)
        fired = alerts.evaluate([app(5)], now: t0.addingTimeInterval(130), onBattery: true, enabled: true, threshold: limit)
        check("alert after sustained high power", fired.map(\.name) == ["Hot App"])
        fired = alerts.evaluate([app(5)], now: t0.addingTimeInterval(400), onBattery: true, enabled: true, threshold: limit)
        check("one alert per hour", fired.isEmpty)
        _ = alerts.evaluate([app(1)], now: t0.addingTimeInterval(500), onBattery: true, enabled: true, threshold: limit)
        fired = alerts.evaluate([app(5)], now: t0.addingTimeInterval(4000), onBattery: false, enabled: true, threshold: limit)
        check("no alerts while plugged in", fired.isEmpty)

        print("== Device batteries")
        let sample = """
        {"SPBluetoothDataType":[{"controller_properties":{},"device_connected":[
          {"Jamie’s AirPods Pro":{"device_minorType":"Headphones","device_batteryLevelLeft":"82%","device_batteryLevelRight":"79%","device_batteryLevelCase":"100%"}},
          {"MX Master 3S":{"device_minorType":"Mouse","device_batteryLevelMain":"64%"}},
          {"Speaker":{"device_minorType":"Speaker"}}],
          "device_not_connected":[{"Old Keyboard":{"device_minorType":"Keyboard","device_batteryLevelMain":"5%"}}]}]}
        """
        let parsed = DeviceBatteries.parseBluetooth(Data(sample.utf8))
        check("bluetooth batteries parsed", parsed.count == 2, parsed.map(\.name).joined(separator: ", "))
        if let pods = parsed.first(where: { $0.kind == .headphones }) {
            check("AirPods buds and case", pods.left == 82 && pods.right == 79 && pods.caseLevel == 100 && pods.lowest == 79, pods.levelText)
        }
        let merged = DeviceBatteries.merge(parsed, [DeviceBattery(name: "mx master 3s", kind: .other, main: 64)],
                                           [DeviceBattery(name: "Magic Keyboard", kind: .keyboard, main: 15)])
        check("devices merged by name", merged.count == 3 && merged.first?.kind == .headphones, merged.map(\.name).joined(separator: ", "))
        if !ci {
            let live = DeviceBatteries.merge(DeviceBatteries.readRegistry(), DeviceBatteries.readBluetooth())
            check("live device read", true, "\(live.count) connected device(s) with a battery")
        }

        print("== Shortcuts")
        let combo = KeyCombo(keyCode: kVK_LeftArrow, modifiers: UInt32(controlKey | optionKey))
        check("shortcut display", combo.displayString == "⌃⌥←", combo.displayString)
        check("shortcut storage round trip", KeyCombo(storage: combo.storage) == combo)
        let ids = Shortcuts.all.map(\.id)
        check("shortcut ids unique", Set(ids).count == ids.count)
        let defaults = Shortcuts.all.compactMap(\.defaultCombo)
        check("default shortcuts don't collide", Set(defaults).count == defaults.count)
        check("conflicts detected", ShortcutStore.shared.conflict(for: combo, excluding: Shortcuts.clipboard.id)?.id == "tile.leftHalf")
        if !ci {
            check("letter keys named from the keyboard layout", KeyCombo.keyName(kVK_ANSI_V).count == 1, KeyCombo.keyName(kVK_ANSI_V))
        }
    }
}
