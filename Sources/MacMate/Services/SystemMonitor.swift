import Darwin
import Foundation
import IOKit

struct SystemStats {
    var cpuTotal = 0.0            // 0…100
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var perCore: [Double] = []
    var efficiencyCores = 0
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var memPressure = 1           // 1 normal, 2 warning, 4 critical
    var diskTotal: UInt64 = 0
    var diskFree: UInt64 = 0
    var netDown = 0.0             // bytes/s
    var netUp = 0.0
    var gpu: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var uptime: TimeInterval = 0
    var loadAvg = 0.0

    var memPercent: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) * 100 : 0 }
    var diskUsedPercent: Double { diskTotal > 0 ? Double(diskTotal - diskFree) / Double(diskTotal) * 100 : 0 }

    var thermalText: String {
        switch thermal {
        case .nominal: return "Normal"
        case .fair: return "Warm"
        case .serious: return "Hot"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    var pressureText: String { memPressure >= 4 ? "Critical" : memPressure >= 2 ? "Warning" : "Normal" }
}

final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published private(set) var stats = SystemStats()
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistory: [Double] = []
    @Published private(set) var gpuHistory: [Double] = []
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []

    private let queue = DispatchQueue(label: "macmate.system", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var interval: TimeInterval = 5
    private var prevTicks: [[UInt32]] = []
    private var prevNet: (rx: UInt64, tx: UInt64, at: UInt64)?
    private var diskCounter = 0
    private var cachedDisk: (UInt64, UInt64) = (0, 0)
    private let historyLength = 60

    func start() {
        queue.async { self.sample() }
        schedule()
    }

    func setFast(_ fast: Bool) {
        let new: TimeInterval = fast ? 1.5 : 5
        guard new != interval else { return }
        interval = new
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    func sample() {
        var s = SystemStats()
        readCPU(&s)
        readMemory(&s)
        readDisk(&s)
        readNetwork(&s)
        s.gpu = SystemMonitor.gpuUtilization()
        s.thermal = ProcessInfo.processInfo.thermalState
        s.uptime = ProcessInfo.processInfo.systemUptime
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { s.loadAvg = load[0] }
        var eff: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel1.logicalcpu", &eff, &sz, nil, 0) == 0 { s.efficiencyCores = Int(eff) }

        DispatchQueue.main.async {
            self.stats = s
            self.push(&self.cpuHistory, s.cpuTotal)
            self.push(&self.memHistory, s.memPercent)
            self.push(&self.gpuHistory, s.gpu ?? 0)
            self.push(&self.downHistory, s.netDown)
            self.push(&self.upHistory, s.netUp)
        }
    }

    private func push(_ arr: inout [Double], _ v: Double) {
        arr.append(v)
        if arr.count > historyLength { arr.removeFirst(arr.count - historyLength) }
    }

    // MARK: CPU

    private func readCPU(_ s: inout SystemStats) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var ticks: [[UInt32]] = []
        for i in 0..<Int(count) {
            let base = Int(CPU_STATE_MAX) * i
            ticks.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return }
        var user = 0.0, sys = 0.0, all = 0.0
        for (now, old) in zip(ticks, prevTicks) {
            let u = Double(now[0] &- old[0]) + Double(now[3] &- old[3])
            let k = Double(now[1] &- old[1])
            let idle = Double(now[2] &- old[2])
            let t = u + k + idle
            s.perCore.append(t > 0 ? (u + k) / t * 100 : 0)
            user += u; sys += k; all += t
        }
        if all > 0 {
            s.cpuUser = user / all * 100
            s.cpuSystem = sys / all * 100
            s.cpuTotal = s.cpuUser + s.cpuSystem
        }
    }

    // MARK: Memory

    private func readMemory(_ s: inout SystemStats) {
        s.memTotal = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = UInt64(vm_kernel_page_size)
        let internalPages = UInt64(vm.internal_page_count)
        let purgeable = UInt64(vm.purgeable_count)
        s.memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        s.memWired = UInt64(vm.wire_count) * page
        s.memCompressed = UInt64(vm.compressor_page_count) * page
        s.memCached = (UInt64(vm.external_page_count) + purgeable) * page
        s.memUsed = min(s.memTotal, s.memApp + s.memWired + s.memCompressed)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { s.swapUsed = swap.xsu_used }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 { s.memPressure = Int(level) }
    }

    // MARK: Disk

    private func readDisk(_ s: inout SystemStats) {
        if diskCounter % 10 == 0 {
            let url = URL(fileURLWithPath: NSHomeDirectory())
            if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                cachedDisk = (UInt64(v.volumeTotalCapacity ?? 0), UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0)))
            }
        }
        diskCounter += 1
        s.diskTotal = cachedDisk.0
        s.diskFree = cachedDisk.1
    }

    // MARK: Network

    private func readNetwork(_ s: inout SystemStats) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return }
        var rx: UInt64 = 0, tx: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen <= 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let loopback = (h2.ifm_flags & IFF_LOOPBACK) != 0
                    // Physical interfaces only (Ethernet/Wi‑Fi = IFT_ETHER, cellular = IFT_CELLULAR).
                    let type = Int32(h2.ifm_data.ifi_type)
                    if !loopback && (type == IFT_ETHER || type == IFT_CELLULAR) {
                        rx += h2.ifm_data.ifi_ibytes
                        tx += h2.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let p = prevNet, now > p.at {
            let dt = Double(now - p.at) / 1e9
            if rx >= p.rx { s.netDown = Double(rx - p.rx) / dt }
            if tx >= p.tx { s.netUp = Double(tx - p.tx) / dt }
        }
        prevNet = (rx, tx, now)
    }

    // MARK: GPU

    static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                let util = (stats["Device Utilization %"] as? NSNumber)?.doubleValue {
                best = max(best ?? 0, util)
            }
        }
        return best
    }
}
