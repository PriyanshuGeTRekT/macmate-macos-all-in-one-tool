import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// What the Dock preview panel shows.
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var windows: [SwitcherWindow] = []
    /// Thumbnail grid when Screen Recording is allowed; nil shows a list of titles.
    @Published var layout: PreviewGridLayout?
    @Published var hovered: Int?
}

/// Window previews above (or beside) Dock icons. The Dock reports which item is under the pointer
/// through Accessibility, so nothing runs until the pointer is actually on the Dock.
final class DockPreviews: ObservableObject {
    static let shared = DockPreviews()
    static let dockBundleID = "com.apple.dock"

    enum Orientation: String {
        case bottom, left, right

        init(dockValue: String?) { self = Orientation(rawValue: dockValue ?? "") ?? .bottom }

        static var current: Orientation {
            Orientation(dockValue: UserDefaults(suiteName: DockPreviews.dockBundleID)?.string(forKey: "orientation"))
        }
    }

    /// The Dock item under the pointer.
    struct Hover: Equatable {
        let pid: pid_t
        /// Icon frame in Cocoa coordinates.
        let iconFrame: CGRect
    }

    let model = DockPreviewModel()

    @Published private(set) var attached = false

    static let hoverDelay: TimeInterval = 0.4
    static let switchDelay: TimeInterval = 0.12
    static let leaveGrace: TimeInterval = 0.25
    static let titleRowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 28

    private var observer: AXObserver?
    private var cancellables: [AnyCancellable] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lastEnabled: Bool?

    // Hover state (main thread).
    private var hoveredPid: pid_t?
    private var dockFrame: CGRect = .zero
    private var shown: Hover?
    private var orientation: Orientation = .bottom
    private var pendingShow: DispatchWorkItem?
    private var generation = 0
    private var panel: PreviewPanel?
    private var trackTimer: Timer?
    private var outsideSince: TimeInterval?
    private var clickMonitor: Any?

