import Carbon.HIToolbox
import SwiftUI

// MARK: - Clipboard

struct ClipboardTab: View {
    @ObservedObject private var clipboard = ClipboardHistory.shared
    @AppStorage(Keys.clipEnabled) private var enabled = true
    @AppStorage(Keys.clipAutoPaste) private var autoPaste = true
    @ViewState private var query = ""

    private var filtered: [ClipItem] {
        let all = clipboard.items.sorted { ($0.pinned ? 0 : 1) < ($1.pinned ? 0 : 1) }
        guard !query.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search", text: $query, prompt: Text("Search clipboard history"))
                    .labelsHidden()
            }
            Section {
                if filtered.isEmpty {
                    Text(clipboard.items.isEmpty ? "Text you copy appears here." : "No matches.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { item in
                        Button { choose(item) } label: { ClipRow(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(item.pinned ? "Unpin" : "Pin") { clipboard.togglePin(item) }
                                Button("Delete", role: .destructive) { clipboard.delete(item) }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("History")
                    Spacer()
                    Button("Clear") { clipboard.clear() }
                        .buttonStyle(.link)
                        .disabled(clipboard.items.isEmpty)
                }
            } footer: {
                Text("Press ⌃⌥V anywhere to open this list. Right-click an item to pin it.")
            }
            Section {
                Toggle("Keep clipboard history", isOn: $enabled)
                Toggle("Paste into the app straight away", isOn: $autoPaste)
            } footer: {
                Text("Kept in memory only and cleared when MacMate quits. Passwords copied from password managers are never recorded.")
            }
        }
    }

    private func choose(_ item: ClipItem) {
        clipboard.copy(item)
        MenuBarPanel.close()
        guard autoPaste, Permissions.accessibility else { return }
        let target = WindowManager.shared.lastExternalApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            target?.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { postKey(kVK_ANSI_V, flags: .maskCommand) }
        }
    }
}

