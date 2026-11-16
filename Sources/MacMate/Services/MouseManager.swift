import AppKit
import Carbon.HIToolbox
import IOKit
import IOKit.hid
import IOKit.hidsystem

enum MouseAction: String, CaseIterable, Identifiable {
    case passThrough, back, forward, missionControl, appWindows, showDesktop
    case spaceLeft, spaceRight, copy, paste, closeTab, playPause

    var id: String { rawValue }

    var title: String {
        switch self {
        case .passThrough: return "Default (do nothing special)"
        case .back: return "Back"
        case .forward: return "Forward"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .showDesktop: return "Show desktop"
        case .spaceLeft: return "Space to the left"
        case .spaceRight: return "Space to the right"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .closeTab: return "Close tab / window"
        case .playPause: return "Play / pause"
        }
    }

    func perform() {
        switch self {
        case .passThrough: break
        case .back: postKey(kVK_ANSI_LeftBracket, flags: .maskCommand)
        case .forward: postKey(kVK_ANSI_RightBracket, flags: .maskCommand)
        case .missionControl: MouseAction.missionControl(arg: nil)
        case .appWindows: MouseAction.missionControl(arg: "2")
        case .showDesktop: MouseAction.missionControl(arg: "1")
        case .spaceLeft: postKey(kVK_LeftArrow, flags: .maskControl)
        case .spaceRight: postKey(kVK_RightArrow, flags: .maskControl)
        case .copy: postKey(kVK_ANSI_C, flags: .maskCommand)
        case .paste: postKey(kVK_ANSI_V, flags: .maskCommand)
        case .closeTab: postKey(kVK_ANSI_W, flags: .maskCommand)
        case .playPause: MediaKey.post(16) // NX_KEYTYPE_PLAY
        }
    }

    private static func missionControl(arg: String?) {
        let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        guard FileManager.default.isExecutableFile(atPath: binary) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arg.map { [$0] } ?? []
        try? p.run()
    }
}

enum MediaKey {
    /// Posts a system-defined media key (play/pause, next, …).
    static func post(_ key: Int) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

struct PointingDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var vendorID: Int
    var productID: Int
    var transport: String
    var isThirdPartyMouse: Bool
    var battery: Int?
}

/// Fixes for ordinary (non-Apple) mice: natural scrolling only for the trackpad, smooth wheel
/// scrolling, side-button actions and pointer speed. Trackpads and the Magic Mouse are left alone.
final class MouseManager: ObservableObject {
    static let shared = MouseManager()

    @Published private(set) var devices: [PointingDevice] = []

    private let scroller = SmoothScroller()
    private var hidClient: IOHIDEventSystemClient?
    private var pollTimer: Timer?
    private var appliedTo = Set<String>()

    var thirdPartyMice: [PointingDevice] { devices.filter(\.isThirdPartyMouse) }

