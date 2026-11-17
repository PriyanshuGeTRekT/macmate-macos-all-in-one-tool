import AppKit
import Carbon.HIToolbox
import Combine
import IOKit
import IOKit.hid
import IOKit.hidsystem

extension Keys {
    static let keyboardHyper = "keyboard.hyper"
    static let keyboardHyperEscape = "keyboard.hyperEscape"
    static let remapPairs = "remap.pairs"
    static let remapExternalOnly = "remap.externalOnly"
    /// The mapping entries MacMate last wrote, so they can be removed again (also after a crash).
    static let remapOwned = "remap.owned"
}

/// A key that can be picked in the remapping menus, with its HID usage (page 7, keyboard).
enum KeyRemapKey: String, CaseIterable, Identifiable, Codable {
    case capsLock, escape, tab, returnKey, delete, forwardDelete
    case leftCommand, rightCommand, leftOption, rightOption, leftControl, rightControl, leftShift, rightShift
    case section, grave
    case f13, f14, f15, f16, f17, f18, f19
    case leftArrow, rightArrow, upArrow, downArrow, home, end, pageUp, pageDown

    var id: String { rawValue }

    /// Usage page 0x07 in the high 32 bits, usage in the low bits – the format UserKeyMapping expects.
    var hidUsage: UInt64 {
        let usage: UInt64
        switch self {
        case .capsLock: usage = 0x39
        case .escape: usage = 0x29
        case .tab: usage = 0x2B
        case .returnKey: usage = 0x28
        case .delete: usage = 0x2A
        case .forwardDelete: usage = 0x4C
        case .leftControl: usage = 0xE0
        case .leftShift: usage = 0xE1
        case .leftOption: usage = 0xE2
        case .leftCommand: usage = 0xE3
        case .rightControl: usage = 0xE4
        case .rightShift: usage = 0xE5
        case .rightOption: usage = 0xE6
        case .rightCommand: usage = 0xE7
        case .section: usage = 0x64
        case .grave: usage = 0x35
        case .f13: usage = 0x68
        case .f14: usage = 0x69
        case .f15: usage = 0x6A
        case .f16: usage = 0x6B
        case .f17: usage = 0x6C
        case .f18: usage = 0x6D
        case .f19: usage = 0x6E
        case .rightArrow: usage = 0x4F
        case .leftArrow: usage = 0x50
        case .downArrow: usage = 0x51
        case .upArrow: usage = 0x52
        case .home: usage = 0x4A
        case .pageUp: usage = 0x4B
        case .end: usage = 0x4D
        case .pageDown: usage = 0x4E
        }
        return 0x7_0000_0000 | usage
    }

    var title: String {
        switch self {
        case .capsLock: return "Caps Lock"
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .returnKey: return "Return"
        case .delete: return "Delete"
        case .forwardDelete: return "Forward Delete"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        case .leftShift: return "Left Shift"
        case .rightShift: return "Right Shift"
        case .section: return "§ (ISO key)"
        case .grave: return "` Grave accent"
        case .f13: return "F13"
        case .f14: return "F14"
        case .f15: return "F15"
        case .f16: return "F16"
        case .f17: return "F17"
        case .f18: return "F18"
        case .f19: return "F19"
        case .leftArrow: return "← Left Arrow"
        case .rightArrow: return "→ Right Arrow"
        case .upArrow: return "↑ Up Arrow"
        case .downArrow: return "↓ Down Arrow"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        }
    }

    /// Menu groups, in display order.
    static let groups: [(title: String, keys: [KeyRemapKey])] = [
        ("Keys", [.capsLock, .escape, .tab, .returnKey, .delete, .forwardDelete, .section, .grave]),
        ("Modifiers", [.leftCommand, .rightCommand, .leftOption, .rightOption, .leftControl, .rightControl, .leftShift, .rightShift]),
        ("Function Keys", [.f13, .f14, .f15, .f16, .f17, .f18, .f19]),
        ("Navigation", [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .pageUp, .pageDown]),
    ]
}

