import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum TileAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case maximize, almostMaximize, center, restore, nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .leftThird: return "Left third"
        case .centerThird: return "Center third"
        case .rightThird: return "Right third"
        case .leftTwoThirds: return "Left two thirds"
        case .rightTwoThirds: return "Right two thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost maximize"
        case .center: return "Center"
        case .restore: return "Restore"
        case .nextDisplay: return "Next display"
        }
    }

    /// Default shortcut: ⌃⌥ plus this key.
    var keyCode: Int {
        switch self {
        case .leftHalf: return kVK_LeftArrow
        case .rightHalf: return kVK_RightArrow
        case .topHalf: return kVK_UpArrow
        case .bottomHalf: return kVK_DownArrow
        case .topLeft: return kVK_ANSI_U
        case .topRight: return kVK_ANSI_I
        case .bottomLeft: return kVK_ANSI_J
        case .bottomRight: return kVK_ANSI_K
        case .leftThird: return kVK_ANSI_D
        case .centerThird: return kVK_ANSI_F
        case .rightThird: return kVK_ANSI_G
        case .leftTwoThirds: return kVK_ANSI_E
        case .rightTwoThirds: return kVK_ANSI_T
        case .maximize: return kVK_Return
        case .almostMaximize: return kVK_ANSI_M
        case .center: return kVK_ANSI_C
        case .restore: return kVK_Delete
        case .nextDisplay: return kVK_ANSI_N
        }
    }

    var keyLabel: String {
        switch self {
        case .leftHalf: return "←"
        case .rightHalf: return "→"
        case .topHalf: return "↑"
        case .bottomHalf: return "↓"
        case .topLeft: return "U"
        case .topRight: return "I"
        case .bottomLeft: return "J"
        case .bottomRight: return "K"
        case .leftThird: return "D"
        case .centerThird: return "F"
        case .rightThird: return "G"
        case .leftTwoThirds: return "E"
        case .rightTwoThirds: return "T"
        case .maximize: return "↩"
        case .almostMaximize: return "M"
        case .center: return "C"
        case .restore: return "⌫"
        case .nextDisplay: return "N"
        }
    }

    /// Target as fractions of the screen's usable area: x, y (from the top), width, height.
    var unitRect: CGRect? {
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .almostMaximize: return CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        case .center, .restore, .nextDisplay: return nil
        }
    }
}

