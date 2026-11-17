import AppKit

/// Display brightness checks. Nothing here writes to a display: no I2C writes, no DisplayServices set
/// calls and no gamma changes. Packets are checked against bytes worked out by hand from the DDC/CI spec.
extension SelfTest {
    static func runDisplayChecks() {
        print("== Displays: DDC/CI packets")
        // Get VCP 0x10: 6E 51 82 01 10 chk; chk = 6E^51^82^01^10 = AC.
        check("get brightness packet", DisplayDDC.getPacket(0x10) == [0x82, 0x01, 0x10, 0xAC], displayHex(DisplayDDC.getPacket(0x10)))
        // Get VCP 0x12 (contrast): BC^12 = AE.
        check("get contrast packet", DisplayDDC.getPacket(0x12) == [0x82, 0x01, 0x12, 0xAE])
        // Set VCP 0x10 = 50: 6E^51^84^03^10^00^32 = 9A.
        check("set brightness 50 packet", DisplayDDC.setPacket(0x10, value: 50) == [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A],
              displayHex(DisplayDDC.setPacket(0x10, value: 50)))
        // Set VCP 0x10 = 100: A8^00^64 = CC.  Set 0x10 = 0x0100: A8^01^00 = A9.
        check("set brightness 100 packet", DisplayDDC.setPacket(0x10, value: 100) == [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
        check("set 16-bit value packet", DisplayDDC.setPacket(0x10, value: 0x0100) == [0x84, 0x03, 0x10, 0x01, 0x00, 0xA9])
        // On the wire the frame starts 6E 51; XOR over the whole frame, checksum included, must be zero.
        for packet in [DisplayDDC.getPacket(0x10), DisplayDDC.setPacket(0x10, value: 37), DisplayDDC.setPacket(0x62, value: 0xBEEF)] {
            check("frame checksum closes \(displayHex(packet))", DisplayDDC.checksum([0x6E, 0x51] + packet, seed: 0) == 0)
        }

        print("== Displays: DDC/CI replies")
        // 6E 88 02 00 10 00 | max 0064 | cur 0032 | chk = 50^6E^88^02^10^64^32 = F2
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        check("reply 50 of 100", DisplayDDC.parse(reply, code: 0x10) == .value(current: 50, maximum: 100))
        // max 00FF, cur 0080: A4^FF^80 = DB
        check("reply 128 of 255", DisplayDDC.parse([0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0xFF, 0x00, 0x80, 0xDB], code: 0x10)
              == .value(current: 128, maximum: 255))
        var bad = reply; bad[10] = 0xF3
        check("bad checksum rejected", DisplayDDC.parse(bad, code: 0x10) == .invalid)
        var flipped = reply; flipped[9] = 0x33
        check("corrupted value rejected", DisplayDDC.parse(flipped, code: 0x10) == .invalid)
        check("reply for another code rejected", DisplayDDC.parse(reply, code: 0x12) == .invalid)
        check("short reply rejected", DisplayDDC.parse(Array(reply.prefix(7)), code: 0x10) == .invalid)
        check("empty read rejected", DisplayDDC.parse([UInt8](repeating: 0, count: 11), code: 0x10) == .invalid)
        // Result code 01 (unsupported): 50^6E^88^02^01^10 = A5
        check("unsupported code", DisplayDDC.parse([0x6E, 0x88, 0x02, 0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0xA5], code: 0x10) == .unsupported)
        // Null message 6E 80 BE (50^6E^80 = BE), followed by padding.
        check("null message means busy", DisplayDDC.parse([0x6E, 0x80, 0xBE] + [UInt8](repeating: 0, count: 8), code: 0x10) == .busy)

        print("== Displays: levels, keys and matching")
        check("level to raw", DisplayDDC.raw(for: 0.5, maximum: 100) == 50 && DisplayDDC.raw(for: 1.2, maximum: 80) == 80 && DisplayDDC.raw(for: -1, maximum: 80) == 0)
        check("raw to level", DisplayDDC.level(for: 25, maximum: 100) == 0.25 && DisplayDDC.level(for: 300, maximum: 100) == 1)
        check("key step up", DisplayDDC.step(0.5, up: true) == 9.0 / 16)
        check("key step snaps then moves", DisplayDDC.step(0.53, up: false) == 7.0 / 16)
        check("key step clamps", DisplayDDC.step(1, up: true) == 1 && DisplayDDC.step(0.02, up: false) == 0)
        check("PNP vendor ids", DisplayDDC.vendorNumber(pnp: "DEL") == 0x10AC && DisplayDDC.vendorNumber(pnp: "GSM") == 0x1E6D
              && DisplayDDC.vendorNumber(pnp: "00-10-fa") == nil)
        let uuid = DisplayDDC.identity(edidUUID: "10AC4AA0-0000-0000-1C1E-0104B53C2278")
        check("EDID UUID identity", uuid?.vendor == 0x10AC && uuid?.product == 0xA04A, "\(String(describing: uuid))")

        let dell = DisplayIdentity(vendor: 0x10AC, product: 0xA04A, serial: 111)
        let lg = DisplayIdentity(vendor: 0x1E6D, product: 0x5B8E, serial: 222)
        check("match by identity", DisplayIdentity.match(displays: [lg, dell], candidates: [dell, lg]) == [0: 1, 1: 0])
        let twinA = DisplayIdentity(vendor: 0x10AC, product: 0xA04A, serial: 1)
        let twinB = DisplayIdentity(vendor: 0x10AC, product: 0xA04A, serial: 2)
        check("twins told apart by serial", DisplayIdentity.match(displays: [twinB, twinA], candidates: [twinA, twinB]) == [0: 1, 1: 0])
        let blank = DisplayIdentity(vendor: 0x10AC, product: 0xA04A)
        check("identical monitors matched in order", DisplayIdentity.match(displays: [blank, blank], candidates: [blank, blank]) == [0: 0, 1: 1])
        check("unknown services matched in order", DisplayIdentity.match(displays: [dell, lg], candidates: [DisplayIdentity(), DisplayIdentity()]) == [0: 0, 1: 1])
        check("extra display left unmatched", DisplayIdentity.match(displays: [dell, lg], candidates: [lg]) == [1: 0])

        // Brightness-key events, built the way the HID system posts them (NX_SYSDEFINED, subtype 8).
        func key(_ code: Int, down: Bool, flags: NSEvent.ModifierFlags = []) -> CGEvent? {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: (code << 16) | ((down ? 0xA : 0xB) << 8), data2: -1)?.cgEvent
        }
        if let e = key(2, down: true) {
            check("system-defined event type", e.type.rawValue == EventTapHub.systemDefinedType)
            check("brightness up decoded", DisplayControl.brightnessKey(in: e) == .init(up: true, keyDown: true, fine: false))
        }
        if let e = key(3, down: false, flags: [.shift, .option]) {
            check("brightness down key-up decoded", DisplayControl.brightnessKey(in: e) == .init(up: false, keyDown: false, fine: true))
        }
        if let e = key(0, down: true) { check("volume key ignored", DisplayControl.brightnessKey(in: e) == nil) }
        if let e = key(2, down: true) {
            check("keys pass through without a DDC display", !DisplayControl.shared.handleEvent(.init(rawValue: EventTapHub.systemDefinedType)!, e))
        }

        print("== Displays: write throttling")
        let queue = DispatchQueue(label: "MacMate.selftest.throttle")
        let sent = Atomic<[Double]>([])
        let throttle = DisplayWriteThrottle(queue: queue, interval: 0.1) { _, v in sent.set(sent.get() + [v]) }
        let t0 = Date()
        for i in 1...40 {
            throttle.submit(Double(i) / 40, for: 7)
            Thread.sleep(forTimeInterval: 0.01)
        }
        let dragTime = Date().timeIntervalSince(t0)
        Thread.sleep(forTimeInterval: 0.25)
        queue.sync {}
        let writes = sent.get()
        let allowed = Int(dragTime / 0.1) + 2
        check("drag throttled to ~10 writes/s", writes.count >= 2 && writes.count <= allowed, "\(writes.count) writes for 40 changes in \(String(format: "%.2f", dragTime))s")
        check("final value always sent", writes.last == 1.0)

        print("== Displays: this Mac")
        print("  IOAVService functions: \(DisplayAVService.available ? "resolved" : "missing")")
        print("  DisplayServices functions: \(DisplaySystemBrightness.available ? "resolved" : "missing")")
        let entries = DisplayAVService.scan(openExternal: false)
        for e in entries {
            let i = e.identity
            print("  DCPAVServiceProxy location=\(e.location) framebuffer=\(e.framebuffer.isEmpty ? "?" : e.framebuffer)"
                  + " vendor=\(i.vendor.map { String($0) } ?? "-") product=\(i.product.map { String($0) } ?? "-")"
                  + " serial=\(i.serial.map { String($0) } ?? "-") name=\(i.name ?? "-") edidUUID=\(e.edidUUID ?? "-")")
        }
        if !ci {
            check("IOAVService functions resolve", DisplayAVService.available)
            check("DisplayServices functions resolve", DisplaySystemBrightness.available)
            check("DCPAVServiceProxy entries found", !entries.isEmpty, "\(entries.count) (\(entries.filter { $0.location == "External" }.count) external)")
        }

        // Lists displays without probing DDC: only reads (DisplayServicesGetBrightness), never writes.
        DisplayControl.shared.rescan(probeDDC: false)
        spin(0.5)
        for d in DisplayControl.shared.displays {
            print("  display \(d.id) \(d.name) builtIn=\(d.builtIn) control=\(d.control) brightness=\(String(format: "%.2f", d.brightness))")
        }
        if !ci {
            check("displays listed", !DisplayControl.shared.displays.isEmpty)
            if let builtIn = DisplayControl.shared.displays.first(where: \.builtIn) {
                check("built-in brightness readable", builtIn.control == .system && (0...1).contains(builtIn.brightness),
                      String(format: "%.0f%%", builtIn.brightness * 100))
            }
        }
    }

    private static func displayHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
