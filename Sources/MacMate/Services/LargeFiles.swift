import AppKit
import CoreServices
import Foundation
import Quartz
import UniformTypeIdentifiers

extension Keys {
    /// Smallest file size shown by Large & Old Files, in bytes.
    static let largeFilesMinSize = "cleanup.largeFiles.minSize"
    /// Show only files not opened for more than a year.
    static let largeFilesOnlyOld = "cleanup.largeFiles.onlyOld"
}

/// One of the user's own files, as Spotlight knows it.
struct LargeFileItem: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let size: UInt64
    let lastOpened: Date?
    let modified: Date?
    let contentType: String?
    var selected = false

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    /// When the file was last opened, or failing that last changed.
    var lastUsed: Date? { lastOpened ?? modified }

    func isOld(now: Date = Date()) -> Bool {
        guard let d = lastUsed else { return false }
        return d < now.addingTimeInterval(-LargeFileFinder.oldAge)
    }
}

/// Finds big files in the home folder through the Spotlight index, so nothing is read from disk while scanning.
final class LargeFileFinder: ObservableObject {
    static let shared = LargeFileFinder()

    /// Size choices in the picker.
    static let sizeChoices: [(label: String, bytes: Int)] = [
        ("50 MB", 50_000_000), ("100 MB", 100_000_000), ("500 MB", 500_000_000), ("1 GB", 1_000_000_000),
    ]
    static let defaultMinSize = 100_000_000
    /// The scan always covers the smallest choice; the picker filters what is shown.
    static let scanFloor: UInt64 = 50_000_000
    static let oldAge: TimeInterval = 365 * 24 * 3600
    static let displayLimit = 500

    @Published var items: [LargeFileItem] = []
    @Published private(set) var scanning = false
    @Published var loaded = false
    @Published private(set) var lastResult = ""
    @Published private(set) var spotlightFailed = false

    func scan() {
        guard !scanning else { return }
        scanning = true
        lastResult = ""
        inBackground {
            let found = LargeFileFinder.query(minSize: LargeFileFinder.scanFloor)
            DispatchQueue.main.async {
                self.spotlightFailed = found == nil
                // Keep ticks on files that are still there.
                let ticked = Set(self.items.filter(\.selected).map(\.path))
                self.items = (found ?? []).map { var f = $0; f.selected = ticked.contains(f.path); return f }
                self.scanning = false
                self.loaded = true
            }
        }
    }

    /// The files shown for the current filter, largest first.
    func visible(minSize: Int, onlyOld: Bool) -> [LargeFileItem] {
        let now = Date()
        return Array(items.filter { $0.size >= UInt64(max(0, minSize)) && (!onlyOld || $0.isOld(now: now)) }.prefix(Self.displayLimit))
    }

    func setSelected(_ path: String, _ on: Bool) {
        if let i = items.firstIndex(where: { $0.path == path }) { items[i].selected = on }
    }

    func trash(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let size = items.filter { paths.contains($0.path) }.reduce(0) { $0 + $1.size }
        scanning = true
        inBackground {
            let result = LargeFileFinder.moveToTrash(paths)
            DispatchQueue.main.async {
                let gone = Set(result.trashed)
                self.items.removeAll { gone.contains($0.path) }
                self.scanning = false
                self.lastResult = "Moved \(result.trashed.count) \(result.trashed.count == 1 ? "file" : "files") (\(Fmt.bytes(size))) to the Trash."
                    + (result.failed.isEmpty ? "" : " \(result.failed.count) could not be moved.")
            }
        }
    }

    // MARK: Spotlight

