import SwiftUI

enum CleanupMode: Hashable {
    case uninstall, junk
}

final class CleanupModel: ObservableObject {
    static let shared = CleanupModel()

    @Published var mode: CleanupMode = .uninstall
    @Published var selectedApp: InstalledApp?
    @Published var related: [RelatedItem] = []
    @Published var searching = false
    @Published var message = ""

    func select(_ app: InstalledApp?) {
        selectedApp = app
        related = []
        message = ""
        guard let app else { return }
        searching = true
        let others = Uninstaller.shared.apps.map(\.bundleID)
        inBackground {
            let found = Uninstaller.findRelated(for: app, otherBundleIDs: others)
            DispatchQueue.main.async {
                guard self.selectedApp?.path == app.path else { return }
                self.related = found
                self.searching = false
            }
        }
    }

    var selectedSize: UInt64 {
        (selectedApp?.size ?? 0) + related.filter(\.selected).reduce(0) { $0 + $1.size }
    }

    func uninstall() {
        guard let app = selectedApp else { return }
        let paths = related.filter(\.selected).map(\.path) + [app.path]
        let size = selectedSize
        searching = true
        inBackground {
            Uninstaller.quitIfRunning(app)
            if Uninstaller.isRunning(app) { Thread.sleep(forTimeInterval: 1.5) }
            let result = Uninstaller.moveToTrash(paths)
            DispatchQueue.main.async {
                self.searching = false
                let appGone = !FileManager.default.fileExists(atPath: app.path)
                if appGone {
                    self.message = "\(app.name) and \(result.trashed.count - 1) related items (\(Fmt.bytes(size))) were moved to the Trash."
                    self.selectedApp = nil
                    self.related = []
                } else {
                    self.message = "\(app.name) could not be moved to the Trash. Quit it and try again."
                }
                if !result.failed.isEmpty, appGone { self.message += " \(result.failed.count) protected items were left in place." }
                Uninstaller.shared.loadApps()
            }
        }
    }
}

/// The Cleanup window: an uninstaller that also removes an app's leftovers, and a junk cleaner.
struct CleanupView: View {
    @ObservedObject private var model = CleanupModel.shared
    @ObservedObject private var uninstaller = Uninstaller.shared
    @ViewState private var query = ""
    @ViewState private var selection: String?
    @ViewState private var confirming = false

