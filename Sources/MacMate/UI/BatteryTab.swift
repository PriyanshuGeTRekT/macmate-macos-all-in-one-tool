import SwiftUI

struct BatteryTab: View {
    @ObservedObject private var battery = BatteryService.shared
    @ObservedObject private var energy = EnergyMonitor.shared
    @ViewState private var sinceUnplugged = false
    @ViewState private var showAll = false

    private var info: BatteryInfo { battery.info }

    var body: some View {
        Form {
            Section { hero }
            Section {
                energyRows
            } header: {
                HStack {
                    Text("Energy by App")
                    Spacer()
                    Picker("Period", selection: $sinceUnplugged) {
                        Text("Now").tag(false)
                        Text(info.onBattery ? "Since Unplugged" : "This Session").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            } footer: {
                Text(footnote)
            }
            Section("Battery Health") {
                LabeledContent("Maximum capacity", value: info.designMah > 0 ? "\(info.healthPercent)%" : "—")
                LabeledContent("Cycle count", value: "\(info.cycleCount)")
                if info.maxMah > 0 {
                    LabeledContent("Charge", value: "\(info.currentMah.formatted()) of \(info.maxMah.formatted()) mAh")
                }
                if let t = info.temperatureC {
                    LabeledContent("Temperature", value: String(format: "%.1f °C", t))
                }
                if info.isPluggedIn {
                    LabeledContent("Power adapter", value: info.adapterW.map { "\($0) W" } ?? "Connected")
                }
            }
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.hasBattery ? "\(info.percent)%" : "—")
                    .font(.system(size: 46, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.watts(info.systemLoadW))
                        .font(.title2.weight(.medium))
                        .monospacedDigit()
                    Text("system power")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            CapacityBar(fraction: Double(info.percent) / 100, color: levelColor)
            HStack {
                Label(info.statusText, systemImage: info.isPluggedIn ? "powerplug.fill" : "battery.100percent")
                    .labelStyle(.titleAndIcon)
                Spacer()
                Text(timeText).monospacedDigit()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var levelColor: Color {
        if info.isCharging { return .green }
        return info.percent <= 10 ? .red : info.percent <= 20 ? .yellow : .green
    }

    private var timeText: String {
        if info.isCharging, let m = info.minutesRemaining { return "\(Fmt.duration(minutes: m)) until full" }
        if info.onBattery {
            let rate = info.fullWh > 0 ? info.systemLoadW / info.fullWh * 100 : 0
            let left = info.minutesRemaining.map { "\(Fmt.duration(minutes: $0)) left" } ?? "Estimating…"
            return rate > 0 ? "\(left) · \(String(format: "%.0f", rate))% per hour" : left
        }
        return ""
    }

    // MARK: Energy list

    private var ranked: [AppUsage] {
        let list = sinceUnplugged
            ? energy.apps.filter { $0.sessionJoules > 0.5 }.sorted { $0.sessionJoules > $1.sessionJoules }
            : energy.apps.filter { $0.watts > 0.004 }
        return Array(list.prefix(showAll ? 40 : 6))
    }

    @ViewBuilder private var energyRows: some View {
        let rows = ranked
        if rows.isEmpty {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            let top = sinceUnplugged ? (rows.first?.sessionJoules ?? 1) : (rows.first?.watts ?? 1)
            ForEach(rows) { app in
                EnergyRow(app: app,
                          value: sinceUnplugged ? Fmt.energy(joules: app.sessionJoules) : Fmt.watts(app.watts),
                          detail: detail(for: app),
                          fraction: (sinceUnplugged ? app.sessionJoules : app.watts) / max(top, 0.0001))
            }
            Button(showAll ? "Show Less" : "Show All") { withAnimation(.snappy) { showAll.toggle() } }
                .buttonStyle(.link)
        }
    }

    /// The answer to "how fast is this app draining me?"
    private func detail(for app: AppUsage) -> String {
        guard info.fullWh > 0 else { return String(format: "CPU %.0f%%", app.cpuPercent) }
        if sinceUnplugged {
            let share = app.sessionJoules / 3600 / info.fullWh * 100
            return share >= 0.05 ? String(format: "%.1f%% of battery", share) : "under 0.1% of battery"
        }
        let perHour = app.watts / info.fullWh * 100
        var text = perHour >= 0.05 ? String(format: "%.1f%% per hour", perHour) : "negligible"
        let load = info.systemLoadW
        if info.onBattery, load - app.watts > 1, app.watts > 0.05 {
            let minutes = (info.remainingWh / (load - app.watts) - info.remainingWh / load) * 60
            if minutes >= 1 { text += " · \(Fmt.duration(minutes: Int(minutes))) less battery life" }
        }
        return text
    }

    private var footnote: String {
        let load = info.systemLoadW
        let apps = energy.totalWatts
        var text = "Measured by the chip's own per-process energy counters, not estimated from CPU load."
        if load > apps, apps > 0 {
            text = "Apps and background processes are using \(Fmt.watts(apps)). The display, graphics, radios and the rest of the system use the other \(Fmt.watts(load - apps)). " + text
        }
        return text
    }
}

private struct EnergyRow: View {
    let app: AppUsage
    let value: String
    let detail: String
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.bundlePath)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(value).monospacedDigit()
                }
                CapacityBar(fraction: fraction, color: fraction > 0.66 ? .orange : .accentColor)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let path = app.bundlePath {
                Button("Quit \(app.name)") {
                    NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path }?.terminate()
                }
                Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
            }
        }
    }
}
