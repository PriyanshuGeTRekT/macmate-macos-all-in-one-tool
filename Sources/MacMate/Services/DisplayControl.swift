import AppKit
import CoreGraphics
import IOKit

extension Keys {
    static let displaysBrightnessKeys = "displays.brightnessKeys"
}

// MARK: - DDC/CI protocol

/// DDC/CI (VESA MCCS) packets for reading and setting a monitor's VCP features.
/// Pure functions only, so they can be checked against hand-computed byte sequences.
enum DisplayDDC {
    /// 7-bit I2C address of the monitor's DDC/CI endpoint (0x6E / 0x6F on the wire).
    static let deviceAddress: UInt8 = 0x37
    /// Source address byte the host puts in front of every message.
    static let hostAddress: UInt8 = 0x51
    /// Virtual address that replaces the destination when checking a reply's checksum.
    static let replyAddress: UInt8 = 0x50
    /// VCP code for luminance (brightness).
    static let brightness: UInt8 = 0x10

    static let getOpcode: UInt8 = 0x01
    static let replyOpcode: UInt8 = 0x02
    static let setOpcode: UInt8 = 0x03
    /// A Get VCP Feature reply is 11 bytes: source, length, opcode, result, code, type, max (2), current (2), checksum.
    static let replyLength = 11

    enum Reply: Equatable {
        case value(current: UInt16, maximum: UInt16)
        /// The monitor understood the request but does not support this VCP code.
        case unsupported
        /// The "null message": the monitor is busy and the request should be repeated.
        case busy
        /// Garbage, a bad checksum or a reply to something else.
        case invalid
    }

    static func checksum<S: Sequence>(_ bytes: S, seed: UInt8) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    /// The seed covers the two address bytes that the I2C call puts on the wire itself (0x6E, 0x51).
    private static var requestSeed: UInt8 { (deviceAddress << 1) ^ hostAddress }

    /// Get VCP Feature, as handed to the I2C write (without the 0x6E/0x51 address bytes).
    static func getPacket(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x80 | 2, getOpcode, code]
        return body + [checksum(body, seed: requestSeed)]
    }

    /// Set VCP Feature, as handed to the I2C write (without the 0x6E/0x51 address bytes).
    static func setPacket(_ code: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x80 | 4, setOpcode, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body, seed: requestSeed)]
    }

    /// Parses the bytes read back after a Get VCP Feature request.
    static func parse(_ r: [UInt8], code: UInt8) -> Reply {
        guard r.count >= 3, r[0] == deviceAddress << 1, r[1] & 0x80 != 0 else { return .invalid }
        let length = Int(r[1] & 0x7F)
        guard r.count >= length + 3 else { return .invalid }
        guard checksum(r[0..<(length + 2)], seed: replyAddress) == r[length + 2] else { return .invalid }
        if length == 0 { return .busy }
        guard length == 8, r[2] == replyOpcode, r[4] == code else { return .invalid }
        if r[3] != 0 { return .unsupported }
        let maximum = UInt16(r[6]) << 8 | UInt16(r[7])
        let current = UInt16(r[8]) << 8 | UInt16(r[9])
        guard maximum > 0 else { return .invalid }
        return .value(current: current, maximum: maximum)
    }

    static func raw(for level: Double, maximum: UInt16) -> UInt16 {
        UInt16((max(0, min(1, level)) * Double(maximum)).rounded())
    }

    static func level(for raw: UInt16, maximum: UInt16) -> Double {
        maximum == 0 ? 1 : max(0, min(1, Double(raw) / Double(maximum)))
    }

    /// One brightness-key press: snaps to the nearest step, then moves one step.
    static func step(_ level: Double, up: Bool, steps: Double = 16) -> Double {
        let k = (max(0, min(1, level)) * steps).rounded() + (up ? 1 : -1)
        return max(0, min(1, k / steps))
    }

    /// Decodes the vendor number CoreGraphics reports from a three-letter PNP ID ("DEL" → 0x10AC).
    static func vendorNumber(pnp: String) -> UInt32? {
        let letters = Array(pnp.uppercased().unicodeScalars)
        guard letters.count == 3, letters.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else { return nil }
        return letters.reduce(UInt32(0)) { ($0 << 5) | ($1.value - 64) }
    }

    /// Vendor and product from the registry's "EDID UUID" ("10AC4AA0-…": vendor big-endian, product little-endian).
    static func identity(edidUUID: String) -> (vendor: UInt32, product: UInt32)? {
        let hex = edidUUID.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 8, let v = UInt32(hex.prefix(4), radix: 16),
              let p = UInt32(hex.dropFirst(4).prefix(4), radix: 16) else { return nil }
        return (v, ((p & 0xFF) << 8) | (p >> 8))
    }
}

