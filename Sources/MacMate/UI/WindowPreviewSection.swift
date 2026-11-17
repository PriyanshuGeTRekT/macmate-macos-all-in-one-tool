import SwiftUI

/// Window preview settings for the Windows tab: thumbnails in ⌥Tab and on Dock hover.
struct WindowPreviewSection: View {
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @AppStorage(Keys.previewsSwitcher) private var inSwitcher = false
    @AppStorage(Keys.previewsDock) private var inDock = false
    @AppStorage(Keys.switcherEnabled) private var switcher = false
    @ViewState private var asked = false

    var body: some View {
        Section {
            Toggle("Show window previews in ⌥Tab", isOn: $inSwitcher)
                .disabled(!switcher)
            Toggle("Show window previews when hovering the Dock", isOn: $inDock)
                .onChange(of: inDock) { _, _ in DockPreviews.shared.update() }
        } header: {
            Text("Window Previews")
        } footer: {
            Text(switcher ? "Rest the pointer on an app in the Dock to see its windows. Click one to bring it forward."
                          : "Turn on ⌥Tab switching above to use previews there. Rest the pointer on an app in the Dock to see its windows.")
        }
        Section {
            LabeledContent {
                if thumbnails.screenRecordingGranted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                } else {
                    Text("Not allowed").foregroundStyle(.secondary)
                }
            } label: {
                Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
            }
            if !thumbnails.screenRecordingGranted {
                HStack {
                    Button("Grant access…") {
                        asked = true
                        thumbnails.requestAccess()
                    }
                    Button("Open Privacy & Security Settings") { ThumbnailStore.openPrivacySettings() }
                }
                if asked {
                    Text("After allowing MacMate in Privacy & Security, quit and reopen it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Thumbnails are pictures of other apps’ windows, so macOS requires Screen Recording access. MacMate captures only while a preview is showing and never saves the images. Without access, previews list window titles instead.")
        }
        .onAppear { thumbnails.refreshPermission() }
    }
}