    func start() {
        UserDefaults.standard.register(defaults: [Keys.previewsSwitcher: false, Keys.previewsDock: false])
        AppState.shared.$accessibilityGranted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.update() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: Keys.previewsDock)
                if enabled != self.lastEnabled { self.update() }
            }
            .store(in: &cancellables)
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == DockPreviews.dockBundleID else { return }
            // The Dock restarted: its old elements are gone. Give the new one a moment to build its items.
            self?.detach()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.update() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == DockPreviews.dockBundleID else { return }
            self?.detach()
        })
    }

    /// Attaches or detaches the Dock observer to match the setting and the Accessibility grant.
    func update() {
        let enabled = UserDefaults.standard.bool(forKey: Keys.previewsDock)
        lastEnabled = enabled
        let want = enabled && Permissions.accessibility
        if want, observer == nil { attach(retries: 3) }
        if !want, observer != nil { detach() }
    }

    // MARK: Dock observer

    private func attach(retries: Int) {
        guard observer == nil, UserDefaults.standard.bool(forKey: Keys.previewsDock), Permissions.accessibility,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: DockPreviews.dockBundleID).first else { return }
        let pid = dock.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let children: [AXUIElement] = AX.attribute(app, kAXChildrenAttribute) ?? []
        let lists = children.filter { (AX.attribute($0, kAXRoleAttribute) as String?) == (kAXListRole as String) }
        guard !lists.isEmpty else {
            if retries > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.attach(retries: retries - 1) } }
            return
        }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<DockPreviews>.fromOpaque(refcon).takeUnretainedValue().selectionChanged(in: element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for list in lists {
            AXUIElementSetMessagingTimeout(list, 0.25)
            AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        attached = true
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        attached = false
        hoveredPid = nil
        hide()
    }

    /// The Dock's list changed its selection: the pointer moved onto another item, or off the Dock.
    private func selectionChanged(in list: AXUIElement) {
        if let f = AX.frame(of: list) { dockFrame = ScreenGeometry.cocoaRect(fromAX: f) }
        let selected: [AXUIElement] = AX.attribute(list, kAXSelectedChildrenAttribute) ?? []
        guard let item = selected.first,
              (AX.attribute(item, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let url = (AX.attribute(item, kAXURLAttribute) as NSURL?) as URL?,
              let frame = AX.frame(of: item),
              let app = NSWorkspace.shared.runningApplications.first(where: { DockPreviews.sameApp(itemURL: url, bundleURL: $0.bundleURL) })
        else {
            hoveredPid = nil
            pendingShow?.cancel()
            pendingShow = nil
            return
        }
        let hover = Hover(pid: app.processIdentifier, iconFrame: ScreenGeometry.cocoaRect(fromAX: frame))
        hoveredPid = hover.pid
        if let shown, shown.pid == hover.pid, panel?.isVisible == true {
            self.shown = hover
            return
        }
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.load(hover) }
        pendingShow = work
        let visible = panel?.isVisible == true
        DispatchQueue.main.asyncAfter(deadline: .now() + (visible ? DockPreviews.switchDelay : DockPreviews.hoverDelay), execute: work)
    }

    /// True when a Dock item's URL and a running app's bundle URL name the same app.
    static func sameApp(itemURL: URL, bundleURL: URL?) -> Bool {
        guard let bundleURL, itemURL.isFileURL, bundleURL.isFileURL else { return false }
        func norm(_ u: URL) -> String {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            return p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
        }
        return norm(itemURL) == norm(bundleURL)
    }

    // MARK: Showing

    private func load(_ hover: Hover) {
        generation += 1
        let gen = generation
        inBackground {
            let windows = WindowSwitcher.listWindows(pid: hover.pid)
            onMain {
                guard gen == self.generation, self.hoveredPid == hover.pid else { return }
                if windows.isEmpty { self.hide(); return }
                self.show(hover, windows: windows)
            }
        }
    }

    private func show(_ hover: Hover, windows: [SwitcherWindow]) {
        let app = NSRunningApplication(processIdentifier: hover.pid)
        orientation = .current
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: hover.iconFrame.midX, y: hover.iconFrame.midY)) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let thumbnails = ThumbnailStore.permitted
        let size: CGSize
        if thumbnails {
            let layout = DockPreviews.gridLayout(count: windows.count, orientation: orientation, bounds: area.size)
            model.layout = layout
            size = layout.panelSize
        } else {
            model.layout = nil
            size = DockPreviews.listSize(count: windows.count, bounds: area.size)
        }
        model.appName = app?.localizedName ?? windows[0].appName
        model.appIcon = app?.icon ?? windows[0].icon
        model.windows = windows
        model.hovered = nil
        shown = hover

        let p = panel ?? makePanel()
        panel = p
        let frame = DockPreviews.panelFrame(icon: hover.iconFrame, size: size, orientation: orientation, screen: screen?.frame ?? area)
        p.setFrame(frame, display: true)
        p.orderFrontRegardless()
        startTracking()

        if let layout = model.layout {
            ThumbnailStore.shared.capture(windows.compactMap { w in
                guard let id = w.windowID, !w.minimized else { return nil }
                return ThumbnailStore.Request(windowID: id, windowSize: w.frame.size, displaySize: layout.thumbnail)
            })
        }
    }

    func hide() {
        pendingShow?.cancel()
        pendingShow = nil
        generation += 1
        shown = nil
        trackTimer?.invalidate()
        trackTimer = nil
        outsideSince = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
        model.windows = []
        model.hovered = nil
    }

    private func pick(_ index: Int) {
        guard model.windows.indices.contains(index) else { return }
        let w = model.windows[index]
        hide()
        WindowSwitcher.focus(w)
    }

    private func makePanel() -> PreviewPanel {
        let p = PreviewPanel()
        let host = PreviewHostingView(rootView: DockPreviewView(model: model) { [weak self] i in self?.pick(i) })
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    /// While the panel is up, a light timer watches the pointer; it stops as soon as the panel hides.
    private func startTracking() {
        outsideSince = nil
        if trackTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.track() }
            t.tolerance = 0.03
            RunLoop.main.add(t, forMode: .common)
            trackTimer = t
        }
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                // Clicks inside the panel arrive as local events, so any global click is elsewhere.
                self?.hide()
            }
        }
    }

    private func track() {
        guard let panel, panel.isVisible, let shown else { hide(); return }
        let mouse = NSEvent.mouseLocation
        let onDock = hoveredPid != nil && (dockFrame.isEmpty || dockFrame.insetBy(dx: -4, dy: -4).contains(mouse))
        let keep = onDock || DockPreviews.keepZones(icon: shown.iconFrame, panel: panel.frame, orientation: orientation).contains { $0.contains(mouse) }
        let now = ProcessInfo.processInfo.systemUptime
        if keep { outsideSince = nil; return }
        if outsideSince == nil { outsideSince = now }
        if let since = outsideSince, now - since >= DockPreviews.leaveGrace { hide() }
    }

    // MARK: Geometry (pure, tested)

    static func gridLayout(count: Int, orientation: Orientation, bounds: CGSize) -> PreviewGridLayout {
        PreviewGridLayout.make(count: count, maxColumns: orientation == .bottom ? 5 : 2, ideal: CGSize(width: 200, height: 125),
                               minimumWidth: 110, padding: 10, header: headerHeight + 8,
                               bounds: bounds, widthShare: 0.9, heightShare: 0.8)
    }

    static func listSize(count: Int, bounds: CGSize) -> CGSize {
        let rows = min(max(count, 1), max(1, Int((bounds.height * 0.6 - headerHeight - 20) / titleRowHeight)))
        return CGSize(width: 300, height: 16 + headerHeight + CGFloat(rows) * titleRowHeight)
    }

    /// Where the panel goes: above the icon for a bottom Dock, beside it for a side Dock, kept on screen.
    static func panelFrame(icon: CGRect, size: CGSize, orientation: Orientation, screen: CGRect,
                           gap: CGFloat = 10, margin: CGFloat = 8) -> CGRect {
        var origin: CGPoint
        switch orientation {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + gap)
        case .left: origin = CGPoint(x: icon.maxX + gap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - gap - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - margin - size.width)
        origin.y = min(max(origin.y, screen.minY + margin), screen.maxY - margin - size.height)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }

    /// Areas the pointer may be in without the panel closing: the icon, the panel, and the gap between them.
    static func keepZones(icon: CGRect, panel: CGRect, orientation: Orientation) -> [CGRect] {
        let bridge: CGRect
        switch orientation {
        case .bottom:
            bridge = CGRect(x: min(icon.minX, panel.minX), y: icon.midY,
                            width: max(icon.maxX, panel.maxX) - min(icon.minX, panel.minX), height: max(0, panel.minY - icon.midY) + 2)
        case .left:
            bridge = CGRect(x: icon.midX, y: min(icon.minY, panel.minY),
                            width: max(0, panel.minX - icon.midX) + 2, height: max(icon.maxY, panel.maxY) - min(icon.minY, panel.minY))
        case .right:
            bridge = CGRect(x: panel.maxX - 2, y: min(icon.minY, panel.minY),
                            width: max(0, icon.midX - panel.maxX) + 2, height: max(icon.maxY, panel.maxY) - min(icon.minY, panel.minY))
        }
        return [icon.insetBy(dx: -4, dy: -4), panel.insetBy(dx: -6, dy: -6), bridge]
    }
}

