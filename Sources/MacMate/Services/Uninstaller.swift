import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let bundleID: String
    let version: String
    let path: String
    var size: UInt64?
}

struct RelatedItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let category: String
    var size: UInt64
    var selected: Bool
    /// True when the file lives in a system folder and macOS will ask for an admin password.
    let needsAdmin: Bool
    /// True when macOS will not let other apps look inside (app data protection), so the size is unknown.
    var isProtected = false

    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

struct RemovalResult {
    var trashed: [String] = []
    var failed: [String] = []
}

/// Finds an app and everything it left around the system, and moves it all to the Trash
/// (never deletes outright, so anything can be put back from the Trash).
final class Uninstaller: ObservableObject {
    static let shared = Uninstaller()

    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var loading = false

    // MARK: Installed apps

    func loadApps() {
        guard !loading else { return }
        loading = true
        inBackground {
            let found = Uninstaller.scanApps()
            DispatchQueue.main.async {
                self.apps = found
                self.loading = false
            }
            // Sizes take a while; fill them in afterwards.
            for app in found {
                let size = diskSize(of: URL(fileURLWithPath: app.path))
                DispatchQueue.main.async {
                    if let i = self.apps.firstIndex(where: { $0.path == app.path }) { self.apps[i].size = size }
                }
            }
        }
    }

