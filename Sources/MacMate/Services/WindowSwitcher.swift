import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

struct SwitcherWindow: Identifiable {
    let id = UUID()
    let element: AXUIElement
    let pid: pid_t
    let appName: String
    let title: String
    let icon: NSImage?
    let minimized: Bool
    /// The window server's id, known for windows that are on screen. Used to capture a thumbnail.
    var windowID: CGWindowID? = nil
    /// Frame in Accessibility coordinates.
    var frame: CGRect = .zero
}

final class SwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
    /// Set when the switcher shows thumbnails; nil for the plain list.
    @Published var layout: PreviewGridLayout?
}

/// Sizes for a grid of window thumbnails (⌥Tab switcher and Dock previews).
struct PreviewGridLayout: Equatable {
    var columns: Int
    var rows: Int
    /// Rows that fit without scrolling.
    var visibleRows: Int
    var thumbnail: CGSize
    var cell: CGSize
    var spacing: CGFloat
    var padding: CGFloat
    var header: CGFloat
    var panelSize: CGSize

    static let labelHeight: CGFloat = 20
    static let labelGap: CGFloat = 6
    static let cellInset: CGFloat = 8

    /// - Parameters:
    ///   - count: number of windows
    ///   - bounds: usable size of the screen the grid appears on
    ///   - header: height of anything drawn above the grid inside the panel
    static func make(count: Int, maxColumns: Int = 5, ideal: CGSize = CGSize(width: 220, height: 138),
                     minimumWidth: CGFloat = 96, spacing: CGFloat = 8, padding: CGFloat = 14, header: CGFloat = 0,
                     bounds: CGSize, widthShare: CGFloat = 0.9, heightShare: CGFloat = 0.85) -> PreviewGridLayout {
        let n = max(1, count)
        let columns = max(1, min(n, maxColumns))
        let rows = (n + columns - 1) / columns
        let maxW = bounds.width * widthShare, maxH = bounds.height * heightShare
        let c = CGFloat(columns), r = CGFloat(rows)
        let cellExtraW = cellInset * 2
        let cellExtraH = cellInset * 2 + labelGap + labelHeight

        let widthScale = (maxW - padding * 2 - (c - 1) * spacing - c * cellExtraW) / (c * ideal.width)
        let heightScale = (maxH - padding * 2 - header - (r - 1) * spacing - r * cellExtraH) / (r * ideal.height)
        var scale = min(1, widthScale, heightScale)
        let minimumScale = minimumWidth / ideal.width
        if scale < minimumScale { scale = min(minimumScale, max(widthScale, 0.01)) }

        let thumb = CGSize(width: (ideal.width * scale).rounded(.down), height: (ideal.height * scale).rounded(.down))
        let cell = CGSize(width: thumb.width + cellExtraW, height: thumb.height + cellExtraH)
        // Rows beyond what fits scroll.
        var visible = rows
        while visible > 1, padding * 2 + header + CGFloat(visible) * cell.height + CGFloat(visible - 1) * spacing > maxH { visible -= 1 }
        let width = padding * 2 + c * cell.width + (c - 1) * spacing
        let height = padding * 2 + header + CGFloat(visible) * cell.height + CGFloat(visible - 1) * spacing
        return PreviewGridLayout(columns: columns, rows: rows, visibleRows: visible, thumbnail: thumb, cell: cell,
                                 spacing: spacing, padding: padding, header: header,
                                 panelSize: CGSize(width: width.rounded(.up), height: height.rounded(.up)))
    }

    /// Indices of the windows in each row.
    func indices(row: Int, count: Int) -> Range<Int> {
        let start = row * columns
        return start..<min(count, start + columns)
    }
}

