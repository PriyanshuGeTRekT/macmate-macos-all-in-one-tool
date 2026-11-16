import SwiftUI

struct MonitorTab: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var energy = EnergyMonitor.shared
    @ViewState private var sortByMemory = false

    private var s: SystemStats { monitor.stats }

    var body: some View {
        Form {
            Section {
                MetricHeader(title: "Processor", symbol: "cpu", value: Fmt.percent(s.cpuTotal),
                             detail: String(format: "User %.0f%% · System %.0f%%", s.cpuUser, s.cpuSystem))
                Sparkline(values: monitor.cpuHistory, maximum: 100, color: .blue).frame(height: 40)
                if !s.perCore.isEmpty { CoreBars(usage: s.perCore, efficiency: s.efficiencyCores) }
            }
            Section {
                MetricHeader(title: "Memory", symbol: "memorychip", value: "\(Fmt.mem(s.memUsed)) of \(Fmt.mem(s.memTotal))",
                             detail: "Pressure: \(s.pressureText)")
                CapacityBar(fraction: s.memPercent / 100, color: s.memPressure >= 4 ? .red : s.memPressure >= 2 ? .yellow : .green)
                LabeledContent("App memory", value: Fmt.mem(s.memApp))
                LabeledContent("Wired", value: Fmt.mem(s.memWired))
                LabeledContent("Compressed", value: Fmt.mem(s.memCompressed))
                LabeledContent("Swap used", value: Fmt.mem(s.swapUsed))
            }
            Section {
                MetricHeader(title: "Network", symbol: "network", value: "↓ \(Fmt.rate(s.netDown))", detail: "↑ \(Fmt.rate(s.netUp))")
                Sparkline(values: monitor.downHistory, color: .teal).frame(height: 34)
            }
            Section {
                if let gpu = s.gpu {
                    MetricHeader(title: "Graphics", symbol: "square.stack.3d.up", value: Fmt.percent(gpu), detail: nil)
                    Sparkline(values: monitor.gpuHistory, maximum: 100, color: .purple).frame(height: 30)
                }
                MetricHeader(title: "Storage", symbol: "internaldrive", value: "\(Fmt.bytes(s.diskFree)) free",
                             detail: "of \(Fmt.bytes(s.diskTotal))")
                CapacityBar(fraction: s.diskUsedPercent / 100, color: (s.diskUsedPercent / 100).loadColor)
                LabeledContent("Thermal state", value: s.thermalText)
                LabeledContent("Uptime", value: uptimeText)
            }
            Section {
                ForEach(topProcesses) { app in
                    HStack(spacing: 10) {
                        AppIcon(path: app.bundlePath, size: 22)
                        Text(app.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(sortByMemory ? Fmt.mem(app.memBytes) : Fmt.percent(app.cpuPercent, digits: 1))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        if let path = app.bundlePath {
                            Button("Quit \(app.name)") {
                                NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }?.terminate()
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Top Processes")
                    Spacer()
                    Picker("Sort", selection: $sortByMemory) {
                        Text("CPU").tag(false)
                        Text("Memory").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
        }
    }

    private var topProcesses: [AppUsage] {
        let sorted = sortByMemory ? energy.apps.sorted { $0.memBytes > $1.memBytes } : energy.apps.sorted { $0.cpuPercent > $1.cpuPercent }
        return Array(sorted.prefix(7))
    }

    private var uptimeText: String {
        let minutes = Int(s.uptime / 60)
        let days = minutes / 1440
        return days > 0 ? "\(days)d \(Fmt.duration(minutes: minutes % 1440))" : Fmt.duration(minutes: minutes)
    }
}

private struct MetricHeader: View {
    let title: String
    let symbol: String
    let value: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: symbol).font(.headline)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.headline).monospacedDigit().contentTransition(.numericText())
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }
}

/// One slim bar per core; efficiency cores are drawn first and slightly dimmer.
private struct CoreBars: View {
    let usage: [Double]
    let efficiency: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(usage.enumerated()), id: \.offset) { index, value in
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.quaternary)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(index < efficiency ? Color.blue.opacity(0.55) : Color.blue)
                                .frame(height: max(1, geo.size.height * value / 100))
                        }
                    }
                }
            }
            .frame(height: 26)
            if efficiency > 0, efficiency < usage.count {
                Text("\(efficiency) efficiency · \(usage.count - efficiency) performance cores")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
