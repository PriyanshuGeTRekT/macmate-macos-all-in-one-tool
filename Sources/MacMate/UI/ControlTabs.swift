import SwiftUI

// MARK: - Keep Awake

struct AwakeTab: View {
    @ObservedObject private var awake = KeepAwake.shared
    @AppStorage(Keys.awakeDisplay) private var keepDisplay = true
    @AppStorage(Keys.awakeBatteryStop) private var stopOnLow = true
    @ViewState private var customHours = 0
    @ViewState private var customMinutes = 45

    private let presets: [(String, Double)] = [("15 min", 15), ("30 min", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)]

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { awake.isActive }, set: { $0 ? awake.start(minutes: nil) : awake.stop() })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Awake")
                            Text(awake.statusText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                            .foregroundStyle(awake.isActive ? Color.orange : .secondary)
                    }
                }
            }
            Section("Stay Awake For") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(presets, id: \.0) { preset in
                        Button { awake.start(minutes: preset.1) } label: {
                            Text(preset.0).frame(maxWidth: .infinity)
                        }
                    }
                }
                .controlSize(.large)
                .padding(.vertical, 2)
                Button { awake.start(minutes: nil) } label: {
                    Label("Until I Turn It Off", systemImage: "infinity").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            Section("Custom") {
                Stepper("Hours: \(customHours)", value: $customHours, in: 0...48)
                Stepper("Minutes: \(customMinutes)", value: $customMinutes, in: 0...59, step: 5)
                Button("Start for \(customLabel)") {
                    awake.start(minutes: Double(customHours * 60 + customMinutes))
                }
                .disabled(customHours == 0 && customMinutes == 0)
            }
            Section {
                Toggle("Keep the display on too", isOn: $keepDisplay)
                    .onChange(of: keepDisplay) { _, _ in awake.optionsChanged() }
                Toggle("Turn off when battery drops to 10%", isOn: $stopOnLow)
            } footer: {
                Text("With the display option off, the screen may dim and sleep but the Mac keeps running. Closing the lid still puts a MacBook to sleep.")
            }
        }
    }

    private var customLabel: String {
        Fmt.duration(minutes: customHours * 60 + customMinutes)
    }
}

// MARK: - Windows

struct WindowsTab: View {
    @ObservedObject private var manager = WindowManager.shared
    @AppStorage(Keys.tileHotkeys) private var hotkeys = true
    @AppStorage(Keys.tileDragSnap) private var dragSnap = false
    @AppStorage(Keys.tileGap) private var gap = 0
    @AppStorage(Keys.switcherEnabled) private var switcher = false
    @ViewState private var showShortcuts = false

    private let grid: [TileAction] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize,
        .topLeft, .topRight, .bottomLeft, .bottomRight, .almostMaximize,
        .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds,
    ]

    var body: some View {
        Form {
            AccessibilityNotice(reason: "MacMate needs it to move and resize other apps' windows.")
            ConflictNotice(table: Conflicts.windows, consequence: "It uses the same shortcuts and edge snapping, so windows may be moved twice. Keep only one of the two running.")
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(grid) { action in
                        Button { manager.perform(action) } label: {
                            TileGlyph(unit: action.unitRect ?? .zero).frame(maxWidth: .infinity)
                        }
                        .help("\(action.title)  ⌃⌥\(action.keyLabel)")
                        .accessibilityLabel(action.title)
                    }
                }
                .controlSize(.large)
                .padding(.vertical, 2)
                HStack(spacing: 8) {
                    Button { manager.perform(.center) } label: { Text("Center").frame(maxWidth: .infinity) }
                    Button { manager.perform(.restore) } label: { Text("Restore").frame(maxWidth: .infinity) }
                    Button { manager.perform(.nextDisplay) } label: { Text("Next Display").frame(maxWidth: .infinity) }
                }
            } header: {
                Text("Arrange Front Window")
            } footer: {
                Text(manager.lastExternalApp?.localizedName.map { "Applies to the front window of \($0)." } ?? "Applies to the window you were last using.")
            }
            Section {
                Toggle("Keyboard shortcuts", isOn: $hotkeys)
                    .onChange(of: hotkeys) { _, _ in manager.applySettings() }
                DisclosureGroup("Shortcut list", isExpanded: $showShortcuts) {
                    ForEach(TileAction.allCases) { action in
                        LabeledContent(action.title) {
                            Text("⌃⌥\(action.keyLabel)").monospaced().foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Snap when dragged to a screen edge", isOn: $dragSnap)
                    .onChange(of: dragSnap) { _, _ in manager.applySettings() }
                Stepper("Gap between windows: \(gap) pt", value: $gap, in: 0...24, step: 2)
            } footer: {
                Text(snapFootnote)
            }
            Section {
                Toggle("Switch windows with ⌥Tab", isOn: $switcher)
            } footer: {
                Text("Hold ⌥ and press Tab to step through every open window, not just apps. Release ⌥ to switch.")
            }
        }
    }

    private var snapFootnote: String {
        var text = "Press ← or → again to cycle between half, two thirds and one third. Drag to a side for halves, a corner for quarters, the top to maximize, or the bottom for thirds."
        if WindowManager.nativeEdgeTilingEnabled {
            text += " macOS has its own edge tiling switched on in Desktop & Dock settings; turn that off if you see two previews."
        }
        return text
    }
}

