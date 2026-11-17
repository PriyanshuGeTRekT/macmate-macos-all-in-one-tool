import Darwin
import Foundation

/// One app (or standalone process) with everything it is costing right now.
struct AppUsage: Identifiable, Equatable {
    let id: String
    var name: String
    var bundlePath: String?
    var pids: [pid_t]
    /// Smoothed power draw in watts, from the kernel's per-process energy counters.
    var watts: Double
    var cpuPercent: Double
    var memBytes: UInt64
    /// Joules used since the session started (reset each time the charger is unplugged).
    var sessionJoules: Double
    var isApp: Bool
}

/// Energy one app used during one sampling interval (for the battery history).
struct EnergySlice {
    let key: String
    let name: String
    let bundlePath: String?
    let joules: Double
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

/// Samples every process the current user can see and groups helpers under their parent app.
///
/// Energy comes from `proc_pid_rusage` (`ri_energy_nj`): nanojoules the CPU actually spent on
/// that process, as measured by the SoC. Power is the difference between two samples over time.
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()

    @Published private(set) var apps: [AppUsage] = []
    /// Sum of all visible processes, in watts.
    @Published private(set) var totalWatts: Double = 0
    @Published private(set) var sessionStart = Date()
    @Published private(set) var sessionJoules: Double = 0
    /// Called on the sampling queue with each interval's per-app energy. Set it before start().
    var onSample: (([EnergySlice]) -> Void)?

    private struct ProcState {
        var startAbs: UInt64
        var lastEnergy: UInt64
        var lastCPU: UInt64
        var key: String
    }

    private struct Group {
        var name: String
        var bundlePath: String?
        var isApp: Bool
        var ema: Double?
        var sessionJ: Double = 0
        var lastSeen: Int = 0
    }

    private let queue = DispatchQueue(label: "macmate.energy", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var procs: [pid_t: ProcState] = [:]
    private var groups: [String: Group] = [:]
    private var lastSample: UInt64 = 0
    private var tick = 0
    private var interval: TimeInterval = 10
    private var timebase = mach_timebase_info_data_t()
    private let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    init() { mach_timebase_info(&timebase) }

    func start() {
        queue.async { self.sample() }
        schedule()
    }

    /// Sample quickly while the panel is open, slowly when it is not.
    func setFast(_ fast: Bool) {
        let new: TimeInterval = fast ? 2 : 10
        guard new != interval else { return }
        interval = new
        schedule()
    }

    /// Fills the list with fixed sample data (used only when rendering documentation screenshots).
    func loadDemo(_ sample: [AppUsage]) {
        timer?.cancel()
        apps = sample
        totalWatts = sample.reduce(0) { $0 + $1.watts }
        sessionJoules = sample.reduce(0) { $0 + $1.sessionJoules }
    }

    func resetSession() {
        queue.async {
            for k in self.groups.keys { self.groups[k]?.sessionJ = 0 }
            DispatchQueue.main.async {
                self.sessionStart = Date()
                self.sessionJoules = 0
            }
        }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func nanos(_ machTicks: UInt64) -> UInt64 {
        machTicks * UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    // MARK: Sampling

    func sample() {
        let now = nanos(mach_absolute_time())
        let dt = lastSample == 0 ? 0 : Double(now - lastSample) / 1e9
        lastSample = now
        tick += 1

        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        guard n > 0 else { return }

        struct Acc { var dE: UInt64 = 0; var dCPU: UInt64 = 0; var mem: UInt64 = 0; var pids: [pid_t] = [] }
        var acc: [String: Acc] = [:]
        var alive = Set<pid_t>()
        alive.reserveCapacity(n)

        for i in 0..<n {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var ri = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &ri) { p in
                p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }
            alive.insert(pid)
            let cpu = ri.ri_user_time &+ ri.ri_system_time
            var dE: UInt64 = 0, dCPU: UInt64 = 0
            let key: String
            if let st = procs[pid], st.startAbs == ri.ri_proc_start_abstime {
                key = st.key
                if ri.ri_energy_nj >= st.lastEnergy { dE = ri.ri_energy_nj - st.lastEnergy }
                if cpu >= st.lastCPU { dCPU = cpu - st.lastCPU }
                procs[pid]?.lastEnergy = ri.ri_energy_nj
                procs[pid]?.lastCPU = cpu
            } else {
                key = resolveGroup(for: pid)
                procs[pid] = ProcState(startAbs: ri.ri_proc_start_abstime, lastEnergy: ri.ri_energy_nj, lastCPU: cpu, key: key)
            }
            var a = acc[key] ?? Acc()
            a.dE += dE
            a.dCPU += dCPU
            a.mem += ri.ri_phys_footprint
            a.pids.append(pid)
            acc[key] = a
        }
        for pid in procs.keys where !alive.contains(pid) { procs[pid] = nil }

        var out: [AppUsage] = []
        out.reserveCapacity(acc.count)
        var slices: [EnergySlice] = []
        var total = 0.0, session = 0.0
        for (key, a) in acc {
            guard var g = groups[key] else { continue }
            let joules = Double(a.dE) / 1e9
            g.sessionJ += joules
            if joules > 0.01 { slices.append(EnergySlice(key: key, name: g.name, bundlePath: g.bundlePath, joules: joules)) }
            g.lastSeen = tick
            var watts = g.ema ?? 0
            var cpuPct = 0.0
            if dt > 0.2 {
                let inst = joules / dt
                // Light smoothing so a 2 s spike doesn't make the list jump around.
                watts = g.ema.map { $0 * 0.55 + inst * 0.45 } ?? inst
                g.ema = watts
                cpuPct = Double(nanos(a.dCPU)) / (dt * 1e9) * 100
            }
            groups[key] = g
            total += watts
            session += g.sessionJ
            out.append(AppUsage(id: key, name: g.name, bundlePath: g.bundlePath, pids: a.pids, watts: watts,
                                cpuPercent: cpuPct, memBytes: a.mem, sessionJoules: g.sessionJ, isApp: g.isApp))
        }
        // Keep quit apps in the session totals, but drop them from memory after a long while.
        for (key, g) in groups where acc[key] == nil {
            session += g.sessionJ
            if tick - g.lastSeen > 2000 && g.sessionJ < 1 { groups[key] = nil }
        }
        out.sort { $0.watts > $1.watts }
        if let onSample, !slices.isEmpty { onSample(slices) }
        DispatchQueue.main.async {
            self.apps = out
            self.totalWatts = total
            self.sessionJoules = session
        }
    }

    // MARK: Grouping

    private func resolveGroup(for pid: pid_t) -> String {
        var owner = pid
        if let responsible, case let r = responsible(pid), r > 1 { owner = r }
        let path = EnergyMonitor.path(of: owner) ?? EnergyMonitor.path(of: pid) ?? ""
        let key: String, name: String, bundle: String?, isApp: Bool
        if let app = EnergyMonitor.outermostApp(in: path) {
            key = app
            bundle = app
            name = String((app as NSString).lastPathComponent.dropLast(4))
            isApp = true
        } else if !path.isEmpty {
            name = (path as NSString).lastPathComponent
            key = "proc:" + name
            bundle = nil
            isApp = false
        } else {
            name = "pid \(pid)"
            key = "proc:unknown"
            bundle = nil
            isApp = false
        }
        if groups[key] == nil {
            groups[key] = Group(name: key == "proc:unknown" ? "Other processes" : name, bundlePath: bundle, isApp: isApp)
        }
        return key
    }

    static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper.app/…" -> "/Applications/Google Chrome.app"
    static func outermostApp(in path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }
}
