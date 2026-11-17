import AppKit
import CoreGraphics
import ScreenCaptureKit
import SwiftUI

extension Keys {
    static let previewsSwitcher = "previews.switcher"
    static let previewsDock = "previews.dock"
}

/// Pictures of other apps' windows, taken with ScreenCaptureKit only while a switcher or Dock
/// preview is about to appear. Images are kept for a few seconds so quick repeat opens are instant.
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    /// Latest picture of each window. Views look their window up here and fall back to the app icon.
    @Published private(set) var images: [CGWindowID: NSImage] = [:]
    /// Whether this process may capture the screen. Refreshed on demand; checking never prompts.
    @Published private(set) var screenRecordingGranted = CGPreflightScreenCaptureAccess()

    /// A picture younger than this is reused instead of captured again.
    static let freshness: TimeInterval = 3
    /// Pictures older than this are dropped entirely.
    static let lifetime: TimeInterval = 30

    private var capturedAt: [CGWindowID: TimeInterval] = [:]
    private var inFlight: Set<CGWindowID> = []
    private var purgeWork: DispatchWorkItem?

    // MARK: Permission

    static var permitted: Bool { CGPreflightScreenCaptureAccess() }

    func refreshPermission() {
        let granted = ThumbnailStore.permitted
        if granted != screenRecordingGranted { screenRecordingGranted = granted }
    }

    /// The only place that may show the system's Screen Recording prompt. Called from the settings button.
    func requestAccess() {
        let granted = CGRequestScreenCaptureAccess()
        if granted != screenRecordingGranted { screenRecordingGranted = granted }
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Capture

    /// One window to picture: its id, its size on screen and the box it will be drawn in (points).
    struct Request {
        let windowID: CGWindowID
        let windowSize: CGSize
        let displaySize: CGSize
    }

    /// Captures every requested window concurrently. Each image is published as soon as it arrives.
    /// Main thread only. Does nothing without Screen Recording access.
    func capture(_ requests: [Request]) {
        refreshPermission()
        guard screenRecordingGranted, !requests.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        prune(now: now)
        let wanted = requests.filter { r in
            !inFlight.contains(r.windowID) && now - (capturedAt[r.windowID] ?? -.infinity) > ThumbnailStore.freshness
        }
        guard !wanted.isEmpty else { return }
        wanted.forEach { inFlight.insert($0.windowID) }
        let ids = Set(wanted.map(\.windowID))

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self else { return }
            let windows = content?.windows.filter { ids.contains($0.windowID) } ?? []
            let byID = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
            for r in wanted {
                guard let window = byID[r.windowID] else {
                    onMain { self.inFlight.remove(r.windowID) }
                    continue
                }
                let config = SCStreamConfiguration()
                let pixels = ThumbnailStore.captureSize(window: r.windowSize, box: r.displaySize, scale: 2)
                config.width = Int(pixels.width)
                config.height = Int(pixels.height)
                config.scalesToFit = true
                config.preservesAspectRatio = true
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, _ in
                    onMain {
                        self.inFlight.remove(r.windowID)
                        guard let image else { return }
                        self.images[r.windowID] = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
                        self.capturedAt[r.windowID] = ProcessInfo.processInfo.systemUptime
                    }
                }
            }
        }
        schedulePurge()
    }

    /// Pixel size for a capture: the window's aspect ratio fitted into the display box, times `scale`.
    static func captureSize(window: CGSize, box: CGSize, scale: CGFloat) -> CGSize {
        guard window.width > 0, window.height > 0, box.width > 0, box.height > 0 else {
            return CGSize(width: max(1, box.width * scale), height: max(1, box.height * scale))
        }
        let fit = min(box.width / window.width, box.height / window.height)
        return CGSize(width: max(1, (window.width * fit * scale).rounded()), height: max(1, (window.height * fit * scale).rounded()))
    }

    /// Used by tests and renders to stand in for real captures.
    func setImage(_ image: NSImage?, for id: CGWindowID) {
        images[id] = image
        capturedAt[id] = image == nil ? nil : ProcessInfo.processInfo.systemUptime
    }

    private func prune(now: TimeInterval) {
        for (id, t) in capturedAt where now - t > ThumbnailStore.lifetime {
            capturedAt[id] = nil
            images[id] = nil
        }
    }

    /// Drops every picture once nothing has asked for one in a while, so idle memory stays low.
    private func schedulePurge() {
        purgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.images = [:]
            self.capturedAt = [:]
        }
        purgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ThumbnailStore.lifetime, execute: work)
    }
}

/// An NSHostingView that reacts to the first click, even though its panel never becomes key.
final class PreviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A floating panel that never takes focus from the app the user is in.
final class PreviewPanel: NSPanel {
    convenience init() {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .popUpMenu
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A window's picture, or its app icon until the picture arrives.
struct PreviewThumbnailView: View {
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    let window: SwitcherWindow
    let size: CGSize

    var body: some View {
        ZStack {
            if let id = window.windowID, let image = thumbnails.images[id] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
                    .overlay {
                        VStack(spacing: 6) {
                            if let icon = window.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: min(64, size.height * 0.5), height: min(64, size.height * 0.5))
                                    .opacity(window.minimized ? 0.6 : 1)
                            }
                            if window.minimized {
                                Text("Minimized")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.15), value: window.windowID.flatMap { thumbnails.images[$0] } != nil)
    }
}
