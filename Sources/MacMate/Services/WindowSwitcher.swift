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
}

final class SwitcherModel: ObservableObject {
    @Published var windows: [SwitcherWindow] = []
    @Published var selection = 0
}

/// Windows-style ⌥Tab: cycles through individual windows, not whole apps.
final class WindowSwitcher {
    static let shared = WindowSwitcher()

    private let active = Atomic(false)
    private let model = SwitcherModel()
    private var panel: NSPanel?

    func start() {
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
            case kVK_DownArrow, kVK_RightArrow:
                DispatchQueue.main.async { self.move(1) }
            case kVK_UpArrow, kVK_LeftArrow:
                DispatchQueue.main.async { self.move(-1) }
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

    private func open(backwards: Bool) {
        let list = WindowSwitcher.listWindows()
        guard !list.isEmpty else { active.set(false); return }
        model.windows = list
        model.selection = list.count > 1 ? (backwards ? list.count - 1 : 1) : 0
        // The user may already have let go of ⌥ while the list was being built.
        if !NSEvent.modifierFlags.contains(.option) {
            active.set(false)
            commit()
            return
        }
        showPanel()
    }

    private func move(_ delta: Int) {
        let n = model.windows.count
        guard n > 0 else { return }
        model.selection = (model.selection + delta + n) % n
    }

    private func close() {
        panel?.orderOut(nil)
    }

    private func commit() {
        close()
        guard model.windows.indices.contains(model.selection) else { return }
        let w = model.windows[model.selection]
        if w.minimized {
            AXUIElementSetAttributeValue(w.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
    }

    private func showPanel() {
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .popUpMenu
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: SwitcherView(model: model))
            return p
        }()
        panel = p
        let rows = min(model.windows.count, 12)
        let size = CGSize(width: 560, height: CGFloat(rows) * 46 + 20)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        p.orderFrontRegardless()
    }

    /// Every standard window of every regular app, front-most first, minimized ones last.
    static func listWindows() -> [SwitcherWindow] {
        struct AXWin { let element: AXUIElement; let frame: CGRect; let title: String; let minimized: Bool; var used = false }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        var perApp: [pid_t: [AXWin]] = [:]
        var appInfo: [pid_t: NSRunningApplication] = [:]
        for app in apps {
            let pid = app.processIdentifier
            appInfo[pid] = app
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            let wins: [AXUIElement] = AX.attribute(element, kAXWindowsAttribute) ?? []
            perApp[pid] = wins.compactMap { w in
                let subrole: String? = AX.attribute(w, kAXSubroleAttribute)
                guard subrole == nil || subrole == "AXStandardWindow" || subrole == "AXDialog" else { return nil }
                guard let frame = AX.frame(of: w), frame.width > 60, frame.height > 40 else { return nil }
                let title: String = AX.attribute(w, kAXTitleAttribute) ?? ""
                let minimized: Bool = (AX.attribute(w, kAXMinimizedAttribute) as NSNumber?)?.boolValue ?? false
                return AXWin(element: w, frame: frame, title: title, minimized: minimized)
            }
        }

        var result: [SwitcherWindow] = []
        func add(_ w: AXWin, _ pid: pid_t) {
            let app = appInfo[pid]
            let name = app?.localizedName ?? "App"
            result.append(SwitcherWindow(element: w.element, pid: pid, appName: name,
                                         title: w.title.isEmpty ? name : w.title, icon: app?.icon, minimized: w.minimized))
        }

        // The window server knows the stacking order; Accessibility knows titles. Join them by frame.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  var wins = perApp[pid] else { continue }
            if let i = wins.firstIndex(where: { !$0.used && !$0.minimized && AX.close($0.frame, bounds, tolerance: 4) }) {
                wins[i].used = true
                perApp[pid] = wins
                add(wins[i], pid)
            }
        }
        for (pid, wins) in perApp {
            for w in wins where !w.used && w.minimized { add(w, pid) }
        }
        return result
    }
}

private struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
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