// MARK: - IOAVService (I2C to external monitors on Apple silicon)

/// The private IOAVService functions in IOKit, resolved at runtime, plus the registry walk that finds
/// the AV service behind each external display.
enum DisplayAVService {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> IOReturn

    private static let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library, let p = dlsym(library, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let createFn = symbol("IOAVServiceCreateWithService", CreateFn.self)
    private static let readFn = symbol("IOAVServiceReadI2C", I2CFn.self)
    private static let writeFn = symbol("IOAVServiceWriteI2C", I2CFn.self)

    static var available: Bool { createFn != nil && readFn != nil && writeFn != nil }

    /// What the registry says about one DCPAVServiceProxy and the framebuffer in front of it.
    struct Candidate {
        var location: String
        var framebuffer: String
        var identity: DisplayIdentity
        var edidUUID: String?
        /// Only opened for external services, and only when asked to.
        var service: CFTypeRef?
    }

    /// Walks the IOService plane in order. Each framebuffer (IOMobileFramebufferShim / AppleCLCD2) carries the
    /// EDID-derived attributes of its display; the DCPAVServiceProxy that follows it belongs to the same display.
    static func scan(openExternal: Bool) -> [Candidate] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Candidate] = []
        var framebuffer = ""
        var identity = DisplayIdentity()
        var edidUUID: String?
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            if IOObjectConformsTo(entry, "IOMobileFramebufferShim") != 0 || IOObjectConformsTo(entry, "AppleCLCD2") != 0 {
                framebuffer = property(entry, "IONameMatched") as? String ?? ""
                (identity, edidUUID) = readIdentity(entry)
            } else if IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0 {
                let location = property(entry, "Location") as? String ?? ""
                var c = Candidate(location: location, framebuffer: framebuffer, identity: identity, edidUUID: edidUUID)
                if openExternal, location == "External", let createFn {
                    c.service = createFn(kCFAllocatorDefault, entry)?.takeRetainedValue()
                }
                found.append(c)
                identity = DisplayIdentity()
                edidUUID = nil
            }
        }
        return found
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func readIdentity(_ entry: io_registry_entry_t) -> (DisplayIdentity, String?) {
        var id = DisplayIdentity()
        let uuid = property(entry, "EDID UUID") as? String
        let product = (property(entry, "DisplayAttributes") as? [String: Any])?["ProductAttributes"] as? [String: Any] ?? [:]
        func number(_ key: String) -> UInt64? { (product[key] as? NSNumber)?.uint64Value }
        if let legacy = number("LegacyManufacturerID"), legacy > 0 { id.vendor = UInt32(truncatingIfNeeded: legacy) }
        else if let pnp = product["ManufacturerID"] as? String { id.vendor = DisplayDDC.vendorNumber(pnp: pnp) }
        if let uuid, let fromUUID = DisplayDDC.identity(edidUUID: uuid) {
            if id.vendor == nil { id.vendor = fromUUID.vendor }
            id.product = fromUUID.product
        } else if let p = number("ProductID"), p <= 0xFFFF {
            id.product = UInt32(p)
        }
        if let serial = number("SerialNumber"), serial > 0 { id.serial = UInt32(truncatingIfNeeded: serial) }
        id.name = product["ProductName"] as? String
        return (id, uuid)
    }

    // MARK: I2C

    static func write(_ service: CFTypeRef, _ packet: [UInt8]) -> Bool {
        guard let writeFn else { return false }
        var bytes = packet
        return bytes.withUnsafeMutableBytes {
            writeFn(service, UInt32(DisplayDDC.deviceAddress), UInt32(DisplayDDC.hostAddress), $0.baseAddress, UInt32($0.count))
        } == kIOReturnSuccess
    }

    static func read(_ service: CFTypeRef, count: Int) -> [UInt8]? {
        guard let readFn else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let ok = bytes.withUnsafeMutableBytes {
            readFn(service, UInt32(DisplayDDC.deviceAddress), 0, $0.baseAddress, UInt32($0.count))
        } == kIOReturnSuccess
        return ok ? bytes : nil
    }

    /// Get VCP Feature with retries. Returns nil when the monitor does not answer or lacks the feature.
    static func readVCP(_ service: CFTypeRef, code: UInt8, attempts: Int = 4) -> (current: UInt16, maximum: UInt16)? {
        let request = DisplayDDC.getPacket(code)
        for attempt in 0..<attempts {
            if attempt > 0 { usleep(UInt32(30_000 * attempt)) }
            guard write(service, request) else { continue }
            usleep(45_000) // DDC/CI: give the monitor 40 ms to prepare the reply.
            guard let reply = read(service, count: DisplayDDC.replyLength) else { continue }
            switch DisplayDDC.parse(reply, code: code) {
            case let .value(current, maximum): return (current, maximum)
            case .unsupported: return nil
            case .busy, .invalid: continue
            }
        }
        return nil
    }

    /// Set VCP Feature. Retries only if the transfer itself failed.
    @discardableResult
    static func writeVCP(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        let packet = DisplayDDC.setPacket(code, value: value)
        for attempt in 0..<3 {
            if attempt > 0 { usleep(20_000) }
            if write(service, packet) { return true }
        }
        return false
    }
}