// MARK: - View

struct DockPreviewView: View {
    @ObservedObject var model: DockPreviewModel
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let icon = model.appIcon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18)
                }
                Text(model.appName).font(.headline).lineLimit(1)
                Spacer(minLength: 8)
                Text(model.windows.count == 1 ? "1 window" : "\(model.windows.count) windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: DockPreviews.headerHeight)
            .padding(.top, 8)

            if let layout = model.layout {
                PreviewGrid(windows: model.windows, layout: layout, selection: model.hovered, showsAppIcon: false,
                            onHover: { i, inside in
                                if inside { model.hovered = i } else if model.hovered == i { model.hovered = nil }
                            }, onPick: onPick)
            } else {
                titles
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }

    private var titles: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(model.windows.enumerated()), id: \.element.id) { i, w in
                    HStack(spacing: 8) {
                        Image(systemName: w.minimized ? "minus.rectangle" : "macwindow")
                            .foregroundStyle(model.hovered == i ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .frame(width: 18)
                        Text(w.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if w.minimized {
                            Text("Minimized").font(.caption)
                                .foregroundStyle(model.hovered == i ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: DockPreviews.titleRowHeight)
                    .foregroundStyle(model.hovered == i ? .white : .primary)
                    .background(model.hovered == i ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                    .onHover { model.hovered = $0 ? i : (model.hovered == i ? nil : model.hovered) }
                    .onTapGesture { onPick(i) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }
}