/// Windows-style ⌥Tab: cycles through individual windows, not whole apps.
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private let active = Atomic(false)
    let model = SwitcherModel()
    private var panel: PreviewPanel?

    // Main-thread state while the window list is being built in the background.
    private var loading = false
    private var pendingDelta = 0
    private var pendingCommit = false
    private var generation = 0

    func start() {
        UserDefaults.standard.register(defaults: [Keys.previewsSwitcher: false, Keys.previewsDock: false])
        EventTapHub.shared.add { [weak self] type, event in self?.handle(type, event) ?? false }
    }

    // MARK: Tap thread

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        guard UserDefaults.standard.bool(forKey: Keys.switcherEnabled) else { return false }
        let flags = e.flags
        switch type {
        case .keyDown:
            let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
            let optionOnly = flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
            if code == kVK_Tab, optionOnly {
                let backwards = flags.contains(.maskShift)
                if active.get() {
                    DispatchQueue.main.async { self.move(backwards ? -1 : 1) }
                } else {
                    active.set(true)
                    DispatchQueue.main.async { self.open(backwards: backwards) }
                }
                return true
            }
            guard active.get() else { return false }
            switch code {
            case kVK_Escape:
                active.set(false)
                DispatchQueue.main.async { self.close() }
            case kVK_RightArrow:
                DispatchQueue.main.async { self.move(1) }
            case kVK_LeftArrow:
                DispatchQueue.main.async { self.move(-1) }
            case kVK_DownArrow:
                DispatchQueue.main.async { self.move(self.rowStep) }
            case kVK_UpArrow:
                DispatchQueue.main.async { self.move(-self.rowStep) }
            default:
                break
            }
            return true
        case .keyUp:
            return active.get()
        case .flagsChanged:
            if active.get(), !flags.contains(.maskAlternate) {
                active.set(false)
                DispatchQueue.main.async { self.commit() }
            }
            return false
        default:
            return false
        }
    }

    // MARK: Main thread

    /// ↑/↓ move a whole row in the grid and one item in the list.
    private var rowStep: Int { model.layout?.columns ?? 1 }

    private var previewsWanted: Bool {
        UserDefaults.standard.bool(forKey: Keys.previewsSwitcher) && ThumbnailStore.permitted
    }

    private func open(backwards: Bool) {
        generation += 1
        let gen = generation
        loading = true
        pendingDelta = 0
        pendingCommit = false
        // Asking every app for its windows can take a moment; never on the main thread.
        inBackground {
            let list = WindowSwitcher.listWindows()
            onMain {
                guard gen == self.generation else { return }
                self.loading = false
                guard !list.isEmpty else { self.active.set(false); return }
                let n = list.count
                let start = n > 1 ? (backwards ? n - 1 : 1) : 0
                self.model.windows = list
                self.model.selection = ((start + self.pendingDelta) % n + n) % n
                // The user may already have let go of ⌥ while the list was being built.
                if self.pendingCommit || !NSEvent.modifierFlags.contains(.option) {
                    self.active.set(false)
                    self.commit()
                    return
                }
                self.showPanel()
            }
        }
    }

    private func move(_ delta: Int) {
        if loading { pendingDelta += delta; return }
        let n = model.windows.count
        guard n > 0 else { return }
        model.selection = ((model.selection + delta) % n + n) % n
    }

    private func close() {
        generation += 1
        loading = false
        panel?.orderOut(nil)
        model.windows = []
    }

    private func commit() {
        if loading { pendingCommit = true; return }
        let target = model.windows.indices.contains(model.selection) ? model.windows[model.selection] : nil
        close()
        if let target { WindowSwitcher.focus(target) }
    }

    /// A thumbnail was clicked.
    private func pick(_ index: Int) {
        guard model.windows.indices.contains(index) else { return }
        model.selection = index
        active.set(false)
        commit()
    }

    /// Brings one window forward: unhides its app, un-minimizes it, raises it and activates the app.
    static func focus(_ w: SwitcherWindow) {
        let app = NSRunningApplication(processIdentifier: w.pid)
        if app?.isHidden == true { app?.unhide() }
        if w.minimized {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        app?.activate(options: [])
    }

    private func showPanel() {
        let p = panel ?? {
            let p = PreviewPanel()
            let host = PreviewHostingView(rootView: SwitcherView(model: model) { [weak self] i in self?.pick(i) })
            host.sizingOptions = []
            p.contentView = host
            return p
        }()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size: CGSize
        if previewsWanted {
            let layout = PreviewGridLayout.make(count: model.windows.count, bounds: area.size)
            model.layout = layout
            size = layout.panelSize
            ThumbnailStore.shared.capture(model.windows.compactMap { w in
                guard let id = w.windowID, !w.minimized else { return nil }
                return ThumbnailStore.Request(windowID: id, windowSize: w.frame.size, displaySize: layout.thumbnail)
            })
        } else {
            model.layout = nil
            let rows = min(model.windows.count, 12)
            size = CGSize(width: 560, height: CGFloat(rows) * 46 + 20)
        }
        p.setFrame(CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                          width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
    }

    // MARK: Window list

    /// A window as Accessibility reports it.
    struct AXWindow {
        let element: AXUIElement
        let frame: CGRect
        let title: String
        let minimized: Bool
    }

    /// A window as the window server reports it, front-most first.
    struct ServerWindow {
        let id: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let layer: Int
    }

    struct AppInfo {
        let name: String
        let icon: NSImage?
        let hidden: Bool
    }

    /// Every standard window of every regular app (or of one app), front-most first, minimized ones last.
    /// Safe to call from any thread.
    static func listWindows(pid only: pid_t? = nil) -> [SwitcherWindow] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && (only == nil || $0.processIdentifier == only)
        }
        var perApp: [pid_t: [AXWindow]] = [:]
        var info: [pid_t: AppInfo] = [:]
        for app in apps {
            let pid = app.processIdentifier
            info[pid] = AppInfo(name: app.localizedName ?? "App", icon: app.icon, hidden: app.isHidden)
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let wins: [AXUIElement] = AX.attribute(element, kAXWindowsAttribute) ?? []
            perApp[pid] = wins.compactMap { w in
                let subrole: String? = AX.attribute(w, kAXSubroleAttribute)
                guard subrole == nil || subrole == "AXStandardWindow" || subrole == "AXDialog" else { return nil }
                guard let frame = AX.frame(of: w), frame.width > 60, frame.height > 40 else { return nil }
                let title: String = AX.attribute(w, kAXTitleAttribute) ?? ""
                let minimized: Bool = (AX.attribute(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
                return AXWindow(element: w, frame: frame, title: title, minimized: minimized)
            }
        }
        return assemble(ax: perApp, server: serverWindows(), apps: info, order: apps.map(\.processIdentifier))
    }

    /// On-screen windows from the window server, in stacking order.
    static func serverWindows() -> [ServerWindow] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return ServerWindow(id: id, pid: pid, bounds: bounds, layer: (entry[kCGWindowLayer as String] as? Int) ?? 0)
        }
    }

    /// Joins the two views of the world: the window server knows stacking order and ids, Accessibility
    /// knows titles and can raise windows. Matched by owner and frame.
    static func assemble(ax: [pid_t: [AXWindow]], server: [ServerWindow], apps: [pid_t: AppInfo], order: [pid_t]) -> [SwitcherWindow] {
        var used: [pid_t: Set<Int>] = [:]
        var result: [SwitcherWindow] = []
        func add(_ w: AXWindow, _ pid: pid_t, id: CGWindowID?) {
            let app = apps[pid]
            let name = app?.name ?? "App"
            result.append(SwitcherWindow(element: w.element, pid: pid, appName: name, title: w.title.isEmpty ? name : w.title,
                                         icon: app?.icon, minimized: w.minimized, windowID: id, frame: w.frame))
        }
        for s in server where s.layer == 0 {
            guard let wins = ax[s.pid] else { continue }
            let taken = used[s.pid] ?? []
            if let i = wins.indices.first(where: { !taken.contains($0) && !wins[$0].minimized && AX.close(wins[$0].frame, s.bounds, tolerance: 4) }) {
                used[s.pid, default: []].insert(i)
                add(wins[i], s.pid, id: s.id)
            }
        }
        // Windows of hidden apps are open but off screen.
        for pid in order where apps[pid]?.hidden == true {
            for (i, w) in (ax[pid] ?? []).enumerated() where !(used[pid]?.contains(i) ?? false) && !w.minimized {
                used[pid, default: []].insert(i)
                add(w, pid, id: nil)
            }
        }
        for pid in order {
            for (i, w) in (ax[pid] ?? []).enumerated() where !(used[pid]?.contains(i) ?? false) && w.minimized {
                add(w, pid, id: nil)
            }
        }
        return result
    }
}

