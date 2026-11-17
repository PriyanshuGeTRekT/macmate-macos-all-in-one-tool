import AppKit
import Foundation

/// One launch agent or launch daemon, read from its property list.
struct StartupItem: Identifiable, Hashable {
    enum Scope: Int, CaseIterable, Hashable {
        /// ~/Library/LaunchAgents: runs while you are logged in, yours to change.
        case user
        /// /Library/LaunchAgents: runs for every account, needs an administrator to change.
        case allUsers
        /// /Library/LaunchDaemons: runs as root, even before anyone logs in.
        case system

        var folder: String {
            switch self {
            case .user: return NSHomeDirectory() + "/Library/LaunchAgents"
            case .allUsers: return "/Library/LaunchAgents"
            case .system: return "/Library/LaunchDaemons"
            }
        }

        var needsAdmin: Bool { self != .user }

        /// The launchd domain the item lives in.
        var domain: String { self == .system ? "system" : "gui/\(getuid())" }
    }

    var id: String { plistPath }
    let label: String
    let plistPath: String
    let scope: Scope
    /// The executable that launchd starts (Program, or the first ProgramArguments entry).
    let program: String?
    let arguments: [String]
    let runAtLoad: Bool
    let keepAlive: Bool
    var appName: String?
    var appPath: String?
    var disabled = false
    var running = false
    /// The program (or the app it opens) no longer exists.
    var appGone = false

    var url: URL { URL(fileURLWithPath: plistPath) }
    var title: String { appName ?? label }
}

/// Finds everything that launchd starts automatically and turns items off and on.
final class StartupItemManager: ObservableObject {
    static let shared = StartupItemManager()

    @Published var items: [StartupItem] = []
    @Published private(set) var scanning = false
    /// True once a scan has finished (or sample data was loaded), so views don't rescan on every appearance.
    @Published var loaded = false
    /// Items with a change in flight.
    @Published private(set) var busy: Set<String> = []
    @Published var message = ""

    func scan() {
        guard !scanning else { return }
        scanning = true
        inBackground {
            let found = StartupItemManager.scanAll()
            DispatchQueue.main.async {
                self.items = found
                self.scanning = false
                self.loaded = true
            }
        }
    }

    /// Turns an item off (bootout + disable) or back on (enable + bootstrap).
    /// Items outside your own Library go through macOS's administrator password prompt.
    func setEnabled(_ item: StartupItem, _ enabled: Bool) {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        message = ""
        inBackground {
            let ok = StartupItemManager.apply(item, enabled: enabled)
            let refreshed = StartupItemManager.scanAll()
            DispatchQueue.main.async {
                self.busy.remove(item.id)
                self.items = refreshed
                if !ok {
                    self.message = "\(item.title) could not be turned \(enabled ? "on" : "off")."
                        + (item.scope.needsAdmin ? " An administrator password is needed." : "")
                }
            }
        }
    }

    /// Unloads an item whose app is gone and moves its property list to the Trash.
    func moveToTrash(_ item: StartupItem) { removeAll([item]) }

