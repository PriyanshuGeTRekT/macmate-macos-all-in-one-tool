import AppKit
import SwiftUI

/// `MacMate --selftest` exercises the non-visual parts and prints what it finds.
enum SelfTest {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static func run() {
        _ = NSApplication.shared
        UserDefaults.registerMacMateDefaults()

        print("== Battery")
        let b = BatteryService.read()
        print(b)
        check("battery present", b.hasBattery)
        check("battery percent plausible", (0...100).contains(b.percent))
        check("capacity read", b.maxMah > 1000 && b.designMah > 1000, "\(b.currentMah)/\(b.maxMah)/\(b.designMah) mAh, \(String(format: "%.1f", b.fullWh)) Wh full")
        check("system load read", b.systemLoadW > 0.5 && b.systemLoadW < 200, Fmt.watts(b.systemLoadW))

        print("== Energy")
        let energy = EnergyMonitor.shared
        energy.sample(); Thread.sleep(forTimeInterval: 2); energy.sample(); Thread.sleep(forTimeInterval: 2); energy.sample()
        spin(0.3)
        for app in energy.apps.prefix(8) {
            print(String(format: "  %-28@ %8@  cpu %5.1f%%  mem %@  pids %d", app.name as NSString, Fmt.watts(app.watts) as NSString,
                         app.cpuPercent, Fmt.mem(app.memBytes), app.pids.count))
        }
        check("apps sampled", energy.apps.count > 10, "\(energy.apps.count) groups")
        check("total app power plausible", energy.totalWatts > 0 && energy.totalWatts < max(b.systemLoadW * 1.5, 30),
              "apps \(Fmt.watts(energy.totalWatts)) vs system \(Fmt.watts(b.systemLoadW))")
        check("helpers grouped under apps", energy.apps.contains { $0.isApp && $0.pids.count > 1 })

        print("== System")
        let mon = SystemMonitor.shared
        mon.sample(); Thread.sleep(forTimeInterval: 1); mon.sample()
        spin(0.3)
        let s = mon.stats
        print("  cpu \(Fmt.percent(s.cpuTotal, digits: 1)) cores \(s.perCore.count) (E \(s.efficiencyCores))  mem \(Fmt.mem(s.memUsed))/\(Fmt.mem(s.memTotal)) pressure \(s.memPressure) swap \(Fmt.mem(s.swapUsed))")
        print("  disk free \(Fmt.bytes(s.diskFree))/\(Fmt.bytes(s.diskTotal))  net ↓\(Fmt.rate(s.netDown)) ↑\(Fmt.rate(s.netUp))  gpu \(s.gpu.map { Fmt.percent($0) } ?? "n/a")  thermal \(s.thermalText)")
        check("cpu sampled", s.perCore.count == ProcessInfo.processInfo.processorCount && s.cpuTotal >= 0 && s.cpuTotal <= 100)
        check("memory sampled", s.memUsed > 0 && s.memUsed <= s.memTotal)
        check("disk sampled", s.diskTotal > 0 && s.diskFree < s.diskTotal)
        check("gpu sampled", s.gpu != nil)

        print("== Keep awake")
        KeepAwake.shared.start(minutes: 1)
        let held = shell("/usr/bin/pmset", ["-g", "assertions"]).out.contains("MacMate Keep Awake")
        KeepAwake.shared.stop()
        let released = !shell("/usr/bin/pmset", ["-g", "assertions"]).out.contains("MacMate Keep Awake")
        check("assertion held while active", held)
        check("assertion released on stop", released)

        print("== Window geometry")
        let area = CGRect(x: 0, y: 25, width: 1512, height: 900)
        check("left half", ScreenGeometry.target(for: TileAction.leftHalf.unitRect!, in: area, gap: 0) == CGRect(x: 0, y: 25, width: 756, height: 900))
        check("bottom right", ScreenGeometry.target(for: TileAction.bottomRight.unitRect!, in: area, gap: 0) == CGRect(x: 756, y: 475, width: 756, height: 450))
        let l = ScreenGeometry.target(for: TileAction.leftHalf.unitRect!, in: area, gap: 10)
        let r = ScreenGeometry.target(for: TileAction.rightHalf.unitRect!, in: area, gap: 10)
        check("gap between halves", r.minX - l.maxX == 10 && l.minX == 10, "\(l) | \(r)")
        if let screen = NSScreen.main {
            let f = screen.frame
            check("snap zone left edge", DragSnapper.zone(at: CGPoint(x: f.minX + 1, y: f.midY)).0 == .leftHalf)
            check("snap zone top-right corner", DragSnapper.zone(at: CGPoint(x: f.maxX - 1, y: f.maxY - 20)).0 == .topRight)
            check("snap zone top", DragSnapper.zone(at: CGPoint(x: f.midX, y: f.maxY - 1)).0 == .maximize)
            check("no snap in middle", DragSnapper.zone(at: CGPoint(x: f.midX, y: f.midY)).0 == nil)
        }
        check("hotkeys unique", Set(TileAction.allCases.map(\.keyCode)).count == TileAction.allCases.count)
        check("accessibility state readable", true, Permissions.accessibility ? "granted" : "not granted to this binary")

