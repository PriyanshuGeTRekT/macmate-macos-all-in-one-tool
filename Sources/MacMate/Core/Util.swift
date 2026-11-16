import AppKit
import Foundation

enum Fmt {
    static func bytes(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .file)
    }

    static func mem(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(b, UInt64(Int64.max))), countStyle: .memory)
    }

    /// Bytes per second.
    static func rate(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.0f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / 1024 / 1024) }
        return String(format: "%.2f GB/s", bps / 1024 / 1024 / 1024)
    }

    static func watts(_ w: Double) -> String {
        if w < 0.0005 { return "0 W" }
        if w < 1 { return String(format: "%.0f mW", w * 1000) }
        if w < 10 { return String(format: "%.2f W", w) }
        return String(format: "%.1f W", w)
    }

    static func energy(joules j: Double) -> String {
        let wh = j / 3600
        if wh < 0.001 { return String(format: "%.0f mJ", j * 1000) }
        if wh < 1 { return String(format: "%.0f mWh", wh * 1000) }
        return String(format: "%.2f Wh", wh)
    }

    static func duration(minutes m: Int) -> String {
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    static func countdown(_ s: TimeInterval) -> String {
        let t = max(0, Int(s.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func percent(_ v: Double, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", v)
    }
}

/// Runs a command and returns its exit status and combined stdout.
@discardableResult
func shell(_ path: String, _ args: [String] = []) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

@discardableResult
func appleScript(_ source: String) -> (ok: Bool, out: String) {
    let r = shell("/usr/bin/osascript", ["-e", source])
    return (r.status == 0, r.out.trimmingCharacters(in: .whitespacesAndNewlines))
}

func inBackground(_ work: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
}

func onMain(_ work: @escaping () -> Void) {
    if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
}

/// Small icon cache so list rows don't hit the disk on every redraw.
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private lazy var generic: NSImage = NSWorkspace.shared.icon(for: .unixExecutable)

    func icon(forPath path: String?) -> NSImage {
        guard let path, !path.isEmpty else { return generic }
        if let hit = cache[path] { return hit }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

/// Total allocated size of a file or directory tree.
func diskSize(of url: URL) -> UInt64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey]
    guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }
    if rv.isDirectory != true {
        return UInt64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0)
    }
    var total: UInt64 = 0
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return 0 }
    for case let f as URL in en {
        if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
            total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
    }
    return total
}

enum Keys {
    // Menu bar
    static let barShowTime = "bar.showTime"
    static let barShowWatts = "bar.showWatts"
    static let barShowCPU = "bar.showCPU"
    static let barShowNet = "bar.showNet"
    // Battery alerts
    static let alertLow = "battery.alertLow"
    static let alertLowLevel = "battery.alertLowLevel"
    static let alertHigh = "battery.alertHigh"
    static let alertHighLevel = "battery.alertHighLevel"
    // Keep awake
    static let awakeDisplay = "awake.keepDisplay"
    static let awakeBatteryStop = "awake.stopOnLowBattery"
    // Windows
    static let tileHotkeys = "tile.hotkeys"
    static let tileDragSnap = "tile.dragSnap"
    static let tileGap = "tile.gap"
    // Mouse
    static let mouseEnabled = "mouse.enabled"
    static let mouseReverse = "mouse.reverseScroll"
    static let mouseReverseH = "mouse.reverseScrollH"
    static let mouseSmooth = "mouse.smooth"
    static let mouseScrollSpeed = "mouse.scrollSpeed"
    static let mouseButton2 = "mouse.button2"
    static let mouseButton3 = "mouse.button3"
    static let mouseButton4 = "mouse.button4"
    static let mouseLinear = "mouse.linear"
    static let mouseSpeedOverride = "mouse.speedOverride"
    static let mouseSpeed = "mouse.speed"
    // Clipboard
    static let clipEnabled = "clip.enabled"
    static let clipAutoPaste = "clip.autoPaste"
    // Switcher / menu bar hider
    static let switcherEnabled = "switcher.enabled"
}

extension UserDefaults {
    static func registerMacMateDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.barShowTime: false,
            Keys.barShowWatts: false,
            Keys.barShowCPU: false,
            Keys.barShowNet: false,
            Keys.alertLow: true,
            Keys.alertLowLevel: 20,
            Keys.alertHigh: false,
            Keys.alertHighLevel: 80,
            Keys.awakeDisplay: true,
            Keys.awakeBatteryStop: true,
            Keys.tileHotkeys: true,
            Keys.tileDragSnap: false,
            Keys.tileGap: 0,
            Keys.mouseEnabled: true,
            Keys.mouseReverse: true,
            Keys.mouseReverseH: false,
            Keys.mouseSmooth: true,
            Keys.mouseScrollSpeed: 1.0,
            Keys.mouseButton2: MouseAction.passThrough.rawValue,
            Keys.mouseButton3: MouseAction.back.rawValue,
            Keys.mouseButton4: MouseAction.forward.rawValue,
            Keys.mouseLinear: false,
            Keys.mouseSpeedOverride: false,
            Keys.mouseSpeed: 1.0,
            Keys.clipEnabled: true,
            Keys.clipAutoPaste: true,
            Keys.switcherEnabled: false,
            Keys.cmdQGuard: false,
            Keys.finderCut: false,
        ])
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
