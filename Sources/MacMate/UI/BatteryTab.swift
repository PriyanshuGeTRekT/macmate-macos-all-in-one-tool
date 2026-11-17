import Charts
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
            BatteryHistorySections()
            DeviceBatterySection()
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

// MARK: - History

/// "Battery Level" chart and "Most Energy Used" list for the last 24 hours or 7 days.
struct BatteryHistorySections: View {
    @ObservedObject private var history = BatteryHistory.shared
    @ObservedObject private var battery = BatteryService.shared
    @AppStorage("battery.historyRange") private var rangeValue = BatteryHistoryRange.day.rawValue

    private var range: BatteryHistoryRange { BatteryHistoryRange(rawValue: rangeValue) ?? .day }

    var body: some View {
        let now = Date()
        let points = history.points(for: range, now: now)
        Section {
            if points.count < 2 {
                Text("Battery levels appear here as MacMate records them.")
                    .foregroundStyle(.secondary)
            } else {
                BatteryLevelChart(points: points, range: range, now: now)
                    .frame(height: 120)
                    .padding(.vertical, 4)
            }
        } header: {
            HStack {
                Text("Battery Level")
                Spacer()
                Picker("Range", selection: $rangeValue) {
                    ForEach(BatteryHistoryRange.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        } footer: {
            Text(drainText(now: now))
        }

        let top = history.topApps(for: range, now: now)
        if !top.isEmpty {
            Section {
                let most = top.first?.joules ?? 1
                ForEach(top) { usage in
                    HStack(spacing: 10) {
                        AppIcon(path: usage.bundlePath)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(usage.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(Fmt.energy(joules: usage.joules)).monospacedDigit()
                            }
                            CapacityBar(fraction: usage.joules / max(most, 0.001), color: .accentColor)
                            if battery.info.fullWh > 0 {
                                Text(shareText(usage.joules))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Most Energy Used")
            } footer: {
                Text("Processor energy per app over the \(range == .day ? "last 24 hours" : "last 7 days"), plugged in or not.")
            }
        }
    }

    private func shareText(_ joules: Double) -> String {
        let share = joules / 3600 / battery.info.fullWh * 100
        return share >= 1 ? "\(Int(share.rounded()))% of a full charge" : "under 1% of a full charge"
    }

    private func drainText(now: Date) -> String {
        let drain = history.drain(for: range, now: now)
        guard drain.hours >= 0.25 else {
            return "Recorded while MacMate is running. Gaps are times the Mac was asleep or MacMate was closed."
        }
        let minutes = Int((drain.hours * 60).rounded())
        var text = "On battery for \(Fmt.duration(minutes: minutes))"
        if drain.percent <= 100 { text += ", using \(drain.percent)% of the charge" }
        if drain.hours >= 0.5 { text += String(format: ", about %.0f%% per hour", Double(drain.percent) / drain.hours) }
        return text + "."
    }
}

/// Charge level over time; times spent charging are shaded green.
struct BatteryLevelChart: View {
    let points: [BatteryChartPoint]
    let range: BatteryHistoryRange
    let now: Date

    private struct Span: Identifiable {
        let id: Int
        let start: Date
        let end: Date
    }

    /// Stretches of time spent charging.
    private var charging: [Span] {
        var spans: [Span] = []
        var start: Date?
        for (a, b) in zip(points, points.dropFirst()) {
            if a.charging, a.run == b.run {
                if start == nil { start = a.date }
            } else if let s = start {
                spans.append(Span(id: spans.count, start: s, end: a.date))
                start = nil
            }
        }
        if let s = start, let last = points.last { spans.append(Span(id: spans.count, start: s, end: last.date)) }
        return spans.filter { $0.end > $0.start }
    }

    /// Whole hours or midnights inside the range, leaving room at the right edge for the labels.
    private func ticks(every step: TimeInterval) -> [Date] {
        let calendar = Calendar.current
        let start = now.addingTimeInterval(-range.seconds)
        var date = step >= 86_400 ? calendar.startOfDay(for: start).addingTimeInterval(86_400)
            : calendar.dateInterval(of: .hour, for: start)?.end ?? start
        if step < 86_400 {
            // Align to multiples of the step (12 AM, 6 AM, 12 PM, 6 PM).
            while calendar.component(.hour, from: date) % Int(step / 3600) != 0 { date.addTimeInterval(3600) }
        }
        var result: [Date] = []
        while date < now.addingTimeInterval(-range.seconds * 0.08) {
            result.append(date)
            date.addTimeInterval(step)
        }
        return result
    }

    var body: some View {
        Chart {
            ForEach(charging) { span in
                RectangleMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end),
                              yStart: .value("Low", 0), yEnd: .value("High", 100))
                    .foregroundStyle(Color.green.opacity(0.13))
            }
            ForEach(points) { point in
                AreaMark(x: .value("Time", point.date), y: .value("Charge", point.percent),
                         series: .value("Run", point.run), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [Color.green.opacity(0.32), Color.green.opacity(0.03)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.date), y: .value("Charge", point.percent),
                         series: .value("Run", point.run))
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .chartXScale(domain: now.addingTimeInterval(-range.seconds)...now)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
        }
        .chartXAxis {
            if range == .day {
                AxisMarks(values: ticks(every: 6 * 3600)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            } else {
                AxisMarks(values: ticks(every: 86_400)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                }
            }
        }
        .accessibilityLabel("Battery level over the \(range == .day ? "last 24 hours" : "last 7 days")")
    }
}

// MARK: - Devices

/// AirPods, mice, keyboards and other connected accessories that report a battery level.
struct DeviceBatterySection: View {
    @ObservedObject private var devices = DeviceBatteries.shared

    var body: some View {
        if !devices.devices.isEmpty {
            Section("Devices") {
                ForEach(devices.devices) { device in
                    LabeledContent {
                        Text(device.levelText)
                            .monospacedDigit()
                            .foregroundStyle((device.lowest ?? 100) <= 20 ? Color.red : Color.secondary)
                    } label: {
                        Label(device.name, systemImage: device.symbol)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