/// A tiny screen with the target region filled in.
private struct TileGlyph: View {
    let unit: CGRect

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 2
            let w = geo.size.width - inset * 2, h = geo.size.height - inset * 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.secondary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: max(2, unit.width * w), height: max(2, unit.height * h))
                    .offset(x: inset + unit.minX * w, y: inset + unit.minY * h)
            }
        }
        .frame(width: 34, height: 23)
    }
}

// MARK: - Mouse

struct MouseTab: View {
    @ObservedObject private var mouse = MouseManager.shared
    @AppStorage(Keys.mouseEnabled) private var enabled = true
    @AppStorage(Keys.mouseReverse) private var reverse = true
    @AppStorage(Keys.mouseReverseH) private var reverseH = false
    @AppStorage(Keys.mouseSmooth) private var smooth = true
    @AppStorage(Keys.mouseScrollSpeed) private var scrollSpeed = 1.0
    @AppStorage(Keys.mouseButton2) private var button2 = MouseAction.passThrough.rawValue
    @AppStorage(Keys.mouseButton3) private var button3 = MouseAction.back.rawValue
    @AppStorage(Keys.mouseButton4) private var button4 = MouseAction.forward.rawValue
    @AppStorage(Keys.mouseLinear) private var linear = false
    @AppStorage(Keys.mouseSpeedOverride) private var speedOverride = false
    @AppStorage(Keys.mouseSpeed) private var speed = 1.0

    var body: some View {
        Form {
            AccessibilityNotice(reason: "MacMate needs it to adjust scrolling and extra buttons from your mouse.")
            ConflictNotice(table: Conflicts.mouse, consequence: "Both apps would rewrite the same scroll and button events, which cancels out or doubles the effect. Keep only one of the two running.")
            Section {
                Toggle("Mouse enhancements", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in mouse.pointerSettingsChanged() }
                if mouse.thirdPartyMice.isEmpty {
                    Label("No mouse connected. Plug one in or pair it and it appears here automatically.", systemImage: "computermouse")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mouse.thirdPartyMice) { device in
                        LabeledContent {
                            Text(device.battery.map { "\($0)%" } ?? device.transport)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label(device.name, systemImage: "computermouse.fill")
                        }
                    }
                }
            } footer: {
                Text("Only ordinary mice are affected. The trackpad and Magic Mouse keep their own settings.")
            }
            Group {
                Section("Scrolling") {
                    Toggle("Reverse wheel direction", isOn: $reverse)
                    Toggle("Reverse horizontal wheel", isOn: $reverseH)
                    Toggle("Smooth scrolling", isOn: $smooth)
                    LabeledContent("Scroll speed") {
                        Slider(value: $scrollSpeed, in: 0.4...3) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "hare").foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Buttons") {
                    actionPicker("Middle button", $button2)
                    actionPicker("Back side button", $button3)
                    actionPicker("Forward side button", $button4)
                }
                Section {
                    Toggle("Turn off pointer acceleration", isOn: $linear)
                        .onChange(of: linear) { _, _ in mouse.pointerSettingsChanged() }
                    Toggle("Separate tracking speed for mice", isOn: $speedOverride)
                        .onChange(of: speedOverride) { _, _ in mouse.pointerSettingsChanged() }
                    if speedOverride {
                        LabeledContent("Tracking speed") {
                            Slider(value: $speed, in: 0...3) { editing in
                                if !editing { mouse.pointerSettingsChanged() }
                            }
                        }
                    }
                } header: {
                    Text("Pointer")
                } footer: {
                    Text("Pointer settings are sent to each mouse when it connects. Unplug and reconnect the mouse to go back to the system setting.")
                }
            }
            .disabled(!enabled)
        }
    }

    private func actionPicker(_ title: String, _ selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MouseAction.allCases) { action in
                Text(action.title).tag(action.rawValue)
            }
        }
    }
}
