import CoreAudio
import SwiftUI

struct SoundTab: View {
    @ObservedObject private var mixer = AudioMixer.shared
    @ObservedObject private var mic = MicMute.shared

    var body: some View {
        Form {
            Section("Output") {
                Picker("Output", selection: Binding(get: { mixer.defaultOutput }, set: { mixer.setDefaultDevice($0, input: false) })) {
                    if !mixer.outputDevices.contains(where: { $0.id == mixer.defaultOutput }) {
                        Text("None").tag(mixer.defaultOutput)
                    }
                    ForEach(mixer.outputDevices) { Text($0.name).tag($0.id) }
                }
                if mixer.outputVolume != nil || mixer.outputMuted != nil {
                    outputRow
                }
            }

            if let problem = mixer.tapProblem {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("App volume isn't available", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .symbolRenderingMode(.multicolor)
                        Text(problem)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Privacy & Security Settings") { SoundCapturePermission.openSettings() }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                if mixer.apps.isEmpty {
                    Label("Apps appear here while they play sound.", systemImage: "speaker.wave.2")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(mixer.apps) { app in
                        SoundAppRow(app: app)
                    }
                }
            } header: {
                Text("Apps")
            } footer: {
                Text("Turning an app down routes its sound through MacMate. The first time, macOS asks to allow System Audio Recording; nothing is recorded or saved.")
            }

            Section {
                Picker("Input", selection: Binding(get: { mixer.defaultInput }, set: { mixer.setDefaultDevice($0, input: true) })) {
                    if !mixer.inputDevices.contains(where: { $0.id == mixer.defaultInput }) {
                        Text("None").tag(mixer.defaultInput)
                    }
                    ForEach(mixer.inputDevices) { Text($0.name).tag($0.id) }
                }
                Toggle("Mute microphone", isOn: Binding(get: { mic.muted }, set: { on in
                    if !mic.setMuted(on) { HUD.shared.show("This microphone cannot be muted", symbol: "exclamationmark.triangle") }
                }))
                .disabled(mixer.inputDevices.isEmpty)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Press ⌃⌥A to mute or unmute from anywhere.")
            }
        }
    }

    private var outputRow: some View {
        let muted = mixer.outputMuted ?? false
        return HStack(spacing: 10) {
            Button { mixer.toggleOutputMute() } label: {
                Image(systemName: SoundSymbol.speaker(level: mixer.outputVolume ?? 1, muted: muted))
                    .frame(width: 22, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .disabled(mixer.outputMuted == nil)
            .help(muted ? "Unmute" : "Mute")
            .accessibilityLabel(muted ? "Unmute output" : "Mute output")
            if let volume = mixer.outputVolume {
                Slider(value: Binding(get: { volume }, set: { mixer.setOutputVolume($0) }), in: 0...1)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Output volume")
                Text(Fmt.percent(volume * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else {
                Text("This device sets its own volume.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct SoundAppRow: View {
    @ObservedObject private var mixer = AudioMixer.shared
    let app: SoundApp

    var body: some View {
        let setting = mixer.setting(for: app)
        HStack(spacing: 10) {
            AppIcon(path: app.iconPath, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)
            Button { mixer.toggleMute(app) } label: {
                Image(systemName: SoundSymbol.speaker(level: setting.volume, muted: setting.muted))
                    .frame(width: 22, alignment: .leading)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            .accessibilityLabel(setting.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            Slider(value: Binding(get: { setting.muted ? 0 : setting.volume },
                                  set: { mixer.setVolume($0, for: app, persist: false) }),
                   in: 0...1) { editing in
                if !editing { mixer.setVolume(mixer.setting(for: app).volume, for: app) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(app.name) volume")
            Text(setting.muted ? "Off" : Fmt.percent(setting.volume * 100))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var status: String {
        if app.isPlaying { return "Playing" }
        let minutes = Int(Date().timeIntervalSince(app.lastPlayed) / 60)
        return minutes < 1 ? "Just now" : "\(minutes) min ago"
    }
}

enum SoundSymbol {
    static func speaker(level: Double, muted: Bool) -> String {
        if muted || level < 0.005 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
