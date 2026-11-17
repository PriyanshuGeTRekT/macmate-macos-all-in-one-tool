import SwiftUI

/// Software Update, for the Settings form: the current status with its one relevant action,
/// and the automatic-check switch.
struct UpdateSection: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Keys.updateAutoCheck) private var autoCheck = true

    var body: some View {
        Section {
            UpdateStatusRow(updater: updater)
            if let release = updater.currentRelease, case .available = updater.state {
                UpdateAvailableDetail(release: release, updater: updater)
            }
        } header: {
            Text("Software Update")
        }

        Section {
            Toggle("Check for updates automatically", isOn: $autoCheck)
        } footer: {
            Text("MacMate asks GitHub once a day whether a newer release exists. Nothing about your Mac is sent.")
        }
    }
}

private struct UpdateStatusRow: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            UpdateAppIcon()
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if case .failed = updater.state {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .accessibilityHidden(true)
                    }
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .downloading(_, let received, let total) = updater.state {
                    UpdateProgress(received: received, total: total) { updater.cancelDownload() }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var trailing: some View {
        switch updater.state {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .idle, .upToDate:
            Button("Check Now") { updater.checkNow() }
        case .failed(_, let release):
            if let release {
                Button("Try Again") { updater.install() }
                    .disabled(release.assetURL == nil)
            } else {
                Button("Try Again") { updater.checkNow() }
            }
        case .available, .downloading:
            EmptyView()
        }
    }

    private var title: String {
        switch updater.state {
        case .idle: return "MacMate \(updater.displayVersion)"
        case .checking: return "Checking for updates…"
        case .upToDate: return "MacMate is up to date"
        case .available(let r): return "Version \(r.version) is available"
        case .downloading(let r, _, _): return "Downloading version \(r.version)…"
        case .installing(let r): return "Installing version \(r.version)…"
        case .failed(_, let r): return r == nil ? "Couldn't check for updates" : "Update not installed"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .failed(let message, _): return message
        case .installing: return "MacMate will reopen when it's done."
        case .downloading: return "MacMate will relaunch once the update is installed."
        case .available:
            var parts = ["You have version \(updater.displayVersion)"]
            if let last = updater.lastCheck { parts.append("checked \(UpdateSection.relative(last))") }
            return parts.joined(separator: " · ")
        case .idle:
            return updater.lastCheck.map { "Last checked \(UpdateSection.relative($0))" } ?? "Not checked yet"
        default:
            var parts = ["Version \(updater.displayVersion)"]
            if let last = updater.lastCheck { parts.append("Last checked \(UpdateSection.relative(last))") }
            return parts.joined(separator: " · ")
        }
    }
}

private struct UpdateAvailableDetail: View {
    let release: UpdateRelease
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let excerpt = release.excerpt
            if !excerpt.isEmpty {
                Text(excerpt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("What's New") { updater.openReleasePage(release) }
                    .glassButton()
                if updater.runningFromBundle && release.assetURL != nil {
                    Button(updater.canInstallInPlace ? "Install and Relaunch" : "Download…") { updater.install() }
                        .prominentGlassButton()
                } else {
                    Button("Download…") { updater.openReleasePage(release) }
                        .prominentGlassButton()
                }
            }
            if !updater.runningFromBundle {
                Text("This copy of MacMate isn't an app bundle, so it can't update itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !updater.canInstallInPlace {
                Text("MacMate can't write to its folder, so the update opens on GitHub instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct UpdateProgress: View {
    let received: Int64
    let total: Int64
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if total > 0 {
                    ProgressView(value: Double(min(received, total)), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Button {
                    cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop downloading")
                .accessibilityLabel("Stop downloading")
            }
            Text(total > 0 ? "\(Fmt.bytes(UInt64(max(0, received)))) of \(Fmt.bytes(UInt64(total)))" : Fmt.bytes(UInt64(max(0, received))))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct UpdateAppIcon: View {
    var body: some View {
        if Bundle.main.bundlePath.hasSuffix(".app") {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
        } else {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white, .tint)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.tint.opacity(0.15)))
        }
    }
}

extension UpdateSection {
    /// "today at 10:12", "yesterday at 18:40", or a date.
    static func relative(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today at \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday at \(time)" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
