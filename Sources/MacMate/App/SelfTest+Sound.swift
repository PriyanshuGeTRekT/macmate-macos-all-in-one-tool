import AppKit
import CoreAudio
import SwiftUI

extension SelfTest {
    /// Read-only: never creates taps or aggregate devices and never changes devices, volume or mute.
    static func runSoundChecks() {
        print("== Sound")

        // Gain curve
        check("full volume is unity gain", SoundGain.amplitude(volume: 1, muted: false) == 1)
        check("half volume is a quarter amplitude", abs(SoundGain.amplitude(volume: 0.5, muted: false) - 0.25) < 1e-6)
        check("muted is silent", SoundGain.amplitude(volume: 0.8, muted: true) == 0)
        check("volume clamped", SoundGain.amplitude(volume: 1.7, muted: false) == 1 && SoundGain.amplitude(volume: -1, muted: false) == 0)

        // Ramp on a synthetic stereo buffer: 1.0 in, gain 1 → 0.25 at 48 kHz.
        let frames = 960
        let step = SoundGain.rampStep(sampleRate: 48_000)
        var ramp = SoundRamp(current: 1, step: step)
        let out = soundRender(inChannels: [2], outChannels: [2], inFrames: frames, outFrames: frames, value: 1, ramp: &ramp, target: 0.25)
        let left = stride(from: 0, to: frames * 2, by: 2).map { out[0][$0] }
        let right = stride(from: 1, to: frames * 2, by: 2).map { out[0][$0] }
        let deltas = zip(left, left.dropFirst()).map { $1 - $0 }
        check("ramp starts near the old gain", left[0] < 1 && left[0] > 0.99, "\(left[0])")
        check("ramp is smooth and monotonic", deltas.allSatisfy { $0 <= 0 && -$0 <= step * 1.001 })
        let settled = left.firstIndex { abs($0 - 0.25) < 1e-6 } ?? -1
        check("ramp settles in about 10 ms", settled >= 300 && settled <= 480, "frame \(settled) = \(String(format: "%.1f", Double(settled) / 48)) ms")
        check("ramp ends on target", left.last == 0.25 && ramp.current == 0.25)
        check("channels get the same gain", left == right)

        var steady = SoundRamp(current: 0.5, step: step)
        let mono = soundRender(inChannels: [1], outChannels: [2], inFrames: 64, outFrames: 64, value: 0.5, ramp: &steady, target: 0.5)
        check("mono tap fills both speakers", mono[0].allSatisfy { $0 == 0.25 })
        let wide = soundRender(inChannels: [2], outChannels: [4], inFrames: 64, outFrames: 64, value: 1, ramp: &steady, target: 0.5)
        check("extra output channels stay silent", (0..<64).allSatisfy { f in wide[0][f * 4] == 0.5 && wide[0][f * 4 + 1] == 0.5 && wide[0][f * 4 + 2] == 0 && wide[0][f * 4 + 3] == 0 })
        let split = soundRender(inChannels: [2], outChannels: [1, 1], inFrames: 64, outFrames: 64, value: 1, ramp: &steady, target: 0.5)
        check("non-interleaved output filled", split[0].allSatisfy { $0 == 0.5 } && split[1].allSatisfy { $0 == 0.5 })
        let short = soundRender(inChannels: [2], outChannels: [2], inFrames: 32, outFrames: 64, value: 1, ramp: &steady, target: 0.5)
        check("missing input frames are silent", short[0][63 * 2] == 0 && short[0][0] == 0.5)

        // Grouping
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/150.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let chrome = SoundGrouping.identity(executablePath: helper)
        check("helper grouped under its app", chrome.key == "/Applications/Google Chrome.app" && chrome.name == "Google Chrome", "\(chrome.name) [\(chrome.settingsKey)]")
        let music = SoundGrouping.identity(executablePath: "/System/Applications/Music.app/Contents/MacOS/Music")
        check("settings keyed by bundle ID", music.settingsKey == "com.apple.Music", music.settingsKey)
        let tool = SoundGrouping.identity(executablePath: "/usr/bin/afplay")
        check("plain tools keyed by path", tool.key == "proc:/usr/bin/afplay" && tool.name == "afplay" && tool.settingsKey == "/usr/bin/afplay")
        check("system daemons left out", SoundGrouping.identity(executablePath: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd").isSystemDaemon
              && !tool.isSystemDaemon && !music.isSystemDaemon)
        let me = SoundGrouping.identity(forPid: getpid())
        check("own process resolves", me != nil, me?.key ?? "nil")

        // Persistence, in a scratch domain so real settings are untouched.
        let suite = "macmate.selftest.sound.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suite) {
            let store = SoundSettingsStore(defaults: defaults)
            store.save(["com.apple.Music": SoundAppSetting(volume: 0.4, muted: false),
                        "com.google.Chrome": SoundAppSetting(volume: 0.7, muted: true),
                        "/usr/bin/afplay": SoundAppSetting(volume: 1, muted: false)])
            let loaded = SoundSettingsStore(defaults: defaults).load()
            check("settings round trip", loaded["com.apple.Music"] == SoundAppSetting(volume: 0.4, muted: false)
                  && loaded["com.google.Chrome"] == SoundAppSetting(volume: 0.7, muted: true), "\(loaded.count) stored")
            check("apps at 100% not stored", loaded["/usr/bin/afplay"] == nil && loaded.count == 2)
            defaults.set(["bad": "value", "x": ["volume": 3.0]], forKey: Keys.soundAppVolumes)
            check("bad stored values ignored", SoundSettingsStore(defaults: defaults).load().isEmpty)
            defaults.removePersistentDomain(forName: suite)
        }

        // Live, read-only Core Audio queries.
        print("  capture permission: \(SoundCapturePermission.status)")
        if !ci {
            let outputs = SoundHAL.devices(input: false), inputs = SoundHAL.devices(input: true)
            let out = SoundHAL.defaultDevice(input: false), inp = SoundHAL.defaultDevice(input: true)
            print("  outputs: " + outputs.map { $0.name + ($0.id == out ? " (default)" : "") }.joined(separator: ", "))
            print("  inputs: " + inputs.map { $0.name + ($0.id == inp ? " (default)" : "") }.joined(separator: ", "))
            check("output devices listed", !outputs.isEmpty)
            check("default output in list", outputs.contains { $0.id == out })
            check("default input in list", inputs.contains { $0.id == inp })
            check("output volume readable", true, SoundHAL.outputVolume(out).map { Fmt.percent($0 * 100) } ?? "no volume control")
            let objects = SoundHAL.processObjects()
            check("audio process objects listed", !objects.isEmpty, "\(objects.count) objects")
            let groups = AudioMixer.inspectGroups()
            for g in groups where (g.playing || g.objects > 1) && !g.identity.isSystemDaemon {
                print("  \(g.identity.name): \(g.objects) objects\(g.playing ? ", playing" : "")  [\(g.identity.settingsKey)]")
            }
            check("process objects grouped", groups.reduce(0) { $0 + $1.objects } >= objects.count - 2, "\(groups.count) groups")
        }
    }

