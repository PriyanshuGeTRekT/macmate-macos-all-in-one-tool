import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import UserNotifications

/// A value that is written on one thread and read on another.
final class Atomic<T> {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

extension Keys {
    static let cmdQGuard = "keys.cmdQGuard"
    static let finderCut = "keys.finderCut"
}

/// Keyboard conveniences that ride on the shared event tap:
/// hold-⌘Q-to-quit, ⌘X/⌘V to move files in Finder, and a lock for cleaning the keyboard.
final class KeyboardFeatures: ObservableObject {
    static let shared = KeyboardFeatures()

    @Published private(set) var keyboardLocked = false

    private let locked = Atomic(false)
    private let frontBundle = Atomic<String>("")
    private let frontName = Atomic<String>("")
    private let qHeld = Atomic(false)
    private var qWork: DispatchWorkItem?
    private var cutPendingUntil: TimeInterval = 0
    private var lockWindow: NSWindow?

    func start() {
        EventTapHub.shared.add { [weak self] type, event in self?.handle(type, event) ?? false }
        let update: (NSRunningApplication?) -> Void = { [weak self] app in
            self?.frontBundle.set(app?.bundleIdentifier ?? "")
            self?.frontName.set(app?.localizedName ?? "this app")
        }
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            update(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }

    // MARK: Tap thread

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if locked.get() { return type == .keyDown || type == .keyUp || type == .flagsChanged }
        guard type == .keyDown || type == .keyUp else { return false }
        let d = UserDefaults.standard
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let mods = e.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        guard mods == .maskCommand else { return false }

        if code == kVK_ANSI_Q, d.bool(forKey: Keys.cmdQGuard) {
            if type == .keyUp {
                qHeld.set(false)
                DispatchQueue.main.async { self.qWork?.cancel(); HUD.shared.hide() }
            } else if e.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                qHeld.set(true)
                let name = frontName.get()
                DispatchQueue.main.async {
                    HUD.shared.show("Keep holding ⌘Q to quit \(name)", symbol: "power", autoHide: nil)
                    self.qWork?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.qHeld.get() else { return }
                        self.qHeld.set(false)
                        HUD.shared.hide()
                        postKey(kVK_ANSI_Q, flags: .maskCommand)
                    }
                    self.qWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                }
            }
            return true
        }

        if type == .keyDown, d.bool(forKey: Keys.finderCut), frontBundle.get() == "com.apple.finder" {
            let now = ProcessInfo.processInfo.systemUptime
            switch code {
            case kVK_ANSI_X where !KeyboardFeatures.focusIsTextField():
                cutPendingUntil = now + 600
                postKey(kVK_ANSI_C, flags: .maskCommand)
                DispatchQueue.main.async { HUD.shared.show("Cut — press ⌘V in the destination folder to move", symbol: "scissors") }
                return true
            case kVK_ANSI_V where now < cutPendingUntil:
                cutPendingUntil = 0
                // ⌥⌘V is Finder's own "Move Item Here".
                postKey(kVK_ANSI_V, flags: [.maskCommand, .maskAlternate])
                return true
            case kVK_ANSI_C:
                cutPendingUntil = 0
            default:
                break
            }
        }
        return false
    }

    /// True while the user is typing in a text field (e.g. renaming a file), where ⌘X must stay a text cut.
    private static func focusIsTextField() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        guard let focused: AXUIElement = AX.attribute(system, kAXFocusedUIElementAttribute),
              let role: String = AX.attribute(focused, kAXRoleAttribute) else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    // MARK: Keyboard cleaning lock

    func lockKeyboard() {
        guard EventTapHub.shared.startIfPossible() else {
            Permissions.requestAccessibility()
            HUD.shared.show("Grant Accessibility access to lock the keyboard", symbol: "lock.slash")
            return
        }
        locked.set(true)
        keyboardLocked = true
        guard let screen = NSScreen.main else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: KeyboardLockView { [weak self] in self?.unlockKeyboard() })
        w.orderFrontRegardless()
        lockWindow = w
    }

    func unlockKeyboard() {
        locked.set(false)
        keyboardLocked = false
        lockWindow?.orderOut(nil)
        lockWindow = nil
    }
}

private struct KeyboardLockView: View {
    let unlock: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard").font(.system(size: 64, weight: .light))
            Text("Keyboard locked").font(.system(size: 34, weight: .semibold))
            Text("Every key press is ignored, so you can wipe the keyboard safely.\nUse the trackpad or mouse to unlock.")
                .multilineTextAlignment(.center).font(.title3).opacity(0.75)
            Button(action: unlock) {
                Text("Unlock keyboard").font(.title3.weight(.semibold)).padding(.horizontal, 26).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small transient message in the middle of the screen (think volume bezel).
final class HUD {
    static let shared = HUD()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ text: String, symbol: String = "checkmark.circle", autoHide: TimeInterval? = 1.6) {
        onMain {
            self.hideWork?.cancel()
            let p = self.panel ?? self.makePanel()
            self.panel = p
            let view = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
            let size = view.fittingSize
            p.contentView = view
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                p.setFrame(CGRect(x: f.midX - size.width / 2, y: f.minY + f.height * 0.18, width: size.width, height: size.height), display: true)
            }
            p.alphaValue = 1
            p.orderFrontRegardless()
            if let autoHide {
                let work = DispatchWorkItem { [weak self] in self?.hide() }
                self.hideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
            }
        }
    }

    func hide() {
        onMain {
            self.hideWork?.cancel()
            self.panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}

private struct HUDView: View {
    let text: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
            Text(text).font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .padding(6)
        .fixedSize()
    }
}

enum Notifier {
    private static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard canNotify else { HUD.shared.show(title, symbol: "bell"); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                HUD.shared.show(title, symbol: "bell", autoHide: 3)
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