/// Screen geometry in Accessibility coordinates (origin at the top-left of the primary display).
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func axRect(fromCocoa r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaRect(fromAX r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Usable areas (no menu bar or Dock) of every screen, in AX coordinates.
    static var usableAreas: [CGRect] { NSScreen.screens.map { axRect(fromCocoa: $0.visibleFrame) } }

    static func screenIndex(containing r: CGRect) -> Int {
        let frames = NSScreen.screens.map { axRect(fromCocoa: $0.frame) }
        var best = 0
        var bestArea: CGFloat = -1
        for (i, f) in frames.enumerated() {
            let inter = f.intersection(r)
            let area = inter.isNull ? 0 : inter.width * inter.height
            if area > bestArea { bestArea = area; best = i }
        }
        return best
    }

    static func target(for unit: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        var r = CGRect(x: area.minX + unit.minX * area.width, y: area.minY + unit.minY * area.height,
                       width: unit.width * area.width, height: unit.height * area.height)
        if gap > 0 {
            // Full gap at screen edges, half a gap between neighbouring tiles.
            let l = unit.minX < 0.001 ? gap : gap / 2
            let t = unit.minY < 0.001 ? gap : gap / 2
            let rt = unit.maxX > 0.999 ? gap : gap / 2
            let b = unit.maxY > 0.999 ? gap : gap / 2
            r = CGRect(x: r.minX + l, y: r.minY + t, width: r.width - l - rt, height: r.height - t - b)
        }
        return r.integral
    }
}

final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    @Published private(set) var lastMessage = ""
    /// The app the user was in before opening MacMate's panel, so the tile buttons act on it.
    private(set) var lastExternalApp: NSRunningApplication?

    private var restoreFrames: [String: CGRect] = [:]
    private var lastAction: (key: String, action: TileAction, frame: CGRect, step: Int)?
    private let snapper = DragSnapper()

    func start() {
        lastExternalApp = NSWorkspace.shared.frontmostApplication
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != getpid() else { return }
            self?.lastExternalApp = app
        }
        applySettings()
    }

    func applySettings() {
        let d = UserDefaults.standard
        HotKeyCenter.shared.unregister(group: "tile")
        if d.bool(forKey: Keys.tileHotkeys) {
            let mods = HotKeyCenter.control | HotKeyCenter.option
            for action in TileAction.allCases {
                HotKeyCenter.shared.register(group: "tile", keyCode: action.keyCode, modifiers: mods) { [weak self] in
                    self?.perform(action)
                }
            }
        }
        snapper.setEnabled(d.bool(forKey: Keys.tileDragSnap))
    }

    /// True when macOS's own "drag windows to screen edges to tile" is switched on.
    static var nativeEdgeTilingEnabled: Bool {
        let v = UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool
        return v ?? true
    }

    // MARK: Actions

    func perform(_ action: TileAction) {
        guard Permissions.accessibility else {
            lastMessage = "Grant Accessibility access first"
            Permissions.requestAccessibility()
            return
        }
        guard let window = focusedWindow(), let current = AX.frame(of: window) else {
            lastMessage = "No window to move"
            return
        }
        let key = AX.identity(of: window)
        let gap = CGFloat(UserDefaults.standard.integer(forKey: Keys.tileGap))
        let areas = ScreenGeometry.usableAreas
        guard !areas.isEmpty else { return }
        let screen = min(ScreenGeometry.screenIndex(containing: current), areas.count - 1)
        let area = areas[screen]
        var target: CGRect

        switch action {
        case .restore:
            guard let saved = restoreFrames[key] else { lastMessage = "Nothing to restore"; return }
            AX.setFrame(window, saved)
            restoreFrames[key] = nil
            lastAction = nil
            lastMessage = "Restored"
            return
        case .center:
            target = CGRect(x: area.midX - current.width / 2, y: area.midY - current.height / 2,
                            width: min(current.width, area.width), height: min(current.height, area.height)).integral
        case .nextDisplay:
            guard areas.count > 1 else { lastMessage = "Only one display"; return }
            let next = areas[(screen + 1) % areas.count]
            // Keep the same relative position and size on the other display.
            let fx = (current.minX - area.minX) / area.width, fy = (current.minY - area.minY) / area.height
            let fw = min(1, current.width / area.width), fh = min(1, current.height / area.height)
            target = CGRect(x: next.minX + fx * next.width, y: next.minY + fy * next.height,
                            width: fw * next.width, height: fh * next.height).integral
        default:
            guard var unit = action.unitRect else { return }
            // Pressing the same half again cycles 1/2 → 2/3 → 1/3, like Rectangle.
            var step = 0
            if action == .leftHalf || action == .rightHalf,
               let last = lastAction, last.key == key, last.action == action, AX.close(last.frame, current) {
                step = (last.step + 1) % 3
                let w: CGFloat = [0.5, 2.0 / 3, 1.0 / 3][step]
                unit = CGRect(x: action == .leftHalf ? 0 : 1 - w, y: 0, width: w, height: 1)
            }
            target = ScreenGeometry.target(for: unit, in: area, gap: gap)
            defer { lastAction = (key, action, AX.frame(of: window) ?? target, step) }
            if restoreFrames[key] == nil { restoreFrames[key] = current }
            AX.setFrame(window, target)
            lastMessage = action.title
            return
        }
        if restoreFrames[key] == nil { restoreFrames[key] = current }
        AX.setFrame(window, target)
        lastMessage = action.title
    }

    func rememberRestoreFrame(_ frame: CGRect, for window: AXUIElement) {
        let key = AX.identity(of: window)
        if restoreFrames[key] == nil { restoreFrames[key] = frame }
    }

    private func focusedWindow() -> AXUIElement? {
        var app = NSWorkspace.shared.frontmostApplication
        if app?.processIdentifier == getpid() { app = lastExternalApp }
        guard let pid = app?.processIdentifier else { return nil }
        let element = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = AX.attribute(element, kAXFocusedWindowAttribute) { return w }
        if let w: AXUIElement = AX.attribute(element, kAXMainWindowAttribute) { return w }
        let all: [AXUIElement]? = AX.attribute(element, kAXWindowsAttribute)
        return all?.first
    }
}

/// Thin wrappers over the Accessibility C API.
enum AX {
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &s) == .success,
              let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    static func setFrame(_ window: AXUIElement, _ rect: CGRect) {
        var origin = rect.origin, size = rect.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Size, move, size again: the first resize can be clamped by the old position.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
    }

    static func identity(of window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        return "\(pid):\(CFHash(window))"
    }

    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 12) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance &&
            abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    /// The window that contains whatever is under the given AX-coordinate point.
    static func window(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        let role: String? = attribute(hit, kAXRoleAttribute)
        if role == (kAXWindowRole as String) { return hit }
        return attribute(hit, kAXWindowAttribute)
    }
}

