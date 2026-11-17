import AppKit
import Foundation

extension Keys {
    static let updateAutoCheck = "update.autoCheck"
    static let updateLastCheck = "update.lastCheck"
    static let updateNotifiedVersion = "update.notifiedVersion"
}

// MARK: - Versions

/// A semantic version as found in tags and bundles: "v1.2", "1.2.0", "1.3.0-beta.2", "2.0b1".
/// Missing components count as zero, so "1.0" equals "1.0.0". A pre-release sorts before its release.
struct UpdateVersion: Comparable, CustomStringConvertible {
    let numbers: [Int]
    let prerelease: [String]

    static let zero = UpdateVersion(numbers: [0, 0, 0], prerelease: [])

    init(numbers: [Int], prerelease: [String]) {
        self.numbers = numbers
        self.prerelease = prerelease
    }

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }   // build metadata never affects order
        var pre: Substring = ""
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...]
            s = s[..<dash]
        }
        var numbers: [Int] = []
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        for (i, part) in parts.enumerated() {
            let digits = part.prefix { $0.isASCII && $0.isNumber }
            guard !digits.isEmpty, let n = Int(digits) else { return nil }
            numbers.append(n)
            if digits.count < part.count {
                // "2.0b1": the letters start a pre-release, which must come last and stand alone.
                guard pre.isEmpty, i == parts.count - 1 else { return nil }
                pre = part[digits.endIndex...]
            }
        }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
        self.prerelease = pre.split(separator: ".").map(String.init).filter { !$0.isEmpty }
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    /// "1.2", "1.2.3" or "1.3-beta.2": trailing zeros beyond the minor version are dropped.
    var description: String {
        var n = numbers
        while n.count > 2, n.last == 0 { n.removeLast() }
        if n.count == 1 { n.append(0) }
        let core = n.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    static func compare(_ a: UpdateVersion, _ b: UpdateVersion) -> ComparisonResult {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true): return .orderedSame
        case (true, false): return .orderedDescending
        case (false, true): return .orderedAscending
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            let lx = x.lowercased(), ly = y.lowercased()
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): if nx != ny { return nx < ny ? .orderedAscending : .orderedDescending }
            case (_?, nil): return .orderedAscending      // numeric identifiers sort before words
            case (nil, _?): return .orderedDescending
            case (nil, nil): if lx != ly { return lx < ly ? .orderedAscending : .orderedDescending }
            }
        }
        if a.prerelease.count == b.prerelease.count { return .orderedSame }
        return a.prerelease.count < b.prerelease.count ? .orderedAscending : .orderedDescending
    }

    static func == (a: UpdateVersion, b: UpdateVersion) -> Bool { compare(a, b) == .orderedSame }
    static func < (a: UpdateVersion, b: UpdateVersion) -> Bool { compare(a, b) == .orderedAscending }
}

// MARK: - Releases

struct UpdateRelease: Equatable {
    let version: UpdateVersion
    let tag: String
    let name: String
    let notes: String
    let pageURL: URL
    let assetName: String?
    let assetURL: URL?
    let assetSize: Int64

    static let repository = "PriyanshuGeTRekT/macos-all-in-one-tool"
    static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int64?
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let assets: [Asset]?
    }

    enum ParseError: Error { case malformed, unreadableVersion(String) }

    /// Reads GitHub's "latest release" JSON.
    static func parse(_ data: Data) throws -> UpdateRelease {
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { throw ParseError.malformed }
        guard let version = UpdateVersion(p.tag_name) else { throw ParseError.unreadableVersion(p.tag_name) }
        let assets = p.assets ?? []
        let asset = assets.first { $0.name == "MacMate.zip" }
            ?? assets.first { $0.name.hasPrefix("MacMate-") && $0.name.lowercased().hasSuffix(".zip") }
        let page = p.html_url.flatMap(URL.init(string:)) ?? releasesPage
        let name = (p.name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "MacMate \(version)"
        return UpdateRelease(version: version, tag: p.tag_name, name: name, notes: p.body ?? "", pageURL: page,
                             assetName: asset?.name, assetURL: asset.flatMap { URL(string: $0.browser_download_url) },
                             assetSize: asset?.size ?? 0)
    }

    /// The opening of the release notes as plain text, for a two- or three-line summary.
    var excerpt: String { UpdateRelease.excerpt(from: notes) }

    static func excerpt(from markdown: String, limit: Int = 180) -> String {
        var lines: [String] = []
        var inCode = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            if line.isEmpty {
                if !lines.isEmpty { break }          // the first paragraph is enough
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix("<!--") || line.allSatisfy({ "-*_=".contains($0) }) { continue }
            for marker in ["- ", "* ", "+ ", "> "] where line.hasPrefix(marker) { line = String(line.dropFirst(2)) }
            lines.append(line)
        }
        var text = lines.joined(separator: " ")
        // Links and images keep their text; emphasis and code marks go.
        if let regex = try? NSRegularExpression(pattern: "!?\\[([^\\]]*)\\]\\([^)]*\\)") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        for mark in ["**", "__", "`", "~~"] { text = text.replacingOccurrences(of: mark, with: "") }
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: CharacterSet(charactersIn: " ,;:.")) + "…"
    }
}