    /// Runs SoundGain.render over freshly allocated buffers filled with `value`; returns the output buffers.
    private static func soundRender(inChannels: [Int], outChannels: [Int], inFrames: Int, outFrames: Int, value: Float,
                                    ramp: inout SoundRamp, target: Float) -> [[Float]] {
        func make(_ channels: [Int], _ frames: Int, fill: Float) -> (UnsafeMutableAudioBufferListPointer, [UnsafeMutablePointer<Float>]) {
            let list = AudioBufferList.allocate(maximumBuffers: channels.count)
            var storage: [UnsafeMutablePointer<Float>] = []
            for (i, ch) in channels.enumerated() {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: ch * frames)
                p.initialize(repeating: fill, count: ch * frames)
                storage.append(p)
                list[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(ch * frames * 4), mData: UnsafeMutableRawPointer(p))
            }
            return (list, storage)
        }
        let (ins, inStore) = make(inChannels, inFrames, fill: value)
        let (outs, outStore) = make(outChannels, outFrames, fill: -9)
        SoundGain.render(input: UnsafePointer(ins.unsafeMutablePointer), output: outs.unsafeMutablePointer, ramp: &ramp, target: target)
        let result = zip(outStore, outChannels).map { Array(UnsafeBufferPointer(start: $0, count: $1 * outFrames)) }
        (inStore + outStore).forEach { $0.deallocate() }
        free(ins.unsafeMutablePointer)
        free(outs.unsafeMutablePointer)
        return result
    }

    /// Renders the Sound tab with sample data (no Core Audio changes).
    static func renderSoundTab(to path: String) {
        Snapshot.active = true
        NSApplication.shared.setActivationPolicy(.accessory)
        UserDefaults.registerMacMateDefaults()
        MicMute.shared.refresh()
        let now = Date()
        func app(_ name: String, _ path: String, _ id: String, playing: Bool, ago: TimeInterval = 0) -> SoundApp {
            SoundApp(id: path, name: name, iconPath: path, settingsKey: id, isPlaying: playing, lastPlayed: now.addingTimeInterval(-ago), processCount: 1)
        }
        AudioMixer.shared.loadDemo(
            outputs: [SoundDevice(id: 101, uid: "a", name: "MacBook Pro Speakers"), SoundDevice(id: 102, uid: "b", name: "AirPods Pro")],
            inputs: [SoundDevice(id: 201, uid: "c", name: "MacBook Pro Microphone")],
            volume: 0.62,
            apps: [app("Google Chrome", "/Applications/Google Chrome.app", "com.google.Chrome", playing: true),
                   app("Music", "/System/Applications/Music.app", "com.apple.Music", playing: true),
                   app("Slack", "/Applications/Slack.app", "com.tinyspeck.slackmacgap", playing: false, ago: 130),
                   app("Safari", "/Applications/Safari.app", "com.apple.Safari", playing: false, ago: 20)],
            settings: ["com.google.Chrome": SoundAppSetting(volume: 0.45, muted: false),
                       "com.tinyspeck.slackmacgap": SoundAppSetting(volume: 0.8, muted: true)])
        Snapshot.render(SoundTab().formStyle(.grouped).background(.regularMaterial), size: CGSize(width: 400, height: 620), to: path)
        // Second state: nothing playing, and the capture permission turned off.
        AudioMixer.shared.loadDemo(outputs: [SoundDevice(id: 103, uid: "d", name: "LG UltraFine Display Audio")],
                                   inputs: [SoundDevice(id: 201, uid: "c", name: "MacBook Pro Microphone")], volume: nil, apps: [], settings: [:],
                                   problem: "Turn on MacMate under System Audio Recording in Privacy & Security, then move the slider again.")
        let second = (path as NSString).deletingPathExtension + "-empty.png"
        Snapshot.render(SoundTab().formStyle(.grouped).background(.regularMaterial), size: CGSize(width: 400, height: 620), to: second)
    }
}