// MARK: - Views

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var onPick: (Int) -> Void = { _ in }

    var body: some View {
        Group {
            if let layout = model.layout {
                PreviewGrid(windows: model.windows, layout: layout, selection: model.selection, showsAppIcon: true, onPick: onPick)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.windows.enumerated()), id: \.element.id) { index, w in
                        HStack(spacing: 12) {
                            if let icon = w.icon {
                                Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                Text(w.minimized ? "\(w.appName) — minimized" : w.appName)
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(index == model.selection ? Color.accentColor.opacity(0.85) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(index == model.selection ? .white : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(index) }
                        .id(index)
                    }
                }
                .padding(10)
            }
            .onChange(of: model.selection) { _, new in proxy.scrollTo(new, anchor: .center) }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.1)))
    }
}

/// Rows of window thumbnails with the app icon and title under each, the selected one in the accent color.
struct PreviewGrid: View {
    let windows: [SwitcherWindow]
    let layout: PreviewGridLayout
    let selection: Int?
    var showsAppIcon = true
    var onHover: ((Int, Bool) -> Void)? = nil
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: layout.spacing) {
                    ForEach(0..<layout.rows, id: \.self) { row in
                        HStack(spacing: layout.spacing) {
                            ForEach(layout.indices(row: row, count: windows.count), id: \.self) { i in
                                cell(i).id(i)
                            }
                        }
                    }
                }
                .padding(layout.padding)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(layout.visibleRows >= layout.rows)
            .onChange(of: selection) { _, new in
                if let new, layout.visibleRows < layout.rows { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) } }
            }
            .onAppear { if let selection, layout.visibleRows < layout.rows { proxy.scrollTo(selection, anchor: .center) } }
        }
    }

    private func cell(_ i: Int) -> some View {
        let w = windows[i]
        let selected = i == selection
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(spacing: PreviewGridLayout.labelGap) {
            PreviewThumbnailView(window: w, size: layout.thumbnail)
            HStack(spacing: 5) {
                if showsAppIcon, let icon = w.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                }
                Text(w.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: layout.thumbnail.width, minHeight: PreviewGridLayout.labelHeight, maxHeight: PreviewGridLayout.labelHeight)
        }
        .padding(PreviewGridLayout.cellInset)
        .frame(width: layout.cell.width, height: layout.cell.height)
        .background(selected ? Color.accentColor.opacity(0.22) : .clear, in: shape)
        .overlay(shape.strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
        .contentShape(shape)
        .onTapGesture { onPick(i) }
        .onHover { inside in onHover?(i, inside) }
        .help(w.minimized ? "\(w.title) — minimized" : w.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(w.appName), \(w.title)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
