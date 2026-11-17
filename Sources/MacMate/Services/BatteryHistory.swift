import Combine
import Foundation

/// One reading in the battery log.
struct BatteryLogSample: Codable, Equatable {
    /// Seconds since 1970.
    var t: TimeInterval
    var percent: Int
    var charging: Bool
    var plugged: Bool
    /// Whole-system power draw at the time, in watts.
    var watts: Double

    var date: Date { Date(timeIntervalSince1970: t) }
}

/// The energy each app used during one clock hour.
struct BatteryLogHour: Codable, Equatable {
    /// Start of the hour, seconds since 1970.
    var start: TimeInterval
    /// App key → joules.
    var joules: [String: Double]
}

struct BatteryLogApp: Codable, Equatable {
    var name: String
    var bundlePath: String?
}

/// An app's total energy over a period.
struct BatteryLogUsage: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let name: String
    let bundlePath: String?
    let joules: Double
}

/// A point on the battery chart. `run` changes wherever there is a gap (sleep, MacMate not running),
/// so the chart doesn't draw a straight line across time it knows nothing about.
struct BatteryChartPoint: Identifiable {
    var id: TimeInterval { date.timeIntervalSince1970 }
    let date: Date
    let percent: Int
    let charging: Bool
    let run: Int
}

enum BatteryHistoryRange: String, CaseIterable, Identifiable {
    case day, week

    var id: String { rawValue }
    var title: String { self == .day ? "24 Hours" : "7 Days" }
    var seconds: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
}

/// Keeps a week of battery levels, and of which apps used the energy, on disk.
final class BatteryHistory: ObservableObject {
    static let shared = BatteryHistory()

    @Published private(set) var samples: [BatteryLogSample] = []
    @Published private(set) var hours: [BatteryLogHour] = []
    private(set) var apps: [String: BatteryLogApp] = [:]

    static let keep: TimeInterval = 7 * 86_400
    /// Readings further apart than this are treated as a gap in the chart.
    static let gap: TimeInterval = 30 * 60
    /// Apps kept per finished hour (the rest are a rounding error).
    private let appsPerHour = 40