/// What identifies a monitor in both CoreGraphics and the IORegistry (all EDID-derived).
struct DisplayIdentity: Equatable {
    var vendor: UInt32?
    var product: UInt32?
    var serial: UInt32?
    var name: String?

    init(vendor: UInt32? = nil, product: UInt32? = nil, serial: UInt32? = nil, name: String? = nil) {
        self.vendor = vendor; self.product = product; self.serial = serial; self.name = name
    }

    init(display id: CGDirectDisplayID, name: String?) {
        vendor = CGDisplayVendorNumber(id)
        product = CGDisplayModelNumber(id)
        let s = CGDisplaySerialNumber(id)
        serial = s == 0 ? nil : s
        self.name = name
    }

    func score(against other: DisplayIdentity) -> Int {
        var score = 0
        if let a = vendor, let b = other.vendor, a != 0 { score += a == b ? 1 : -2 }
        if let a = product, let b = other.product { score += a == b ? 2 : -2 }
        if let a = serial, let b = other.serial { score += a == b ? 4 : -4 }
        if let a = name, let b = other.name, a.caseInsensitiveCompare(b) == .orderedSame { score += 1 }
        return score
    }

    /// Pairs displays with registry services: best identity matches first, then whatever is left in order.
    static func match(displays: [DisplayIdentity], candidates: [DisplayIdentity]) -> [Int: Int] {
        var pairs: [(score: Int, d: Int, c: Int)] = []
        for (d, display) in displays.enumerated() {
            for (c, candidate) in candidates.enumerated() {
                let s = display.score(against: candidate)
                if s > 0 { pairs.append((s, d, c)) }
            }
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.d, $0.c) < ($1.d, $1.c) }
        var result: [Int: Int] = [:]
        var taken = Set<Int>()
        for p in pairs where result[p.d] == nil && !taken.contains(p.c) {
            result[p.d] = p.c
            taken.insert(p.c)
        }
        var free = candidates.indices.filter { !taken.contains($0) }
        for d in displays.indices where result[d] == nil && !free.isEmpty {
            result[d] = free.removeFirst()
        }
        return result
    }
}

// MARK: - DisplayServices (built-in and Apple displays)

/// Brightness of the built-in panel (and Apple's own external displays) through the private DisplayServices framework.
enum DisplaySystemBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let library, let p = dlsym(library, name) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let getFn = symbol("DisplayServicesGetBrightness", GetFn.self)
    private static let setFn = symbol("DisplayServicesSetBrightness", SetFn.self)
    private static let canFn = symbol("DisplayServicesCanChangeBrightness", CanFn.self)

    static var available: Bool { getFn != nil && setFn != nil }

    static func canChange(_ id: CGDirectDisplayID) -> Bool {
        guard available else { return false }
        if let canFn { return canFn(id) }
        return CGDisplayIsBuiltin(id) != 0 && get(id) != nil
    }

    static func get(_ id: CGDirectDisplayID) -> Double? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(id, &value) == 0, value.isFinite else { return nil }
        return Double(max(0, min(1, value)))
    }

    @discardableResult
    static func set(_ level: Double, for id: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        return setFn(id, Float(max(0, min(1, level)))) == 0
    }
}

// MARK: - Write throttling