    /// Regular files of at least `minSize` bytes in the home folder, largest first. Nil when Spotlight can't answer.
    static func query(minSize: UInt64, home: String = NSHomeDirectory()) -> [LargeFileItem]? {
        let text = "kMDItemFSSize >= \(minSize)"
        let attrs = [kMDItemPath, kMDItemFSSize, kMDItemLastUsedDate, kMDItemContentModificationDate, kMDItemContentType,
                     kMDItemContentTypeTree] as CFArray
        guard let q = MDQueryCreate(kCFAllocatorDefault, text as CFString, attrs, nil) else { return nil }
        MDQuerySetSearchScope(q, [home] as CFArray, 0)
        guard MDQueryExecute(q, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        MDQueryDisableUpdates(q)
        var out: [LargeFileItem] = []
        for i in 0..<MDQueryGetResultCount(q) {
            guard let raw = MDQueryGetResultAtIndex(q, i) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  let size = (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.uint64Value, size >= minSize
            else { continue }
            let tree = MDItemCopyAttribute(item, kMDItemContentTypeTree) as? [String] ?? []
            guard !isExcluded(path, home: home), !tree.contains(where: isFolderType) else { continue }
            out.append(LargeFileItem(path: path, size: size,
                                     lastOpened: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
                                     modified: MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date,
                                     contentType: MDItemCopyAttribute(item, kMDItemContentType) as? String))
        }
        return out.sorted { ($0.size, $1.path) > ($1.size, $0.path) }
    }

    static func isFolderType(_ type: String) -> Bool {
        ["public.folder", "public.directory", "com.apple.package", "com.apple.bundle", "public.volume"].contains(type)
    }

    // MARK: Safety

    /// Extensions of folders macOS treats as a single document (their insides are never offered).
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "pkg", "mpkg", "photoslibrary", "photolibrary",
        "musiclibrary", "tvlibrary", "imovielibrary", "theater", "fcpbundle", "logicx", "band", "xcarchive", "xcodeproj",
        "xcworkspace", "sparsebundle", "rtfd", "pages", "numbers", "key", "playground", "dSYM", "lrlibrary", "lrdata",
        "aplibrary", "migratedphotolibrary", "photoboothlibrary", "vmwarevm", "pvm", "utm", "bundle", "docarchive",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    static func isPackageExtension(_ ext: String) -> Bool {
        let e = ext.lowercased()
        guard !e.isEmpty else { return false }
        if packageExtensions.contains(e) { return true }
        // Declared (not made-up) types that are packages.
        return UTType.types(tag: e, tagClass: .filenameExtension, conformingTo: nil)
            .contains { !$0.isDynamic && ($0.conforms(to: .package) || $0.conforms(to: .bundle)) }
    }

    /// Path-only test: inside the home folder, outside ~/Library, not hidden, not a package or inside one.
    /// Touches nothing on disk, so it is safe to run on Spotlight results in privacy-protected folders.
    static func isExcluded(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        guard p.hasPrefix(home + "/") else { return true }
        let rel = p.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard !rel.isEmpty, rel.first != "Library" else { return true }
        for comp in rel {
            if comp.hasPrefix(".") || isPackageExtension((comp as NSString).pathExtension) { return true }
        }
        return false
    }

    /// The check every Move to Trash goes through. Uninstaller.isSafeToRemove refuses the user's own files on
    /// purpose, so these have their own rules: a regular file (not a link or folder) inside the home folder,
    /// outside ~/Library, not hidden, and not inside an app, library or other package.
    static func isSafeToTrash(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let p = (path as NSString).standardizingPath
        guard !isExcluded(p, home: home) else { return false }
        // A symlinked folder on the way must not lead out of the home folder or into ~/Library.
        let resolved = (p as NSString).resolvingSymlinksInPath
        let realHome = (home as NSString).resolvingSymlinksInPath
        guard resolved == p || !isExcluded(resolved, home: realHome) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              attrs[.type] as? FileAttributeType == .typeRegular else { return false }
        // Folders that Finder shows as one item even without a known extension.
        var dir = (p as NSString).deletingLastPathComponent
        while dir.count > home.count, dir.hasPrefix(home + "/") {
            if (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return false }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return true
    }

    static func moveToTrash(_ paths: [String]) -> RemovalResult {
        var result = RemovalResult()
        for path in paths {
            guard isSafeToTrash(path) else { result.failed.append(path); continue }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                result.trashed.append(path)
            } catch {
                result.failed.append(path)
            }
        }
        return result
    }

    // MARK: Quick Look

    static func quickLook(_ paths: [String]) {
        LargeFilePreview.shared.show(paths.map { URL(fileURLWithPath: $0) })
    }
}

/// Drives the system Quick Look panel. It joins the key window's responder chain, which is how the panel
/// finds who controls it.
final class LargeFilePreview: NSResponder, QLPreviewPanelDataSource {
    static let shared = LargeFilePreview()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.title == "Cleanup" }),
              let panel = QLPreviewPanel.shared()
        else {
            // No window to attach to: let the system's previewer open them.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p.arguments = ["-p"] + urls.map(\.path)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            return
        }
        if window.nextResponder !== self {
            nextResponder = window.nextResponder
            window.nextResponder = self
        }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.currentPreviewItemIndex = 0
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.reloadData()
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
