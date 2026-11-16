import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case battery, monitor, awake, windows, mouse, clipboard, tools, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: return "Battery"
        case .monitor: return "Activity"
        case .awake: return "Keep Awake"
        case .windows: return "Windows"
        case .mouse: return "Mouse"
        case .clipboard: return "Clipboard"
        case .tools: return "Tools"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.75percent"
        case .monitor: return "waveform.path.ecg"
        case .awake: return "cup.and.saucer"
        case .windows: return "rectangle.split.2x1"
        case .mouse: return "computermouse"
        case .clipboard: return "clipboard"
        case .tools: return "wrench.and.screwdriver"
        case .settings: return "gearshape"
        }
    }
}

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var tab: PanelTab = .battery
    @Published var accessibilityGranted = Permissions.accessibility
    @Published var panelOpen = false {
        didSet {
            guard panelOpen != oldValue else { return }
            EnergyMonitor.shared.setFast(panelOpen)
            SystemMonitor.shared.setFast(panelOpen)
        }
    }
}

/// Everything that runs in the background, started once at launch.
enum Services {
    private static var permissionTimer: Timer?

    static func startAll() {
        UserDefaults.registerMacMateDefaults()
        let battery = BatteryService.shared
        battery.onChange = { old, new in
            if old.isPluggedIn, !new.isPluggedIn { EnergyMonitor.shared.resetSession() }
            let d = UserDefaults.standard
            let low = d.integer(forKey: Keys.alertLowLevel), high = d.integer(forKey: Keys.alertHighLevel)
            if d.bool(forKey: Keys.alertLow), new.onBattery, old.percent > low, new.percent <= low, old.hasBattery {
                Notifier.post(title: "Battery at \(new.percent)%", body: "Plug in soon to keep working.")
            }
            if d.bool(forKey: Keys.alertHigh), new.isPluggedIn, old.percent < high, new.percent >= high, old.hasBattery {
                Notifier.post(title: "Battery charged to \(new.percent)%", body: "Unplug now to go easier on battery health.")
            }
        }
        battery.start()
        EnergyMonitor.shared.start()
        SystemMonitor.shared.start()
        WindowManager.shared.start()
        MouseManager.shared.start()
        KeyboardFeatures.shared.start()
        WindowSwitcher.shared.start()
        ClipboardHistory.shared.start()
        MicMute.shared.refresh()
        DisplayDimmer.shared.refreshDisplays()
        registerHotKeys()

        EventTapHub.shared.startIfPossible()
        // Pick up the Accessibility grant as soon as the user flips the switch – no relaunch needed.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let granted = Permissions.accessibility
            if granted != AppState.shared.accessibilityGranted { AppState.shared.accessibilityGranted = granted }
            if granted { EventTapHub.shared.startIfPossible() }
        }
        permissionTimer?.tolerance = 0.5
    }

    private static func registerHotKeys() {
        let mods = HotKeyCenter.control | HotKeyCenter.option
        HotKeyCenter.shared.register(group: "tools", keyCode: kVK_ANSI_V, modifiers: mods) { MenuBarPanel.open(.clipboard) }
        HotKeyCenter.shared.register(group: "tools", keyCode: kVK_ANSI_O, modifiers: mods) { ScreenOCR.capture() }
        HotKeyCenter.shared.register(group: "tools", keyCode: kVK_ANSI_A, modifiers: mods) { MicMute.shared.toggle() }
        HotKeyCenter.shared.register(group: "tools", keyCode: kVK_ANSI_P, modifiers: mods) { SystemToggles.pickColor() }
    }
}

/// Opens and closes the menu bar panel from code (hotkeys, "paste and dismiss").
enum MenuBarPanel {
    static func open(_ tab: PanelTab) {
        AppState.shared.tab = tab
        StatusBarController.shared.show()
    }

    static func close() { StatusBarController.shared.close() }
}