/// One "From → To" row in the remapping list.
struct KeyRemapPair: Codable, Hashable, Identifiable {
    var id = UUID()
    var from: KeyRemapKey
    var to: KeyRemapKey
}

/// One entry of the HID "UserKeyMapping" property.
struct KeyRemapEntry: Hashable {
    var src: UInt64
    var dst: UInt64

    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    /// Parses the property value as returned by IOHIDServiceClientCopyProperty (an array of dictionaries).
    static func entries(fromProperty value: Any?) -> [KeyRemapEntry] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            guard let d = item as? [String: Any],
                  let s = (d[srcKey] as? NSNumber)?.uint64Value, let t = (d[dstKey] as? NSNumber)?.uint64Value else { return nil }
            return KeyRemapEntry(src: s, dst: t)
        }
    }

    static func property(from entries: [KeyRemapEntry]) -> [[String: NSNumber]] {
        entries.map { [srcKey: NSNumber(value: $0.src), dstKey: NSNumber(value: $0.dst)] }
    }

    var storageString: String { String(src, radix: 16) + ":" + String(dst, radix: 16) }

    init(src: UInt64, dst: UInt64) { self.src = src; self.dst = dst }

    init?(storageString s: String) {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let a = UInt64(parts[0], radix: 16), let b = UInt64(parts[1], radix: 16) else { return nil }
        src = a
        dst = b
    }
}

/// Caps Lock as a Hyper key (⌃⌥⇧⌘) and simple key remapping.
///
/// Remaps go straight to the keyboard drivers through the HID "UserKeyMapping" property (what
/// `hidutil property --set` does), so they need no permission. Hyper maps Caps Lock to F18 the same way
/// and then turns F18 into the four modifiers in the shared event tap, which needs Accessibility.
final class KeyRemapper: ObservableObject {
    static let shared = KeyRemapper()

    static let hidPropertyKey = "UserKeyMapping"
    /// Caps Lock tapped on its own within this many seconds sends Escape.
    static let escapeTapLimit: TimeInterval = 0.3
    static let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    /// The remapping list. Persisted in UserDefaults; call `apply()` after changing other settings.
    @Published var pairs: [KeyRemapPair] = [] {
        didSet {
            guard !demo, pairs != oldValue else { return }
            KeyRemapper.savePairs(pairs)
            apply()
        }
    }
    /// Keyboards seen at the last apply.
    @Published private(set) var keyboards: [KeyRemapKeyboard] = []

