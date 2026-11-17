import AppKit
import SwiftUI

extension SelfTest {
    /// Startup Items, Leftovers and Large & Old Files. Read-only against the real system: nothing here changes
    /// launchd state or asks for a password, and only files this test creates are moved to the Trash.
    static func runCleanupChecks() {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        print("== Cleanup sidebar")
        check("tool tags unique", Set(CleanupMode.tools.compactMap(\.sidebarTag)).count == CleanupMode.tools.count)
        check("tags round-trip", CleanupMode.tools.allSatisfy { CleanupMode.tool(forTag: $0.sidebarTag) == $0 })
        check("apps are not tools", CleanupMode.tool(forTag: "/Applications/Foo.app") == nil && CleanupMode.tool(forTag: nil) == nil)

        print("== Startup items")
        let disabled = StartupItemManager.parseDisabled("""
            disabled services = {
            \t"com.vendor.agent" => disabled
            \t"com.other.agent" => enabled
            \t"org.legacy.agent" => true
            }
            """)
        check("print-disabled parsed", disabled == ["com.vendor.agent": true, "com.other.agent": false, "org.legacy.agent": true], "\(disabled)")
        let pids = StartupItemManager.parseList("PID\tStatus\tLabel\n-\t0\tcom.idle.agent\n812\t0\tcom.busy.agent\n")
        check("launchctl list parsed", pids == ["com.busy.agent": 812], "\(pids)")

        let a = StartupItemManager.parse(["Label": "com.vendor.sync", "ProgramArguments": ["/Applications/Vendor Sync.app/Contents/MacOS/sync", "--bg"],
                                          "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]],
                                         path: "/tmp/com.vendor.sync.plist", scope: .user)
        check("plist parsed", a?.label == "com.vendor.sync" && a?.program == "/Applications/Vendor Sync.app/Contents/MacOS/sync"
              && a?.runAtLoad == true && a?.keepAlive == true)
        let b = StartupItemManager.parse(["Program": "/usr/local/bin/tool", "KeepAlive": false], path: "/tmp/org.x.tool.plist", scope: .system)
        check("label falls back to file name", b?.label == "org.x.tool" && b?.program == "/usr/local/bin/tool" && b?.keepAlive == false && b?.runAtLoad == false)
        check("enclosing app", StartupItemManager.enclosingApp(of: "/Applications/A.app/Contents/Library/LoginItems/B.app/Contents/MacOS/b") == "/Applications/A.app")
        check("no enclosing app", StartupItemManager.enclosingApp(of: "/usr/local/bin/tool") == nil)

        let present: Set<String> = ["/usr/bin/open", "/Applications/Here.app", "/Applications/Here.app/Contents/MacOS/here"]
        let exists: (String) -> Bool = { present.contains($0) }
        check("missing program is gone", StartupItemManager.isGone(program: "/Applications/Gone.app/Contents/MacOS/gone", arguments: [], exists: exists))
        check("present program is not gone", !StartupItemManager.isGone(program: "/Applications/Here.app/Contents/MacOS/here", arguments: [], exists: exists))
        check("open of a deleted app is gone", StartupItemManager.isGone(program: "/usr/bin/open", arguments: ["/usr/bin/open", "-a", "/Applications/Gone.app"], exists: exists))
        check("relative program never flagged", !StartupItemManager.isGone(program: "node", arguments: [], exists: exists))
        check("unmounted volume never flagged", !StartupItemManager.isGone(program: "/Volumes/External/tool", arguments: [], exists: exists))
        check("privacy folders never probed", StartupItemManager.isPrivacyProtected(home + "/Documents/run.sh") && !StartupItemManager.isPrivacyProtected("/opt/tool"))

        let apps = [InstalledApp(name: "Vendor Sync", bundleID: "com.vendor.sync", version: "1", path: "/Applications/Vendor Sync.app"),
                    InstalledApp(name: "Solo", bundleID: "io.solo.main", version: "1", path: "/Applications/Solo.app")]
        check("owner by label prefix", StartupItemManager.ownerApp(label: "com.vendor.sync.helper", program: nil, arguments: [], associated: [], apps: apps).name == "Vendor Sync")
        check("owner by vendor", StartupItemManager.ownerApp(label: "io.solo.updater", program: nil, arguments: [], associated: [], apps: apps).name == "Solo")
        check("owner by program path", StartupItemManager.ownerApp(label: "x.y.z", program: "/Applications/Old Tool.app/Contents/MacOS/t", arguments: [], associated: [], apps: apps).name == "Old Tool")
        check("no owner", StartupItemManager.ownerApp(label: "net.unknown.agent", program: "/usr/local/bin/u", arguments: [], associated: [], apps: apps).name == nil)

        let tricky = "/Library/Launch Agents/it's a \"test\" \\ $HOME `x`.plist"
        let viaShell = shell("/bin/sh", ["-c", "printf %s " + StartupItemManager.shellQuote(tricky)]).out
        check("shell quoting", viaShell == tricky, viaShell)
        let viaScript = appleScript("return " + StartupItemManager.appleScriptString(tricky)).out
        check("AppleScript quoting", viaScript == tricky, viaScript)
        // The same layering the admin path uses, without administrator privileges.
        let nested = appleScript("do shell script " + StartupItemManager.appleScriptString("printf %s " + StartupItemManager.shellQuote(tricky))).out
        check("shell inside AppleScript", nested == tricky, nested)
        check("admin script shape", StartupItemManager.adminScript("true") == "do shell script \"true\" with administrator privileges")

        if !ci {
            let t = Date()
            let items = StartupItemManager.scanAll()
            print("  \(items.count) items (\(items.filter { $0.scope == .user }.count) yours, \(items.filter { $0.scope == .allUsers }.count) all users, \(items.filter { $0.scope == .system }.count) system), \(items.filter(\.running).count) running, \(items.filter(\.disabled).count) off, \(items.filter(\.appGone).count) gone, \(items.filter { $0.appName != nil }.count) with an app, in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            check("startup scan hides Apple items", !items.contains { $0.label.lowercased().hasPrefix("com.apple.") })
            check("startup items are launchd files", items.allSatisfy { $0.plistPath.hasSuffix(".plist") && fm.fileExists(atPath: $0.plistPath) })
            check("startup items trashable when gone", items.filter(\.appGone).allSatisfy { Uninstaller.isSafeToRemove($0.plistPath) })
        }

        print("== Leftovers")
        let names: [(String, String?)] = [
            ("com.foo.bar.plist", "com.foo.bar"), ("com.foo.bar.savedState", "com.foo.bar"), ("com.foo.bar.binarycookies", "com.foo.bar"),
            ("group.com.foo.bar", "com.foo.bar"), ("ABCDE12345.com.foo.bar", "com.foo.bar"), ("com.Foo.Bar", "com.foo.bar"),
            ("com.foo.bar.0A1B2C3D-0000-1111-2222-333344445555.plist", "com.foo.bar"),
            ("com.foo", nil), ("Google", nil), ("UBF8T346G9.Office", nil), ("Some App.app", nil), ("com.foo..bar", nil),
            ("2BUA8C4S2C.com.foo.bar.plist", "com.foo.bar"), ("ABCDEFGHIJKLMNOP.com.foo.bar", nil), ("V1.2.3", nil),
            ("warp.log.old.1", nil), ("main.kts.compiled.cache", nil), ("ABCDE12345.group.com.foo.shared", "com.foo.shared"),
            ("groups.com.foo.bar", "com.foo.bar"),
        ]
        for (entry, expected) in names {
            let got = LeftoverScanner.bundleID(fromEntry: entry)
            check("name \(entry)", got == expected, "\(got ?? "nil")")
        }
        let known: Set<String> = ["com.vendor.app", "org.solo.editor.pro"]
        check("Apple never a leftover", !LeftoverScanner.isUnclaimed("com.apple.mail", known: known))
        check("installed app kept", !LeftoverScanner.isUnclaimed("com.vendor.app", known: known))
        check("helper kept", !LeftoverScanner.isUnclaimed("com.vendor.app.helper", known: known))
        check("vendor prefix kept", !LeftoverScanner.isUnclaimed("org.solo.editor", known: known))
        check("same vendor kept", !LeftoverScanner.isUnclaimed("com.vendor.otherapp", known: known))
        check("shared framework kept", !LeftoverScanner.isUnclaimed("org.sparkle-project.sparkle", known: known))
        check("unrelated id is a candidate", LeftoverScanner.isUnclaimed("net.gone.app", known: known))
        check("Apple group never a leftover", !LeftoverScanner.isUnclaimed("com.foo.com.apple.podcasts", known: known))
        check("toolchain kept", !LeftoverScanner.isUnclaimed("net.java.openjdk.java", known: known) && !LeftoverScanner.isUnclaimed("is.workflow.my.app", known: known))
        let sig = LeftoverSignatures(teams: ["ABCDE12345"], groups: ["group.com.shared.box"])
        check("team-prefixed data of an installed team kept", LeftoverScanner.parse("ABCDE12345.com.other.family").map { LeftoverScanner.isClaimed($0, signatures: sig) } == true)
        check("app group of an installed app kept", LeftoverScanner.parse("group.com.shared.box").map { LeftoverScanner.isClaimed($0, signatures: sig) } == true)
        check("unknown team not claimed", LeftoverScanner.parse("ZZZZZ99999.com.other.family").map { LeftoverScanner.isClaimed($0, signatures: sig) } == false)
        check("app titles", LeftoverScanner.appTitle("com.paperkite.notes") == "Paperkite Notes" && LeftoverScanner.appTitle("com.operasoftware.opera") == "Opera")
        check("bundle lookup finds a real app", LeftoverScanner.bundleStillExists("com.apple.finder"))
        check("bundle lookup misses a made-up id", !LeftoverScanner.bundleStillExists("net.macmatetest.\(UInt32.random(in: 1000...999_999))"))
        let grouped = LeftoverScanner.group([
            LeftoverItem(path: home + "/Library/Caches/com.gone.photo-editor", bundleID: "com.gone.photo-editor", category: "Caches", size: 10, needsAdmin: false),
            LeftoverItem(path: home + "/Library/Preferences/com.gone.photo-editor.helper.plist", bundleID: "com.gone.photo-editor.helper", category: "Preferences", size: 1, needsAdmin: false),
            LeftoverItem(path: home + "/Library/Caches/net.other.a", bundleID: "net.other.a", category: "Caches", size: 5, needsAdmin: false),
            LeftoverItem(path: home + "/Library/Caches/net.other.b", bundleID: "net.other.b", category: "Caches", size: 5, needsAdmin: false),
        ])
        check("grouped by app", grouped.first?.title == "Gone Photo Editor" && grouped.first?.items.count == 2, grouped.map(\.title).joined(separator: ", "))
        check("grouped by vendor", grouped.last?.title == "Other" && grouped.last?.subtitle == "net.other · 2 apps", grouped.last?.subtitle ?? "")
        check("leftover locations exclude launchd and temp", !LeftoverScanner.scanLocations.contains { $0.path.contains("Launch") || $0.category == "Temporary Files" })

        if !ci {
            // A made-up leftover, old enough to count, and a fresh one that must be left alone.
            let vendorTag = "macmatetest\(UInt32.random(in: 1000...999_999))"
            let old = home + "/Library/Caches/net.\(vendorTag).gone-app"
            let fresh = home + "/Library/Caches/org.\(vendorTag).fresh-app"
            try? fm.createDirectory(atPath: old, withIntermediateDirectories: true)
            try? Data(count: 4096).write(to: URL(fileURLWithPath: old + "/cache.db"))
            try? fm.createDirectory(atPath: fresh, withIntermediateDirectories: true)
            let past = Date().addingTimeInterval(-30 * 24 * 3600)
            try? fm.setAttributes([.modificationDate: past], ofItemAtPath: old + "/cache.db")
            try? fm.setAttributes([.modificationDate: past], ofItemAtPath: old)

            let t = Date()
            let groups = LeftoverScanner.scanAll()
            let all = groups.flatMap(\.items)
            print("  \(all.count) leftovers in \(groups.count) groups, \(Fmt.bytes(groups.reduce(0) { $0 + $1.totalSize })), \(all.filter(\.isProtected).count) protected, in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            check("made-up old leftover found", all.contains { $0.path == old })
            check("fresh folder left out", !all.contains { $0.path == fresh })
            check("leftovers unselected by default", all.allSatisfy { !$0.selected })
            check("leftovers all safe", all.allSatisfy { Uninstaller.isSafeToRemove($0.path) })
            check("no Apple leftovers", !all.contains { $0.bundleID.hasPrefix("com.apple.") })
            let installed = LeftoverScanner.knownBundleIDs()
            check("no leftover belongs to an installed or running app",
                  all.allSatisfy { item in !installed.contains { item.bundleID == $0 || item.bundleID.hasPrefix($0 + ".") || $0.hasPrefix(item.bundleID + ".") } })
            if !apps.isEmpty {
                let sigs = LeftoverScanner.signatures(of: Uninstaller.scanApps())
                print("  \(sigs.teams.count) developer teams, \(sigs.groups.count) app groups read from installed apps")
                check("installed apps' signatures read", !sigs.teams.isEmpty)
            }
            check("no leftover from a vendor still installed",
                  all.allSatisfy { item in !installed.contains { LeftoverScanner.vendor(of: $0) == LeftoverScanner.vendor(of: item.bundleID) } })
            let r = Uninstaller.moveToTrash([old])
            check("made-up leftover moved to Trash", r.trashed == [old] && !fm.fileExists(atPath: old))
            try? fm.removeItem(atPath: fresh)
        }

        print("== Large & old files")
        check("Library excluded", LargeFileFinder.isExcluded(home + "/Library/Caches/big.bin"))
        check("outside home excluded", LargeFileFinder.isExcluded("/tmp/big.bin"))
        check("hidden folder excluded", LargeFileFinder.isExcluded(home + "/.cache/big.bin"))
        check("inside Photos library excluded", LargeFileFinder.isExcluded(home + "/Pictures/Photos Library.photoslibrary/originals/A/1.heic"))
        check("inside app excluded", LargeFileFinder.isExcluded(home + "/Applications/Tool.app/Contents/Resources/data.bin"))
        check("inside archive excluded", LargeFileFinder.isExcluded(home + "/Projects/Build.xcarchive/Products/x.bin"))
        check("package itself excluded", LargeFileFinder.isExcluded(home + "/Movies/Holiday.fcpbundle"))
        check("ordinary file allowed", !LargeFileFinder.isExcluded(home + "/Movies/Holiday.mov"))
        check("dotted folder name allowed", !LargeFileFinder.isExcluded(home + "/Projects/v1.2 release/disk.dmg"))
        check("Library refused for trash", !LargeFileFinder.isSafeToTrash(home + "/Library/Caches/whatever"))
        check("home refused for trash", !LargeFileFinder.isSafeToTrash(home))
        check("size choices include default", LargeFileFinder.sizeChoices.contains { $0.bytes == LargeFileFinder.defaultMinSize })
        let now = Date()
        let oldFile = LargeFileItem(path: home + "/a", size: 1, lastOpened: now.addingTimeInterval(-400 * 86400), modified: nil, contentType: nil)
        let newFile = LargeFileItem(path: home + "/b", size: 1, lastOpened: now.addingTimeInterval(-10 * 86400), modified: now.addingTimeInterval(-900 * 86400), contentType: nil)
        let neverFile = LargeFileItem(path: home + "/c", size: 1, lastOpened: nil, modified: now.addingTimeInterval(-500 * 86400), contentType: nil)
        check("old by last opened", oldFile.isOld(now: now) && !newFile.isOld(now: now) && neverFile.isOld(now: now))

        if !ci {
            // Own scratch folder directly in the home folder (not a privacy-protected one).
            let dir = home + "/MacMate-selftest-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir + "/Thing.photoslibrary", withIntermediateDirectories: true)
            let file = dir + "/big.bin", inPackage = dir + "/Thing.photoslibrary/inner.bin", link = dir + "/link.bin"
            try? Data(count: 1024).write(to: URL(fileURLWithPath: file))
            try? Data(count: 1024).write(to: URL(fileURLWithPath: inPackage))
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: file)
            check("own file safe to trash", LargeFileFinder.isSafeToTrash(file))
            check("folder refused", !LargeFileFinder.isSafeToTrash(dir))
            check("symlink refused", !LargeFileFinder.isSafeToTrash(link))
            check("file inside package refused", !LargeFileFinder.isSafeToTrash(inPackage))
            let r = LargeFileFinder.moveToTrash([file, inPackage, link])
            check("large file moved to Trash", r.trashed == [file] && !fm.fileExists(atPath: file) && fm.fileExists(atPath: inPackage), "\(r.trashed.count) trashed, \(r.failed.count) refused")
            try? fm.removeItem(atPath: dir)

            let t = Date()
            let found = LargeFileFinder.query(minSize: LargeFileFinder.scanFloor)
            let list = found ?? []
            print("  \(list.count) files over 50 MB, \(list.filter { $0.size >= 100_000_000 }.count) over 100 MB, \(list.filter { $0.isOld() }.count) not opened for a year, \(Fmt.bytes(list.reduce(0) { $0 + $1.size })), in \(String(format: "%.1f", Date().timeIntervalSince(t)))s")
            check("Spotlight answered", found != nil)
            check("results are ordinary home files", list.allSatisfy { !LargeFileFinder.isExcluded($0.path) })
            check("results sorted by size", zip(list, list.dropFirst()).allSatisfy { $0.size >= $1.size })
            check("results unselected", list.allSatisfy { !$0.selected })
        }
    }
}

extension Snapshot {
    /// Renders the Startup Items, Leftovers and Large & Old Files panes with made-up sample data.
    static func renderCleanupTools(directory: String) {
        active = true
        let home = NSHomeDirectory()

        func agent(_ label: String, _ scope: StartupItem.Scope, app: String?, running: Bool = false, off: Bool = false,
                   gone: Bool = false, load: Bool = true, keep: Bool = false) -> StartupItem {
            var item = StartupItem(label: label, plistPath: scope.folder + "/" + label + ".plist", scope: scope,
                                   program: "/Applications/\(app ?? "Tool").app/Contents/MacOS/agent", arguments: [],
                                   runAtLoad: load, keepAlive: keep)
            item.appName = app
            item.running = running
            item.disabled = off
            item.appGone = gone
            return item
        }
        let startup = StartupItemManager.shared
        startup.items = [
            agent("com.northwind.sync.agent", .user, app: "Northwind Sync", running: true, keep: true),
            agent("io.lumen.updater", .user, app: "Lumen", off: true),
            agent("net.paperkite.helper", .user, app: nil, gone: true),
            agent("com.harborline.vpn.agent", .allUsers, app: "Harborline VPN", running: true, keep: true),
            agent("com.harborline.vpn.daemon", .system, app: "Harborline VPN", running: true, keep: true),
            agent("org.quillpad.backup", .system, app: nil, gone: true, load: false),
        ]
        startup.loaded = true
        render(StartupItemsView().background(.regularMaterial), size: CGSize(width: 640, height: 600), to: "\(directory)/cleanup-startup.png")

        func left(_ path: String, _ id: String, _ category: String, _ size: UInt64?, on: Bool = false) -> LeftoverItem {
            LeftoverItem(path: path, bundleID: id, category: category, size: size, selected: on, needsAdmin: path.hasPrefix("/Library"))
        }
        let L = home + "/Library"
        let leftovers = LeftoverScanner.shared
        leftovers.groups = LeftoverScanner.group([
            left(L + "/Application Support/com.paperkite.notes", "com.paperkite.notes", "Application Support", 412_000_000, on: true),
            left(L + "/Caches/com.paperkite.notes", "com.paperkite.notes", "Caches", 88_400_000, on: true),
            left(L + "/Preferences/com.paperkite.notes.plist", "com.paperkite.notes", "Preferences", 8192, on: true),
            left(L + "/Containers/com.paperkite.notes.share", "com.paperkite.notes.share", "Containers", nil),
            left(L + "/Caches/io.tidewater.player", "io.tidewater.player", "Caches", 23_000_000),
            left(L + "/HTTPStorages/io.tidewater.player", "io.tidewater.player", "Web Data", 61_440),
            left(L + "/Saved Application State/io.tidewater.player.savedState", "io.tidewater.player", "Saved State", 32_768),
            left("/Library/Application Support/org.quillpad.backup", "org.quillpad.backup", "Application Support", 5_200_000),
            left(L + "/Preferences/org.quillpad.reader.plist", "org.quillpad.reader", "Preferences", 4096),
        ])
        leftovers.loaded = true
        render(LeftoversView().background(.regularMaterial), size: CGSize(width: 640, height: 600), to: "\(directory)/cleanup-leftovers.png")

        let day: TimeInterval = 86400
        func file(_ rel: String, _ mb: Double, opened: Double?, modified: Double, _ type: String, on: Bool = false) -> LargeFileItem {
            LargeFileItem(path: home + "/" + rel, size: UInt64(mb * 1_000_000), lastOpened: opened.map { Date().addingTimeInterval(-$0 * day) },
                          modified: Date().addingTimeInterval(-modified * day), contentType: type, selected: on)
        }
        let large = LargeFileFinder.shared
        UserDefaults.standard.set(LargeFileFinder.defaultMinSize, forKey: Keys.largeFilesMinSize)
        UserDefaults.standard.set(false, forKey: Keys.largeFilesOnlyOld)
        large.items = [
            file("Movies/Coastline drone footage.mov", 8_420, opened: 540, modified: 560, "com.apple.quicktime-movie", on: true),
            file("Downloads/Design Tools Installer.dmg", 2_310, opened: 420, modified: 430, "com.apple.disk-image-udif", on: true),
            file("Documents/Archive/Studio backup 2023.zip", 1_870, opened: nil, modified: 700, "public.zip-archive"),
            file("Movies/Conference keynote.mp4", 1_240, opened: 35, modified: 60, "public.mpeg-4"),
            file("Downloads/Linux 24.04 arm64.iso", 980, opened: 220, modified: 230, "public.iso-image"),
            file("Music/Field recordings/Harbor at dusk.wav", 612, opened: 400, modified: 410, "com.microsoft.waveform-audio"),
            file("Documents/Scans/Floor plans.pdf", 188, opened: 12, modified: 12, "com.adobe.pdf"),
            file("Desktop/Screen recording.mov", 142, opened: 3, modified: 3, "com.apple.quicktime-movie"),
        ].sorted { $0.size > $1.size }
        large.loaded = true
        render(LargeFilesView().background(.regularMaterial), size: CGSize(width: 640, height: 600), to: "\(directory)/cleanup-largefiles.png")
    }
}
