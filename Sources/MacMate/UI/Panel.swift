import Charts
import SwiftUI

/// The panel that drops down from the menu bar. System controls on the system's own glass.
struct PanelView: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.tab.title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("Section", selection: $state.tab) {
                    ForEach(PanelTab.allCases) { tab in
                        Image(systemName: tab.symbol)
                            .accessibilityLabel(tab.title)
                            .help(tab.title)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Group {
                switch state.tab {
                case .battery: BatteryTab()
                case .monitor: MonitorTab()
                case .awake: AwakeTab()
                case .windows: WindowsTab()
                case .input: InputTab()
                case .sound: SoundTab()
                case .calendar: CalendarTab()
                case .clipboard: ClipboardTab()
                case .tools: ToolsTab()
                case .settings: SettingsTab()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 400, height: 620)
    }
}

// MARK: - Shared pieces

/// Shown at the top of any section that needs Accessibility access before it can work.
struct AccessibilityNotice: View {
    @ObservedObject private var state = AppState.shared
    let reason: String

    var body: some View {
        if !state.accessibilityGranted {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Accessibility access needed", systemImage: "hand.raised.fill")
                        .font(.headline)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy & Security Settings") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Other utilities that hook the same input. Two apps rewriting the same events fight each other.
enum Conflicts {
    static let mouse = ["com.nuebling.mac-mouse-fix": "Mac Mouse Fix", "com.lujjjh.linearmouse": "LinearMouse",
                        "com.caldis.mos": "Mos", "com.pilotmoon.scroll-reverser": "Scroll Reverser"]
    static let windows = ["com.knollsoft.rectangle": "Rectangle", "com.knollsoft.hookshot": "Rectangle Pro",
                          "com.crowdcafe.windowmagnet": "Magnet", "com.lwouis.alt-tab-macos": "AltTab"]

    static var suppressed = false

    static func running(_ table: [String: String]) -> [(name: String, apps: [NSRunningApplication])] {
        if suppressed { return [] }
        var found: [String: [NSRunningApplication]] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier?.lowercased() else { continue }
            for (prefix, name) in table where id == prefix || id.hasPrefix(prefix + ".") {
                found[name, default: []].append(app)
            }
        }
        return found.map { (name: $0.key, apps: $0.value) }.sorted { $0.name < $1.name }
    }
}

struct ConflictNotice: View {
    let table: [String: String]
    let consequence: String
    @ViewState private var conflicts: [(name: String, apps: [NSRunningApplication])]

    init(table: [String: String], consequence: String) {
        self.table = table
        self.consequence = consequence
        // Checked up front: an empty section never "appears", so onAppear alone would never fire.
        _conflicts = ViewState(initialValue: Conflicts.running(table))
    }

    var body: some View {
        Group {
            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts, id: \.name) { conflict in
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(conflict.name) is also running", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .symbolRenderingMode(.multicolor)
                            Text(consequence)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Quit \(conflict.name)") {
                                conflict.apps.forEach { $0.terminate() }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { conflicts = Conflicts.running(table) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var maximum: Double?
    var color: Color = .accentColor

    var body: some View {
        let top = maximum ?? max(values.max() ?? 1, 1)
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("Time", point.offset), y: .value("Value", point.element))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.offset), y: .value("Value", point.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...59)
        .chartYScale(domain: 0...top)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }
}

/// A thin capacity bar, like the storage bars in System Settings.
struct CapacityBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}

struct AppIcon: View {
    let path: String?
    var size: CGFloat = 26
    var body: some View {
        Image(nsImage: IconCache.shared.icon(forPath: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

extension Double {
    /// Green → yellow → red as a share of something approaches its limit.
    var loadColor: Color { self < 0.6 ? .green : self < 0.85 ? .yellow : .red }
}

/// The property-wrapper form of SwiftUI's `State`. Spelled through an alias so the project builds with
/// the Command Line Tools alone (the `@State` macro form needs a compiler plugin that only ships in Xcode).
typealias ViewState<Value> = SwiftUI.State<Value>

extension View {
    /// The prominent Liquid Glass button style, with a plain fallback where glass cannot be drawn.
    @ViewBuilder func prominentGlassButton() -> some View {
        if Snapshot.active { buttonStyle(.borderedProminent) } else { buttonStyle(.glassProminent) }
    }

    @ViewBuilder func glassButton() -> some View {
        if Snapshot.active { buttonStyle(.bordered) } else { buttonStyle(.glass) }
    }
}
