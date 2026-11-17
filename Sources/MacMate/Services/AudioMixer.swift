import AppKit
import AudioToolbox  // kAudioHardwareServiceDeviceProperty_VirtualMainVolume
import Combine
import CoreAudio
import Darwin
import Synchronization

extension Keys {
    /// [settings key: ["volume": Double 0…1, "muted": Bool]]. Only apps that differ from 100% are stored.
    static let soundAppVolumes = "sound.appVolumes"
}

// MARK: - Model

struct SoundDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct SoundAppSetting: Equatable {
    /// Slider position, 0…1.
    var volume: Double = 1
    var muted = false

    var isDefault: Bool { !muted && volume >= 0.995 }
    var gain: Float { SoundGain.amplitude(volume: volume, muted: muted) }
    static let normal = SoundAppSetting()
}

/// One app (helpers included) that is playing sound or did so in the last few minutes.
struct SoundApp: Identifiable, Equatable {
    /// The app bundle path, or "proc:" + executable path for a process outside any app.
    let id: String
    var name: String
    var iconPath: String?
    /// Bundle ID, or the executable path when there is none. Per-app settings are stored under it.
    var settingsKey: String
    var isPlaying: Bool
    var lastPlayed: Date
    var processCount: Int
}

// MARK: - Grouping

/// Puts helper processes under the app they belong to, the same way the energy list does.
enum SoundGrouping {
    struct Identity: Equatable {
        let key: String
        let name: String
        let iconPath: String?
        let settingsKey: String

        /// macOS daemons outside any app (speech, Siri, call services). They don't belong in an app mixer.
        var isSystemDaemon: Bool {
            guard key.hasPrefix("proc:") else { return false }
            return ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { settingsKey.hasPrefix($0) }
        }
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsible: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func identity(forPid pid: pid_t) -> Identity? {
        var owner = pid
        if let responsible, case let r = responsible(pid), r > 1 { owner = r }
        guard let path = EnergyMonitor.path(of: owner) ?? EnergyMonitor.path(of: pid) else { return nil }
        var id = identity(executablePath: path)
        // The responsible process may be a launcher outside any app; prefer the process's own app then.
        if !id.key.hasPrefix("/"), owner != pid, let own = EnergyMonitor.path(of: pid), EnergyMonitor.outermostApp(in: own) != nil {
            id = identity(executablePath: own)
        }
        return id
    }

    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Helper (Renderer).app/…" → Google Chrome.
    static func identity(executablePath path: String) -> Identity {
        if let app = EnergyMonitor.outermostApp(in: path) {
            let bundle = Bundle(path: app)
            var name = FileManager.default.displayName(atPath: app)
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            if let display = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !display.isEmpty { name = display }
            return Identity(key: app, name: name, iconPath: app, settingsKey: bundle?.bundleIdentifier ?? app)
        }
        return Identity(key: "proc:" + path, name: (path as NSString).lastPathComponent, iconPath: path, settingsKey: path)
    }
}

// MARK: - Settings

struct SoundSettingsStore {
    let defaults: UserDefaults

    func load() -> [String: SoundAppSetting] {
        guard let raw = defaults.dictionary(forKey: Keys.soundAppVolumes) else { return [:] }
        var out: [String: SoundAppSetting] = [:]
        for (key, value) in raw {
            guard let d = value as? [String: Any] else { continue }
            let volume = (d["volume"] as? NSNumber)?.doubleValue ?? 1
            let s = SoundAppSetting(volume: max(0, min(1, volume)), muted: (d["muted"] as? Bool) ?? false)
            if !s.isDefault { out[key] = s }
        }
        return out
    }

    func save(_ all: [String: SoundAppSetting]) {
        var raw: [String: Any] = [:]
        for (key, s) in all where !s.isDefault { raw[key] = ["volume": s.volume, "muted": s.muted] }
        defaults.set(raw, forKey: Keys.soundAppVolumes)
    }
}

// MARK: - Gain math (runs on the real-time audio thread)

struct SoundRamp {
    /// The gain applied to the last frame.
    var current: Float
    /// Largest change per frame, so a full 0→1 swing takes about 10 ms.
    var step: Float
}

enum SoundGain {
    /// Slider position to linear amplitude. Squared so equal slider moves sound like equal steps.
    static func amplitude(volume: Double, muted: Bool) -> Float {
        guard !muted else { return 0 }
        let v = Float(max(0, min(1, volume)))
        return v * v
    }