/// Coalesces rapid slider changes: at most one write per `interval` per display, and the last value always goes out.
final class DisplayWriteThrottle {
    private let queue: DispatchQueue
    private let interval: TimeInterval
    private let perform: (CGDirectDisplayID, Double) -> Void
    // Touched on `queue` only.
    private var pending: [CGDirectDisplayID: Double] = [:]
    private var scheduled = Set<CGDirectDisplayID>()
    private var lastWrite: [CGDirectDisplayID: TimeInterval] = [:]

    init(queue: DispatchQueue, interval: TimeInterval, perform: @escaping (CGDirectDisplayID, Double) -> Void) {
        self.queue = queue
        self.interval = interval
        self.perform = perform
    }

    func submit(_ value: Double, for id: CGDirectDisplayID) {
        queue.async { [self] in
            pending[id] = value
            guard !scheduled.contains(id) else { return }
            scheduled.insert(id)
            let wait = max(0, (lastWrite[id] ?? -interval) + interval - ProcessInfo.processInfo.systemUptime)
            queue.asyncAfter(deadline: .now() + wait) { [self] in flush(id) }
        }
    }

    private func flush(_ id: CGDirectDisplayID) {
        scheduled.remove(id)
        guard let value = pending.removeValue(forKey: id) else { return }
        lastWrite[id] = ProcessInfo.processInfo.systemUptime
        perform(id, value)
    }
}

// MARK: - Model

struct DisplayDevice: Identifiable, Equatable {
    enum Control: Equatable {
        /// Looking for a DDC/CI answer.
        case checking
        /// Hardware brightness over DDC/CI.
        case ddc(maximum: UInt16)
        /// Hardware brightness through DisplayServices (built-in panel, Apple displays).
        case system
        /// No hardware control. `ddcSilent` when a DDC service exists but the monitor did not answer.
        case software(ddcSilent: Bool)
    }

    let id: CGDirectDisplayID
    var name: String
    let builtIn: Bool
    var control: Control
    /// Hardware brightness, 0…1.
    var brightness: Double

    var isDDC: Bool { if case .ddc = control { return true } else { return false } }
    var hasHardwareBrightness: Bool {
        switch control {
        case .ddc, .system: return true
        default: return false
        }
    }
}

// MARK: - Service

/// Brightness for every connected display: DDC/CI for external monitors, DisplayServices for the built-in
/// panel, and DisplayDimmer's gamma dimming below the hardware minimum or where nothing else works.
final class DisplayControl: ObservableObject {
    static let shared = DisplayControl()

    @Published private(set) var displays: [DisplayDevice] = []
    /// Sample software-dimming levels used instead of DisplayDimmer while showing sample displays.
    @Published private var demoDim: [CGDirectDisplayID: Double] = [:]
    private(set) var isDemo = false

    private let ddcQueue = DispatchQueue(label: "MacMate.displays.ddc", qos: .userInitiated)
    private let systemQueue = DispatchQueue(label: "MacMate.displays.system", qos: .userInitiated)
    // DDC state, touched on ddcQueue only.
    private var services: [CGDirectDisplayID: CFTypeRef] = [:]
    private var maximums: [CGDirectDisplayID: UInt16] = [:]
    private var lastRead: [CGDirectDisplayID: TimeInterval] = [:]
    private var scanToken = 0

    private lazy var ddcWriter = DisplayWriteThrottle(queue: ddcQueue, interval: 0.1) { [weak self] id, level in
        self?.writeDDC(level, for: id)
    }
    private lazy var systemWriter = DisplayWriteThrottle(queue: systemQueue, interval: 1.0 / 60) { id, level in
        DisplaySystemBrightness.set(level, for: id)
    }

    /// Displays the brightness keys may take over; read on the event-tap thread.
    private let ddcReady = Atomic<Set<CGDirectDisplayID>>([])
    private var started = false
    private var generation = 0
    private var rescanWork: DispatchWorkItem?
    /// Bumped on every user change, so a slow read never overwrites what the user just set.
    private var changeStamp: [CGDirectDisplayID: Int] = [:]

