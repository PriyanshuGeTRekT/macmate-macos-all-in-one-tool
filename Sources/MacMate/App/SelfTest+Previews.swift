import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

extension SelfTest {
    /// Window previews: grid layout, Dock geometry and window-list assembly, all with made-up data.
    /// Nothing here captures the screen or asks for a permission.
    static func runPreviewChecks() {
        print("== Window previews")
        UserDefaults.standard.register(defaults: [Keys.previewsSwitcher: false, Keys.previewsDock: false])
        check("preview settings default off", !UserDefaults.standard.bool(forKey: Keys.previewsSwitcher) && !UserDefaults.standard.bool(forKey: Keys.previewsDock))
        print("  screen recording: \(ThumbnailStore.permitted ? "granted" : "not granted to this binary")")

        // Grid layout
        let laptop = CGSize(width: 1512, height: 900)
        let three = PreviewGridLayout.make(count: 3, bounds: laptop)
        check("grid: 3 windows in one row at full size", three.columns == 3 && three.rows == 1 && three.thumbnail == CGSize(width: 220, height: 138),
              "\(three.columns)x\(three.rows) \(three.thumbnail)")
        let seven = PreviewGridLayout.make(count: 7, bounds: laptop)
        check("grid: rows of at most 5", seven.columns == 5 && seven.rows == 2 && seven.indices(row: 1, count: 7) == 5..<7)
        let one = PreviewGridLayout.make(count: 1, bounds: laptop)
        check("grid: single window", one.columns == 1 && one.rows == 1 && one.visibleRows == 1)
        check("grid: panel width adds up", three.panelSize.width == 2 * three.padding + 3 * three.cell.width + 2 * three.spacing)
        var fits = true, detail = ""
        for screen in [CGSize(width: 1512, height: 900), CGSize(width: 1024, height: 640), CGSize(width: 800, height: 500), CGSize(width: 3008, height: 1692)] {
            for n in 1...60 {
                let g = PreviewGridLayout.make(count: n, bounds: screen)
                let ok = g.panelSize.width <= screen.width * 0.9 + 1 && g.panelSize.height <= screen.height * 0.85 + 1
                    && g.columns * g.rows >= n && g.visibleRows >= 1 && g.visibleRows <= g.rows && g.thumbnail.width >= 1
                if !ok, fits { fits = false; detail = "\(n) on \(screen): \(g.panelSize)" }
            }
        }
        check("grid: always fits the screen", fits, detail)
        let many = PreviewGridLayout.make(count: 40, bounds: CGSize(width: 1024, height: 640))
        check("grid: many windows scroll instead of shrinking away", many.visibleRows < many.rows && many.thumbnail.width >= 96,
              "\(many.visibleRows)/\(many.rows) rows, thumb \(many.thumbnail)")
        let small = PreviewGridLayout.make(count: 15, bounds: CGSize(width: 1024, height: 640))
        check("grid: shrinks on a small screen", small.thumbnail.width < 220 && small.visibleRows == small.rows, "\(small.thumbnail)")
        check("capture size keeps aspect at 2x", ThumbnailStore.captureSize(window: CGSize(width: 1600, height: 1000), box: CGSize(width: 220, height: 138), scale: 2) == CGSize(width: 440, height: 275))
        check("capture size for tall windows", ThumbnailStore.captureSize(window: CGSize(width: 500, height: 1000), box: CGSize(width: 220, height: 138), scale: 2) == CGSize(width: 138, height: 276))

        // Dock geometry
        check("dock orientation default bottom", DockPreviews.Orientation(dockValue: nil) == .bottom && DockPreviews.Orientation(dockValue: "nonsense") == .bottom)
        check("dock orientation left/right", DockPreviews.Orientation(dockValue: "left") == .left && DockPreviews.Orientation(dockValue: "right") == .right)
        print("  this Mac's Dock: \(DockPreviews.Orientation.current.rawValue)")
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let size = CGSize(width: 400, height: 200)
        let bottomIcon = CGRect(x: 700, y: 4, width: 64, height: 64)
        let above = DockPreviews.panelFrame(icon: bottomIcon, size: size, orientation: .bottom, screen: screen)
        check("dock bottom: panel centered above icon", above == CGRect(x: 532, y: 78, width: 400, height: 200), "\(above)")
        let edge = DockPreviews.panelFrame(icon: CGRect(x: 2, y: 4, width: 64, height: 64), size: size, orientation: .bottom, screen: screen)
        check("dock bottom: kept on screen", edge.minX == 8, "\(edge)")
        let leftIcon = CGRect(x: 4, y: 400, width: 64, height: 64)
        let beside = DockPreviews.panelFrame(icon: leftIcon, size: size, orientation: .left, screen: screen)
        check("dock left: panel to the right of icon", beside.minX == 78 && beside.midY == leftIcon.midY, "\(beside)")
        let rightIcon = CGRect(x: 1444, y: 900, width: 64, height: 64)
        let rightPanel = DockPreviews.panelFrame(icon: rightIcon, size: size, orientation: .right, screen: screen)
        check("dock right: panel to the left, clamped vertically", rightPanel.maxX == 1434 && rightPanel.maxY == screen.maxY - 8, "\(rightPanel)")
        let zones = DockPreviews.keepZones(icon: bottomIcon, panel: above, orientation: .bottom)
        check("dock: gap between icon and panel keeps it open", zones.contains { $0.contains(CGPoint(x: 732, y: 73)) } && zones.contains { $0.contains(CGPoint(x: 560, y: 72)) })
        check("dock: elsewhere closes it", !zones.contains { $0.contains(CGPoint(x: 200, y: 500)) } && !zones.contains { $0.contains(CGPoint(x: 1100, y: 30)) })
        let sideZones = DockPreviews.keepZones(icon: leftIcon, panel: beside, orientation: .left)
        check("dock left: gap keeps it open", sideZones.contains { $0.contains(CGPoint(x: 73, y: 432)) })
        check("dock item matches running app", DockPreviews.sameApp(itemURL: URL(string: "file:///System/Applications/Notes.app/")!, bundleURL: URL(fileURLWithPath: "/System/Applications/Notes.app")))
        check("dock item does not match another app", !DockPreviews.sameApp(itemURL: URL(string: "file:///Applications/Safari.app/")!, bundleURL: URL(fileURLWithPath: "/Applications/Safari Technology Preview.app"))
              && !DockPreviews.sameApp(itemURL: URL(string: "file:///Applications/Safari.app/")!, bundleURL: nil))
        let gridDock = DockPreviews.gridLayout(count: 3, orientation: .bottom, bounds: CGSize(width: 1512, height: 900))
        let sideDock = DockPreviews.gridLayout(count: 3, orientation: .left, bounds: CGSize(width: 1512, height: 900))
        check("dock grid: one row for a bottom Dock, two columns beside", gridDock.columns == 3 && sideDock.columns == 2 && sideDock.rows == 2)

        // Window list assembly
        let el = AXUIElementCreateApplication(1)
        func ax(_ title: String, _ r: CGRect, min: Bool = false) -> WindowSwitcher.AXWindow {
            WindowSwitcher.AXWindow(element: el, frame: r, title: title, minimized: min)
        }
        let r1 = CGRect(x: 0, y: 0, width: 800, height: 600), r2 = CGRect(x: 100, y: 100, width: 800, height: 600)
        let axWindows: [pid_t: [WindowSwitcher.AXWindow]] = [
            101: [ax("Doc 1", r1), ax("Doc 2", r2), ax("Old", r1, min: true), ax("Twin", r1)],
            102: [ax("Hidden window", r1)],
            103: [ax("", CGRect(x: 50, y: 50, width: 700, height: 500)), ax("On another Space", r1)],
        ]
        let server = [
            WindowSwitcher.ServerWindow(id: 9, pid: 103, bounds: CGRect(x: 51, y: 50, width: 700, height: 500), layer: 0),
            WindowSwitcher.ServerWindow(id: 3, pid: 101, bounds: r1, layer: 25),
            WindowSwitcher.ServerWindow(id: 7, pid: 101, bounds: r2, layer: 0),
            WindowSwitcher.ServerWindow(id: 5, pid: 101, bounds: r1, layer: 0),
            WindowSwitcher.ServerWindow(id: 6, pid: 101, bounds: r1, layer: 0),
            WindowSwitcher.ServerWindow(id: 8, pid: 999, bounds: r1, layer: 0),
        ]
        let apps: [pid_t: WindowSwitcher.AppInfo] = [
            101: .init(name: "Alpha", icon: nil, hidden: false),
            102: .init(name: "Bravo", icon: nil, hidden: true),
            103: .init(name: "Charlie", icon: nil, hidden: false),
        ]
        let list = WindowSwitcher.assemble(ax: axWindows, server: server, apps: apps, order: [101, 102, 103])
        let titles = list.map(\.title)
        check("window list: stacking order, hidden, then minimized", titles == ["Charlie", "Doc 2", "Doc 1", "Twin", "Hidden window", "Old"], titles.joined(separator: ", "))
        check("window list: window ids joined", list.map(\.windowID) == [9, 7, 5, 6, nil, nil], "\(list.map(\.windowID))")
        check("window list: minimized flagged", list.last?.minimized == true && list.dropLast().allSatisfy { !$0.minimized })
        check("window list: one app only", WindowSwitcher.assemble(ax: [101: axWindows[101]!], server: server, apps: apps, order: [101]).count == 4)

        // Thumbnail cache
        let store = ThumbnailStore.shared
        store.setImage(previewPlaceholder(size: CGSize(width: 220, height: 138), hue: 0.6, title: "Test"), for: 4242)
        check("thumbnail stored for window", store.images[4242] != nil)
        store.setImage(nil, for: 4242)
        check("thumbnail removed", store.images[4242] == nil)

        // ⌥Tab is swallowed only while the switcher is on. Without Accessibility the window list is empty,
        // so nothing on this Mac can be switched to; with it, this would raise a real window, so skip.
        if !ci, !Permissions.accessibility {
            let switcher = WindowSwitcher.shared
            func tab(_ flags: CGEventFlags) -> CGEvent? {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Tab), keyDown: true)
                e?.flags = flags
                return e
            }
            UserDefaults.standard.register(defaults: [Keys.switcherEnabled: false])
            if let e = tab(.maskAlternate) { check("⌥Tab passes when switcher is off", !switcher.handle(.keyDown, e)) }
            UserDefaults.standard.register(defaults: [Keys.switcherEnabled: true])
            if let e = tab([]) { check("plain Tab passes", !switcher.handle(.keyDown, e)) }
            if let e = tab(.maskAlternate) { check("⌥Tab swallowed when switcher is on", switcher.handle(.keyDown, e)) }
            // Releasing ⌥ ends it; the background list (empty without Accessibility) must not leave a panel up.
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Option), keyDown: false) {
                up.flags = []
                _ = switcher.handle(.flagsChanged, up)
            }
            spin(1)
            check("switcher closed after ⌥ released", !NSApp.windows.contains { $0 is PreviewPanel && $0.isVisible })
            if let e = tab([]) { check("Tab passes again afterwards", !switcher.handle(.keyDown, e)) }
            UserDefaults.standard.register(defaults: [Keys.switcherEnabled: false])
        }
    }

    /// A stand-in for a captured window: a gradient with a fake title bar and a few content lines.
    static func previewPlaceholder(size: CGSize, hue: CGFloat, title: String, dark: Bool = false) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            let body = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            body.addClip()
            let top = NSColor(calibratedHue: hue, saturation: 0.35, brightness: dark ? 0.35 : 0.98, alpha: 1)
            let bottom = NSColor(calibratedHue: hue, saturation: 0.55, brightness: dark ? 0.22 : 0.85, alpha: 1)
            NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: 90)
            let bar = CGRect(x: 0, y: 0, width: rect.width, height: max(14, rect.height * 0.11))
            (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
            bar.fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                let d = bar.height * 0.42
                NSBezierPath(ovalIn: CGRect(x: 8 + CGFloat(i) * (d + 5), y: (bar.height - d) / 2, width: d, height: d)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: bar.height * 0.5, weight: .medium),
                                                        .foregroundColor: dark ? NSColor.white : NSColor.darkGray]
            let t = title as NSString
            let ts = t.size(withAttributes: attrs)
            t.draw(at: CGPoint(x: (rect.width - ts.width) / 2, y: (bar.height - ts.height) / 2), withAttributes: attrs)
            (dark ? NSColor.white.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.12)).setFill()
            var y = bar.maxY + rect.height * 0.08
            var line = 0
            while y < rect.height - 10 {
                let w = rect.width * [0.7, 0.55, 0.8, 0.4][line % 4]
                NSBezierPath(roundedRect: CGRect(x: 14, y: y, width: w, height: max(3, rect.height * 0.035)), xRadius: 2, yRadius: 2).fill()
                y += rect.height * 0.09
                line += 1
            }
            return true
        }
    }

    /// `MacMate --render-previews <dir>`: draws the switcher grid, the Dock panel and the settings section.
    static func renderPreviews(directory: String) {
        Snapshot.active = true
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        UserDefaults.registerMacMateDefaults()
        UserDefaults.standard.register(defaults: [Keys.previewsSwitcher: false, Keys.previewsDock: false])
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let el = AXUIElementCreateApplication(1)
        func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
        let samples: [(String, String, String, CGSize, Bool)] = [
            ("Safari", "/Applications/Safari.app", "Apple Developer — Human Interface Guidelines", CGSize(width: 1400, height: 900), false),
            ("Notes", "/System/Applications/Notes.app", "Groceries", CGSize(width: 900, height: 700), false),
            ("Mail", "/System/Applications/Mail.app", "Inbox — 3 unread", CGSize(width: 1300, height: 850), false),
            ("Terminal", "/System/Applications/Utilities/Terminal.app", "~ — zsh — 80×24", CGSize(width: 700, height: 460), false),
            ("Calendar", "/System/Applications/Calendar.app", "Calendar", CGSize(width: 1200, height: 800), false),
            ("Music", "/System/Applications/Music.app", "Music", CGSize(width: 1100, height: 720), false),
            ("Preview", "/System/Applications/Preview.app", "Quarterly report.pdf", CGSize(width: 800, height: 1000), true),
        ]
        var windows: [SwitcherWindow] = []
        for (i, s) in samples.enumerated() {
            let id = CGWindowID(5000 + i)
            windows.append(SwitcherWindow(element: el, pid: 1, appName: s.0, title: s.2, icon: icon(s.1), minimized: s.4,
                                          windowID: s.4 ? nil : id, frame: CGRect(origin: .zero, size: s.3)))
            // One window still waiting for its picture shows the app icon.
            if !s.4 && i != 5 {
                let fit = ThumbnailStore.captureSize(window: s.3, box: CGSize(width: 220, height: 138), scale: 1)
                ThumbnailStore.shared.setImage(previewPlaceholder(size: fit, hue: CGFloat(i) / 7, title: s.0, dark: i == 3), for: id)
            }
        }
        let backdrop = LinearGradient(colors: [Color(red: 0.25, green: 0.35, blue: 0.6), Color(red: 0.55, green: 0.35, blue: 0.55)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)

        // ⌥Tab grid
        let model = SwitcherModel()
        model.windows = windows
        model.selection = 1
        let layout = PreviewGridLayout.make(count: windows.count, bounds: CGSize(width: 1512, height: 900))
        model.layout = layout
        let margin: CGFloat = 40
        Snapshot.render(ZStack { backdrop; SwitcherView(model: model).frame(width: layout.panelSize.width, height: layout.panelSize.height) },
                        size: CGSize(width: layout.panelSize.width + margin * 2, height: layout.panelSize.height + margin * 2),
                        to: "\(directory)/previews-1.png")

        // Dock panel, thumbnails
        let dock = DockPreviewModel()
        dock.appName = "Safari"
        dock.appIcon = icon("/Applications/Safari.app")
        dock.windows = Array(windows.prefix(3)).enumerated().map { i, w in
            SwitcherWindow(element: el, pid: 1, appName: "Safari", title: ["Apple Developer", "Swift.org — Documentation", "Start Page"][i],
                           icon: w.icon, minimized: false, windowID: w.windowID, frame: w.frame)
        }
        let dockLayout = DockPreviews.gridLayout(count: 3, orientation: .bottom, bounds: CGSize(width: 1512, height: 900))
        dock.layout = dockLayout
        dock.hovered = 0
        Snapshot.render(ZStack { backdrop; DockPreviewView(model: dock).frame(width: dockLayout.panelSize.width, height: dockLayout.panelSize.height) },
                        size: CGSize(width: dockLayout.panelSize.width + margin * 2, height: dockLayout.panelSize.height + margin * 2),
                        to: "\(directory)/previews-2.png")

        // Dock panel, titles only
        let titles = DockPreviewModel()
        titles.appName = "Preview"
        titles.appIcon = icon("/System/Applications/Preview.app")
        titles.windows = ["Quarterly report.pdf", "Screenshot 2026-11-14 at 10.42.13.png", "Floor plan.pdf"].enumerated().map { i, t in
            SwitcherWindow(element: el, pid: 1, appName: "Preview", title: t, icon: nil, minimized: i == 2)
        }
        titles.hovered = 1
        let listSize = DockPreviews.listSize(count: 3, bounds: CGSize(width: 1512, height: 900))
        Snapshot.render(ZStack { backdrop; DockPreviewView(model: titles).frame(width: listSize.width, height: listSize.height) },
                        size: CGSize(width: listSize.width + margin * 2, height: listSize.height + margin * 2),
                        to: "\(directory)/previews-3.png")

        // Settings
        UserDefaults.standard.register(defaults: [Keys.switcherEnabled: true])
        Snapshot.render(Form { WindowPreviewSection() }.formStyle(.grouped).background(.regularMaterial),
                        size: CGSize(width: 400, height: 620), to: "\(directory)/previews-4.png")
        AppState.shared.accessibilityGranted = true
        AppState.shared.tab = .windows
        Conflicts.suppressed = true
        Snapshot.render(WindowsTab().formStyle(.grouped).scrollContentBackground(.hidden).background(.regularMaterial),
                        size: CGSize(width: 400, height: 1300), to: "\(directory)/previews-5.png")

        // Smaller screen: the grid shrinks.
        let crowded = SwitcherModel()
        crowded.windows = windows + windows + windows.prefix(4)
        crowded.selection = 8
        let smallLayout = PreviewGridLayout.make(count: crowded.windows.count, bounds: CGSize(width: 1024, height: 640))
        crowded.layout = smallLayout
        Snapshot.render(ZStack { backdrop; SwitcherView(model: crowded).frame(width: smallLayout.panelSize.width, height: smallLayout.panelSize.height) },
                        size: CGSize(width: 1024, height: 640), to: "\(directory)/previews-6.png")
    }
}
