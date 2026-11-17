import AppKit
import Carbon.HIToolbox

extension SelfTest {
    /// Hyper key and key remapping. Never sets a HID property and never posts an event:
    /// the tap handler is fed synthetic events directly and its Escape output is captured.
    static func runKeyboardChecks() {
        print("== Keyboard remapping")

        // HID usage table
        let usages = KeyRemapKey.allCases.map(\.hidUsage)
        check("usages unique", Set(usages).count == usages.count)
        check("usages on keyboard page", usages.allSatisfy { $0 >> 32 == 7 && $0 & 0xFFFF_FFFF <= 0xE7 })
        check("caps lock usage", KeyRemapKey.capsLock.hidUsage == 0x7_0000_0039)
        check("f18 usage", KeyRemapKey.f18.hidUsage == 0x7_0000_006D)
        check("escape usage", KeyRemapKey.escape.hidUsage == 0x7_0000_0029)
        check("command/option usages", KeyRemapKey.leftCommand.hidUsage == 0x7_0000_00E3 && KeyRemapKey.rightOption.hidUsage == 0x7_0000_00E6)
        check("iso and grave usages", KeyRemapKey.section.hidUsage == 0x7_0000_0064 && KeyRemapKey.grave.hidUsage == 0x7_0000_0035)
        check("menu groups cover every key once",
              KeyRemapKey.groups.flatMap(\.keys).sorted { $0.rawValue < $1.rawValue } == KeyRemapKey.allCases.sorted { $0.rawValue < $1.rawValue })
        check("titles unique", Set(KeyRemapKey.allCases.map(\.title)).count == KeyRemapKey.allCases.count)

        // Property parsing and storage
        let raw: [[String: Any]] = [["HIDKeyboardModifierMappingSrc": NSNumber(value: 0x7_0000_0039 as UInt64),
                                     "HIDKeyboardModifierMappingDst": NSNumber(value: 0x7_0000_00E0 as UInt64)],
                                    ["garbage": 1]]
        let parsed = KeyRemapEntry.entries(fromProperty: raw)
        check("parses mapping property", parsed == [KeyRemapEntry(src: 0x7_0000_0039, dst: 0x7_0000_00E0)])
        check("round-trips through property", KeyRemapEntry.entries(fromProperty: KeyRemapEntry.property(from: parsed)) == parsed)
        check("null property is empty", KeyRemapEntry.entries(fromProperty: nil).isEmpty)
        let stored = KeyRemapEntry(src: 0x7_0000_00E3, dst: 0x7_0000_00E2)
        check("owned entry storage round trip", KeyRemapEntry(storageString: stored.storageString) == stored)
        let pairs = [KeyRemapPair(from: .capsLock, to: .escape), KeyRemapPair(from: .capsLock, to: .tab), KeyRemapPair(from: .f13, to: .home)]
        let decoded = KeyRemapper.decodePairs(KeyRemapper.encodePairs(pairs))
        check("pairs persist without duplicate From keys", decoded.map(\.from) == [.capsLock, .f13] && decoded[0].to == .escape)
        check("bad stored pairs ignored", KeyRemapper.decodePairs("not json").isEmpty)

        // Merge with other tools' entries
        let foreign = KeyRemapEntry(src: 0x7_0000_0064, dst: 0x7_0000_0035)
        let hyperEntry = KeyRemapEntry(src: KeyRemapKey.capsLock.hidUsage, dst: KeyRemapKey.f18.hidUsage)
        let added = KeyRemapper.merge(existing: [foreign], desired: [hyperEntry], owned: [])
        check("merge keeps other tools' entries", added == [foreign, hyperEntry])
        check("merge is idempotent", KeyRemapper.merge(existing: added, desired: [hyperEntry], owned: [hyperEntry]) == added)
        check("turning off removes only ours", KeyRemapper.merge(existing: added, desired: [], owned: [hyperEntry]) == [foreign])
        let oldOurs = KeyRemapEntry(src: KeyRemapKey.f13.hidUsage, dst: KeyRemapKey.home.hidUsage)
        let newOurs = KeyRemapEntry(src: KeyRemapKey.f13.hidUsage, dst: KeyRemapKey.end.hidUsage)
        check("changed remap replaces old entry",
              KeyRemapper.merge(existing: [oldOurs, foreign], desired: [newOurs], owned: [oldOurs]) == [foreign, newOurs])
        let foreignCaps = KeyRemapEntry(src: KeyRemapKey.capsLock.hidUsage, dst: KeyRemapKey.leftControl.hidUsage)
        check("same source: ours takes its place", KeyRemapper.merge(existing: [foreignCaps], desired: [hyperEntry], owned: []) == [hyperEntry])
        check("nothing owned, nothing removed", KeyRemapper.merge(existing: [foreignCaps, foreign], desired: [], owned: []) == [foreignCaps, foreign])

        // Desired entries per keyboard
        let swap = KeyRemapper.withCommandOptionSwap([KeyRemapPair(from: .leftCommand, to: .f13), KeyRemapPair(from: .grave, to: .escape)])
        check("preset swaps both sides", swap.count == 5 && swap.filter { $0.from == .leftCommand }.map(\.to) == [.leftOption]
              && swap.contains { $0.from == .rightOption && $0.to == .rightCommand } && swap.contains { $0.from == .grave })
        let config = KeyRemapConfig(hyper: true, externalOnly: true,
                                    pairs: [KeyRemapPair(from: .capsLock, to: .escape), KeyRemapPair(from: .leftCommand, to: .leftOption),
                                            KeyRemapPair(from: .tab, to: .tab)])
        check("built-in gets only Hyper when remaps are external-only", KeyRemapper.desired(for: true, config: config) == [hyperEntry])
        let external = KeyRemapper.desired(for: false, config: config)
        check("Hyper wins over a Caps Lock remap", external.filter { $0.src == KeyRemapKey.capsLock.hidUsage } == [hyperEntry])
        check("external gets remaps, identity rows skipped",
              external == [hyperEntry, KeyRemapEntry(src: KeyRemapKey.leftCommand.hidUsage, dst: KeyRemapKey.leftOption.hidUsage)])
        var allConfig = config
        allConfig.hyper = false
        allConfig.externalOnly = false
        check("without Hyper, Caps Lock remap applies everywhere",
              KeyRemapper.desired(for: true, config: allConfig).first == KeyRemapEntry(src: KeyRemapKey.capsLock.hidUsage, dst: KeyRemapKey.escape.hidUsage))
        check("built-in by property", KeyRemapper.isBuiltIn(builtInProperty: true, product: "Keyboard"))
        check("built-in by name", KeyRemapper.isBuiltIn(builtInProperty: nil, product: "Apple Internal Keyboard / Trackpad"))
        check("external keyboard", !KeyRemapper.isBuiltIn(builtInProperty: false, product: "USB Keyboard"))

        // Hyper / Escape state machine, on synthetic events that are never posted
        let r = KeyRemapper.shared
        var clock: TimeInterval = 1000
        var escapes = 0
        let savedPost = r.postEscape, savedNow = r.now
        r.postEscape = { escapes += 1 }
        r.now = { clock }
        func key(_ code: Int, _ down: Bool, repeat isRepeat: Bool = false) -> CGEvent {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            if isRepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            return e
        }
        func send(_ code: Int, _ down: Bool, repeat isRepeat: Bool = false) -> (swallowed: Bool, event: CGEvent) {
            let e = key(code, down, repeat: isRepeat)
            return (r.handle(down ? .keyDown : .keyUp, e), e)
        }

        r.setTapConfig(.init(hyper: false, escapeAlone: true))
        check("F18 passes through when Hyper is off", !send(kVK_F18, true).swallowed && !send(kVK_F18, false).swallowed && escapes == 0)

        r.setTapConfig(.init(hyper: true, escapeAlone: true))
        let down = send(kVK_F18, true)
        clock += 0.12
        let up = send(kVK_F18, false)
        check("quick tap swallowed and sends Escape", down.swallowed && up.swallowed && escapes == 1, "escapes \(escapes)")

        escapes = 0
        _ = send(kVK_F18, true)
        clock += 0.05
        let a = send(kVK_ANSI_T, true)
        check("key while held gets ⌃⌥⇧⌘", !a.swallowed && a.event.flags.isSuperset(of: KeyRemapper.hyperFlags))
        let aUp = send(kVK_ANSI_T, false)
        check("key up while held gets ⌃⌥⇧⌘", aUp.event.flags.isSuperset(of: KeyRemapper.hyperFlags))
        clock += 0.05
        _ = send(kVK_F18, false)
        check("no Escape after a chord", escapes == 0)
        let after = send(kVK_ANSI_T, true)
        check("no modifiers after release", after.event.flags.intersection(KeyRemapper.hyperFlags).isEmpty)

        _ = send(kVK_F18, true)
        clock += 0.5
        _ = send(kVK_F18, false)
        check("long hold sends no Escape", escapes == 0)

        _ = send(kVK_F18, true)
        clock += 0.1
        let rep = send(kVK_F18, true, repeat: true)
        clock += 0.1
        _ = send(kVK_F18, false)
        check("autorepeat swallowed, does not restart the timer", rep.swallowed && escapes == 1, "escapes \(escapes)")

        escapes = 0
        _ = send(kVK_F18, true)
        if let shift = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: true) {
            shift.flags = .maskShift
            _ = r.handle(.flagsChanged, shift)
        }
        clock += 0.05
        _ = send(kVK_F18, false)
        check("modifier in between cancels Escape", escapes == 0)

