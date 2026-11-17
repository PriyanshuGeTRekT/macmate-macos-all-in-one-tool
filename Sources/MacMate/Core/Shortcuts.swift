import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus Carbon modifier flags, as used by RegisterEventHotKey.
struct KeyCombo: Equatable, Hashable {
    var keyCode: Int
    var modifiers: UInt32

    init(keyCode: Int, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(storage: String) {
        let parts = storage.split(separator: ":")
        guard parts.count == 2, let code = Int(parts[0]), let mods = UInt32(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    /// From a key press while recording. Needs ⌘, ⌃ or ⌥ unless it's a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        let code = Int(event.keyCode)
        let needsModifier = !KeyCombo.functionKeys.contains(code)
        if needsModifier && mods & UInt32(controlKey | optionKey | cmdKey) == 0 { return nil }
        self.init(keyCode: code, modifiers: mods)
    }

    var storage: String { "\(keyCode):\(modifiers)" }

    /// "⌃⌥←", in Apple's modifier order.
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    private static let specialNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_Help: "Help", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// The key's label on the current keyboard layout ("A", "[", "Ö"…).
    static func keyName(_ code: Int) -> String {
        if let name = specialNames[code] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "Key \(code)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "Key \(code)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// Something the user can give a global shortcut to.
struct ShortcutDefinition: Identifiable, Hashable {
    let id: String
    let title: String
    let defaultCombo: KeyCombo?
}

enum Shortcuts {
    private static let ctrlOpt = UInt32(controlKey | optionKey)

    static func tile(_ action: TileAction) -> ShortcutDefinition {
        ShortcutDefinition(id: "tile.\(action.rawValue)", title: action.title,
                           defaultCombo: KeyCombo(keyCode: action.keyCode, modifiers: ctrlOpt))
    }

    static let clipboard = ShortcutDefinition(id: "tool.clipboard", title: "Open clipboard history",
                                              defaultCombo: KeyCombo(keyCode: kVK_ANSI_V, modifiers: ctrlOpt))
    static let ocr = ShortcutDefinition(id: "tool.ocr", title: "Copy text from the screen",
                                        defaultCombo: KeyCombo(keyCode: kVK_ANSI_O, modifiers: ctrlOpt))
    static let mic = ShortcutDefinition(id: "tool.mic", title: "Mute or unmute the microphone",
                                        defaultCombo: KeyCombo(keyCode: kVK_ANSI_A, modifiers: ctrlOpt))
    static let color = ShortcutDefinition(id: "tool.color", title: "Pick a color",
                                          defaultCombo: KeyCombo(keyCode: kVK_ANSI_P, modifiers: ctrlOpt))
    static let awake = ShortcutDefinition(id: "tool.awake", title: "Turn Keep Awake on or off", defaultCombo: nil)
    static let panel = ShortcutDefinition(id: "tool.panel", title: "Open the MacMate panel", defaultCombo: nil)
    static let lockKeys = ShortcutDefinition(id: "tool.lockKeyboard", title: "Lock the keyboard for cleaning", defaultCombo: nil)

    static let tools: [ShortcutDefinition] = [panel, clipboard, ocr, mic, color, awake, lockKeys]
    static var all: [ShortcutDefinition] { TileAction.allCases.map(tile) + tools }

    /// What each tool shortcut does.
    static func perform(_ id: String) {
        switch id {
        case clipboard.id: MenuBarPanel.open(.clipboard)
        case ocr.id: ScreenOCR.capture()
        case mic.id: MicMute.shared.toggle()
        case color.id: SystemToggles.pickColor()
        case awake.id:
            KeepAwake.shared.toggle()
            HUD.shared.show(KeepAwake.shared.isActive ? "Keep Awake on" : "Keep Awake off",
                            symbol: KeepAwake.shared.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
        case panel.id: MenuBarPanel.open(AppState.shared.tab)
        case lockKeys.id: KeyboardFeatures.shared.lockKeyboard()
        default: break
        }
    }

    /// (Re)registers every global shortcut from the user's settings.
    static func registerAll() {
        guard !ShortcutStore.shared.isRecording else { return }
        WindowManager.shared.applySettings()
        HotKeyCenter.shared.unregister(group: "tools")
        for def in tools {
            guard let combo = ShortcutStore.shared.combo(for: def) else { continue }
            let id = def.id
            HotKeyCenter.shared.register(group: "tools", keyCode: combo.keyCode, modifiers: combo.modifiers) { perform(id) }
        }
    }
}

/// The user's changes to the default shortcuts, saved in UserDefaults.
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    /// id → "keyCode:modifiers", or "" when the user removed the shortcut. Defaults aren't stored.
    @Published private(set) var overrides: [String: String]
    @Published private(set) var isRecording = false
    private let defaultsKey = "shortcuts.overrides"

    init() {
        overrides = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func combo(for def: ShortcutDefinition) -> KeyCombo? {
        if let stored = overrides[def.id] { return KeyCombo(storage: stored) }
        return def.defaultCombo
    }

    func isCustomized(_ def: ShortcutDefinition) -> Bool { overrides[def.id] != nil }

    func set(_ combo: KeyCombo?, for def: ShortcutDefinition) {
        if combo == def.defaultCombo { overrides[def.id] = nil } else { overrides[def.id] = combo?.storage ?? "" }
        persist()
    }

    func reset(_ def: ShortcutDefinition) {
        overrides[def.id] = nil
        persist()
    }

    func resetAll(_ defs: [ShortcutDefinition]) {
        for def in defs { overrides[def.id] = nil }
        persist()
    }

    /// Another shortcut that already uses this key combination.
    func conflict(for combo: KeyCombo, excluding id: String) -> ShortcutDefinition? {
        Shortcuts.all.first { $0.id != id && self.combo(for: $0) == combo }
    }

    /// While recording, global shortcuts are switched off so the keys reach the recorder.
    func beginRecording() {
        isRecording = true
        HotKeyCenter.shared.unregisterAll()
    }

    func endRecording() {
        isRecording = false
        Shortcuts.registerAll()
    }

    private func persist() {
        UserDefaults.standard.set(overrides, forKey: defaultsKey)
        Shortcuts.registerAll()
    }
}

/// A shortcut field like the ones in System Settings › Keyboard › Keyboard Shortcuts.
/// Click it, press the new keys. Delete removes the shortcut, Esc cancels.
struct ShortcutRecorder: View {
    let definition: ShortcutDefinition
    @ObservedObject private var store = ShortcutStore.shared
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: toggle) {
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(recording ? Color.accentColor : (store.combo(for: definition) == nil ? .secondary : .primary))
                    .frame(minWidth: 64)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(recording ? "Press the new shortcut. Delete removes it, Esc cancels." : "Click to change")
            .accessibilityLabel("\(definition.title) shortcut, \(label)")
            if store.isCustomized(definition) && !recording {
                Button {
                    store.reset(definition)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Restore the default shortcut")
                .accessibilityLabel("Restore default")
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return "Type shortcut…" }
        return store.combo(for: definition)?.displayString ?? "None"
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        store.beginRecording()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            switch Int(event.keyCode) {
            case kVK_Escape where plain:
                stop()
            case kVK_Delete where plain, kVK_ForwardDelete where plain:
                store.set(nil, for: definition)
                stop()
            default:
                guard let combo = KeyCombo(event: event) else {
                    NSSound.beep()
                    return nil
                }
                if let other = store.conflict(for: combo, excluding: definition.id) {
                    HUD.shared.show("\(combo.displayString) is already used for “\(other.title)”", symbol: "exclamationmark.triangle")
                    return nil
                }
                store.set(combo, for: definition)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            store.endRecording()
        }
    }
}