    static func rampStep(sampleRate: Double) -> Float {
        Float(1 / max(1, 0.010 * (sampleRate > 0 ? sampleRate : 48_000)))
    }

    /// Copies the tap's channels to the device output, scaled by a gain that glides toward `target`.
    /// Mono input feeds the first two outputs; extra output channels are silent. No allocation, no locks.
    static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                       ramp: inout SoundRamp, target: Float) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)

        var inChannels = 0
        var inFrames = Int.max
        for i in 0..<ins.count {
            let b = ins[i]
            let ch = Int(b.mNumberChannels)
            guard ch > 0, b.mData != nil else { continue }
            inChannels += ch
            inFrames = min(inFrames, Int(b.mDataByteSize) / (4 * ch))
        }
        if inChannels == 0 { inFrames = 0 }

        var frames = 0
        for i in 0..<outs.count {
            let ch = Int(outs[i].mNumberChannels)
            guard ch > 0 else { continue }
            frames = max(frames, Int(outs[i].mDataByteSize) / (4 * ch))
        }

        var g = ramp.current
        let step = ramp.step
        for f in 0..<frames {
            if g != target {
                let d = target - g
                g = abs(d) <= step ? target : g + (d > 0 ? step : -step)
            }
            var base = 0
            for i in 0..<outs.count {
                let b = outs[i]
                let oc = Int(b.mNumberChannels)
                guard oc > 0 else { continue }
                defer { base += oc }
                guard let od = b.mData?.assumingMemoryBound(to: Float.self), f < Int(b.mDataByteSize) / (4 * oc) else { continue }
                for c in 0..<oc {
                    od[f * oc + c] = f < inFrames ? sample(ins, channel: base + c, inChannels: inChannels, frame: f) * g : 0
                }
            }
        }
        ramp.current = g
    }

    @inline(__always)
    private static func sample(_ ins: UnsafeMutableAudioBufferListPointer, channel k: Int, inChannels: Int, frame f: Int) -> Float {
        var src = inChannels == 1 ? (k < 2 ? 0 : -1) : (k < inChannels ? k : -1)
        guard src >= 0 else { return 0 }
        for i in 0..<ins.count {
            let b = ins[i]
            let ch = Int(b.mNumberChannels)
            guard ch > 0, let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            if src < ch { return data[f * ch + src] }
            src -= ch
        }
        return 0
    }
}

/// State shared with the IOProc. Lives at a fixed address for the life of a tap.
struct SoundTapShared: ~Copyable {
    /// Float bit pattern of the gain to reach; written by the app, read by the audio thread.
    let target: Synchronization.Atomic<UInt32>
    /// Touched only by the audio thread once the IOProc runs.
    var ramp: SoundRamp
}

private func soundTapIOProc(_ device: AudioObjectID, _ now: UnsafePointer<AudioTimeStamp>,
                            _ input: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>,
                            _ output: UnsafeMutablePointer<AudioBufferList>, _ outputTime: UnsafePointer<AudioTimeStamp>,
                            _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let shared = clientData.assumingMemoryBound(to: SoundTapShared.self)
    let target = Float(bitPattern: shared.pointee.target.load(ordering: .relaxed))
    SoundGain.render(input: input, output: output, ramp: &shared.pointee.ramp, target: target)
    return noErr
}

// MARK: - Core Audio helpers