    /// Stops items whose program is gone and moves their property lists to the Trash.
    /// Items in /Library are stopped with one administrator prompt; Finder moves their files.
    func removeAll(_ list: [StartupItem]) {
        let chosen = list.filter { $0.appGone && !busy.contains($0.id) }
        guard !chosen.isEmpty else { return }
        chosen.forEach { busy.insert($0.id) }
        message = ""
        inBackground {
            let admin = chosen.filter(\.scope.needsAdmin)
            var adminOK = true
            if !admin.isEmpty {
                let script = admin.map { "/bin/launchctl bootout \($0.scope.domain) \(StartupItemManager.shellQuote($0.plistPath)) 2>/dev/null" }
                    .joined(separator: "; ") + "; true"
                // Only fails when the password prompt is cancelled; then those items stay where they are.
                adminOK = StartupItemManager.runAsAdmin(script)
            }
            for item in chosen where !item.scope.needsAdmin {
                shell("/bin/launchctl", ["bootout", item.scope.domain, item.plistPath])
            }
            let paths = chosen.filter { adminOK || !$0.scope.needsAdmin }.map(\.plistPath)
            var result = Uninstaller.moveToTrash(paths)
            if !adminOK { result.failed += admin.map(\.plistPath) }
            let refreshed = StartupItemManager.scanAll()
            DispatchQueue.main.async {
                chosen.forEach { self.busy.remove($0.id) }
                self.items = refreshed
                if chosen.count == 1 {
                    self.message = result.trashed.isEmpty
                        ? "\(chosen[0].label) could not be moved to the Trash."
                        : "\(chosen[0].label) was moved to the Trash."
                } else {
                    self.message = "Moved \(result.trashed.count) items to the Trash."
                        + (result.failed.isEmpty ? "" : " \(result.failed.count) could not be moved.")
                }
            }
        }
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Scanning

    static func scanAll() -> [StartupItem] {
        let fm = FileManager.default
        let apps = Uninstaller.scanApps()
        let userDisabled = parseDisabled(shell("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]).out)
        let systemDisabled = parseDisabled(shell("/bin/launchctl", ["print-disabled", "system"]).out)
        let pids = parseList(shell("/bin/launchctl", ["list"]).out)
        let processes = runningExecutables()

        var result: [StartupItem] = []
        for scope in StartupItem.Scope.allCases {
            let files = ((try? fm.contentsOfDirectory(atPath: scope.folder)) ?? []).filter { $0.hasSuffix(".plist") && !$0.hasPrefix(".") }
            for file in files.sorted() {
                let path = scope.folder + "/" + file
                guard let data = fm.contents(atPath: path),
                      let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
                      var item = parse(plist, path: path, scope: scope)
                else { continue }
                if item.label.lowercased().hasPrefix("com.apple.") { continue }

                let associated = plist["AssociatedBundleIdentifiers"] as? [String]
                    ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
                let owner = ownerApp(label: item.label, program: item.program, arguments: item.arguments,
                                     associated: associated, apps: apps)
                item.appName = owner.name
                item.appPath = owner.path
                item.appGone = isGone(program: item.program, arguments: item.arguments)

                let disabledTable = scope == .system ? systemDisabled : userDisabled
                item.disabled = disabledTable[item.label] ?? (plist["Disabled"] as? Bool ?? false)
                if scope == .system {
                    item.running = item.program.map { processes.contains($0) } ?? false
                } else {
                    item.running = pids[item.label] != nil
                }
                result.append(item)
            }
        }
        return result
    }

    /// Reads the parts of a launchd property list that matter here.
    static func parse(_ plist: [String: Any], path: String, scope: StartupItem.Scope) -> StartupItem? {
        let fallbackLabel = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let label = (plist["Label"] as? String) ?? fallbackLabel
        guard !label.isEmpty else { return nil }
        let args = plist["ProgramArguments"] as? [String] ?? []
        let program = (plist["Program"] as? String) ?? args.first
        let keepAlive: Bool
        if let b = plist["KeepAlive"] as? Bool { keepAlive = b } else { keepAlive = plist["KeepAlive"] is [String: Any] }
        return StartupItem(label: label, plistPath: path, scope: scope, program: program, arguments: args,
                           runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive)
    }

    /// `launchctl print-disabled` lines look like `"com.vendor.agent" => disabled` (older systems: `=> true`).
    static func parseDisabled(_ output: String) -> [String: Bool] {
        var table: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            table[label] = state == "disabled" || state == "true"
        }
        return table
    }

    /// `launchctl list` rows are `PID<tab>Status<tab>Label`, with "-" for no PID.
    static func parseList(_ output: String) -> [String: Int] {
        var table: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count >= 3, let pid = Int(cols[0].trimmingCharacters(in: .whitespaces)) else { continue }
            table[String(cols[2])] = pid
        }
        return table
    }

    /// Full paths of everything running right now (`ps` shows the executable path for launchd jobs).
    static func runningExecutables() -> Set<String> {
        Set(shell("/bin/ps", ["-axo", "comm="]).out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Works out which app an item belongs to: an app it names, an app its program lives in, or an app whose
    /// bundle identifier starts its label.
    static func ownerApp(label: String, program: String?, arguments: [String], associated: [String],
                         apps: [InstalledApp]) -> (name: String?, path: String?) {
        for id in associated {
            if let app = apps.first(where: { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }) { return (app.name, app.path) }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), url.path)
            }
        }
        for path in [program].compactMap({ $0 }) + arguments where path.hasPrefix("/") {
            if let app = enclosingApp(of: path) {
                let name = String((app as NSString).lastPathComponent.dropLast(4))
                return (name, FileManager.default.fileExists(atPath: app) ? app : nil)
            }
        }
        let l = label.lowercased()
        let byPrefix = apps.filter { let id = $0.bundleID.lowercased(); return l == id || l.hasPrefix(id + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
        if let app = byPrefix { return (app.name, app.path) }
        // Same vendor (first two parts of the identifier) and only one installed app from it.
        let parts = l.split(separator: ".")
        if parts.count >= 3 {
            let vendor = parts.prefix(2).joined(separator: ".") + "."
            let same = apps.filter { $0.bundleID.lowercased().hasPrefix(vendor) }
            if same.count == 1 { return (same[0].name, same[0].path) }
        }
        return (nil, nil)
    }

    /// "/Applications/Foo.app/Contents/MacOS/foo" → "/Applications/Foo.app" (outermost app).
    static func enclosingApp(of path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) ?? (path.lowercased().hasSuffix(".app") ? path.range(of: ".app", options: [.caseInsensitive, .backwards]) : nil)
        else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Folders macOS guards with a privacy prompt, or that may simply be unmounted. Never probed.
    static func isPrivacyProtected(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let guarded = ["/Desktop", "/Documents", "/Downloads", "/Pictures", "/Movies", "/Music", "/Library/Mobile Documents",
                       "/Library/CloudStorage", "/Library/Containers", "/Library/Group Containers"].map { home + $0 }
        if path.hasPrefix("/Volumes/") || path.hasPrefix("/Users/") && !path.hasPrefix(home + "/") { return true }
        return guarded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// True only when the item clearly points at something that has been deleted.
    static func isGone(program: String?, arguments: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        guard let program, program.hasPrefix("/"), !isPrivacyProtected(program) else { return false }
        if !exists(program) { return true }
        // Launchers such as /usr/bin/open or a shell: look at app bundles named in the arguments.
        for arg in arguments.dropFirst() where arg.hasPrefix("/") && !isPrivacyProtected(arg) {
            if let app = enclosingApp(of: arg), !exists(app) { return true }
        }
        return false
    }

    // MARK: Changing state

    static func apply(_ item: StartupItem, enabled: Bool) -> Bool {
        let domain = item.scope.domain
        let target = domain + "/" + item.label
        if item.scope.needsAdmin {
            let plist = shellQuote(item.plistPath), service = shellQuote(target)
            let script = enabled
                ? "/bin/launchctl enable \(service) && { /bin/launchctl bootstrap \(domain) \(plist) 2>/dev/null; true; }"
                : "{ /bin/launchctl bootout \(domain) \(plist) 2>/dev/null; true; } && /bin/launchctl disable \(service)"
            return runAsAdmin(script)
        }
        if enabled {
            let ok = shell("/bin/launchctl", ["enable", target]).status == 0
            // Fails harmlessly when the item is already loaded.
            shell("/bin/launchctl", ["bootstrap", domain, item.plistPath])
            return ok
        } else {
            shell("/bin/launchctl", ["bootout", domain, item.plistPath])
            return shell("/bin/launchctl", ["disable", target]).status == 0
        }
    }

    /// Runs a shell command as root. macOS itself shows the password prompt.
    static func runAsAdmin(_ command: String) -> Bool {
        appleScript(adminScript(command)).ok
    }

    static func adminScript(_ command: String) -> String {
        "do shell script \(appleScriptString(command)) with administrator privileges"
    }

    /// Single-quotes a word for /bin/sh.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A double-quoted AppleScript string literal.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