    /// What the tap does when Caps Lock is tapped alone. Replaceable so the self-test can observe it without posting.
    var postEscape: () -> Void = { postKey(kVK_Escape) }
    /// Clock used by the tap handler (seconds). Replaceable for the self-test.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    struct TapConfig: Equatable {
        var hyper = false
        var escapeAlone = true
    }

    private struct HyperState {
        var held = false
        var downAt: TimeInterval = 0
        var otherPressed = false
    }

    private let tapConfig = Atomic(TapConfig())
    private let hyperState = Atomic(HyperState())
    private let applyLock = NSLock()
    /// Bumped on every apply; a background pass that is no longer the latest skips its work.
    private let applyGeneration = Atomic(0)
    private var hidClient: IOHIDEventSystemClient?
    private var notifyPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var observers: [AnyCancellable] = []
    private var pendingApply: DispatchWorkItem?
    private var started = false
    private var demo = false

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        UserDefaults.standard.register(defaults: [
            Keys.keyboardHyper: false,
            Keys.keyboardHyperEscape: true,
            Keys.remapPairs: "[]",
            Keys.remapExternalOnly: false,
            Keys.remapOwned: [String](),
        ])
        demo = false
        pairs = KeyRemapper.loadPairs()
        started = true
        hidClient = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        EventTapHub.shared.add { [weak self] type, event in self?.handle(type, event) ?? false }
        // Caps Lock only becomes F18 once the tap can turn F18 back into modifiers.
        AppState.shared.$accessibilityGranted.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }
            .store(in: &observers)
        watchForKeyboards()
        apply()
    }

    /// Removes every mapping entry MacMate added. Call from applicationWillTerminate.
    func restoreOnQuit() {
        guard started else { return }
        applyLock.lock()
        defer { applyLock.unlock() }
        let owned = KeyRemapper.loadOwned()
        for kb in KeyRemapper.readKeyboards(client: hidClient) {
            let merged = KeyRemapper.merge(existing: kb.mapping, desired: [], owned: owned)
            if merged != kb.mapping { KeyRemapper.write(merged, to: kb.service) }
        }
        UserDefaults.standard.set([String](), forKey: Keys.remapOwned)
    }

    /// Re-reads the settings and brings every keyboard's mapping up to date. Cheap when nothing changed.
    func apply() {
        guard started, !demo else { return }
        let d = UserDefaults.standard
        let config = KeyRemapConfig(hyper: d.bool(forKey: Keys.keyboardHyper) && Permissions.accessibility,
                                    externalOnly: d.bool(forKey: Keys.remapExternalOnly), pairs: pairs)
        let tap = TapConfig(hyper: config.hyper, escapeAlone: d.bool(forKey: Keys.keyboardHyperEscape))
        setTapConfig(tap)
        let client = hidClient
        let generation = applyGeneration.get() + 1
        applyGeneration.set(generation)
        inBackground { [weak self] in
            guard let self else { return }
            self.applyLock.lock()
            guard self.applyGeneration.get() == generation else { self.applyLock.unlock(); return }
            let owned = KeyRemapper.loadOwned()
            var nowOwned = Set<KeyRemapEntry>()
            let found = KeyRemapper.readKeyboards(client: client)
            for kb in found {
                let desired = KeyRemapper.desired(for: kb.isBuiltIn, config: config)
                nowOwned.formUnion(desired)
                let merged = KeyRemapper.merge(existing: kb.mapping, desired: desired, owned: owned)
                if merged != kb.mapping { KeyRemapper.write(merged, to: kb.service) }
            }
            // A keyboard that is gone takes its mapping with it, so only what was just written stays owned.
            UserDefaults.standard.set(nowOwned.map(\.storageString).sorted(), forKey: Keys.remapOwned)
            self.applyLock.unlock()
            let list = KeyRemapper.uniqueKeyboards(found)
            onMain { if self.keyboards != list { self.keyboards = list } }
        }
    }

    /// Debounced apply after hardware changes: the new service reaches the HID event system a moment after the registry.
    private func scheduleApply() {
        onMain {
            self.pendingApply?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.apply() }
            self.pendingApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.apply() }
        }
    }

    /// Shows fixed sample rows without touching settings or hardware (documentation renders).
    func loadDemo(_ sample: [KeyRemapPair], keyboards sampleKeyboards: [KeyRemapKeyboard]) {
        demo = true
        pairs = sample
        keyboards = sampleKeyboards
    }

    // MARK: Editing

    /// Keys still free to be used as a "From" key in the row with the given id.
    func availableFromKeys(for rowID: UUID?, hyper: Bool) -> [KeyRemapKey] {
        let used = Set(pairs.filter { $0.id != rowID }.map(\.from))
        let current = pairs.first { $0.id == rowID }?.from
        return KeyRemapKey.allCases.filter { key in
            key == current || (!used.contains(key) && !(hyper && key == .capsLock))
        }
    }

    func addRow(hyper: Bool) {
        guard let from = availableFromKeys(for: nil, hyper: hyper).first else { return }
        pairs.append(KeyRemapPair(from: from, to: from == .escape ? .capsLock : .escape))
    }

    func removeRow(_ id: UUID) { pairs.removeAll { $0.id == id } }

    func update(_ id: UUID, from: KeyRemapKey? = nil, to: KeyRemapKey? = nil) {
        guard let i = pairs.firstIndex(where: { $0.id == id }) else { return }
        var p = pairs[i]
        if let from, !pairs.contains(where: { $0.id != id && $0.from == from }) { p.from = from }
        if let to { p.to = to }
        pairs[i] = p
    }

    /// Swaps ⌘ and ⌥ on both sides and limits remapping to external keyboards (for Windows-layout keyboards).
    func applyCommandOptionPreset() {
        UserDefaults.standard.set(true, forKey: Keys.remapExternalOnly)
        pairs = KeyRemapper.withCommandOptionSwap(pairs)
    }

    static func withCommandOptionSwap(_ list: [KeyRemapPair]) -> [KeyRemapPair] {
        let swap: [(KeyRemapKey, KeyRemapKey)] = [(.leftCommand, .leftOption), (.leftOption, .leftCommand),
                                                  (.rightCommand, .rightOption), (.rightOption, .rightCommand)]
        let froms = Set(swap.map(\.0))
        return list.filter { !froms.contains($0.from) } + swap.map { KeyRemapPair(from: $0.0, to: $0.1) }
    }

    // MARK: Pure logic (unit-tested)

    /// The entries one keyboard should carry for the given settings.
    static func desired(for builtIn: Bool, config: KeyRemapConfig) -> [KeyRemapEntry] {
        var out: [KeyRemapEntry] = []
        var sources = Set<UInt64>()
        if config.hyper {
            out.append(KeyRemapEntry(src: KeyRemapKey.capsLock.hidUsage, dst: KeyRemapKey.f18.hidUsage))
            sources.insert(KeyRemapKey.capsLock.hidUsage)
        }
        if !(config.externalOnly && builtIn) {
            for p in config.pairs where p.from != p.to && !sources.contains(p.from.hidUsage) {
                out.append(KeyRemapEntry(src: p.from.hidUsage, dst: p.to.hidUsage))
                sources.insert(p.from.hidUsage)
            }
        }
        return out
    }

    /// Keeps entries other tools set, drops the ones MacMate wrote before (`owned`), then adds `desired`.
    /// Where another tool maps the same source key, MacMate's entry takes its place.
    static func merge(existing: [KeyRemapEntry], desired: [KeyRemapEntry], owned: Set<KeyRemapEntry>) -> [KeyRemapEntry] {
        let ourSources = Set(desired.map(\.src))
        let foreign = existing.filter { !owned.contains($0) && !ourSources.contains($0.src) }
        return foreign + desired
    }

    static func isBuiltIn(builtInProperty: Bool?, product: String?) -> Bool {
        builtInProperty == true || (product ?? "").localizedCaseInsensitiveContains("Apple Internal")
    }

    static func decodePairs(_ json: String) -> [KeyRemapPair] {
        guard let data = json.data(using: .utf8), let list = try? JSONDecoder().decode([KeyRemapPair].self, from: data) else { return [] }
        var seen = Set<KeyRemapKey>()
        return list.filter { seen.insert($0.from).inserted }
    }

    static func encodePairs(_ list: [KeyRemapPair]) -> String {
        (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func loadPairs() -> [KeyRemapPair] { decodePairs(UserDefaults.standard.string(forKey: Keys.remapPairs) ?? "[]") }
    private static func savePairs(_ list: [KeyRemapPair]) { UserDefaults.standard.set(encodePairs(list), forKey: Keys.remapPairs) }

    private static func loadOwned() -> Set<KeyRemapEntry> {
        Set((UserDefaults.standard.stringArray(forKey: Keys.remapOwned) ?? []).compactMap(KeyRemapEntry.init(storageString:)))
    }

    // MARK: HID services

    struct ServiceInfo {
        let service: IOHIDServiceClient
        let name: String
        let isBuiltIn: Bool
        let mapping: [KeyRemapEntry]
    }

    /// Every keyboard service with its current mapping. Read-only.
    static func readKeyboards(client: IOHIDEventSystemClient?) -> [ServiceInfo] {
        guard let client, let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return services.compactMap { s in
            let keyboard = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
            let keypad = IOHIDServiceClientConformsTo(s, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keypad)) != 0
            guard keyboard || keypad else { return nil }
            let name = IOHIDServiceClientCopyProperty(s, kIOHIDProductKey as CFString) as? String
            let builtIn = (IOHIDServiceClientCopyProperty(s, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue
            let mapping = KeyRemapEntry.entries(fromProperty: IOHIDServiceClientCopyProperty(s, hidPropertyKey as CFString))
            return ServiceInfo(service: s, name: name ?? "Keyboard", isBuiltIn: isBuiltIn(builtInProperty: builtIn, product: name), mapping: mapping)
        }
    }

    /// Convenience for the self-test: reads keyboards through a fresh client.
    static func readKeyboards() -> [ServiceInfo] { readKeyboards(client: IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)) }

    private static func write(_ entries: [KeyRemapEntry], to service: IOHIDServiceClient) {
        IOHIDServiceClientSetProperty(service, hidPropertyKey as CFString, property(entries) as CFArray)
    }

    private static func property(_ entries: [KeyRemapEntry]) -> [[String: NSNumber]] { KeyRemapEntry.property(from: entries) }

    static func uniqueKeyboards(_ found: [ServiceInfo]) -> [KeyRemapKeyboard] {
        var seen = Set<String>()
        var out: [KeyRemapKeyboard] = []
        for s in found where seen.insert(s.name).inserted {
            out.append(KeyRemapKeyboard(name: s.name, isBuiltIn: s.isBuiltIn))
        }
        return out.sorted { ($0.isBuiltIn ? 0 : 1, $0.name) < ($1.isBuiltIn ? 0 : 1, $1.name) }
    }

    /// Re-applies when a HID service appears (a keyboard is plugged in or paired). Registry notifications need no permission.
    private func watchForKeyboards() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let callback: IOServiceMatchingCallback = { _, iterator in
            if KeyRemapper.drain(iterator) > 0 { KeyRemapper.shared.scheduleApply() }
        }
        let result = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDEventService"),
                                                      callback, nil, &matchIterator)
        if result == KERN_SUCCESS { _ = KeyRemapper.drain(matchIterator) } // Arms the notification.
    }

    /// Releases every object in a registry iterator and returns how many there were.
    @discardableResult
    static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        var obj = IOIteratorNext(iterator)
        while obj != 0 {
            count += 1
            IOObjectRelease(obj)
            obj = IOIteratorNext(iterator)
        }
        return count
    }

    // MARK: Event tap (tap thread)

    func setTapConfig(_ config: TapConfig) {
        if config != tapConfig.get() { hyperState.set(HyperState()) }
        tapConfig.set(config)
    }

    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let config = tapConfig.get()
        guard config.hyper else { return false }
        switch type {
        case .keyDown, .keyUp:
            let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
            var state = hyperState.get()
            if code == kVK_F18 {
                if type == .keyDown {
                    if e.getIntegerValueField(.keyboardEventAutorepeat) == 0 || !state.held {
                        state = HyperState(held: true, downAt: now(), otherPressed: false)
                        hyperState.set(state)
                    }
                } else {
                    let tapped = state.held && !state.otherPressed && now() - state.downAt <= KeyRemapper.escapeTapLimit
                    hyperState.set(HyperState())
                    if tapped && config.escapeAlone { postEscape() }
                }
                return true
            }
            guard state.held else { return false }
            if type == .keyDown && !state.otherPressed {
                state.otherPressed = true
                hyperState.set(state)
            }
            e.flags = e.flags.union(KeyRemapper.hyperFlags)
            return false
        case .flagsChanged:
            var state = hyperState.get()
            if state.held && !state.otherPressed {
                state.otherPressed = true
                hyperState.set(state)
            }
            return false
        default:
            return false
        }
    }
}

/// The settings that decide which entries each keyboard gets.
struct KeyRemapConfig {
    var hyper: Bool
    var externalOnly: Bool
    var pairs: [KeyRemapPair]
}

struct KeyRemapKeyboard: Equatable, Identifiable {
    var id: String { name }
    var name: String
    var isBuiltIn: Bool
}
