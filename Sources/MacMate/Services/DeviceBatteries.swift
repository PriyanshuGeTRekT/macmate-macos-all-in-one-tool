import AppKit
import Combine
import IOKit

/// The battery of a connected accessory: AirPods and other headphones, mice, keyboards, trackpads.
struct DeviceBattery: Identifiable, Equatable {
    enum Kind: Int, Comparable {
        case headphones, keyboard, mouse, trackpad, gamepad, other
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String { name.lowercased() }
    var name: String
    var kind: Kind
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    /// The level that matters most for a warning.
    var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    var levelText: String {
        if left != nil || right != nil || caseLevel != nil {
            var parts: [String] = []
            if let left { parts.append("L \(left)%") }
            if let right { parts.append("R \(right)%") }
            if let caseLevel { parts.append("Case \(caseLevel)%") }
            if parts.isEmpty, let main { parts.append("\(main)%") }
            return parts.joined(separator: "  ")
        }
        return main.map { "\($0)%" } ?? "—"
    }

    var symbol: String {
        let n = name.lowercased()
        let wanted: String
        switch kind {
        case .headphones:
            wanted = n.contains("airpods max") ? "airpods.max" : n.contains("airpods pro") ? "airpods.pro"
                : n.contains("airpods") ? "airpods" : "headphones"
        case .mouse: wanted = n.contains("magic mouse") ? "magicmouse" : "computermouse"
        case .keyboard: wanted = "keyboard"
        case .trackpad: wanted = "rectangle.and.hand.point.up.left"
        case .gamepad: wanted = "gamecontroller"
        case .other: wanted = "dot.radiowaves.left.and.right"
        }
        // Older symbol names differ between releases; fall back to something that always exists.
        return NSImage(systemSymbolName: wanted, accessibilityDescription: nil) != nil ? wanted : "battery.75percent"
    }
}

/// Reads accessory batteries while the panel is open (about 0.15 s of work, once a minute).
final class DeviceBatteries: ObservableObject {
    static let shared = DeviceBatteries()

    @Published private(set) var devices: [DeviceBattery] = []
    private var timer: Timer?
    private var busy = false
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = AppState.shared.$panelOpen.removeDuplicates().sink { [weak self] open in self?.setActive(open) }
    }

    private func setActive(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 10
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        inBackground {
            let list = DeviceBatteries.merge(DeviceBatteries.readRegistry(), DeviceBatteries.readBluetooth())
            onMain {
                self.busy = false
                if list != self.devices { self.devices = list }
            }
        }
    }

    /// Shows fixed sample devices (used only to render documentation screenshots).
    func loadDemo(_ sample: [DeviceBattery]) {
        cancellable = nil
        devices = sample
    }

    // MARK: Sources

    /// Accessories that report "BatteryPercent" in the I/O Registry: Apple's Magic devices and many Bluetooth LE ones.
    static func readRegistry() -> [DeviceBattery] {
        var found: [DeviceBattery] = []
        for cls in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard let percent = (prop("BatteryPercent") as? NSNumber)?.intValue, (0...100).contains(percent),
                      let name = prop("Product") as? String, !name.isEmpty else { continue }
                let usage = (prop("PrimaryUsage") as? NSNumber)?.intValue ?? (prop("DeviceUsage") as? NSNumber)?.intValue
                found.append(DeviceBattery(name: name, kind: kind(name: name, minorType: nil, usage: usage), main: percent))
            }
        }
        return found
    }

    /// Everything `system_profiler` knows about connected Bluetooth devices, which includes AirPods buds and case.
    static func readBluetooth() -> [DeviceBattery] {
        let result = shell("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        guard result.status == 0, let data = result.out.data(using: .utf8) else { return [] }
        return parseBluetooth(data)
    }

    static func parseBluetooth(_ data: Data) -> [DeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        func level(_ value: Any?) -> Int? {
            guard let text = value as? String else { return (value as? NSNumber)?.intValue }
            return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
        }
        var out: [DeviceBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let props = value as? [String: Any] else { continue }
                    let device = DeviceBattery(name: name,
                                               kind: kind(name: name, minorType: props["device_minorType"] as? String, usage: nil),
                                               main: level(props["device_batteryLevelMain"] ?? props["device_batteryLevel"]),
                                               left: level(props["device_batteryLevelLeft"]),
                                               right: level(props["device_batteryLevelRight"]),
                                               caseLevel: level(props["device_batteryLevelCase"]))
                    if device.main != nil || device.left != nil || device.right != nil || device.caseLevel != nil {
                        out.append(device)
                    }
                }
            }
        }
        return out
    }

    static func kind(name: String, minorType: String?, usage: Int?) -> DeviceBattery.Kind {
        let n = name.lowercased(), t = (minorType ?? "").lowercased()
        if t.contains("headphone") || t.contains("headset") || t.contains("speaker") || n.contains("airpods") || n.contains("beats") { return .headphones }
        if t.contains("trackpad") || n.contains("trackpad") { return .trackpad }
        if t.contains("mouse") || n.contains("mouse") || usage == 2 { return .mouse }
        if t.contains("keyboard") || n.contains("keyboard") || usage == 6 { return .keyboard }
        if t.contains("gamepad") || t.contains("game") || n.contains("controller") || usage == 5 { return .gamepad }
        return .other
    }

    /// One entry per device, keeping the most detailed reading of each.
    static func merge(_ lists: [DeviceBattery]...) -> [DeviceBattery] {
        var byID: [String: DeviceBattery] = [:]
        for device in lists.flatMap({ $0 }) {
            guard var existing = byID[device.id] else { byID[device.id] = device; continue }
            existing.main = existing.main ?? device.main
            existing.left = existing.left ?? device.left
            existing.right = existing.right ?? device.right
            existing.caseLevel = existing.caseLevel ?? device.caseLevel
            if existing.kind == .other { existing.kind = device.kind }
            byID[device.id] = existing
        }
        return byID.values.sorted { ($0.kind, $0.name) < ($1.kind, $1.name) }
    }
}