    func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [Keys.displaysBrightnessKeys: true])
        CGDisplayRegisterReconfigurationCallback(DisplayControl.reconfigured, nil)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in
            DisplayControl.shared.scheduleRescan()
        }
        EventTapHub.shared.add { [weak self] type, event in self?.handleEvent(type, event) ?? false }
        rescan()
    }

    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, _ in
        guard !flags.contains(.beginConfigurationFlag) else { return }
        DispatchQueue.main.async { DisplayControl.shared.scheduleRescan() }
    }

    /// One reconfiguration produces a burst of callbacks; scan once after they settle.
    func scheduleRescan() {
        rescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Lists the active displays and works out how each one's brightness can be controlled.
    /// With `probeDDC` false nothing is sent to any monitor.
    func rescan(probeDDC: Bool = true) {
        guard !isDemo else { return }
        generation += 1
        let gen = generation
        let screens = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (CGDirectDisplayID(n.uint32Value), s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        ids = Array(ids.prefix(Int(count)))
        let previous = displays

        ddcQueue.async { [self] in
            var list: [DisplayDevice] = []
            for (n, id) in ids.enumerated() {
                let builtIn = CGDisplayIsBuiltin(id) != 0
                let name = screens[id] ?? (builtIn ? "Built-in Display" : "Display \(n + 1)")
                var d = DisplayDevice(id: id, name: name, builtIn: builtIn, control: .software(ddcSilent: false),
                                      brightness: previous.first { $0.id == id }?.brightness ?? 1)
                if DisplaySystemBrightness.canChange(id), let level = DisplaySystemBrightness.get(id) {
                    d.control = .system
                    d.brightness = level
                } else if !builtIn, probeDDC, DisplayAVService.available {
                    // A monitor that already answered keeps its slider while it is checked again.
                    let before = previous.first { $0.id == id }
                    d.control = before?.isDDC == true ? before!.control : .checking
                }
                list.append(d)
            }
            list.sort { $0.builtIn && !$1.builtIn }
            publish(gen) { $0 = list }

            scanToken += 1
            services.removeAll()
            let externals = list.filter { $0.control == .checking || $0.isDDC }
            guard !externals.isEmpty else { return }
            let candidates = DisplayAVService.scan(openExternal: true).filter { $0.location == "External" }
            let pairs = DisplayIdentity.match(displays: externals.map { DisplayIdentity(display: $0.id, name: $0.name) },
                                              candidates: candidates.map(\.identity))
            for (i, display) in externals.enumerated() {
                guard let c = pairs[i].map({ candidates[$0] }), let service = c.service else {
                    publish(gen) { $0.updateDisplay(display.id) { $0.control = .software(ddcSilent: false) } }
                    continue
                }
                services[display.id] = service
                if display.name.hasPrefix("Display "), let name = c.identity.name {
                    publish(gen) { $0.updateDisplay(display.id) { $0.name = name } }
                }
                probe(display.id, gen: gen, token: scanToken, retryLater: true)
            }
        }
    }

    /// Reads the current brightness over DDC. A monitor that has only just woken up may not answer yet,
    /// so a silent one gets one more try a few seconds later.
    private func probe(_ id: CGDirectDisplayID, gen: Int, token: Int, retryLater: Bool) {
        guard token == scanToken, let service = services[id] else { return }
        if let r = DisplayAVService.readVCP(service, code: DisplayDDC.brightness) {
            maximums[id] = r.maximum
            lastRead[id] = ProcessInfo.processInfo.systemUptime
            publish(gen) { $0.updateDisplay(id) { d in
                d.control = .ddc(maximum: r.maximum)
                d.brightness = DisplayDDC.level(for: r.current, maximum: r.maximum)
            } }
        } else if retryLater {
            ddcQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.probe(id, gen: gen, token: token, retryLater: false)
            }
        } else {
            publish(gen) { $0.updateDisplay(id) { $0.control = .software(ddcSilent: true) } }
        }
    }

    /// Applies a change to the display list on the main thread, unless a newer scan has started since.
    private func publish(_ gen: Int, _ change: @escaping (inout [DisplayDevice]) -> Void) {
        onMain { [self] in
            guard gen == generation else { return }
            change(&displays)
            ddcReady.set(Set(displays.filter(\.isDDC).map(\.id)))
        }
    }

    /// Re-reads hardware levels the user may have changed elsewhere (keys, the monitor's own menu). Called when the panel opens.
    func refreshLevels() {
        guard !isDemo else { return }
        for d in displays {
            let stamp = changeStamp[d.id, default: 0]
            let apply: (Double) -> Void = { [weak self] level in
                onMain {
                    guard let self, self.changeStamp[d.id, default: 0] == stamp else { return }
                    self.displays.updateDisplay(d.id) { $0.brightness = level }
                }
            }
            switch d.control {
            case .system:
                systemQueue.async { if let level = DisplaySystemBrightness.get(d.id) { apply(level) } }
            case .ddc:
                ddcQueue.async { [self] in
                    let now = ProcessInfo.processInfo.systemUptime
                    guard let service = services[d.id], now - (lastRead[d.id] ?? 0) > 5 else { return }
                    lastRead[d.id] = now
                    if let r = DisplayAVService.readVCP(service, code: DisplayDDC.brightness, attempts: 2) {
                        maximums[d.id] = r.maximum
                        apply(DisplayDDC.level(for: r.current, maximum: r.maximum))
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: Changing brightness (main thread)

    func setBrightness(_ level: Double, for id: CGDirectDisplayID) {
        guard let d = displays.first(where: { $0.id == id }) else { return }
        let l = max(0, min(1, level))
        displays.updateDisplay(id) { $0.brightness = l }
        changeStamp[id, default: 0] += 1
        guard !isDemo else { return }
        switch d.control {
        case .ddc: ddcWriter.submit(l, for: id)
        case .system: systemWriter.submit(l, for: id)
        default: break
        }
    }

    private func writeDDC(_ level: Double, for id: CGDirectDisplayID) {
        guard let service = services[id], let maximum = maximums[id] else { return }
        DisplayAVService.writeVCP(service, code: DisplayDDC.brightness, value: DisplayDDC.raw(for: level, maximum: maximum))
        lastRead[id] = ProcessInfo.processInfo.systemUptime
    }

    /// Software dimming level (DisplayDimmer's gamma), 1 = none.
    func dimLevel(for id: CGDirectDisplayID) -> Double {
        isDemo ? demoDim[id] ?? 1 : DisplayDimmer.shared.level(for: id)
    }

    func setDim(_ level: Double, for id: CGDirectDisplayID) {
        if isDemo { demoDim[id] = level } else { DisplayDimmer.shared.set(level, for: id) }
    }

    func stepBrightness(_ id: CGDirectDisplayID, up: Bool, fine: Bool) {
        guard let d = displays.first(where: { $0.id == id }), d.isDDC else { return }
        let level = DisplayDDC.step(d.brightness, up: up, steps: fine ? 64 : 16)
        setBrightness(level, for: id)
        guard !isDemo else { return }
        HUD.shared.show("Brightness \(Int((level * 100).rounded()))%", symbol: level < 0.5 ? "sun.min.fill" : "sun.max.fill")
    }

    // MARK: Brightness keys (event-tap thread)

    struct BrightnessKey: Equatable {
        var up: Bool
        var keyDown: Bool
        var fine: Bool
    }

    /// NX_SYSDEFINED subtype 8 carries the key in data1: code in the high 16 bits, 0xA (down) / 0xB (up) in bits 8–15.
    static func brightnessKey(in event: CGEvent) -> BrightnessKey? {
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return nil }
        let data1 = ns.data1
        let code = (data1 & 0xFFFF_0000) >> 16
        guard code == 2 || code == 3 else { return nil } // NX_KEYTYPE_BRIGHTNESS_UP / _DOWN
        let flags = event.flags
        return BrightnessKey(up: code == 2, keyDown: ((data1 & 0xFF00) >> 8) == 0xA,
                             fine: flags.contains(.maskShift) && flags.contains(.maskAlternate))
    }

    /// Takes over the brightness keys while the pointer is on an external monitor that answers DDC.
    func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type.rawValue == EventTapHub.systemDefinedType else { return false }
        let ready = ddcReady.get()
        guard !ready.isEmpty, let key = DisplayControl.brightnessKey(in: event),
              UserDefaults.standard.bool(forKey: Keys.displaysBrightnessKeys) else { return false }
        let point = CGEvent(source: nil)?.location ?? event.location
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0, ready.contains(id) else { return false }
        if key.keyDown {
            DispatchQueue.main.async { self.stepBrightness(id, up: key.up, fine: key.fine) }
        }
        return true
    }

    // MARK: Sample data

    /// Shows the given displays instead of the real ones. Nothing is sent to any display afterwards.
    func loadDemo(_ devices: [DisplayDevice], dim: [CGDirectDisplayID: Double] = [:]) {
        isDemo = true
        generation += 1
        displays = devices
        demoDim = dim
        ddcReady.set(Set(devices.filter(\.isDDC).map(\.id)))
    }
}

private extension Array where Element == DisplayDevice {
    mutating func updateDisplay(_ id: CGDirectDisplayID, _ change: (inout DisplayDevice) -> Void) {
        if let i = firstIndex(where: { $0.id == id }) { change(&self[i]) }
    }
}