/// Windows-style snapping: drag a window to a screen edge or corner to tile it.
final class DragSnapper {
    private var monitors: [Any] = []
    private var window: AXUIElement?
    private var initialFrame: CGRect?
    private var moving = false
    private var lookedUp = false
    private var lastCheck: TimeInterval = 0
    private var zone: TileAction?
    private lazy var overlay = SnapOverlay()

    func setEnabled(_ on: Bool) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        guard on else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in self?.reset() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in self?.dragged() }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in self?.released() }) { monitors.append(m) }
    }

    private func reset() {
        window = nil
        initialFrame = nil
        moving = false
        lookedUp = false
        zone = nil
        overlay.hide()
    }

    private func dragged() {
        guard Permissions.accessibility else { return }
        let mouse = NSEvent.mouseLocation
        if !lookedUp {
            lookedUp = true
            let p = CGPoint(x: mouse.x, y: ScreenGeometry.primaryHeight - mouse.y)
            if let w = AX.window(at: p) {
                window = w
                initialFrame = AX.frame(of: w)
            }
        }
        guard let window, let initialFrame else { return }
        if !moving {
            let t = ProcessInfo.processInfo.systemUptime
            guard t - lastCheck > 0.06 else { return }
            lastCheck = t
            guard let now = AX.frame(of: window) else { return }
            let sameSize = abs(now.width - initialFrame.width) < 2 && abs(now.height - initialFrame.height) < 2
            let moved = abs(now.minX - initialFrame.minX) > 3 || abs(now.minY - initialFrame.minY) > 3
            if !sameSize { self.window = nil; return } // a resize, not a move
            if moved { moving = true } else { return }
        }
        let (newZone, screen) = DragSnapper.zone(at: mouse)
        if newZone != zone {
            zone = newZone
            if let z = newZone, let unit = z.unitRect, let screen {
                let gap = CGFloat(UserDefaults.standard.integer(forKey: Keys.tileGap))
                let ax = ScreenGeometry.target(for: unit, in: ScreenGeometry.axRect(fromCocoa: screen.visibleFrame), gap: gap)
                overlay.show(at: ScreenGeometry.cocoaRect(fromAX: ax))
            } else {
                overlay.hide()
            }
        }
    }

    private func released() {
        defer { reset() }
        guard moving, let window, let zone, let unit = zone.unitRect, let initialFrame else { return }
        let (_, screen) = DragSnapper.zone(at: NSEvent.mouseLocation)
        guard let screen else { return }
        let gap = CGFloat(UserDefaults.standard.integer(forKey: Keys.tileGap))
        let target = ScreenGeometry.target(for: unit, in: ScreenGeometry.axRect(fromCocoa: screen.visibleFrame), gap: gap)
        WindowManager.shared.rememberRestoreFrame(initialFrame, for: window)
        // Let the app finish its own drag handling before resizing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { AX.setFrame(window, target) }
    }

    /// Which tile the cursor is asking for, given a Cocoa-coordinate mouse location.
    static func zone(at mouse: CGPoint) -> (TileAction?, NSScreen?) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }) else { return (nil, nil) }
        let f = screen.frame
        let edge: CGFloat = 6
        let corner = f.height * 0.22
        let nearLeft = mouse.x <= f.minX + edge, nearRight = mouse.x >= f.maxX - edge
        let nearTop = mouse.y >= f.maxY - edge, nearBottom = mouse.y <= f.minY + edge
        if nearLeft {
            if mouse.y >= f.maxY - corner { return (.topLeft, screen) }
            if mouse.y <= f.minY + corner { return (.bottomLeft, screen) }
            return (.leftHalf, screen)
        }
        if nearRight {
            if mouse.y >= f.maxY - corner { return (.topRight, screen) }
            if mouse.y <= f.minY + corner { return (.bottomRight, screen) }
            return (.rightHalf, screen)
        }
        if nearTop { return (.maximize, screen) }
        if nearBottom {
            let third = f.width / 3
            if mouse.x < f.minX + third { return (.leftThird, screen) }
            if mouse.x > f.maxX - third { return (.rightThird, screen) }
            return (.centerThird, screen)
        }
        return (nil, screen)
    }
}

/// The translucent preview shown while dragging toward a snap zone.
final class SnapOverlay {
    private var panel: NSPanel?

    func show(at frame: CGRect) {
        let p = panel ?? makePanel()
        panel = p
        if p.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().setFrame(frame, display: true)
            }
        } else {
            p.setFrame(frame, display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                p.animator().alphaValue = 1
            }
        }
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 12
        p.contentView = v
        return p
    }
}
