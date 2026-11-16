import Foundation
import IOKit
import IOKit.ps

struct BatteryInfo: Equatable {
    var hasBattery = false
    var percent = 0
    var isCharging = false
    var isPluggedIn = false
    var isFull = false
    /// Minutes to empty while discharging, minutes to full while charging.
    var minutesRemaining: Int?
    var voltage = 0.0
    /// Amps, negative while discharging.
    var amperage = 0.0
    /// What the whole machine is drawing right now, in watts.
    var systemLoadW = 0.0
    var adapterW: Int?
    var adapterName: String?
    var cycleCount = 0
    var designMah = 0
    var maxMah = 0
    var currentMah = 0
    var temperatureC: Double?

    var healthPercent: Int {
        designMah > 0 ? min(100, Int((Double(maxMah) / Double(designMah) * 100).rounded())) : 0
    }

    /// Nominal pack voltage, derived from the cell count (3.82 V per Li-ion cell).
    var nominalVoltage: Double {
        let cells = max(1, (voltage / 3.95).rounded())
        return voltage > 0 ? cells * 3.82 : 11.46
    }

    var fullWh: Double { Double(maxMah) / 1000 * nominalVoltage }
    var remainingWh: Double { Double(currentMah) / 1000 * nominalVoltage }
    var batteryPowerW: Double { voltage * amperage }
    var onBattery: Bool { hasBattery && !isPluggedIn }

    var statusText: String {
        if !hasBattery { return "No battery" }
        if isFull && isPluggedIn { return "Fully charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }
}

final class BatteryService: ObservableObject {
    static let shared = BatteryService()

    @Published private(set) var info = BatteryInfo()
    /// Called on the main thread with (old, new) whenever a reading changes.
    var onChange: ((BatteryInfo, BatteryInfo) -> Void)?

    private var timer: Timer?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 1
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryService>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    func refresh() {
        let new = BatteryService.read()
        let old = info
        if new != old {
            info = new
            onChange?(old, new)
        }
    }

    static func read() -> BatteryInfo {
        var b = BatteryInfo()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return b }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return b }
        let data = dict["BatteryData"] as? [String: Any] ?? [:]

        func num(_ key: String) -> Int64? {
            if let n = dict[key] as? NSNumber { return n.int64Value }
            if let n = data[key] as? NSNumber { return n.int64Value }
            return nil
        }
        func flag(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }

        b.hasBattery = flag("BatteryInstalled") || num("CurrentCapacity") != nil
        b.isCharging = flag("IsCharging")
        b.isPluggedIn = flag("ExternalConnected")
        b.isFull = flag("FullyCharged")
        b.voltage = Double(num("Voltage") ?? 0) / 1000
        b.amperage = Double(num("InstantAmperage") ?? num("Amperage") ?? 0) / 1000
        b.cycleCount = Int(num("CycleCount") ?? 0)
        b.designMah = Int(num("DesignCapacity") ?? 0)
        b.maxMah = Int(num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity") ?? 0)
        b.currentMah = Int(num("AppleRawCurrentCapacity") ?? 0)

        // "CurrentCapacity"/"MaxCapacity" at the top level are the user-facing percentage on Apple silicon.
        let cur = Double(num("CurrentCapacity") ?? 0), mx = Double(num("MaxCapacity") ?? 100)
        b.percent = mx > 0 ? Int((cur / mx * 100).rounded()) : 0
        if b.maxMah == 0, mx > 200 { b.maxMah = Int(mx); b.currentMah = Int(cur) }

        if let t = num("Temperature") ?? num("VirtualTemperature"), t > 0 {
            b.temperatureC = Double(t) / 100
        }

        let key = b.isCharging ? "AvgTimeToFull" : "AvgTimeToEmpty"
        if let m = num(key) ?? num("TimeRemaining"), m > 0, m < 6000, b.isCharging || !b.isPluggedIn {
            b.minutesRemaining = Int(m)
        }

        if let tel = dict["PowerTelemetryData"] as? [String: Any],
           let load = (tel["SystemLoad"] as? NSNumber)?.int64Value, load > 0 {
            b.systemLoadW = Double(load) / 1000
        } else if !b.isPluggedIn {
            b.systemLoadW = abs(b.voltage * b.amperage)
        }

        if let ad = dict["AdapterDetails"] as? [String: Any] {
            if let w = (ad["Watts"] as? NSNumber)?.intValue, w > 0 { b.adapterW = w }
            b.adapterName = ad["Name"] as? String
        }
        return b
    }
}
