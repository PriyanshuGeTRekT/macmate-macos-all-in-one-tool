import Foundation
import IOKit.pwr_mgt

/// Holds a power assertion so the Mac (and optionally the display) will not idle-sleep.
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isActive = false
    /// nil while active means "until I turn it off".
    @Published private(set) var endDate: Date?
    @Published private(set) var now = Date()

    private var assertion: IOPMAssertionID = 0
    private var ticker: Timer?

    var remaining: TimeInterval? { endDate.map { max(0, $0.timeIntervalSince(now)) } }

    var statusText: String {
        guard isActive else { return "Off — your Mac sleeps normally" }
        if let r = remaining { return "Awake for \(Fmt.countdown(r)) more" }
        return "Awake until you turn it off"
    }

    /// Pass nil for no time limit.
    func start(minutes: Double?) {
        stop()
        let keepDisplay = UserDefaults.standard.bool(forKey: Keys.awakeDisplay)
        let type = (keepDisplay ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep) as CFString
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacMate Keep Awake" as CFString, &id)
        guard ok == kIOReturnSuccess else { return }
        assertion = id
        isActive = true
        now = Date()
        endDate = minutes.map { Date().addingTimeInterval($0 * 60) }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        ticker?.tolerance = 0.2
    }

    func stop() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        ticker?.invalidate()
        ticker = nil
        isActive = false
        endDate = nil
    }

    func toggle() { isActive ? stop() : start(minutes: nil) }

    /// Re-create the assertion when the "keep display on" option changes mid-session.
    func optionsChanged() {
        guard isActive else { return }
        let left = remaining.map { $0 / 60 }
        start(minutes: left)
    }

    private func tick() {
        now = Date()
        if let end = endDate, now >= end { stop(); return }
        let battery = BatteryService.shared.info
        if UserDefaults.standard.bool(forKey: Keys.awakeBatteryStop), battery.onBattery, battery.percent <= 10 {
            stop()
            Notifier.post(title: "Keep Awake turned off", body: "Battery is at \(battery.percent)%, so your Mac can sleep again.")
        }
    }
}
