import AppKit
import Foundation
import Security

/// Developer teams and app groups that installed apps are signed with.
struct LeftoverSignatures {
    var teams = Set<String>()
    var groups = Set<String>()
}

/// A file or folder named after an app that is no longer on this Mac.
struct LeftoverItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    /// The bundle identifier the name was read as (lowercased).
    let bundleID: String
    let category: String
    /// Nil when macOS keeps other apps out of the folder, so its size cannot be measured.
    var size: UInt64?
    var selected = false
    let needsAdmin: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    var isProtected: Bool { size == nil }
}

/// Leftovers that probably came from the same app or vendor.
struct LeftoverGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    var items: [LeftoverItem]

    var totalSize: UInt64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
    var selectedSize: UInt64 { items.filter(\.selected).reduce(0) { $0 + ($1.size ?? 0) } }
}

/// Finds data left behind by apps that have been deleted. Deliberately cautious: anything that might
/// belong to an installed or running app, to a shared framework, or that changed in the last week is left out.
final class LeftoverScanner: ObservableObject {
    static let shared = LeftoverScanner()

    @Published var groups: [LeftoverGroup] = []
    @Published private(set) var scanning = false
    @Published var loaded = false
    @Published private(set) var lastResult = ""

    var selectedItems: [LeftoverItem] { groups.flatMap { $0.items.filter(\.selected) } }
    var selectedSize: UInt64 { groups.reduce(0) { $0 + $1.selectedSize } }
    var totalSize: UInt64 { groups.reduce(0) { $0 + $1.totalSize } }
    var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        lastResult = ""
        inBackground {
            let found = LeftoverScanner.scanAll()
            DispatchQueue.main.async {
                self.groups = found
                self.scanning = false
                self.loaded = true
            }
        }
    }

    func setAll(_ on: Bool, in groupID: String) {
        guard let g = groups.firstIndex(where: { $0.id == groupID }) else { return }
        for i in groups[g].items.indices { groups[g].items[i].selected = on }
    }

    func trashSelected() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let size = selectedSize
        scanning = true
        inBackground {
            let result = Uninstaller.moveToTrash(chosen.map(\.path))
            let found = LeftoverScanner.scanAll()
            DispatchQueue.main.async {
                self.groups = found
                self.scanning = false
                self.lastResult = "Moved \(result.trashed.count) items (\(Fmt.bytes(size))) to the Trash."
                    + (result.failed.isEmpty ? "" : " \(result.failed.count) could not be moved.")
            }
        }
    }

    // MARK: Rules

    /// Frameworks, updaters, toolchains and system components whose data is never one app's leftover,
    /// because they are shared or come from command-line tools Spotlight can't see.
    static let sharedPrefixes = [
        "org.sparkle-project", "com.github.electron", "com.electron", "com.crashlytics", "io.sentry", "com.plausiblelabs",
        "com.google.keystone", "com.google.googleupdater", "com.microsoft.autoupdate", "com.squirrel", "com.adobe.acc",
        "com.oracle", "net.java", "org.openjdk", "com.android", "org.python", "org.mozilla.updater", "org.webkit", "org.chromium",
        "org.cups", "org.gnu", "org.llvm", "org.swift", "org.nodejs", "org.rust-lang", "sh.brew", "org.homebrew", "org.macports",
        "org.xquartz", "org.macosforge", "is.workflow", "com.jetbrains.toolbox",
    ]

    /// Folders where a leftover search makes sense. Launch agents and daemons are handled by Startup Items,
    /// and temporary folders are cleaned by macOS itself.
    static var scanLocations: [Uninstaller.Location] {
        Uninstaller.locations.filter { loc in
            !loc.path.hasSuffix("/LaunchAgents") && !loc.path.hasSuffix("/LaunchDaemons") && !loc.path.hasSuffix("/PrivilegedHelperTools")
                && !loc.path.contains("/var/folders/") && !loc.path.hasPrefix("/private/var/") && loc.category != "Temporary Files"
        }
    }

    /// Folders macOS guards with an "access data from other apps" prompt. Never looked inside.
    static func isGuardedLocation(_ base: String) -> Bool {
        base.hasSuffix("/Library/Containers") || base.hasSuffix("/Library/Group Containers")
    }

    /// Top-level domains a bundle identifier may start with.
    static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "app", "dev", "co", "me", "ai", "edu", "gov", "info", "biz", "xyz", "tech", "pro", "one",
        "studio", "design", "software", "tools", "systems", "cloud", "fm", "tv", "cc", "ly", "sh", "so", "im", "to", "is", "gg",
        "us", "uk", "ca", "au", "nz", "de", "at", "ch", "fr", "be", "nl", "lu", "it", "es", "pt", "se", "no", "dk", "fi", "pl",
        "cz", "sk", "hu", "ro", "ru", "ua", "eu", "jp", "cn", "kr", "tw", "hk", "sg", "in", "br", "mx", "ar", "cl", "za", "il", "tr",
    ]

    /// How a file or folder name reads as a bundle identifier.
    struct ParsedName: Equatable {
        /// The bundle identifier, lowercased, without prefixes or suffixes.
        let id: String
        /// A 10-character developer team prefix, if there was one.
        let team: String?
        /// The app-group name exactly as apps declare it (with "group." or the team prefix), lowercased.
        let group: String?
    }

    /// Reads a file or folder name as a bundle identifier, or returns nil when it isn't clearly one.
    /// Handles .plist/.savedState/.binarycookies, ByHost host suffixes, team-ID and "group." prefixes.
    static func parse(_ entry: String) -> ParsedName? {
        var name = entry
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.lowercased().hasSuffix(suffix.lowercased()) {
            name = String(name.dropLast(suffix.count))
            break
        }
        // ByHost preferences end in the host's UUID: com.vendor.app.0A1B2C3D-….plist
        if let dot = name.lastIndex(of: ".") {
            let last = name[name.index(after: dot)...]
            if UUID(uuidString: String(last)) != nil || (last.count == 12 && last.allSatisfy(\.isHexDigit) && last.contains(where: \.isNumber)) {
                name = String(name[..<dot])
            }
        }
        let groupName = name.lowercased()
        var team: String?
        var isGroup = false
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[0].count == 10, parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
           parts[0].contains(where: \.isLetter) {
            team = String(parts[0])
            name = parts.dropFirst().joined(separator: ".")
            isGroup = true
        }
        for prefix in ["group.", "groups."] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            isGroup = true
            break
        }
        let comps = name.split(separator: ".", omittingEmptySubsequences: false)
        guard comps.count >= 3 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard comps.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        // A reverse-DNS start such as com, org, net, io, de.
        guard topLevelDomains.contains(String(comps[0])) else { return nil }
        return ParsedName(id: name.lowercased(), team: team, group: isGroup ? groupName : nil)
    }

    static func bundleID(fromEntry entry: String) -> String? { parse(entry)?.id }

    static func vendor(of id: String) -> String {
        id.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// The name-only part of the decision: is this identifier unrelated to every app we know about?
    /// `known` holds lowercased bundle identifiers of installed and running apps.
    static func isUnclaimed(_ id: String, known: Set<String>) -> Bool {
        let id = id.lowercased()
        if id.hasPrefix("com.apple.") || id == "com.apple" || id.contains(".apple.") || id.contains("com.apple") { return false }
        if sharedPrefixes.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) { return false }
        let v = vendor(of: id)
        for k in known {
            // Same app, a helper of it, an app it is the vendor prefix of, or anything else from the same vendor.
            if id == k || id.hasPrefix(k + ".") || k.hasPrefix(id + ".") || vendor(of: k) == v { return false }
        }
        return true
    }

    /// Does an installed app claim this name through its developer team or its app groups?
    static func isClaimed(_ name: ParsedName, signatures: LeftoverSignatures) -> Bool {
        if let team = name.team, signatures.teams.contains(team) { return true }
        if let group = name.group, signatures.groups.contains(group) { return true }
        return false
    }

    /// Bundle identifiers of everything installed or running, including macOS's own apps.
    static func knownBundleIDs(apps: [InstalledApp] = Uninstaller.scanApps()) -> Set<String> {
        var ids = Set(apps.map { $0.bundleID.lowercased() })
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        for path in systemAppPaths() {
            if let id = Bundle(path: path)?.bundleIdentifier { ids.insert(id.lowercased()) }
        }
        if let own = Bundle.main.bundleIdentifier { ids.insert(own.lowercased()) }
        return ids
    }

    static func systemAppPaths() -> [String] {
        let fm = FileManager.default
        return ["/System/Applications", "/System/Applications/Utilities"].flatMap { root in
            ((try? fm.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasSuffix(".app") }.map { root + "/" + $0 }
        }
    }

    /// Developer teams and app groups of installed apps, read from their code signatures (nothing is verified or run).
    static func signatures(of apps: [InstalledApp]) -> LeftoverSignatures {
        var result = LeftoverSignatures()
        let fm = FileManager.default
        var bundles = apps.map(\.path)
        for app in apps {
            for sub in ["/Contents/PlugIns", "/Contents/Library/LoginItems", "/Contents/Library/LaunchServices"] {
                for entry in (try? fm.contentsOfDirectory(atPath: app.path + sub)) ?? [] { bundles.append(app.path + sub + "/" + entry) }
            }
        }
        for path in bundles {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { continue }
            var info: CFDictionary?
            let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
            guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess, let dict = info as? [String: Any] else { continue }
            if let team = dict[kSecCodeInfoTeamIdentifier as String] as? String { result.teams.insert(team) }
            if let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
                for key in ["com.apple.security.application-groups", "com.apple.security.team-identifier"] {
                    if let groups = ents[key] as? [String] { groups.forEach { result.groups.insert($0.lowercased()) } }
                    if let one = ents[key] as? String { result.teams.insert(one) }
                }
            }
        }
        return result
    }

    /// Asks Launch Services and Spotlight whether any bundle anywhere still carries this identifier.
    static func bundleStillExists(_ id: String) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil { return true }
        // `id` only contains letters, digits, dots, dashes and underscores (see bundleID(fromEntry:)).
        let query = "kMDItemCFBundleIdentifier == '\(id)'c || kMDItemCFBundleIdentifier == '\(id).*'c"
        let count = Int(shell("/usr/bin/mdfind", ["-count", query]).out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return count > 0
    }

    // MARK: Scanning

    static let minimumAge: TimeInterval = 7 * 24 * 3600

    static func scanAll() -> [LeftoverGroup] {
        let fm = FileManager.default
        let apps = Uninstaller.scanApps()
        let known = knownBundleIDs(apps: apps)
        let signed = signatures(of: apps)
        let home = NSHomeDirectory()
        let cutoff = Date().addingTimeInterval(-minimumAge)
        var candidates: [(path: String, id: String, category: String, guarded: Bool, modified: Date?)] = []
        var seen = Set<String>()

        for loc in scanLocations {
            let base = loc.path.hasSuffix("/") ? String(loc.path.dropLast()) : loc.path
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey]
            // Listing with prefetched attributes reads the parent folder only, never inside guarded containers.
            guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: keys, options: [])
            else { continue }
            for url in entries {
                let entry = url.lastPathComponent
                guard !entry.hasPrefix("."), let parsed = parse(entry), isUnclaimed(parsed.id, known: known),
                      !isClaimed(parsed, signatures: signed) else { continue }
                let id = parsed.id
                let rv = try? url.resourceValues(forKeys: Set(keys))
                if rv?.isSymbolicLink == true { continue }
                let path = base + "/" + entry
                guard seen.insert(path).inserted else { continue }
                candidates.append((path, id, loc.category, isGuardedLocation(base), rv?.contentModificationDate))
            }
        }

        // Expensive checks once per identifier.
        var exists: [String: Bool] = [:]
        for id in Set(candidates.map(\.id)) { exists[id] = bundleStillExists(id) }

        var items: [LeftoverItem] = []
        for c in candidates where exists[c.id] == false {
            if let m = c.modified, m > cutoff { continue }
            var size: UInt64?
            if !c.guarded {
                let measured = measure(c.path)
                if let newest = measured.newest, newest > cutoff { continue }
                size = measured.size
            }
            let parent = (c.path as NSString).deletingLastPathComponent
            let admin = !c.path.hasPrefix(home + "/") && !fm.isWritableFile(atPath: parent)
            items.append(LeftoverItem(path: c.path, bundleID: c.id, category: c.category, size: size, needsAdmin: admin))
        }
        items = items.filter { Uninstaller.isSafeToRemove($0.path) }
        return group(items)
    }

    /// Allocated size and newest modification date of a file or folder tree.
    static func measure(_ path: String) -> (size: UInt64, newest: Date?) {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return (0, nil) }
        var newest = rv.contentModificationDate
        if rv.isDirectory != true { return (UInt64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0), newest) }
        var total: UInt64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let f as URL in en {
                guard let v = try? f.resourceValues(forKeys: keys) else { continue }
                if let m = v.contentModificationDate, m > (newest ?? .distantPast) { newest = m }
                if v.isRegularFile == true { total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
            }
        }
        return (total, newest)
    }

    /// Groups by vendor; named after the app when everything points at one app.
    static func group(_ items: [LeftoverItem]) -> [LeftoverGroup] {
        let byVendor = Dictionary(grouping: items) { vendor(of: $0.bundleID) }
        let groups = byVendor.map { vendorID, list -> LeftoverGroup in
            // Root identifiers: those not nested under another identifier in the same group.
            let ids = Set(list.map(\.bundleID)).sorted { $0.count < $1.count }
            var roots: [String] = []
            for id in ids where !roots.contains(where: { id.hasPrefix($0 + ".") }) { roots.append(id) }
            let title: String
            let subtitle: String
            if roots.count == 1 {
                title = appTitle(roots[0])
                subtitle = roots[0]
            } else {
                title = prettyName(String(vendorID.split(separator: ".").last ?? ""))
                subtitle = "\(vendorID) · \(roots.count) apps"
            }
            let sorted = list.sorted { ($0.size ?? 0, $1.path) > ($1.size ?? 0, $0.path) }
            return LeftoverGroup(id: vendorID, title: title, subtitle: subtitle, items: sorted)
        }
        return groups.sorted { ($0.totalSize, $1.title) > ($1.totalSize, $0.title) }
    }

    /// "com.paperkite.notes" → "Paperkite Notes", "com.operasoftware.opera" → "Opera".
    static func appTitle(_ id: String) -> String {
        let comps = id.split(separator: ".").map(String.init)
        guard comps.count >= 2 else { return prettyName(id) }
        let vendorName = comps[1].lowercased(), last = comps.last!.lowercased()
        if comps.count == 2 || vendorName.hasPrefix(last) || last.hasPrefix(vendorName) { return prettyName(comps.last!) }
        return prettyName(comps[1]) + " " + prettyName(comps.last!)
    }

    /// "photo-editor" → "Photo Editor", "slackmacgap" → "Slackmacgap", "OmniFocus" stays.
    static func prettyName(_ s: String) -> String {
        let words = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").split(separator: " ")
        return words.map { w in w.first.map { $0.isLowercase ? $0.uppercased() + w.dropFirst() : String(w) } ?? "" }.joined(separator: " ")
    }
}