    static func scanApps() -> [InstalledApp] {
        let fm = FileManager.default
        var roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        // One level of sub-folders, e.g. /Applications/Utilities or a vendor folder.
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !entry.hasSuffix(".app") && !entry.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = root + "/" + entry
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { roots.append(p) }
            }
        }
        var result: [InstalledApp] = []
        var seen = Set<String>()
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where entry.hasSuffix(".app") {
                let path = root + "/" + entry
                let resolved = (path as NSString).resolvingSymlinksInPath
                // Skip macOS's own sealed apps (Safari and friends) – they cannot be removed.
                guard !resolved.hasPrefix("/System/"), fm.isDeletableFile(atPath: path), seen.insert(resolved).inserted else { continue }
                if let app = app(at: path) { result.append(app) }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func app(at path: String) -> InstalledApp? {
        guard let bundle = Bundle(path: path) else { return nil }
        let info = bundle.infoDictionary ?? [:]
        guard let id = bundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
        var name = String((path as NSString).lastPathComponent.dropLast(4))
        // Some apps ship with an invisible or symbol-only file name; fall back to the name inside the bundle.
        if !name.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
            name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? id
        }
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        return InstalledApp(name: name, bundleID: id, version: version, path: path, size: nil)
    }

    // MARK: Leftover search

    private struct Location {
        let path: String
        let category: String
        let allowNameMatch: Bool
        let allowSuffixMatch: Bool
    }

    private static var locations: [Location] {
        let home = NSHomeDirectory()
        var list = [
            Location(path: home + "/Library/Application Support", category: "Application Support", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: home + "/Library/Caches", category: "Caches", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: home + "/Library/Preferences", category: "Preferences", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: home + "/Library/Preferences/ByHost", category: "Preferences", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/Logs", category: "Logs", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: home + "/Library/Saved Application State", category: "Saved State", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/Containers", category: "Containers", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/Group Containers", category: "Group Containers", allowNameMatch: false, allowSuffixMatch: true),
            Location(path: home + "/Library/Application Scripts", category: "Scripts", allowNameMatch: false, allowSuffixMatch: true),
            Location(path: home + "/Library/HTTPStorages", category: "Web Data", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/WebKit", category: "Web Data", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/Cookies", category: "Web Data", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: home + "/Library/LaunchAgents", category: "Login & Background Items", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: "/Library/Application Support", category: "Application Support", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: "/Library/Caches", category: "Caches", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: "/Library/Preferences", category: "Preferences", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: "/Library/Logs", category: "Logs", allowNameMatch: true, allowSuffixMatch: false),
            Location(path: "/Library/LaunchAgents", category: "Login & Background Items", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: "/Library/LaunchDaemons", category: "Login & Background Items", allowNameMatch: false, allowSuffixMatch: false),
            Location(path: "/Library/PrivilegedHelperTools", category: "Login & Background Items", allowNameMatch: false, allowSuffixMatch: false),
        ]
        // Per-user cache and temp folders under /var/folders.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buf, buf.count) > 0 {
            list.append(Location(path: String(cString: buf), category: "Caches", allowNameMatch: false, allowSuffixMatch: false))
        }
        list.append(Location(path: NSTemporaryDirectory(), category: "Temporary Files", allowNameMatch: false, allowSuffixMatch: false))
        return list
    }

    /// Does a file or folder name belong to this app?
    static func matches(entry: String, bundleID: String, appName: String, allowName: Bool, allowSuffix: Bool,
                        otherBundleIDs: [String] = []) -> Bool {
        let e = entry.lowercased()
        let stem = (e as NSString).deletingPathExtension
        let bid = bundleID.lowercased()
        let name = appName.lowercased()
        guard !e.isEmpty else { return false }

        if bid.count >= 5, bid.contains(".") {
            var hit = e == bid || stem == bid || e.hasPrefix(bid + ".")
            if !hit, allowSuffix { hit = e.hasSuffix("." + bid) || stem.hasSuffix("." + bid) || e.contains("." + bid + ".") }
            if hit {
                // "com.vendor.app" must not swallow a sibling app such as "com.vendor.app.beta".
                for other in otherBundleIDs {
                    let o = other.lowercased()
                    if o != bid, o.hasPrefix(bid + "."), e == o || stem == o || e.hasPrefix(o + ".") || e.contains("." + o) { return false }
                }
                return true
            }
        }
        if allowName, name.count >= 2 {
            return e == name || stem == name
        }
        return false
    }

    static func findRelated(for app: InstalledApp, otherBundleIDs: [String] = []) -> [RelatedItem] {
        let fm = FileManager.default
        var paths: [(String, String)] = []
        var seen = Set<String>()
        func add(_ path: String, _ category: String) {
            if seen.insert(path).inserted { paths.append((path, category)) }
        }

        for loc in locations {
            let base = loc.path.hasSuffix("/") ? String(loc.path.dropLast()) : loc.path
            for entry in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
                if matches(entry: entry, bundleID: app.bundleID, appName: app.name, allowName: loc.allowNameMatch,
                           allowSuffix: loc.allowSuffixMatch, otherBundleIDs: otherBundleIDs) {
                    add(base + "/" + entry, loc.category)
                }
            }
        }

        // Vendor folders: com.google.Chrome keeps its data in "Application Support/Google/Chrome".
        let parts = app.bundleID.split(separator: ".").map(String.init)
        if parts.count >= 3 {
            let vendor = parts[1].lowercased()
            let last = parts.last!.lowercased()
            let name = app.name.lowercased()
            var candidates: Set<String> = [name, last]
            if name.hasPrefix(vendor + " ") { candidates.insert(String(name.dropFirst(vendor.count + 1))) }
            let bases = [(NSHomeDirectory() + "/Library/Application Support", "Application Support"),
                         (NSHomeDirectory() + "/Library/Caches", "Caches"),
                         ("/Library/Application Support", "Application Support")]
            for (base, category) in bases {
                for dir in (try? fm.contentsOfDirectory(atPath: base)) ?? [] where dir.lowercased() == vendor {
                    for child in (try? fm.contentsOfDirectory(atPath: base + "/" + dir)) ?? [] where candidates.contains(child.lowercased()) {
                        add(base + "/" + dir + "/" + child, category)
                    }
                }
            }
        }

        let home = NSHomeDirectory()
        return paths.map { path, category in
            let parent = (path as NSString).deletingLastPathComponent
            let admin = !path.hasPrefix(home) && !fm.isWritableFile(atPath: parent)
            var isDir: ObjCBool = false
            let locked = fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                && (try? fm.contentsOfDirectory(atPath: path)) == nil
            return RelatedItem(path: path, category: category, size: diskSize(of: URL(fileURLWithPath: path)), selected: true,
                               needsAdmin: admin, isProtected: locked)
        }
        .sorted { ($0.category, $0.path) < ($1.category, $1.path) }
    }

    // MARK: Removal

    /// Moves everything to the Trash. Items that need admin rights are handed to Finder, which asks for the password.
    static func moveToTrash(_ paths: [String]) -> RemovalResult {
        let fm = FileManager.default
        var result = RemovalResult()
        // Drop anything nested inside another selected item, and refuse anything outside known-safe places.
        let sorted = paths.sorted { $0.count < $1.count }
        var roots: [String] = []
        for p in sorted where isSafeToRemove(p) && !roots.contains(where: { p.hasPrefix($0 + "/") }) { roots.append(p) }

        var needFinder: [String] = []
        for path in roots {
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result.trashed.append(path)
            } catch {
                needFinder.append(path)
            }
        }
        if !needFinder.isEmpty {
            let list = needFinder.map { "POSIX file \"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
                .joined(separator: ", ")
            _ = appleScript("tell application \"Finder\" to delete {\(list)}")
            for path in needFinder {
                if fm.fileExists(atPath: path) { result.failed.append(path) } else { result.trashed.append(path) }
            }
        }
        return result
    }

    /// Developer cache folders the junk cleaner may offer, besides things inside a Library folder.
    static var extraRemovable: Set<String> {
        let home = NSHomeDirectory()
        return [home + "/.npm/_cacache", home + "/.gradle/caches", home + "/.cargo/registry/cache", home + "/.cache"]
    }

    static func isSafeToRemove(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let home = NSHomeDirectory()
        if p.hasPrefix("/System/") || p == "/" || p == home { return false }
        if p.hasSuffix(".app"), p.hasPrefix("/Applications/") || p.hasPrefix(home + "/Applications/") { return true }
        if extraRemovable.contains(p) { return true }
        // Otherwise it must be an item *inside* a Library sub-folder (never the sub-folder itself),
        // or inside the per-user cache/temp area.
        for base in [home + "/Library/", "/Library/"] where p.hasPrefix(base) {
            return p.dropFirst(base.count).split(separator: "/").count >= 2
        }
        for base in ["/private/var/folders/", "/var/folders/"] where p.hasPrefix(base) {
            return p.dropFirst(base.count).split(separator: "/").count >= 4
        }
        return false
    }

    static func quitIfRunning(_ app: InstalledApp) {
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.path == app.path {
            running.terminate()
        }
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == app.path }
    }
}