        print("== Mouse")
        let mouse = MouseManager.shared
        UserDefaults.standard.register(defaults: [Keys.mouseSmooth: false, Keys.mouseReverse: true, Keys.mouseScrollSpeed: 1.0])
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0) {
            check("wheel event is not continuous", wheel.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
            let swallowed = mouse.handle(.scrollWheel, wheel)
            check("wheel reversed in place", !swallowed && wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3,
                  "delta \(wheel.getIntegerValueField(.scrollWheelEventDeltaAxis1))")
        }
        if let pad = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0) {
            let before = pad.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let swallowed = mouse.handle(.scrollWheel, pad)
            check("trackpad scrolling untouched", !swallowed && pad.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == before)
        }
        UserDefaults.standard.register(defaults: [Keys.mouseSmooth: true])
        if let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0) {
            wheel.setIntegerValueField(.eventSourceUserData, value: EventTapHub.magic)
            check("own events pass the tap", !EventTapHub.shared.dispatch(.scrollWheel, wheel))
        }
        if let other = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center) {
            other.setIntegerValueField(.mouseEventButtonNumber, value: 7)
            check("unmapped buttons pass through", !mouse.handle(.otherMouseDown, other))
        }
        mouse.refreshDevices()
        mouse.start()
        mouse.refreshDevices()
        for d in mouse.devices { print("  device: \(d.name) vendor \(d.vendorID) transport \(d.transport) thirdParty \(d.isThirdPartyMouse)") }
        check("pointing devices enumerated", !mouse.devices.isEmpty)
        check("built-in trackpad not treated as a mouse", !mouse.devices.contains { $0.isThirdPartyMouse && $0.name.lowercased().contains("apple") })

        print("== Uninstaller")
        func m(_ e: String, _ id: String, _ n: String, name: Bool = true, suffix: Bool = false, others: [String] = []) -> Bool {
            Uninstaller.matches(entry: e, bundleID: id, appName: n, allowName: name, allowSuffix: suffix, otherBundleIDs: others)
        }
        check("exact bundle id", m("com.foo.Bar", "com.foo.bar", "Bar"))
        check("plist", m("com.foo.bar.plist", "com.foo.bar", "Bar"))
        check("saved state", m("com.foo.bar.savedState", "com.foo.bar", "Bar", name: false))
        check("helper prefix", m("com.foo.bar.helper", "com.foo.bar", "Bar"))
        check("group container", m("group.com.foo.bar", "com.foo.bar", "Bar", name: false, suffix: true))
        check("team-prefixed container", m("ABCDE12345.com.foo.bar", "com.foo.bar", "Bar", name: false, suffix: true))
        check("name folder", m("Bar", "com.foo.bar", "Bar"))
        check("no partial name match", !m("Barista", "com.foo.bar", "Bar"))
        check("no partial id match", !m("com.foo.barista", "com.foo.bar", "Bar"))
        check("sibling app protected", !m("com.foo.bar.beta.plist", "com.foo.bar", "Bar", others: ["com.foo.bar.beta"]))
        check("name not used where disallowed", !m("Bar", "com.foo.bar", "Bar", name: false))
        let home = NSHomeDirectory()
        check("refuses home", !Uninstaller.isSafeToRemove(home))
        check("refuses Library folder itself", !Uninstaller.isSafeToRemove(home + "/Library/Caches"))
        check("refuses Documents", !Uninstaller.isSafeToRemove(home + "/Documents/thing"))
        check("refuses system", !Uninstaller.isSafeToRemove("/System/Applications/Mail.app"))
        check("refuses /usr", !Uninstaller.isSafeToRemove("/usr/local/bin/tool"))
        check("allows cache item", Uninstaller.isSafeToRemove(home + "/Library/Caches/com.foo.bar"))
        check("allows app", Uninstaller.isSafeToRemove("/Applications/Foo.app"))
        check("allows npm cache", Uninstaller.isSafeToRemove(home + "/.npm/_cacache"))
        let apps = Uninstaller.scanApps()
        check("installed apps found", apps.count > 3, "\(apps.count) apps")
        let ids = apps.map(\.bundleID)
        for app in apps.filter({ ["Google Chrome", "Firefox", "WhatsApp", "Slack"].contains($0.name) }).prefix(3) {
            let t = Date()
            let items = Uninstaller.findRelated(for: app, otherBundleIDs: ids)
            print("  \(app.name) [\(app.bundleID)] → \(items.count) related items in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            for i in items { print("     \(i.category): \(i.displayPath)  \(Fmt.bytes(i.size))\(i.needsAdmin ? "  (admin)" : "")") }
            check("\(app.name) leftovers found", !items.isEmpty)
            check("\(app.name) leftovers all safe", items.allSatisfy { Uninstaller.isSafeToRemove($0.path) })
        }

        print("== Trash round trip")
        let scratch = home + "/Library/Caches/macmate-selftest-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: scratch + "/inner", withIntermediateDirectories: true)
        try? "x".write(toFile: scratch + "/inner/file.txt", atomically: true, encoding: .utf8)
        let result = Uninstaller.moveToTrash([scratch, scratch + "/inner"])
        check("item moved to Trash", result.trashed == [scratch] && !FileManager.default.fileExists(atPath: scratch), "\(result)")

        print("== Junk scan")
        let t = Date()
        let junk = JunkCleaner.scanAll()
        for c in junk { print("  \(c.title): \(c.items.count) items, \(Fmt.bytes(c.totalSize))") }
        check("junk scan ran", junk.count == 3, String(format: "%.1fs", Date().timeIntervalSince(t)))
        check("junk never lists Apple caches", !junk.flatMap(\.items).contains { $0.name.hasPrefix("com.apple.") })
        check("junk items all safe", junk.flatMap(\.items).allSatisfy { Uninstaller.isSafeToRemove($0.path) })

        print("== Clipboard")
        let clip = ClipboardHistory.shared
        clip.record("one", source: nil); clip.record("two", source: nil); clip.record("one", source: nil)
        check("dedupes and moves to top", clip.items.map(\.text) == ["one", "two"])

        print("== OCR")
        let image = NSImage(size: NSSize(width: 640, height: 120), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            ("MacMate reads 12345 words" as NSString).draw(at: NSPoint(x: 20, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            return true
        }
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let text = ScreenOCR.recognize(cg)
            check("text recognised", text.contains("MacMate") && text.contains("12345"), text)
        }

        print("== Audio / displays")
        MicMute.shared.refresh()
        check("microphone found", !MicMute.shared.deviceName.isEmpty, "\(MicMute.shared.deviceName), muted: \(MicMute.shared.muted)")
        DisplayDimmer.shared.refreshDisplays()
        check("displays listed", !DisplayDimmer.shared.displays.isEmpty, DisplayDimmer.shared.displays.map(\.name).joined(separator: ", "))

        if Permissions.accessibility {
            print("== Windows (live)")
            let wins = WindowSwitcher.listWindows()
            for w in wins.prefix(8) { print("  \(w.appName): \(w.title)") }
            check("window list", !wins.isEmpty)
        }

        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    }
}