private struct ClipRow: View {
    let item: ClipItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .lineLimit(2)
                    .truncationMode(.tail)
                Text([item.source, item.date.formatted(date: .omitted, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.pinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Tools

struct ToolsTab: View {
    @ObservedObject private var mic = MicMute.shared
    @ObservedObject private var keyboard = KeyboardFeatures.shared
    @ObservedObject private var dimmer = DisplayDimmer.shared
    @AppStorage(Keys.cmdQGuard) private var cmdQGuard = false
    @AppStorage(Keys.finderCut) private var finderCut = false
    @ViewState private var hiddenFiles = SystemToggles.hiddenFilesShown
    @ViewState private var desktopHidden = SystemToggles.desktopIconsHidden
    @ViewState private var darkMode = SystemToggles.darkMode

    var body: some View {
        Form {
            Section("Cleanup") {
                Button { open(.uninstall) } label: {
                    ToolLink(title: "Uninstall Apps", detail: "Remove an app with all its leftover files", symbol: "trash")
                }
                Button { open(.junk) } label: {
                    ToolLink(title: "Clean Up Junk", detail: "Caches, logs and developer leftovers", symbol: "sparkles")
                }
            }
            .buttonStyle(.plain)

            Section("Quick Actions") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ActionTile(title: "Copy Text", symbol: "text.viewfinder") { MenuBarPanel.close(); ScreenOCR.capture() }
                        .help("Drag over any part of the screen to copy the text in it  ⌃⌥O")
                    ActionTile(title: "Pick Color", symbol: "eyedropper") { MenuBarPanel.close(); SystemToggles.pickColor() }
                        .help("Copy the hex value of any pixel  ⌃⌥P")
                    ActionTile(title: mic.muted ? "Unmute" : "Mute Mic", symbol: mic.muted ? "mic.slash.fill" : "mic.fill", active: mic.muted) { mic.toggle() }
                        .help("Mute the microphone everywhere  ⌃⌥A")
                    ActionTile(title: "Lock Keys", symbol: "keyboard") { MenuBarPanel.close(); keyboard.lockKeyboard() }
                        .help("Ignore the keyboard while you clean it")
                    ActionTile(title: "Sleep Display", symbol: "moon.fill") { MenuBarPanel.close(); inBackground { SystemToggles.sleepDisplay() } }
                    ActionTile(title: "Eject Disks", symbol: "eject.fill") {
                        inBackground {
                            let names = SystemToggles.ejectAll()
                            HUD.shared.show(names.isEmpty ? "No external disks to eject" : "Ejected \(names.joined(separator: ", "))", symbol: "eject")
                        }
                    }
                    ActionTile(title: "Restart Finder", symbol: "face.smiling") { inBackground { SystemToggles.restartFinder() } }
                    ActionTile(title: "Restart Dock", symbol: "dock.rectangle") { inBackground { SystemToggles.restartDock() } }
                }
                .padding(.vertical, 2)
            }

            Section("Finder & Appearance") {
                Toggle("Show hidden files", isOn: $hiddenFiles)
                    .onChange(of: hiddenFiles) { _, on in inBackground { SystemToggles.setHiddenFilesShown(on) } }
                Toggle("Hide desktop icons", isOn: $desktopHidden)
                    .onChange(of: desktopHidden) { _, on in inBackground { SystemToggles.setDesktopIconsHidden(on) } }
                Toggle("Dark appearance", isOn: $darkMode)
                    .onChange(of: darkMode) { _, on in inBackground { _ = SystemToggles.setDarkMode(on) } }
            }

            Section {
                Toggle("Hold ⌘Q to quit", isOn: $cmdQGuard)
                Toggle("Cut and paste files in Finder with ⌘X and ⌘V", isOn: $finderCut)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Holding ⌘Q for a moment protects you from quitting an app by accident. Both options need Accessibility access.")
            }

            Section {
                ForEach(dimmer.displays) { display in
                    LabeledContent(display.name) {
                        Slider(value: Binding(get: { dimmer.level(for: display.id) }, set: { dimmer.set($0, for: display.id) }), in: 0.2...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Image(systemName: "sun.min").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "sun.max").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Display Dimming")
            } footer: {
                Text("Dims in software, so it works on external monitors whose brightness macOS cannot change.")
            }
        }
        .onAppear {
            mic.refresh()
            dimmer.refreshDisplays()
        }
    }

    private func open(_ mode: CleanupMode) {
        MenuBarPanel.close()
        CleanupWindow.show(mode)
    }
}

private struct ToolLink: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// A Control Center–style tile: a round glass button with a caption beneath it.
private struct ActionTile: View {
    let title: String
    let symbol: String
    var active = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .glassButton()
            .buttonBorderShape(.circle)
            .tint(active ? .red : nil)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject private var state = AppState.shared
    @AppStorage(Keys.barShowTime) private var showTime = false
    @AppStorage(Keys.barShowWatts) private var showWatts = false
    @AppStorage(Keys.barShowCPU) private var showCPU = false
    @AppStorage(Keys.barShowNet) private var showNet = false
    @AppStorage(Keys.alertLow) private var alertLow = true
    @AppStorage(Keys.alertLowLevel) private var alertLowLevel = 20
    @AppStorage(Keys.alertHigh) private var alertHigh = false
    @AppStorage(Keys.alertHighLevel) private var alertHighLevel = 80
    @ViewState private var launchAtLogin = LoginItem.enabled

    var body: some View {
        Form {
            Section("Show in Menu Bar") {
                Toggle("Time remaining", isOn: $showTime)
                Toggle("System power in watts", isOn: $showWatts)
                Toggle("Processor load", isOn: $showCPU)
                Toggle("Download speed", isOn: $showNet)
            }
            Section("Battery Alerts") {
                Toggle("Warn when battery is low", isOn: $alertLow)
                if alertLow { Stepper("At \(alertLowLevel)%", value: $alertLowLevel, in: 5...50, step: 5) }
                Toggle("Remind me to unplug when charged", isOn: $alertHigh)
                if alertHigh { Stepper("At \(alertHighLevel)%", value: $alertHighLevel, in: 50...100, step: 5) }
            }
            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .disabled(!LoginItem.available)
                    .onChange(of: launchAtLogin) { _, on in
                        if !LoginItem.set(on) { launchAtLogin = LoginItem.enabled }
                    }
                LabeledContent("Accessibility access") {
                    if state.accessibilityGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            Permissions.requestAccessibility()
                            Permissions.openAccessibilitySettings()
                        }
                    }
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                Button("Quit MacMate") { NSApp.terminate(nil) }
            }
        }
    }
}