// MARK: - Junk cleaner

struct JunkItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: UInt64
    var selected: Bool
    var name: String { (path as NSString).lastPathComponent }
}

struct JunkCategory: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    var items: [JunkItem]
    var selectedSize: UInt64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
}

final class JunkCleaner: ObservableObject {
    static let shared = JunkCleaner()

    @Published var categories: [JunkCategory] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastResult = ""

    var selectedSize: UInt64 { categories.reduce(0) { $0 + $1.selectedSize } }

    func scan() {
        guard !scanning else { return }
        scanning = true
        lastResult = ""
        inBackground {
            let found = JunkCleaner.scanAll()
            DispatchQueue.main.async {
                self.categories = found
                self.scanning = false
            }
        }
    }

    func cleanSelected() {
        let paths = categories.flatMap { $0.items.filter(\.selected).map(\.path) }
        guard !paths.isEmpty else { return }
        let size = selectedSize
        scanning = true
        inBackground {
            let result = Uninstaller.moveToTrash(paths)
            let found = JunkCleaner.scanAll()
            DispatchQueue.main.async {
                self.categories = found
                self.scanning = false
                self.lastResult = "Moved \(result.trashed.count) items (\(Fmt.bytes(size))) to the Trash. Empty the Trash to free the space."
                    + (result.failed.isEmpty ? "" : " \(result.failed.count) could not be moved.")
            }
        }
    }

    static func scanAll() -> [JunkCategory] {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        func children(of dir: String, skip: (String) -> Bool = { _ in false }, selected: Bool, minSize: UInt64 = 64 * 1024) -> [JunkItem] {
            ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { !$0.hasPrefix(".") && !skip($0) }
                .map { dir + "/" + $0 }
                .map { JunkItem(path: $0, size: diskSize(of: URL(fileURLWithPath: $0)), selected: selected) }
                .filter { $0.size >= minSize }
                .sorted { $0.size > $1.size }
        }
        func single(_ paths: [String], selected: Bool) -> [JunkItem] {
            paths.filter { fm.fileExists(atPath: $0) }
                .map { JunkItem(path: $0, size: diskSize(of: URL(fileURLWithPath: $0)), selected: selected) }
                .filter { $0.size >= 64 * 1024 }
                .sorted { $0.size > $1.size }
        }

        // Apple's own caches are left alone: several are protected or shared with the system.
        let protectedCaches: (String) -> Bool = { name in
            let n = name.lowercased()
            return n.hasPrefix("com.apple.") || ["cloudkit", "familycircle", "geoservices", "macmate"].contains(n)
        }
        var out: [JunkCategory] = []
        out.append(JunkCategory(id: "caches", title: "App caches", symbol: "internaldrive",
                                detail: "Temporary data apps rebuild when they need it",
                                items: children(of: home + "/Library/Caches", skip: protectedCaches, selected: true)))
        out.append(JunkCategory(id: "logs", title: "Logs and crash reports", symbol: "doc.text",
                                detail: "Old diagnostic output",
                                items: children(of: home + "/Library/Logs", selected: true)))
        out.append(JunkCategory(id: "dev", title: "Developer leftovers", symbol: "hammer",
                                detail: "Build products and package-manager caches",
                                items: single([
                                    home + "/Library/Developer/Xcode/DerivedData",
                                    home + "/Library/Developer/Xcode/iOS DeviceSupport",
                                    home + "/Library/Developer/CoreSimulator/Caches",
                                    home + "/.npm/_cacache",
                                    home + "/.gradle/caches",
                                    home + "/.cargo/registry/cache",
                                    home + "/.cache",
                                ], selected: false)))
        return out
    }

    /// Size of the Trash, or nil when macOS will not let us look (needs Full Disk Access).
    static func trashSize() -> UInt64? {
        let trash = NSHomeDirectory() + "/.Trash"
        guard (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil else { return nil }
        return diskSize(of: URL(fileURLWithPath: trash))
    }

    static func emptyTrash() -> Bool {
        appleScript("tell application \"Finder\" to empty trash").ok
    }
}
