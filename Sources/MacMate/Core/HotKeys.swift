import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey. Needs no special permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    static let control = UInt32(controlKey)
    static let option = UInt32(optionKey)
    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var groups: [String: [UInt32]] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(group: String, keyCode: Int, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        install()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4D4D_4154), id: id) // 'MMAT'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = handler
        groups[group, default: []].append(id)
        return true
    }

    func unregister(group: String) {
        for id in groups[group] ?? [] {
            if let ref = refs[id] { UnregisterEventHotKey(ref) }
            refs[id] = nil
            handlers[id] = nil
        }
        groups[group] = nil
    }

    func unregisterAll() {
        for group in Array(groups.keys) { unregister(group: group) }
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if err == noErr { HotKeyCenter.shared.fire(hk.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Sends a key press with modifiers, tagged so MacMate's own event tap ignores it.
func postKey(_ keyCode: Int, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: down) else { continue }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: EventTapHub.magic)
        e.post(tap: .cghidEventTap)
    }
}