    func start() {
        EventTapHub.shared.add { [weak self] type, event in self?.handle(type, event) ?? false }
        hidClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        refreshDevices()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refreshDevices() }
        pollTimer?.tolerance = 1
    }

    /// Shows fixed sample devices (used only when rendering documentation screenshots).
    func loadDemo(_ sample: [PointingDevice]) {
        pollTimer?.invalidate()
        devices = sample
    }

    // MARK: Event handling (tap thread)

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: Keys.mouseEnabled) else { return false }
        switch type {
        case .scrollWheel:
            return handleScroll(e, d)
        case .otherMouseDown, .otherMouseUp:
            let button = e.getIntegerValueField(.mouseEventButtonNumber)
            let key: String
            switch button {
            case 2: key = Keys.mouseButton2
            case 3: key = Keys.mouseButton3
            case 4: key = Keys.mouseButton4
            default: return false
            }
            guard let action = MouseAction(rawValue: d.string(forKey: key) ?? ""), action != .passThrough else { return false }
            if type == .otherMouseDown { DispatchQueue.main.async { action.perform() } }
            return true
        default:
            return false
        }
    }

    private func handleScroll(_ e: CGEvent, _ d: UserDefaults) -> Bool {
        // Continuous events come from trackpads and the Magic Mouse; a wheel mouse sends line steps.
        guard e.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return false }
        let reverseV = d.bool(forKey: Keys.mouseReverse), reverseH = d.bool(forKey: Keys.mouseReverseH)
        let smooth = d.bool(forKey: Keys.mouseSmooth)
        let speed = max(0.2, min(5, d.double(forKey: Keys.mouseScrollSpeed)))
        guard reverseV || reverseH || smooth || abs(speed - 1) > 0.01 else { return false }

        let lineY = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineX = e.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let fixedY = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let pointY = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let sy: Double = reverseV ? -1 : 1, sx: Double = reverseH ? -1 : 1

        if smooth {
            // One wheel notch = one step; the system's own acceleration makes fast spins report more lines.
            let step = 56.0 * speed
            let notchY: Double = lineY != 0 ? Double(lineY) : (fixedY > 0 ? 1 : fixedY < 0 ? -1 : 0)
            let notchX: Double = lineX != 0 ? Double(lineX) : (fixedX > 0 ? 1 : fixedX < 0 ? -1 : 0)
            var dy = sy * notchY * step
            var dx = sx * notchX * step
            var flags = e.flags
            if flags.contains(.maskShift), dx == 0 {
                // Shift + wheel scrolls sideways; do it ourselves because we replace the event.
                dx = dy
                dy = 0
                flags.remove(.maskShift)
            }
            scroller.add(dx: dx, dy: dy, flags: flags)
            return true
        }

        func scaled(_ v: Int64, _ sign: Double) -> Int64 {
            guard v != 0 else { return 0 }
            let r = (Double(v) * sign * speed).rounded()
            return r == 0 ? Int64(sign * (v > 0 ? 1 : -1)) : Int64(r)
        }
        // Order matters: writing the line delta resets the derived fields.
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: scaled(lineY, sy))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedY * sy * speed)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: scaled(pointY, sy))
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: scaled(lineX, sx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedX * sx * speed)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: scaled(pointX, sx))
        return false
    }

    // MARK: Devices

    func refreshDevices() {
        guard let client = hidClient, let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return }
        var found: [String: PointingDevice] = [:]
        var handles: [String: [IOHIDServiceClient]] = [:]
        for s in services {
            let isMouse = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
            let isPointer = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            guard isMouse || isPointer else { continue }
            func prop(_ k: String) -> Any? { IOHIDServiceClientCopyProperty(s, k as CFString) }
            let name = (prop(kIOHIDProductKey) as? String) ?? "Pointing device"
            let vendor = (prop(kIOHIDVendorIDKey) as? NSNumber)?.intValue ?? 0
            let product = (prop(kIOHIDProductIDKey) as? NSNumber)?.intValue ?? 0
            let transport = (prop(kIOHIDTransportKey) as? String) ?? ""
            let builtIn = (prop(kIOHIDBuiltInKey) as? NSNumber)?.boolValue ?? false
            let lower = name.lowercased()
            let apple = vendor == 0x05AC || vendor == 0x004C || lower.contains("apple internal")
            let trackpadLike = lower.contains("trackpad") || lower.contains("touchpad") || lower.contains("magic mouse")
            // Virtual pointers from screen-sharing and tablet drivers have no vendor at all.
            let third = !builtIn && !apple && !trackpadLike && vendor != 0
            let id = "\(vendor):\(product):\(name)"
            let battery = (prop("BatteryPercent") as? NSNumber)?.intValue
            if var existing = found[id] {
                existing.battery = existing.battery ?? battery
                found[id] = existing
            } else {
                found[id] = PointingDevice(id: id, name: name, vendorID: vendor, productID: product, transport: transport,
                                           isThirdPartyMouse: third, battery: battery)
            }
            if third { handles[id, default: []].append(s) }
        }
        let list = found.values.sorted { ($0.isThirdPartyMouse ? 0 : 1, $0.name) < ($1.isThirdPartyMouse ? 0 : 1, $1.name) }
        if list != devices { devices = list }
        applyPointerSettings(to: handles)
    }

    /// Forces the pointer settings to be re-sent, e.g. after a slider changes.
    func pointerSettingsChanged() {
        appliedTo.removeAll()
        refreshDevices()
    }

    private func applyPointerSettings(to handles: [String: [IOHIDServiceClient]]) {
        let d = UserDefaults.standard
        appliedTo.formIntersection(Set(handles.keys))
        guard d.bool(forKey: Keys.mouseEnabled) else { return }
        let override = d.bool(forKey: Keys.mouseSpeedOverride), linear = d.bool(forKey: Keys.mouseLinear)
        guard override || linear else { return }
        for (id, services) in handles where !appliedTo.contains(id) {
            for s in services {
                if override {
                    // Same scale as System Settings › Mouse › Tracking speed (0…3), as 16.16 fixed point.
                    let fixed = Int(max(0, min(3, d.double(forKey: Keys.mouseSpeed))) * 65536)
                    IOHIDServiceClientSetProperty(s, "HIDMouseAcceleration" as CFString, NSNumber(value: fixed))
                }
                if linear {
                    IOHIDServiceClientSetProperty(s, "HIDUseLinearScalingMouseAcceleration" as CFString, NSNumber(value: 1))
                }
            }
            appliedTo.insert(id)
        }
    }
}

/// Turns chunky wheel notches into a short eased glide of pixel-precise scroll events.
final class SmoothScroller {
    private let queue = DispatchQueue(label: "macmate.scroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var remainX = 0.0, remainY = 0.0
    private var carryX = 0.0, carryY = 0.0
    private var flags: CGEventFlags = []

    func add(dx: Double, dy: Double, flags: CGEventFlags) {
        queue.async {
            // Reversing direction mid-glide should stop the old motion immediately.
            if dy != 0, (dy > 0) != (self.remainY > 0) { self.remainY = 0; self.carryY = 0 }
            if dx != 0, (dx > 0) != (self.remainX > 0) { self.remainX = 0; self.carryX = 0 }
            self.remainX += dx
            self.remainY += dy
            self.flags = flags
            if self.timer == nil { self.startTimer() }
        }
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .microseconds(8333), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let factor = 0.14
        let stepX = remainX * factor, stepY = remainY * factor
        remainX -= stepX
        remainY -= stepY
        carryX += stepX
        carryY += stepY
        if abs(remainX) < 0.4 { carryX += remainX; remainX = 0 }
        if abs(remainY) < 0.4 { carryY += remainY; remainY = 0 }
        let outX = Int32(carryX.rounded(.towardZero)), outY = Int32(carryY.rounded(.towardZero))
        carryX -= Double(outX)
        carryY -= Double(outY)
        if outX != 0 || outY != 0 { post(dx: outX, dy: outY) }
        if remainX == 0 && remainY == 0 {
            carryX = 0
            carryY = 0
            timer?.cancel()
            timer = nil
        }
    }

    private func post(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: EventTapHub.magic)
        e.post(tap: .cgSessionEventTap)
    }
}