    private let fileURL: URL
    private var dirty = false
    private var saveTimer: Timer?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
            self.fileURL = base.appendingPathComponent("MacMate/history.json")
        }
    }

    func start() {
        load()
        EnergyMonitor.shared.onSample = { [weak self] slices in
            DispatchQueue.main.async { self?.addEnergy(slices, at: Date()) }
        }
        record(BatteryService.shared.info)
        saveTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.saveIfNeeded() }
        saveTimer?.tolerance = 60
    }

    // MARK: Recording

    /// Called with every battery reading. Keeps one when something meaningful changed, or every ten minutes.
    func record(_ info: BatteryInfo, at date: Date = Date()) {
        guard info.hasBattery else { return }
        let sample = BatteryLogSample(t: date.timeIntervalSince1970, percent: info.percent, charging: info.isCharging,
                                      plugged: info.isPluggedIn, watts: (info.systemLoadW * 10).rounded() / 10)
        if let last = samples.last, last.percent == sample.percent, last.charging == sample.charging,
           last.plugged == sample.plugged, sample.t - last.t < 600 {
            return
        }
        samples.append(sample)
        trim(now: date)
        dirty = true
    }

    /// Adds one sampling interval's worth of per-app energy to the current hour.
    func addEnergy(_ slices: [EnergySlice], at date: Date) {
        guard slices.contains(where: { $0.joules > 0 }) else { return }
        let hourStart = (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600
        if hours.last?.start != hourStart {
            compactLastHour()
            hours.append(BatteryLogHour(start: hourStart, joules: [:]))
            trim(now: date)
        }
        var current = hours[hours.count - 1]
        for slice in slices where slice.joules > 0 {
            current.joules[slice.key, default: 0] += slice.joules
            if apps[slice.key]?.name != slice.name || apps[slice.key]?.bundlePath != slice.bundlePath {
                apps[slice.key] = BatteryLogApp(name: slice.name, bundlePath: slice.bundlePath)
            }
        }
        hours[hours.count - 1] = current
        dirty = true
    }

    private func compactLastHour() {
        guard var last = hours.last, last.joules.count > appsPerHour else { return }
        let kept = last.joules.sorted { $0.value > $1.value }.prefix(appsPerHour)
        last.joules = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        hours[hours.count - 1] = last
    }

    private func trim(now: Date) {
        let cutoff = now.timeIntervalSince1970 - BatteryHistory.keep
        if let first = samples.first, first.t < cutoff { samples.removeAll { $0.t < cutoff } }
        if let first = hours.first, first.start < cutoff - 3600 { hours.removeAll { $0.start < cutoff - 3600 } }
    }

    // MARK: Reading

    func points(for range: BatteryHistoryRange, now: Date = Date()) -> [BatteryChartPoint] {
        let from = now.timeIntervalSince1970 - range.seconds
        let window = samples.filter { $0.t >= from }
        // A week of readings is thinned to one point per 20 minutes; the shape stays the same.
        let step: TimeInterval = range == .week ? 1200 : 0
        var points: [BatteryChartPoint] = []
        var run = 0
        var previous: BatteryLogSample?
        var lastKept: TimeInterval = -.infinity
        for (index, sample) in window.enumerated() {
            if let previous, sample.t - previous.t > BatteryHistory.gap { run += 1 }
            let isLast = index == window.count - 1
            let stateChanged = previous.map { $0.charging != sample.charging || $0.plugged != sample.plugged } ?? true
            if step == 0 || isLast || stateChanged || sample.t - lastKept >= step || (previous.map { sample.t - $0.t > BatteryHistory.gap } ?? false) {
                points.append(BatteryChartPoint(date: sample.date, percent: sample.percent, charging: sample.charging, run: run))
                lastKept = sample.t
            }
            previous = sample
        }
        return points
    }

    /// Time spent on battery and how much charge that used.
    func drain(for range: BatteryHistoryRange, now: Date = Date()) -> (hours: Double, percent: Int) {
        let from = now.timeIntervalSince1970 - range.seconds
        let window = samples.filter { $0.t >= from }
        var seconds = 0.0
        var used = 0
        for (a, b) in zip(window, window.dropFirst()) where !a.plugged && !b.plugged && b.t - a.t <= BatteryHistory.gap {
            seconds += b.t - a.t
            used += max(0, a.percent - b.percent)
        }
        return (seconds / 3600, used)
    }

    func topApps(for range: BatteryHistoryRange, now: Date = Date(), limit: Int = 6) -> [BatteryLogUsage] {
        let from = now.timeIntervalSince1970 - range.seconds
        var totals: [String: Double] = [:]
        for hour in hours where hour.start + 3600 > from {
            for (key, joules) in hour.joules { totals[key, default: 0] += joules }
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map { key, joules in
            let app = apps[key]
            return BatteryLogUsage(key: key, name: app?.name ?? key, bundlePath: app?.bundlePath, joules: joules)
        }
    }

    /// Average power of an app during the hours it ran, from the stored history. nil if unknown.
    func typicalWatts(for key: String) -> Double? {
        var total = 0.0
        var count = 0
        for hour in hours.dropLast() {
            if let joules = hour.joules[key] { total += joules; count += 1 }
        }
        return count >= 3 ? total / Double(count) / 3600 : nil
    }

    // MARK: Storage

    private struct Stored: Codable {
        var version = 1
        var samples: [BatteryLogSample]
        var hours: [BatteryLogHour]
        var apps: [String: BatteryLogApp]
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        samples = stored.samples.sorted { $0.t < $1.t }
        hours = stored.hours.sorted { $0.start < $1.start }
        let used = Set(hours.flatMap(\.joules.keys))
        apps = stored.apps.filter { used.contains($0.key) }
        trim(now: Date())
    }

    func save() {
        let stored = Stored(samples: samples, hours: hours, apps: apps)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        dirty = false
    }

    func saveIfNeeded() {
        if dirty { save() }
    }

    /// Replaces everything with sample data (used only to render documentation screenshots).
    func loadDemo(samples: [BatteryLogSample], hours: [BatteryLogHour], apps: [String: BatteryLogApp]) {
        self.samples = samples
        self.hours = hours
        self.apps = apps
    }
}

/// Warns when an app suddenly uses far more energy than usual while the Mac is on battery.
final class EnergyAlerts {
    static let shared = EnergyAlerts()

    /// How long an app must stay above its threshold before we say anything.
    let sustain: TimeInterval = 120
    /// At most one alert per app per hour.
    let cooldown: TimeInterval = 3600
    /// Never alert below this, whatever the app's history.
    static let floorWatts = 2.5

    private var highSince: [String: Date] = [:]
    private var lastAlert: [String: Date] = [:]
    private var cancellable: AnyCancellable?

    func start() {
        cancellable = EnergyMonitor.shared.$apps.dropFirst().sink { [weak self] apps in
            guard let self else { return }
            let battery = BatteryService.shared.info
            for app in self.evaluate(apps, now: Date(), onBattery: battery.onBattery,
                                     enabled: UserDefaults.standard.bool(forKey: Keys.alertEnergy)) {
                let perHour = battery.fullWh > 0 ? app.watts / battery.fullWh * 100 : 0
                Notifier.post(title: "\(app.name) is using a lot of energy",
                              body: "About \(Fmt.watts(app.watts)) for the last few minutes"
                                  + (perHour >= 1 ? ", roughly \(Int(perHour.rounded()))% of your battery per hour." : ".")
                                  + " You can quit it from MacMate's Battery section.")
            }
        }
    }

    func threshold(for key: String) -> Double {
        max(EnergyAlerts.floorWatts, (BatteryHistory.shared.typicalWatts(for: key) ?? 0) * 4)
    }

    /// Returns the apps that should trigger an alert now. Apps arrive sorted by power, highest first.
    func evaluate(_ apps: [AppUsage], now: Date, onBattery: Bool, enabled: Bool,
                  threshold: ((String) -> Double)? = nil) -> [AppUsage] {
        guard enabled, onBattery else {
            highSince.removeAll()
            return []
        }
        let limit = threshold ?? self.threshold(for:)
        var fired: [AppUsage] = []
        var hot = Set<String>()
        for app in apps {
            if app.watts < EnergyAlerts.floorWatts { break }
            guard app.watts >= limit(app.id) else { continue }
            hot.insert(app.id)
            let since = highSince[app.id] ?? now
            highSince[app.id] = since
            if now.timeIntervalSince(since) >= sustain,
               now.timeIntervalSince(lastAlert[app.id] ?? .distantPast) >= cooldown {
                lastAlert[app.id] = now
                fired.append(app)
            }
        }
        highSince = highSince.filter { hot.contains($0.key) }
        return fired
    }
}