        r.setTapConfig(.init(hyper: true, escapeAlone: false))
        _ = send(kVK_F18, true)
        clock += 0.05
        _ = send(kVK_F18, false)
        check("Escape option off", escapes == 0)
        r.setTapConfig(.init(hyper: true, escapeAlone: true))
        _ = send(kVK_F18, true)
        r.setTapConfig(.init(hyper: false, escapeAlone: true))
        let afterOff = send(kVK_ANSI_T, true)
        check("turning Hyper off clears the held state", afterOff.event.flags.intersection(KeyRemapper.hyperFlags).isEmpty)

        let tagged = key(kVK_F18, true)
        tagged.setIntegerValueField(.eventSourceUserData, value: EventTapHub.magic)
        check("own events skip the tap", !EventTapHub.shared.dispatch(.keyDown, tagged))
        r.postEscape = savedPost
        r.now = savedNow

        // Live, read-only: current mapping on real keyboards
        if !ci {
            let keyboards = KeyRemapper.readKeyboards()
            for kb in KeyRemapper.uniqueKeyboards(keyboards) { print("  keyboard: \(kb.name)\(kb.isBuiltIn ? " (built-in)" : "")") }
            check("keyboards enumerated", !keyboards.isEmpty, "\(keyboards.count) services")
            let hid = shell("/usr/bin/hidutil", ["property", "--get", KeyRemapper.hidPropertyKey]).out
            let mapped = keyboards.filter { !$0.mapping.isEmpty }
            check("mapping read matches hidutil", mapped.isEmpty == !hid.contains("HIDKeyboardModifierMappingSrc"),
                  "\(mapped.count) keyboards with a mapping")
        }
    }
}