    private var apps: [InstalledApp] {
        query.isEmpty ? uninstaller.apps : uninstaller.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("Junk Cleaner", systemImage: "sparkles").tag("junk")
                }
                Section("Applications") {
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            AppIcon(path: app.path, size: 24)
                            Text(app.name).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(app.size.map(Fmt.bytes) ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(app.path)
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search apps")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if selection == "junk" {
                JunkView()
            } else if let app = model.selectedApp {
                appDetail(app)
            } else {
                ContentUnavailableView {
                    Label(model.message.isEmpty ? "Choose an App" : "Done", systemImage: model.message.isEmpty ? "trash" : "checkmark.circle")
                } description: {
                    Text(model.message.isEmpty
                        ? "Pick an app on the left to see everything it has stored on your Mac. Nothing is removed until you confirm."
                        : model.message)
                }
            }
        }
        .navigationTitle("Cleanup")
        .frame(minWidth: 760, minHeight: 480)
        .onAppear {
            if uninstaller.apps.isEmpty { uninstaller.loadApps() }
            if model.mode == .junk { selection = "junk" }
        }
        .onChange(of: model.mode) { _, mode in
            if mode == .junk { selection = "junk" } else if selection == "junk" { selection = nil }
        }
        .onChange(of: selection) { _, new in
            if new == "junk" {
                model.mode = .junk
                model.select(nil)
            } else {
                model.mode = .uninstall
                model.select(uninstaller.apps.first { $0.path == new })
            }
        }
    }

    func appDetail(_ app: InstalledApp) -> some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppIcon(path: app.path, size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text("Version \(app.version) · \(app.bundleID)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if Uninstaller.isRunning(app) {
                            Label("Running now. It will be quit first.", systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Text(app.size.map(Fmt.bytes) ?? "—").font(.title3).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            if model.searching {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for related files…").foregroundStyle(.secondary)
                    }
                }
            } else if model.related.isEmpty {
                Section { Text("No leftover files found. Only the app itself will be removed.").foregroundStyle(.secondary) }
            } else {
                ForEach(categories, id: \.self) { category in
                    Section(category) {
                        ForEach($model.related) { $item in
                            if item.category == category {
                                Toggle(isOn: $item.selected) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                            Text(item.displayPath)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.head)
                                        }
                                        Spacer(minLength: 8)
                                        if item.needsAdmin {
                                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                                .help("macOS will ask for your password to remove this")
                                        }
                                        if item.isProtected {
                                            Label("Protected", systemImage: "lock.shield")
                                                .foregroundStyle(.secondary)
                                                .help("macOS keeps other apps out of this folder, so its size is hidden. Finder moves it to the Trash for you.")
                                        } else {
                                            Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(.checkbox)
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.bytes(model.selectedSize))\(model.related.contains { $0.selected && $0.isProtected } ? " or more" : "") selected")
                        .font(.headline).monospacedDigit()
                    Text(model.related.contains { $0.selected && ($0.isProtected || $0.needsAdmin) }
                        ? "Goes to the Trash. Protected items are moved by Finder, which may ask for permission."
                        : "Everything goes to the Trash, so you can put it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Move to Trash", role: .destructive) { confirming = true }
                    .prominentGlassButton()
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(model.searching)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.uninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app and \(model.related.filter(\.selected).count) related items will be moved to the Trash.")
        }
    }

    private var categories: [String] {
        var seen = Set<String>()
        return model.related.map(\.category).filter { seen.insert($0).inserted }
    }
}

struct JunkView: View {
    @ObservedObject private var cleaner = JunkCleaner.shared
    @ViewState private var trashSize: UInt64?
    @ViewState private var confirmingEmpty = false

    var body: some View {
        Form {
            if cleaner.scanning && cleaner.categories.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").foregroundStyle(.secondary)
                    }
                }
            }
            if !cleaner.lastResult.isEmpty {
                Section { Label(cleaner.lastResult, systemImage: "checkmark.circle.fill") }
            }
            ForEach($cleaner.categories) { $category in
                Section {
                    if category.items.isEmpty {
                        Text("Nothing to clean.").foregroundStyle(.secondary)
                    }
                    ForEach($category.items) { $item in
                        Toggle(isOn: $item.selected) {
                            HStack {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(Fmt.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                        }
                    }
                } header: {
                    HStack {
                        Label(category.title, systemImage: category.symbol)
                        Spacer()
                        Text(Fmt.bytes(category.totalSize)).monospacedDigit()
                    }
                } footer: {
                    Text(category.detail)
                }
            }
            Section("Trash") {
                LabeledContent("In the Trash now", value: trashSize.map(Fmt.bytes) ?? "Not visible without Full Disk Access")
                Button("Empty Trash…", role: .destructive) { confirmingEmpty = true }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.bytes(cleaner.selectedSize)) selected").font(.headline).monospacedDigit()
                    Text("Apps rebuild caches when they need them. Items go to the Trash first.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") { cleaner.scan() }.controlSize(.large).disabled(cleaner.scanning)
                Button("Clean") { cleaner.cleanSelected() }
                    .prominentGlassButton()
                    .controlSize(.large)
                    .disabled(cleaner.scanning || cleaner.selectedSize == 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmpty) {
            Button("Empty Trash", role: .destructive) {
                inBackground {
                    _ = JunkCleaner.emptyTrash()
                    let size = JunkCleaner.trashSize()
                    DispatchQueue.main.async { trashSize = size }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash are deleted permanently. This cannot be undone.")
        }
        .onAppear {
            if cleaner.categories.isEmpty { cleaner.scan() }
            inBackground {
                let size = JunkCleaner.trashSize()
                DispatchQueue.main.async { trashSize = size }
            }
        }
    }
}