enum SoundHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let aggregatePrefix = "com.macmate.sound."

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var addr = address
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var addr = address
        var v = value
        return withUnsafeMutablePointer(to: &v) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr
    }

    static func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var ok: DarwinBoolean = false
        return AudioObjectHasProperty(object, &addr) && AudioObjectIsPropertySettable(object, &addr, &ok) == noErr && ok.boolValue
    }

    static func ids(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // Devices

    static func defaultDevice(input: Bool) -> AudioDeviceID {
        get(system, address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), AudioDeviceID(0)) ?? 0
    }

    /// Every visible device with streams in the given direction (MacMate's own private devices excluded).
    static func devices(input: Bool) -> [SoundDevice] {
        let scope = input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput
        return ids(system, address(kAudioHardwarePropertyDevices)).compactMap { id in
            guard !ids(id, address(kAudioDevicePropertyStreams, scope)).isEmpty,
                  (get(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) ?? 0) == 0,
                  let uid = string(id, address(kAudioDevicePropertyDeviceUID)), !uid.hasPrefix(aggregatePrefix) else { return nil }
            return SoundDevice(id: id, uid: uid, name: string(id, address(kAudioObjectPropertyName)) ?? uid)
        }
    }

    private static var mainVolume: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
    }

    /// 0…1, or nil when the device has no software-adjustable volume.
    static func outputVolume(_ device: AudioDeviceID) -> Double? {
        guard device != 0, settable(device, mainVolume) else { return nil }
        return get(device, mainVolume, Float32(0)).map(Double.init)
    }

    static func setOutputVolume(_ device: AudioDeviceID, _ value: Double) {
        set(device, mainVolume, Float32(max(0, min(1, value))))
    }

    static func outputMuted(_ device: AudioDeviceID) -> Bool? {
        let addr = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard device != 0, settable(device, addr) else { return nil }
        return get(device, addr, UInt32(0)).map { $0 != 0 }
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        get(device, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    }

    // Process objects (one per process that has talked to Core Audio)

    static func processObjects() -> [AudioObjectID] {
        ids(system, address(kAudioHardwarePropertyProcessObjectList))
    }

    static func pid(ofProcess object: AudioObjectID) -> pid_t? {
        get(object, address(kAudioProcessPropertyPID), pid_t(-1)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        (get(object, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) ?? 0) != 0
    }
}

/// System Audio Recording status, without asking. Taps deliver silence when it is denied.
enum SoundCapturePermission {
    enum Status { case granted, denied, undetermined }

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private static let preflight: PreflightFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    static var status: Status {
        guard let preflight else { return .undetermined }
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - One tapped app

enum SoundTapError: Error {
    case failed(step: String, status: OSStatus)
}

/// A private process tap that silences an app, plus a private aggregate device that plays the tapped
/// sound back on the current output at the chosen gain.
final class SoundTapSession {
    let outputUID: String
    private(set) var processObjects: [AudioObjectID]
    private let description: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let shared: UnsafeMutablePointer<SoundTapShared>

    init(name: String, processObjects: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.outputUID = outputUID
        self.processObjects = processObjects
        shared = .allocate(capacity: 1)
        // Start at full level: the app was audible until now, so glide down from there.
        shared.initialize(to: SoundTapShared(target: Synchronization.Atomic(gain.bitPattern), ramp: SoundRamp(current: 1, step: SoundGain.rampStep(sampleRate: 48_000))))

        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.name = "MacMate volume for \(name)"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .muted
        description = desc

        do { try build() } catch {
            teardown()
            throw error
        }
    }

    deinit {
        teardown()
        shared.deinitialize(count: 1)
        shared.deallocate()
    }

    private func build() throws {
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw SoundTapError.failed(step: "tap", status: status) }
        guard let tapUID = SoundHAL.string(tapID, SoundHAL.address(kAudioTapPropertyUID)) else {
            throw SoundTapError.failed(step: "tap", status: -1)
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacMate Sound",
            kAudioAggregateDeviceUIDKey: SoundHAL.aggregatePrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard status == noErr else { throw SoundTapError.failed(step: "aggregate", status: status) }

        shared.pointee.ramp.step = SoundGain.rampStep(sampleRate: SoundHAL.nominalSampleRate(aggregateID))
        status = AudioDeviceCreateIOProcID(aggregateID, soundTapIOProc, UnsafeMutableRawPointer(shared), &procID)
        guard status == noErr, procID != nil else { throw SoundTapError.failed(step: "ioproc", status: status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw SoundTapError.failed(step: "start", status: status) }
    }

    func setGain(_ gain: Float) {
        shared.pointee.target.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Points the tap at a new set of process objects without rebuilding anything. False if that failed.
    func updateProcesses(_ objects: [AudioObjectID]) -> Bool {
        description.processes = objects
        var addr = SoundHAL.address(kAudioTapPropertyDescription)
        var desc: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &desc) {
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status == noErr { processObjects = objects }
        return status == noErr
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

// MARK: - Service

/// Output and input devices, plus per-app volume through Core Audio process taps.
/// Everything is driven by Core Audio property listeners; nothing polls.
final class AudioMixer: ObservableObject {
    static let shared = AudioMixer()

    @Published private(set) var outputDevices: [SoundDevice] = []
    @Published private(set) var inputDevices: [SoundDevice] = []
    @Published private(set) var defaultOutput: AudioDeviceID = 0
    @Published private(set) var defaultInput: AudioDeviceID = 0
    /// nil when the current output has no volume control.
    @Published private(set) var outputVolume: Double?
    /// nil when the current output cannot be muted.
    @Published private(set) var outputMuted: Bool?
    @Published private(set) var apps: [SoundApp] = []
    @Published private(set) var settings: [String: SoundAppSetting] = [:]
    /// Set when a tap could not be created or System Audio Recording is off.
    @Published private(set) var tapProblem: String?

    /// How long an app stays in the list after it stops playing.
    static let recentWindow: TimeInterval = 5 * 60
    /// How long a tap stays up after its app goes quiet, so pause and play don't rebuild it.
    static let tapLinger: TimeInterval = 30

    private let queue = DispatchQueue(label: "macmate.sound", qos: .userInitiated)
    private let store = SoundSettingsStore(defaults: .standard)
    private var started = false
    private var observers: [AnyCancellable] = []

    // Owned by `queue`.
    private struct Proc {
        let pid: pid_t
        let identity: SoundGrouping.Identity
        var running: Bool
    }
    private struct Group {
        var identity: SoundGrouping.Identity
        var playing = false
        var lastPlayed = Date.distantPast
    }
    private var procs: [AudioObjectID: Proc] = [:]
    private var ignored = Set<AudioObjectID>()
    private var groups: [String: Group] = [:]
    private var sessions: [String: SoundTapSession] = [:]
    private var queueSettings: [String: SoundAppSetting] = [:]
    private var failedKeys = Set<String>()
    private var procBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var deviceBlock: AudioObjectPropertyListenerBlock?
    private var inputBlock: AudioObjectPropertyListenerBlock?
    private var watchedOutput: AudioDeviceID = 0
    private var watchedInput: AudioDeviceID = 0
    private var currentOutputUID = ""
    private var housekeeping: DispatchWorkItem?
    private var permissionCheck: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [Keys.soundAppVolumes: [String: Any]()])
        settings = store.load()
        let initial = settings
        queue.async {
            self.queueSettings = initial
            self.installSystemListeners()
            self.refreshDevices()
            self.refreshProcesses()
        }
        // Drop stale "recent" rows and recheck the permission whenever the panel opens.
        AppState.shared.$panelOpen.removeDuplicates().filter { $0 }.sink { [weak self] _ in
            self?.queue.async {
                self?.reconcile()
                self?.checkPermissionIfTapping()
            }
        }.store(in: &observers)
    }

    /// Destroys every tap and aggregate device. Call on quit; blocks until done.
    func shutdown() {
        queue.sync {
            sessions.removeAll()
            housekeeping?.cancel()
            permissionCheck?.cancel()
        }
    }

    /// Fixed sample data for documentation renders. Never touches Core Audio.
    func loadDemo(outputs: [SoundDevice], inputs: [SoundDevice], volume: Double?, apps: [SoundApp], settings: [String: SoundAppSetting],
                  problem: String? = nil) {
        outputDevices = outputs
        inputDevices = inputs
        defaultOutput = outputs.first?.id ?? 0
        defaultInput = inputs.first?.id ?? 0
        outputVolume = volume
        outputMuted = false
        self.apps = apps
        self.settings = settings
        tapProblem = problem
    }

    // MARK: User actions (main thread)

    func setting(for app: SoundApp) -> SoundAppSetting { settings[app.settingsKey] ?? .normal }

    /// Applies at once; `persist` is false while a slider is being dragged.
    func set(_ setting: SoundAppSetting, for app: SoundApp, persist: Bool = true) {
        let key = app.settingsKey
        if setting.isDefault { settings[key] = nil } else { settings[key] = setting }
        if persist { store.save(settings) }
        queue.async {
            self.queueSettings[key] = setting.isDefault ? nil : setting
            self.failedKeys.remove(key)
            self.reconcile()
        }
    }

    func setVolume(_ volume: Double, for app: SoundApp, persist: Bool = true) {
        var s = setting(for: app)
        s.volume = volume
        if volume > 0.001 { s.muted = false }
        set(s, for: app, persist: persist)
    }

    func toggleMute(_ app: SoundApp) {
        var s = setting(for: app)
        s.muted.toggle()
        if !s.muted, s.volume < 0.01 { s.volume = 1 }
        set(s, for: app)
    }

    func setDefaultDevice(_ id: AudioDeviceID, input: Bool) {
        if input { defaultInput = id } else { defaultOutput = id }
        queue.async {
            SoundHAL.set(SoundHAL.system, SoundHAL.address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice), id)
        }
    }

    func setOutputVolume(_ value: Double) {
        outputVolume = value
        let dev = defaultOutput
        queue.async {
            SoundHAL.setOutputVolume(dev, value)
            if value > 0.001, SoundHAL.outputMuted(dev) == true {
                SoundHAL.set(dev, SoundHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(0))
            }
        }
    }

    func toggleOutputMute() {
        guard let muted = outputMuted else { return }
        outputMuted = !muted
        let dev = defaultOutput
        queue.async {
            SoundHAL.set(dev, SoundHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), UInt32(muted ? 0 : 1))
        }
    }

    // MARK: Listeners (queue)

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                        _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = SoundHAL.address(selector, scope, element)
        AudioObjectAddPropertyListenerBlock(object, &addr, queue, block)
    }

    private func unlisten(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                          _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                          _ block: @escaping AudioObjectPropertyListenerBlock) {
        var addr = SoundHAL.address(selector, scope, element)
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
    }

    private func installSystemListeners() {
        let sys = SoundHAL.system
        listen(sys, kAudioHardwarePropertyProcessObjectList) { [weak self] _, _ in self?.refreshProcesses() }
        listen(sys, kAudioHardwarePropertyDevices) { [weak self] _, _ in self?.refreshDevices() }
        listen(sys, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] _, _ in
            self?.refreshDevices()
            self?.reconcile()
        }
        listen(sys, kAudioHardwarePropertyDefaultInputDevice) { [weak self] _, _ in self?.refreshDevices() }
    }

    private func refreshDevices() {
        let outputs = SoundHAL.devices(input: false)
        let inputs = SoundHAL.devices(input: true)
        let out = SoundHAL.defaultDevice(input: false)
        let inp = SoundHAL.defaultDevice(input: true)
        currentOutputUID = outputs.first { $0.id == out }?.uid ?? SoundHAL.string(out, SoundHAL.address(kAudioDevicePropertyDeviceUID)) ?? ""

        if out != watchedOutput {
            if let deviceBlock, watchedOutput != 0 {
                unlisten(watchedOutput, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, deviceBlock)
                unlisten(watchedOutput, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard, deviceBlock)
                unlisten(watchedOutput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, deviceBlock)
            }
            watchedOutput = out
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publishOutputLevel() }
            deviceBlock = block
            if out != 0 {
                listen(out, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, block)
                listen(out, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementWildcard, block)
                listen(out, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, block)
            }
        }
        if inp != watchedInput {
            if let inputBlock, watchedInput != 0 {
                unlisten(watchedInput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain, inputBlock)
            }
            watchedInput = inp
            // Keeps the microphone toggle (and the menu bar glyph) right when the mute changes elsewhere.
            let block: AudioObjectPropertyListenerBlock = { _, _ in onMain { MicMute.shared.refresh() } }
            inputBlock = block
            if inp != 0 { listen(inp, kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain, block) }
            onMain { MicMute.shared.refresh() }
        }

        DispatchQueue.main.async {
            if self.outputDevices != outputs { self.outputDevices = outputs }
            if self.inputDevices != inputs { self.inputDevices = inputs }
            if self.defaultOutput != out { self.defaultOutput = out }
            if self.defaultInput != inp { self.defaultInput = inp }
        }
        publishOutputLevel()
    }

    private func publishOutputLevel() {
        let dev = watchedOutput
        let volume = SoundHAL.outputVolume(dev)
        let muted = SoundHAL.outputMuted(dev)
        DispatchQueue.main.async {
            if self.outputVolume != volume { self.outputVolume = volume }
            if self.outputMuted != muted { self.outputMuted = muted }
        }
    }

    private func refreshProcesses() {
        let list = SoundHAL.processObjects()
        let alive = Set(list)
        for (id, block) in procBlocks where !alive.contains(id) {
            unlisten(id, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, block)
            procBlocks[id] = nil
        }
        procs = procs.filter { alive.contains($0.key) }
        ignored = ignored.intersection(alive)

        let me = getpid()
        for id in list {
            if procs[id] != nil {
                procs[id]?.running = SoundHAL.isRunningOutput(id)
                continue
            }
            guard !ignored.contains(id) else { continue }
            guard let pid = SoundHAL.pid(ofProcess: id), pid != me, let identity = SoundGrouping.identity(forPid: pid),
                  !identity.isSystemDaemon else {
                ignored.insert(id)
                continue
            }
            procs[id] = Proc(pid: pid, identity: identity, running: SoundHAL.isRunningOutput(id))
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self, self.procs[id] != nil else { return }
                self.procs[id]?.running = SoundHAL.isRunningOutput(id)
                self.reconcile()
            }
            procBlocks[id] = block
            listen(id, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, block)
        }
        reconcile()
    }

    // MARK: Reconcile (queue)

    /// Brings groups, taps and the published list in line with the current process objects and settings.
    private func reconcile() {
        let now = Date()
        var members: [String: [AudioObjectID]] = [:]
        var playing = Set<String>()
        for (id, p) in procs {
            members[p.identity.key, default: []].append(id)
            if p.running { playing.insert(p.identity.key) }
            if groups[p.identity.key] == nil { groups[p.identity.key] = Group(identity: p.identity) }
        }
        for (key, g) in groups {
            let isPlaying = playing.contains(key)
            if isPlaying || g.playing { groups[key]?.lastPlayed = now }
            groups[key]?.playing = isPlaying
            if !isPlaying, members[key] == nil, now.timeIntervalSince(g.lastPlayed) > AudioMixer.recentWindow { groups[key] = nil }
        }

        // Taps
        for (key, session) in sessions {
            let g = groups[key]
            let s = g.flatMap { queueSettings[$0.identity.settingsKey] } ?? .normal
            let wanted = g != nil && members[key] != nil && wantsTap(g!, setting: s, now: now)
            if !wanted || session.outputUID != currentOutputUID { sessions[key] = nil }
        }
        for (key, g) in groups {
            let s = queueSettings[g.identity.settingsKey] ?? .normal
            guard let objects = members[key]?.sorted(), wantsTap(g, setting: s, now: now) else { continue }
            if let session = sessions[key] {
                if session.processObjects != objects, !session.updateProcesses(objects) {
                    sessions[key] = nil
                    createSession(key: key, group: g, objects: objects, gain: s.gain)
                } else {
                    session.setGain(s.gain)
                }
            } else {
                createSession(key: key, group: g, objects: objects, gain: s.gain)
            }
        }

        publishApps(now: now)
        scheduleHousekeeping(now: now)
    }

    private func wantsTap(_ g: Group, setting: SoundAppSetting, now: Date) -> Bool {
        guard !setting.isDefault, !currentOutputUID.isEmpty, !failedKeys.contains(g.identity.settingsKey) else { return false }
        return g.playing || now.timeIntervalSince(g.lastPlayed) < AudioMixer.tapLinger
    }

    private func createSession(key: String, group: Group, objects: [AudioObjectID], gain: Float) {
        if SoundCapturePermission.status == .denied {
            failedKeys.insert(group.identity.settingsKey)
            publishProblem("Turn on MacMate under System Audio Recording in Privacy & Security, then move the slider again.")
            return
        }
        do {
            sessions[key] = try SoundTapSession(name: group.identity.name, processObjects: objects, outputUID: currentOutputUID, gain: gain)
            publishProblem(nil)
            schedulePermissionCheck()
        } catch {
            failedKeys.insert(group.identity.settingsKey)
            var detail = ""
            if case let SoundTapError.failed(step, status) = error { detail = " (\(step) error \(status))" }
            publishProblem("macOS did not let MacMate take over the sound of \(group.identity.name)\(detail). Check that MacMate is allowed under System Audio Recording.")
        }
    }

    /// A denied permission makes taps silent rather than failing, which would mute the app outright.
    private func schedulePermissionCheck() {
        permissionCheck?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.checkPermissionIfTapping() }
        permissionCheck = item
        queue.asyncAfter(deadline: .now() + 4, execute: item)
    }

    private func checkPermissionIfTapping() {
        guard !sessions.isEmpty, SoundCapturePermission.status == .denied else { return }
        for key in sessions.keys { if let g = groups[key] { failedKeys.insert(g.identity.settingsKey) } }
        sessions.removeAll()
        publishProblem("Turn on MacMate under System Audio Recording in Privacy & Security, then move the slider again.")
        reconcile()
    }

    private func publishProblem(_ text: String?) {
        DispatchQueue.main.async { if self.tapProblem != text { self.tapProblem = text } }
    }

    private func publishApps(now: Date) {
        var counts: [String: Int] = [:]
        for p in procs.values { counts[p.identity.key, default: 0] += 1 }
        let list = groups.values
            .filter { $0.playing || now.timeIntervalSince($0.lastPlayed) < AudioMixer.recentWindow }
            .map { g in
                SoundApp(id: g.identity.key, name: g.identity.name, iconPath: g.identity.iconPath, settingsKey: g.identity.settingsKey,
                         isPlaying: g.playing, lastPlayed: g.lastPlayed, processCount: counts[g.identity.key] ?? 0)
            }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        DispatchQueue.main.async { if self.apps != list { self.apps = list } }
    }

    /// One wake-up at the next moment a row should disappear or an idle tap should close.
    private func scheduleHousekeeping(now: Date) {
        housekeeping?.cancel()
        housekeeping = nil
        var next: Date?
        for (key, g) in groups where !g.playing {
            var candidates = [g.lastPlayed.addingTimeInterval(AudioMixer.recentWindow)]
            if sessions[key] != nil { candidates.append(g.lastPlayed.addingTimeInterval(AudioMixer.tapLinger)) }
            for c in candidates where c > now { next = min(next ?? c, c) }
        }
        guard let next else { return }
        let item = DispatchWorkItem { [weak self] in self?.reconcile() }
        housekeeping = item
        queue.asyncAfter(deadline: .now() + next.timeIntervalSince(now) + 0.5, execute: item)
    }

    // MARK: Read-only inspection (self-test)

    /// Groups the current process objects by app without starting anything.
    static func inspectGroups() -> [(identity: SoundGrouping.Identity, objects: Int, playing: Bool)] {
        var out: [String: (identity: SoundGrouping.Identity, objects: Int, playing: Bool)] = [:]
        for id in SoundHAL.processObjects() {
            guard let pid = SoundHAL.pid(ofProcess: id), let identity = SoundGrouping.identity(forPid: pid) else { continue }
            var e = out[identity.key] ?? (identity, 0, false)
            e.objects += 1
            e.playing = e.playing || SoundHAL.isRunningOutput(id)
            out[identity.key] = e
        }
        return out.values.sorted { $0.identity.name < $1.identity.name }
    }
}