// MARK: - State

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case downloading(UpdateRelease, received: Int64, total: Int64)
    case installing(UpdateRelease)
    case failed(String, UpdateRelease?)

    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

// MARK: - Service

/// Checks GitHub Releases once a day (and on request) and installs a newer build in place.
/// This is the only code in MacMate that touches the network.
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var state: UpdateState = .idle
    @Published private(set) var lastCheck: Date?

    /// CFBundleShortVersionString, or nil for a bare binary (a debug build run from the terminal).
    let bundleVersionString: String?
    let currentVersion: UpdateVersion
    private var demoInstallable: Bool?

    private var timer: Timer?
    private var started = false
    private var autoCheck = true
    private var observers: [NSObjectProtocol] = []
    private var downloadTask: URLSessionDownloadTask?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 15 * 60
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let launchDelay: TimeInterval = 10

    init(bundle: Bundle = .main) {
        let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        bundleVersionString = v
        currentVersion = v.flatMap(UpdateVersion.init) ?? .zero
        lastCheck = UserDefaults.standard.object(forKey: Keys.updateLastCheck) as? Date
    }

    /// The version shown to the user: "1.0", or "0.0" for a bare binary.
    var displayVersion: String { bundleVersionString ?? UpdateVersion.zero.description }

    var bundleURL: URL { URL(fileURLWithPath: Bundle.main.bundlePath) }

    /// Running from an .app with a version, so an in-place install makes sense.
    var runningFromBundle: Bool {
        if let demoInstallable { return demoInstallable }
        return bundleVersionString != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// Whether "Install and Relaunch" can replace the app where it sits.
    var canInstallInPlace: Bool {
        if let demoInstallable { return demoInstallable }
        return runningFromBundle && UpdateInstaller.canReplace(bundleURL)
    }

    // MARK: Scheduling

    func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [Keys.updateAutoCheck: true])
        autoCheck = UserDefaults.standard.bool(forKey: Keys.updateAutoCheck)
        if autoCheck { schedule(after: Updater.launchDelay) }

        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let on = UserDefaults.standard.bool(forKey: Keys.updateAutoCheck)
            guard on != self.autoCheck else { return }
            self.autoCheck = on
            on ? self.scheduleNext() : self.cancelTimer()
        })
        // Timers do not count time asleep; recompute the next check from the clock after waking.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.autoCheck, self.timer != nil else { return }
            self.scheduleNext()
        })
    }

    private func scheduleNext() {
        let due = (lastCheck ?? .distantPast).addingTimeInterval(Updater.checkInterval).timeIntervalSinceNow
        schedule(after: max(Updater.launchDelay, due))
    }

    private func schedule(after seconds: TimeInterval) {
        cancelTimer()
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            self.check(userInitiated: false)
        }
        t.tolerance = seconds > 3600 ? 3600 : max(1, seconds * 0.2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Checking

    func checkNow() { check(userInitiated: true) }

    private func check(userInitiated: Bool) {
        onMain {
            guard !self.state.isBusy else { return }
            let previous = self.state
            self.state = .checking
            self.fetchLatest { result in
                onMain { self.finishCheck(result, previous: previous, userInitiated: userInitiated) }
            }
        }
    }

    private func finishCheck(_ result: Result<UpdateRelease, Error>, previous: UpdateState, userInitiated: Bool) {
        let now = Date()
        switch result {
        case .success(let release):
            lastCheck = now
            UserDefaults.standard.set(now, forKey: Keys.updateLastCheck)
            if release.version > currentVersion {
                state = .available(release)
                if !userInitiated { notifyOnce(release) }
            } else {
                state = .upToDate
            }
        case .failure(let error):
            // A failed background check (offline at login, say) stays quiet; a requested one explains itself.
            state = userInitiated ? .failed(Updater.describe(error), nil) : (previous == .checking ? .idle : previous)
        }
        if autoCheck { scheduleNext() }
    }

    private func notifyOnce(_ release: UpdateRelease) {
        let d = UserDefaults.standard
        guard runningFromBundle, d.string(forKey: Keys.updateNotifiedVersion) != release.version.description else { return }
        d.set(release.version.description, forKey: Keys.updateNotifiedVersion)
        Notifier.post(title: "MacMate \(release.version) is available", body: "Open MacMate Settings to install it.")
    }

    var userAgent: String { "MacMate/\(displayVersion)" }

    /// One GET to GitHub's "latest release" endpoint. No token, no cookies.
    func fetchLatest(_ completion: @escaping (Result<UpdateRelease, Error>) -> Void) {
        var request = URLRequest(url: UpdateRelease.latestURL)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { return completion(.failure(error)) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else { return completion(.failure(UpdateError.http(status))) }
            completion(Result { try UpdateRelease.parse(data) })
        }.resume()
    }

    // MARK: Installing

    func openReleasePage(_ release: UpdateRelease? = nil) {
        NSWorkspace.shared.open(release?.pageURL ?? currentRelease?.pageURL ?? UpdateRelease.releasesPage)
    }

    var currentRelease: UpdateRelease? {
        switch state {
        case .available(let r), .downloading(let r, _, _), .installing(let r): return r
        case .failed(_, let r): return r
        default: return nil
        }
    }

    func install() {
        guard let release = currentRelease, !state.isBusy else { return }
        guard canInstallInPlace, let assetURL = release.assetURL else {
            openReleasePage(release)
            return
        }
        state = .downloading(release, received: 0, total: release.assetSize)
        let destination = bundleURL

        let folder: URL
        do { folder = try UpdateInstaller.makeWorkFolder(near: destination) } catch {
            state = .failed(Updater.describe(error), release)
            return
        }
        let zip = folder.appendingPathComponent(release.assetName ?? "MacMate.zip")
        downloadTask = download(assetURL, to: zip, progress: { [weak self] received, total in
            onMain {
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(release, received: received, total: total > 0 ? total : release.assetSize)
            }
        }, completion: { [weak self] failure in
            guard let self else { return }
            onMain { self.downloadTask = nil }
            if let failure {
                try? FileManager.default.removeItem(at: folder)
                onMain {
                    if (failure as? URLError)?.code == .cancelled { self.state = .available(release) }
                    else { self.state = .failed(Updater.describe(failure), release) }
                }
                return
            }
            onMain { self.state = .installing(release) }
            inBackground { self.finishInstall(release, zip: zip, folder: folder, destination: destination) }
        })
    }

    /// Downloads `url` to `file`. `progress` is called at most once per percent, `completion` once with
    /// nil on success. Both run on a background queue.
    @discardableResult
    func download(_ url: URL, to file: URL, progress: @escaping (Int64, Int64) -> Void,
                  completion: @escaping (Error?) -> Void) -> URLSessionDownloadTask {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        var observation: NSKeyValueObservation?
        let task = session.downloadTask(with: request) { location, response, error in
            observation?.invalidate()
            observation = nil
            // The downloaded file disappears when this handler returns, so move it first.
            var failure: Error? = error
            if failure == nil {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 { failure = UpdateError.http(status) }
                else if let location {
                    do {
                        try? FileManager.default.removeItem(at: file)
                        try FileManager.default.moveItem(at: location, to: file)
                    } catch { failure = error }
                } else { failure = UpdateError.download }
            }
            completion(failure)
        }
        var lastStep = -1
        observation = task.progress.observe(\.fractionCompleted) { [weak task] p, _ in
            let step = Int(p.fractionCompleted * 100)
            guard step != lastStep, let task else { return }
            lastStep = step
            progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
        }
        task.resume()
        return task
    }

    func cancelDownload() { downloadTask?.cancel() }

    private func finishInstall(_ release: UpdateRelease, zip: URL, folder: URL, destination: URL) {
        do {
            let app = try UpdateInstaller.unpack(zip, into: folder.appendingPathComponent("unpacked"))
            try UpdateInstaller.validate(app, expectedVersion: release.version)
            try UpdateInstaller.replace(destination, with: app, retire: UpdateInstaller.moveToTrash)
            try? FileManager.default.removeItem(at: folder)
            onMain {
                guard UpdateInstaller.relaunch(destination) else {
                    self.state = .failed("The update was installed. Quit and reopen MacMate to finish.", release)
                    return
                }
                NSApp.terminate(nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if case UpdateError.notWritable = error {
                onMain { self.state = .available(release); self.openReleasePage(release) }
                return
            }
            onMain { self.state = .failed(Updater.describe(error), release) }
        }
    }

    // MARK: Errors

    static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        if error is UpdateRelease.ParseError { return "GitHub sent a reply MacMate couldn't read. Try again later." }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Connect to the internet and try again."
            case .timedOut: return "GitHub didn't respond in time. Try again later."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach GitHub. Check your connection and try again."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "A secure connection to GitHub couldn't be made."
            default: return "Couldn't connect to GitHub (\(e.code.rawValue))."
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteNoPermissionError {
            return "MacMate doesn't have permission to replace itself. Download the update from GitHub instead."
        }
        return ns.localizedDescription
    }

    // MARK: Demo

    /// Puts the section into a given state for screenshots and tests. Nothing is fetched.
    func loadDemo(_ state: UpdateState, lastCheck: Date?, installable: Bool? = true) {
        demoInstallable = installable
        self.state = state
        self.lastCheck = lastCheck
    }
}

enum UpdateError: Error, Equatable {
    case http(Int)
    case download
    case noAppInArchive
    case unzipFailed
    case wrongIdentifier(String)
    case wrongVersion(String)
    case badSignature
    case notWritable

    var message: String {
        switch self {
        case .http(403), .http(429): return "GitHub is limiting requests right now. Try again in an hour."
        case .http(404): return "No published release was found on GitHub."
        case .http(let code) where code >= 500: return "GitHub is having trouble (error \(code)). Try again later."
        case .http(let code): return "GitHub returned an unexpected response (error \(code))."
        case .download: return "The download didn't finish. Try again."
        case .noAppInArchive: return "The downloaded file doesn't contain MacMate."
        case .unzipFailed: return "The downloaded file couldn't be opened. Try again."
        case .wrongIdentifier: return "The downloaded app isn't MacMate, so it wasn't installed."
        case .wrongVersion(let v): return "The downloaded app is version \(v), not the one announced, so it wasn't installed."
        case .badSignature: return "The downloaded app's signature is damaged, so it wasn't installed."
        case .notWritable: return "MacMate can't replace itself in this folder."
        }
    }
}

// MARK: - Installer steps

/// The file work behind "Install and Relaunch", kept apart so each step can be tested on temporary copies.
enum UpdateInstaller {
    static let bundleIdentifier = "com.macmate.app"

    /// Can we move the bundle out and a new one in? Needs a writable parent folder and an owned bundle.
    static func canReplace(_ bundle: URL) -> Bool {
        let fm = FileManager.default
        let parent = bundle.deletingLastPathComponent().path
        return fm.fileExists(atPath: bundle.path) && fm.isWritableFile(atPath: parent) && fm.isWritableFile(atPath: bundle.path)
    }

    /// A private folder on the same volume as the app, so the final move is a rename, not a copy.
    static func makeWorkFolder(near bundle: URL) throws -> URL {
        let fm = FileManager.default
        if let url = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true) {
            return url
        }
        let url = fm.temporaryDirectory.appendingPathComponent("MacMate-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Unzips with ditto (keeps permissions, symlinks and signatures) and returns the app inside.
    static func unpack(_ zip: URL, into folder: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard shell("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path]).status == 0 else { throw UpdateError.unzipFailed }
        let named = folder.appendingPathComponent("MacMate.app")
        if fm.fileExists(atPath: named.path) { return named }
        let apps = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { $0.hasSuffix(".app") } ?? []
        guard apps.count == 1 else { throw UpdateError.noAppInArchive }
        return folder.appendingPathComponent(apps[0])
    }

    /// The bundle must be MacMate, carry the announced version, and pass a strict signature check.
    static func validate(_ app: URL, expectedVersion: UpdateVersion) throws {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { throw UpdateError.noAppInArchive }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleIdentifier else { throw UpdateError.wrongIdentifier(id) }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard let v = UpdateVersion(version), v == expectedVersion else { throw UpdateError.wrongVersion(version) }
        guard shell("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else { throw UpdateError.badSignature }
    }

    /// Moves `destination` out of the way with `retire`, then moves `source` into its place.
    /// If the second move fails, the old bundle is put back. `retire` returns where the old bundle went.
    static func replace(_ destination: URL, with source: URL, retire: (URL) throws -> URL?) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw UpdateError.noAppInArchive }
        guard canReplace(destination) else { throw UpdateError.notWritable }
        let retired = try retire(destination)
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            if let retired, !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
    }

    /// The real app's old bundle goes to the Trash, where the user can still get it back.
    static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Waits for process `$1` to exit (up to a minute), then runs `$3 "$2"`. Values arrive as positional
    /// arguments, never spliced into the script, so any path is safe.
    static let relaunchScript = """
    i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 300 ] && exit 0; sleep 0.2; done; exec "$3" "$2"
    """

    /// Starts a detached shell, in its own session, that reopens `app` once this process has quit.
    @discardableResult
    static func relaunch(_ app: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier, opener: String = "/usr/bin/open") -> Bool {
        spawnDetached(["/bin/sh", "-c", relaunchScript, "sh", String(pid), app.path, opener])
    }

    static func spawnDetached(_ argv: [String]) -> Bool {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }

        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, environ)
        return status == 0
    }
}
