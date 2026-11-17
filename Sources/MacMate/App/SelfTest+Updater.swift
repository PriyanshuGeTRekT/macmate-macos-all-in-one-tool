import AppKit
import Foundation

extension SelfTest {
    static func runUpdaterChecks() {
        print("== Updater: versions")
        func v(_ s: String) -> UpdateVersion? { UpdateVersion(s) }
        func same(_ a: String, _ b: String) -> Bool { v(a) != nil && v(a) == v(b) }
        func older(_ a: String, _ b: String) -> Bool { guard let x = v(a), let y = v(b) else { return false }; return x < y && !(y < x) }
        check("leading v ignored", same("v1.2.3", "1.2.3"))
        check("missing components are zero", same("1.0", "1.0.0") && same("1", "1.0.0") && same("V2", "2.0"))
        check("build metadata ignored", same("1.0.0+42", "1.0.0"))
        check("numeric, not text, order", older("1.9", "1.10") && older("v1.2.9", "1.3"))
        check("patch release is newer", older("1.0", "1.0.1"))
        check("pre-release before its release", older("1.1.0-beta.1", "1.1.0") && older("2.0b1", "2.0") && older("1.0.0-rc.1", "v1.0.0"))
        check("pre-release after the previous release", older("1.0", "1.1.0-beta"))
        check("pre-release identifiers ordered", older("1.0.0-alpha", "1.0.0-alpha.1") && older("1.0.0-alpha.1", "1.0.0-beta")
              && older("1.0.0-beta.2", "1.0.0-beta.11") && older("1.0.0-1", "1.0.0-alpha"))
        check("garbage rejected", v("") == nil && v("latest") == nil && v("1..2") == nil && v("1.x") == nil && v("v") == nil)
        check("short display form", v("v1.0.0")?.description == "1.0" && v("1.2.3")?.description == "1.2.3" && v("2.0.0-beta.1")?.description == "2.0-beta.1")
        if !Bundle.main.bundlePath.hasSuffix(".app") {
            let u = Updater.shared
            check("bare binary counts as 0.0.0", u.bundleVersionString == nil && u.currentVersion == .zero && u.displayVersion == "0.0")
            check("bare binary never installs", !u.runningFromBundle && !u.canInstallInPlace)
        }

        print("== Updater: release parsing")
        func json(_ assets: [String], body: String = "") -> Data {
            let object: [String: Any] = [
                "tag_name": "v1.4.0", "name": "MacMate 1.4", "body": body, "draft": false,
                "html_url": "https://github.com/x/y/releases/tag/v1.4.0",
                "assets": assets.map { ["name": $0, "size": 10, "browser_download_url": "https://example.invalid/\($0)"] as [String: Any] },
            ]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        let r1 = try? UpdateRelease.parse(json(["MacMate-1.4.0.zip", "MacMate.zip", "notes.txt"]))
        check("release parsed", r1?.version == v("1.4") && r1?.name == "MacMate 1.4" && r1?.pageURL.absoluteString.hasSuffix("/v1.4.0") == true)
        check("MacMate.zip preferred", r1?.assetName == "MacMate.zip" && r1?.assetURL?.lastPathComponent == "MacMate.zip")
        check("falls back to MacMate-*.zip", (try? UpdateRelease.parse(json(["Source.zip", "MacMate-1.4.0.zip"])))?.assetName == "MacMate-1.4.0.zip")
        check("no asset is not an error", (try? UpdateRelease.parse(json(["MacMateX.zip", "MacMate-1.4.0.dmg"])))?.assetURL == nil)
        check("malformed JSON throws", (try? UpdateRelease.parse(Data("{\"message\":\"Not Found\"}".utf8))) == nil)
        let notes = "## What's new\n\nFirst release of **MacMate**, with [window tiling](https://x.y) and `code`.\nSecond line.\n\n- bullet"
        check("notes excerpt is plain text", UpdateRelease.excerpt(from: notes) == "First release of MacMate, with window tiling and code. Second line.",
              UpdateRelease.excerpt(from: notes))
        let long = UpdateRelease.excerpt(from: String(repeating: "word ", count: 100))
        check("long notes shortened", long.count <= 181 && long.hasSuffix("…"))
        check("errors read well", Updater.describe(URLError(.notConnectedToInternet)).hasPrefix("You're offline")
              && Updater.describe(UpdateError.http(403)).contains("limiting"))

        print("== Updater: installer (offline)")
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macmate-updater-test-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        /// A small signed bundle with the given identity, built from this very binary.
        func makeApp(at url: URL, id: String, version: String) -> Bool {
            try? fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "MacMate",
                                      "CFBundlePackageType": "APPL", "CFBundleName": "MacMate"]
            guard info.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true),
                  (try? fm.copyItem(atPath: CommandLine.arguments[0], toPath: url.appendingPathComponent("Contents/MacOS/MacMate").path)) != nil
            else { return false }
            return shell("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", id, url.path]).status == 0
        }
        let built = work.appendingPathComponent("build/MacMate.app")
        if makeApp(at: built, id: UpdateInstaller.bundleIdentifier, version: "1.4.0") {
            let zip = work.appendingPathComponent("MacMate-1.4.0.zip")
            shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", built.path, zip.path])
            let unpacked = try? UpdateInstaller.unpack(zip, into: work.appendingPathComponent("unpacked one"))
            check("archive unpacked", unpacked?.lastPathComponent == "MacMate.app")
            if let app = unpacked {
                check("valid bundle accepted", (try? UpdateInstaller.validate(app, expectedVersion: v("v1.4")!)) != nil)
                check("version mismatch rejected", throwsError(.wrongVersion("1.4.0")) { try UpdateInstaller.validate(app, expectedVersion: v("1.5")!) })
                // A changed resource breaks the seal.
                try? "tampered".write(to: app.appendingPathComponent("Contents/Info.plist.extra"), atomically: true, encoding: .utf8)
                try? "x".write(to: app.appendingPathComponent("Contents/MacOS/extra"), atomically: true, encoding: .utf8)
                check("broken signature rejected", throwsError(.badSignature) { try UpdateInstaller.validate(app, expectedVersion: v("1.4")!) })
            }
            let other = work.appendingPathComponent("other/MacMate.app")
            if makeApp(at: other, id: "com.example.other", version: "1.4.0") {
                check("other app rejected", throwsError(.wrongIdentifier("com.example.other")) { try UpdateInstaller.validate(other, expectedVersion: v("1.4")!) })
            }
            check("garbage archive rejected", {
                let bad = work.appendingPathComponent("bad.zip")
                try? "not a zip".write(to: bad, atomically: true, encoding: .utf8)
                return (try? UpdateInstaller.unpack(bad, into: work.appendingPathComponent("bad"))) == nil
            }())

            // Replace an "installed" copy in a folder with spaces, retiring the old one to another temp folder.
            let installed = work.appendingPathComponent("Apps 'quoted' folder/MacMate.app")
            let retiredDir = work.appendingPathComponent("retired", isDirectory: true)
            try? fm.createDirectory(at: retiredDir, withIntermediateDirectories: true)
            func retire(_ url: URL) throws -> URL? {
                let to = retiredDir.appendingPathComponent(UUID().uuidString + ".app")
                try fm.moveItem(at: url, to: to)
                return to
            }
            if makeApp(at: installed, id: UpdateInstaller.bundleIdentifier, version: "1.0"),
               let fresh = try? UpdateInstaller.unpack(zip, into: work.appendingPathComponent("unpacked two")) {
                let replaced = (try? UpdateInstaller.replace(installed, with: fresh, retire: retire)) != nil
                let nowVersion = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
                check("bundle replaced in place", replaced && nowVersion == "1.4.0" && !fm.fileExists(atPath: fresh.path))
                check("old bundle retired", (try? fm.contentsOfDirectory(atPath: retiredDir.path))?.count == 1)
                check("replaced bundle still verifies", (try? UpdateInstaller.validate(installed, expectedVersion: v("1.4")!)) != nil)
                // A failed move puts the old bundle back.
                let missing = work.appendingPathComponent("nothing/MacMate.app")
                let rolledBack = (try? UpdateInstaller.replace(installed, with: missing, retire: retire)) == nil && fm.fileExists(atPath: installed.path)
                check("nothing lost when the new bundle is missing", rolledBack)
            }

            let locked = work.appendingPathComponent("locked")
            try? fm.createDirectory(at: locked.appendingPathComponent("MacMate.app"), withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            check("read-only folder detected", !UpdateInstaller.canReplace(locked.appendingPathComponent("MacMate.app")))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        } else {
            check("test bundle built and signed", false)
        }

        // The relaunch helper, with an exited process and `touch` standing in for `open`.
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        if (try? gone.run()) != nil {
            gone.waitUntilExit()
            let marker = work.appendingPathComponent("it's \"relaunched\" $(nope) `x`.txt")
            let spawned = UpdateInstaller.relaunch(marker, pid: gone.processIdentifier, opener: "/usr/bin/touch")
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: marker.path), Date() < until { Thread.sleep(forTimeInterval: 0.1) }
            check("relaunch helper opens the exact path", spawned && fm.fileExists(atPath: marker.path))
        }
        let busy = Process()
        busy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        busy.arguments = ["1.5"]
        if (try? busy.run()) != nil {
            let marker = work.appendingPathComponent("waited.txt")
            UpdateInstaller.relaunch(marker, pid: busy.processIdentifier, opener: "/usr/bin/touch")
            Thread.sleep(forTimeInterval: 0.6)
            let early = fm.fileExists(atPath: marker.path)
            busy.waitUntilExit()
            let until = Date().addingTimeInterval(5)
            while !fm.fileExists(atPath: marker.path), Date() < until { Thread.sleep(forTimeInterval: 0.1) }
            check("relaunch helper waits for the process to quit", !early && fm.fileExists(atPath: marker.path))
        }

        print("== Updater: GitHub (network)")
        guard !ci else { print("  skipped on CI"); return }
        var fetched: Result<UpdateRelease, Error>?
        let done = DispatchSemaphore(value: 0)
        Updater.shared.fetchLatest { fetched = $0; done.signal() }
        _ = done.wait(timeout: .now() + 40)
        guard case .success(let release)? = fetched else {
            check("latest release fetched", false, fetched.map { if case .failure(let e) = $0 { return Updater.describe(e) }; return "" } ?? "timed out")
            return
        }
        check("latest release fetched", true, "\(release.tag) — \(release.name), asset \(release.assetName ?? "none") \(Fmt.bytes(UInt64(max(0, release.assetSize))))")
        check("release version newer than a bare binary", release.version > .zero)
        check("release notes excerpt", !release.excerpt.isEmpty, release.excerpt)
        guard let assetURL = release.assetURL else { check("release has a MacMate zip", false); return }

        let zip = work.appendingPathComponent(release.assetName ?? "MacMate.zip")
        var steps = 0, failure: Error?
        let downloaded = DispatchSemaphore(value: 0)
        Updater.shared.download(assetURL, to: zip, progress: { _, _ in steps += 1 }, completion: { failure = $0; downloaded.signal() })
        let finished = downloaded.wait(timeout: .now() + 120) == .success
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
        check("asset downloaded", finished && failure == nil && size > 100_000,
              "\(Fmt.bytes(UInt64(size))), \(steps) progress updates\(failure.map { ", " + Updater.describe($0) } ?? "")")
        guard finished, failure == nil else { return }
        do {
            let app = try UpdateInstaller.unpack(zip, into: work.appendingPathComponent("release one"))
            try UpdateInstaller.validate(app, expectedVersion: release.version)
            check("release bundle valid", true, app.lastPathComponent)
            let copy = try UpdateInstaller.unpack(zip, into: work.appendingPathComponent("release two"))
            let target = work.appendingPathComponent("Installed Apps/MacMate.app")
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: copy, to: target)
            let retiredDir = work.appendingPathComponent("release retired", isDirectory: true)
            try fm.createDirectory(at: retiredDir, withIntermediateDirectories: true)
            try UpdateInstaller.replace(target, with: app) { old in
                let to = retiredDir.appendingPathComponent("MacMate.app")
                try fm.moveItem(at: old, to: to)
                return to
            }
            try UpdateInstaller.validate(target, expectedVersion: release.version)
            check("release bundle swapped into a temp install", fm.fileExists(atPath: retiredDir.appendingPathComponent("MacMate.app").path))
        } catch {
            check("release bundle unpacked, validated and swapped", false, Updater.describe(error))
        }
    }

    private static func throwsError(_ expected: UpdateError, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return (error as? UpdateError) == expected }
    }
}
