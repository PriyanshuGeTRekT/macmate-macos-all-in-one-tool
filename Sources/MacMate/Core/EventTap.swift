import AppKit
import CoreGraphics

/// One shared, session-level event tap for every feature that needs to see or change input
/// (mouse fixes, window switcher, ⌘Q guard, Finder cut/paste, keyboard lock).
/// It runs on its own thread so a busy UI can never make typing or scrolling lag.
final class EventTapHub {
    static let shared = EventTapHub()
    /// Stamped on events MacMate posts itself so the tap lets them straight through.
    static let magic: Int64 = 0x4D41_434D

    /// A handler returns true to swallow the event. Handlers run on the tap thread.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private var handlers: [Handler] = []
    private var tap: CFMachPort?
    private var thread: Thread?
    private(set) var isRunning = false

    func add(_ handler: @escaping Handler) { handlers.append(handler) }

    /// Starts the tap if Accessibility access has been granted. Safe to call repeatedly.
    @discardableResult
    func startIfPossible() -> Bool {
        if isRunning { return true }
        guard Permissions.accessibility else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel, .otherMouseDown, .otherMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: eventTapCallback, userInfo: nil) else { return false }
        tap = port
        isRunning = true
        let t = Thread {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        t.name = "MacMate event tap"
        t.qualityOfService = .userInteractive
        t.start()
        thread = t
        return true
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Exposed so the self-test can push synthetic events through the same path.
    func dispatch(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == EventTapHub.magic { return false }
        for h in handlers where h(type, event) { return true }
        return false
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        EventTapHub.shared.reenable()
        return Unmanaged.passUnretained(event)
    }
    return EventTapHub.shared.dispatch(type, event) ? nil : Unmanaged.passUnretained(event)
}