/// The menu bar item and the panel that drops down from it.
final class StatusBarController: NSObject, NSPopoverDelegate {
    static let shared = StatusBarController()

    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var observers: [AnyCancellable] = []
    private var lastSignature = ""

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "MacMate"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.item = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        BatteryService.shared.$info.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        KeepAwake.shared.$isActive.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        MicMute.shared.$muted.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        SystemMonitor.shared.$stats.sink { [weak self] _ in
            let d = UserDefaults.standard
            if d.bool(forKey: Keys.barShowCPU) || d.bool(forKey: Keys.barShowNet) { self?.scheduleRefresh() }
        }.store(in: &observers)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &observers)
        refresh()
    }

    var buttonFrame: CGRect { item?.button?.window?.frame ?? .zero }
    var isShown: Bool { popover.isShown }

    @objc private func toggle() { popover.isShown ? close() : show() }

    func show() {
        guard let button = item?.button, !popover.isShown else { return }
        // Built fresh each time so nothing is laid out or redrawn while the panel is closed.
        popover.contentViewController = NSHostingController(rootView: PanelView())
        popover.contentSize = NSSize(width: 400, height: 620)
        AppState.shared.panelOpen = true
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        AppState.shared.panelOpen = false
        popover.contentViewController = nil
    }

    // MARK: Menu bar text and glyphs

    private func scheduleRefresh() {
        // Publishers fire before the new value is stored; read it on the next pass.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let d = UserDefaults.standard
        let b = BatteryService.shared.info
        var symbols = [StatusBarController.symbol(for: b)]
        if KeepAwake.shared.isActive { symbols.insert("cup.and.saucer.fill", at: 0) }
        if MicMute.shared.muted { symbols.insert("mic.slash.fill", at: 0) }

        var parts = [b.hasBattery ? "\(b.percent)%" : ""]
        if d.bool(forKey: Keys.barShowTime), let m = b.minutesRemaining { parts.append(Fmt.duration(minutes: m)) }
        if d.bool(forKey: Keys.barShowWatts), b.systemLoadW > 0 { parts.append(String(format: "%.1f W", b.systemLoadW)) }
        if d.bool(forKey: Keys.barShowCPU) { parts.append(String(format: "CPU %.0f%%", SystemMonitor.shared.stats.cpuTotal)) }
        if d.bool(forKey: Keys.barShowNet) { parts.append("↓ " + Fmt.rate(SystemMonitor.shared.stats.netDown)) }
        let title = parts.filter { !$0.isEmpty }.joined(separator: "  ")

        let signature = symbols.joined(separator: ",") + "|" + title
        guard signature != lastSignature else { return }
        lastSignature = signature
        button.image = StatusBarController.glyphs(symbols)
        button.title = title
        button.setAccessibilityLabel("MacMate, battery \(b.percent) percent")
    }

    static func symbol(for b: BatteryInfo) -> String {
        guard b.hasBattery else { return "bolt.circle" }
        if b.isCharging || b.isPluggedIn { return "battery.100percent.bolt" }
        switch b.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// Several SF Symbols side by side as one template image, so the menu bar tints them itself.
    private static func glyphs(_ names: [String]) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let images = names.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
        guard !images.isEmpty else { return nil }
        if images.count == 1 { images[0].isTemplate = true; return images[0] }
        let spacing: CGFloat = 5
        let width = images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(images.count - 1)
        let height = images.map(\.size.height).max() ?? 16
        let combined = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for image in images {
                image.draw(in: CGRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height))
                x += image.size.width + spacing
            }
            return true
        }
        combined.isTemplate = true
        return combined
    }
}

/// The Cleanup window (uninstaller and junk cleaner).
enum CleanupWindow {
    private static var window: NSWindow?

    static func show(_ mode: CleanupMode) {
        CleanupModel.shared.mode = mode
        if window == nil {
            let host = NSHostingController(rootView: CleanupView())
            host.sceneBridgingOptions = [.all]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.title = "Cleanup"
            w.toolbarStyle = .unified
            w.setContentSize(NSSize(width: 900, height: 600))
            w.contentMinSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("MacMateCleanup")
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Services.startAll()
        StatusBarController.shared.install()
        Notifier.requestPermission()

        // Test hooks: `--show <section>` opens the panel, `--debug-status <file>` reports what the app sees.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--show"), i + 1 < args.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if args[i + 1] == "cleanup" { CleanupWindow.show(.uninstall) }
                else if let tab = PanelTab(rawValue: args[i + 1]) { MenuBarPanel.open(tab) }
            }
        }
        if let i = args.firstIndex(of: "--debug-status"), i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                var lines = ["panelOpen=\(AppState.shared.panelOpen)", "popoverShown=\(StatusBarController.shared.isShown)",
                             "tab=\(AppState.shared.tab.rawValue)", "accessibility=\(Permissions.accessibility)",
                             "eventTap=\(EventTapHub.shared.isRunning)", "energyGroups=\(EnergyMonitor.shared.apps.count)",
                             "battery=\(BatteryService.shared.info.percent)", "statusItem=\(StatusBarController.shared.buttonFrame)"]
                for w in NSApp.windows where w.isVisible && w.frame.minY >= 0 {
                    lines.append("window \(w.className) frame=\(w.frame) title=\(w.title)")
                }
                try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.stop()
        DisplayDimmer.shared.reset()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
