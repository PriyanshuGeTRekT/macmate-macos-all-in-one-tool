import SwiftUI

/// Brightness for every connected display, one group each, plus the brightness-key option.
/// Made of `Section`s only, so it drops into any grouped `Form`.
struct DisplaysSection: View {
    @ObservedObject private var control = DisplayControl.shared
    @ObservedObject private var state = AppState.shared
    @AppStorage(Keys.displaysBrightnessKeys) private var brightnessKeys = true

    var body: some View {
        Group {
            ForEach(Array(control.displays.enumerated()), id: \.element.id) { index, display in
                if index == 0 {
                    Section { DisplayGroupRows(display: display) } header: { Text("Displays") }
                } else {
                    Section { DisplayGroupRows(display: display) }
                }
            }
            Section {
                Toggle("Brightness keys control the display under the pointer", isOn: $brightnessKeys)
            } footer: {
                Text(footer)
            }
        }
        .onAppear { control.refreshLevels() }
    }

    private var footer: String {
        var text = "Works with external monitors that support DDC/CI. Dim further darkens the picture below the lowest hardware setting."
        if !state.accessibilityGranted { text += " The brightness keys need Accessibility access." }
        return text
    }
}

/// The rows for one display: its name and how it is controlled, then its sliders.
private struct DisplayGroupRows: View {
    @ObservedObject private var control = DisplayControl.shared
    @ObservedObject private var dimmer = DisplayDimmer.shared
    let display: DisplayDevice

    var body: some View {
        LabeledContent {
            if display.control == .checking {
                ProgressView().controlSize(.small)
            } else if display.hasHardwareBrightness {
                Text(Fmt.percent(display.brightness * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: display.builtIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
            }
        }

        if display.hasHardwareBrightness || display.control == .checking {
            LabeledContent("Brightness") {
                Slider(value: brightness, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
                .frame(width: DisplayGroupRows.sliderWidth)
                .accessibilityLabel("Brightness of \(display.name)")
            }
            .disabled(display.control == .checking)
            LabeledContent("Dim further") {
                Slider(value: dim, in: 0.2...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "moon").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                }
                .frame(width: DisplayGroupRows.sliderWidth)
                .accessibilityLabel("Software dimming of \(display.name)")
            }
        } else {
            LabeledContent("Brightness") {
                Slider(value: dim, in: 0.2...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }
                .frame(width: DisplayGroupRows.sliderWidth)
                .accessibilityLabel("Brightness of \(display.name)")
            }
        }
    }

    private static let sliderWidth: CGFloat = 220

    private var status: String {
        switch display.control {
        case .checking: return "Checking for hardware brightness…"
        case .ddc: return "External display · DDC/CI"
        case .system: return display.builtIn ? "Built-in display" : "External display"
        case .software(let silent):
            if silent { return "Doesn’t respond to DDC/CI, so it’s dimmed in software" }
            return display.builtIn ? "Built-in display · dimmed in software" : "Dimmed in software"
        }
    }

    private var brightness: Binding<Double> {
        let id = display.id
        return Binding(get: { control.displays.first { $0.id == id }?.brightness ?? 1 },
                       set: { control.setBrightness($0, for: id) })
    }

    private var dim: Binding<Double> {
        let id = display.id
        return Binding(get: { control.dimLevel(for: id) }, set: { control.setDim($0, for: id) })
    }
}