/// `MacMate --snapshot <dir>` renders each panel section to a PNG, filled with sample data,
/// for the README. Nothing personal (running apps, installed apps, clipboard) ends up in the images.
enum Snapshot {
    /// True while rendering off screen, where glass materials cannot be drawn.
    static var active = false

    static func run(directory: String) {
        active = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.registerMacMateDefaults()
        BatteryService.shared.start()
        SystemMonitor.shared.start(); SystemMonitor.shared.setFast(true)
        MicMute.shared.refresh()
        DisplayDimmer.shared.refreshDisplays()
        AppState.shared.accessibilityGranted = true
        Conflicts.suppressed = true

        func usage(_ name: String, _ path: String, _ watts: Double, _ cpu: Double, _ memGB: Double, _ joules: Double) -> AppUsage {
            AppUsage(id: path, name: name, bundlePath: path, pids: [1], watts: watts, cpuPercent: cpu,
                     memBytes: UInt64(memGB * 1_073_741_824), sessionJoules: joules, isApp: true)
        }
        EnergyMonitor.shared.loadDemo([
            usage("Safari", "/Applications/Safari.app", 2.41, 38.2, 2.6, 5200),
            usage("Xcode", "/Applications/Xcode.app", 1.36, 21.4, 3.9, 3900),
            usage("Music", "/System/Applications/Music.app", 0.48, 6.1, 0.4, 1500),
            usage("Mail", "/System/Applications/Mail.app", 0.21, 2.8, 0.5, 640),
            usage("Photos", "/System/Applications/Photos.app", 0.12, 1.9, 0.9, 410),
            usage("Notes", "/System/Applications/Notes.app", 0.04, 0.6, 0.2, 120),
            usage("Maps", "/System/Applications/Maps.app", 0.02, 0.3, 0.3, 60),
        ])
        MouseManager.shared.loadDemo([
            PointingDevice(id: "demo", name: "Wireless Mouse", vendorID: 1, productID: 1, transport: "Bluetooth", isThirdPartyMouse: true, battery: 82),
        ])
        for text in ["https://developer.apple.com/design/human-interface-guidelines", "let total = items.reduce(0, +)",
                     "Meeting moved to 3:30 pm", "#0A84FF", "The quick brown fox jumps over the lazy dog"] {
            ClipboardHistory.shared.record(text, source: ["Safari", "Xcode", "Mail", "MacMate", "Notes"].randomElement())
        }
        SelfTest.spin(9)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        for tab in PanelTab.allCases {
            AppState.shared.tab = tab
            render(PanelView().background(.regularMaterial), size: CGSize(width: 400, height: 620), to: "\(directory)/\(tab.rawValue).png")
        }

        let home = NSHomeDirectory()
        let chrome = InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome", version: "157.0", path: "/Applications/Google Chrome.app", size: 1_540_000_000)
        func item(_ path: String, _ category: String, _ size: UInt64, admin: Bool = false) -> RelatedItem {
            RelatedItem(path: path, category: category, size: size, selected: true, needsAdmin: admin)
        }
        CleanupModel.shared.selectedApp = chrome
        CleanupModel.shared.related = [
            item(home + "/Library/Application Support/Google/Chrome", "Application Support", 1_920_000_000),
            item(home + "/Library/Caches/Google/Chrome", "Caches", 2_100_000_000),
            item(home + "/Library/Caches/com.google.Chrome.helper", "Caches", 23_400_000),
            item(home + "/Library/Preferences/com.google.Chrome.plist", "Preferences", 4096),
            item(home + "/Library/Saved Application State/com.google.Chrome.savedState", "Saved State", 48_000),
            item("/Library/LaunchAgents/com.google.keystone.agent.plist", "Login & Background Items", 4096, admin: true),
        ]
        render(CleanupView().appDetail(chrome).background(.regularMaterial), size: CGSize(width: 640, height: 600), to: "\(directory)/uninstall.png")

        func junk(_ name: String, _ gb: Double, _ on: Bool = true) -> JunkItem {
            JunkItem(path: home + "/Library/Caches/" + name, size: UInt64(gb * 1_000_000_000), selected: on)
        }
        JunkCleaner.shared.categories = [
            JunkCategory(id: "caches", title: "App caches", symbol: "internaldrive", detail: "Temporary data apps rebuild when they need it",
                         items: [junk("Google", 3.18), junk("Homebrew", 1.47), junk("Firefox", 1.12), junk("pip", 0.44), junk("Slack", 0.31), junk("node-gyp", 0.07)]),
            JunkCategory(id: "logs", title: "Logs and crash reports", symbol: "doc.text", detail: "Old diagnostic output",
                         items: [junk("DiagnosticReports", 0.06), junk("Homebrew", 0.02)]),
            JunkCategory(id: "dev", title: "Developer leftovers", symbol: "hammer", detail: "Build products and package-manager caches",
                         items: [junk("DerivedData", 8.4, false), junk("_cacache", 2.9, false)]),
        ]
        render(JunkView().background(.regularMaterial), size: CGSize(width: 640, height: 600), to: "\(directory)/junk.png")
    }

    /// A borderless window that may become key, so controls draw in their active colours.
    private final class RenderWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private static func render<V: View>(_ view: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = RenderWindow(contentRect: CGRect(origin: CGPoint(x: -3000, y: -3000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        SelfTest.spin(1.2)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        print("wrote \(path)")
    }
}
