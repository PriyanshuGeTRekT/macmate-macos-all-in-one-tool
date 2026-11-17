import SwiftUI

extension StartupItem.Scope {
    var title: String {
        switch self {
        case .user: return "Your account"
        case .allUsers: return "All users"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .user: return "person"
        case .allUsers: return "person.2"
        case .system: return "gearshape.2"
        }
    }

    var footer: String {
        switch self {
        case .user: return "Launch agents that run while you're logged in."
        case .allUsers: return "Launch agents installed for every account. macOS asks for an administrator password to change them."
        case .system: return "Launch daemons run in the background, even before anyone logs in. macOS asks for an administrator password to change them."
        }
    }
}

/// Everything that starts automatically: launch agents and daemons, with a switch for each.
struct StartupItemsView: View {
    @ObservedObject private var manager = StartupItemManager.shared
    @ViewState private var trashing: StartupItem?
    @ViewState private var confirmingCleanup = false

    private var goneItems: [StartupItem] { manager.items.filter(\.appGone) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.clock")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at Login")
                        Text("Apps that open when you log in are managed in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Open Login Items Settings") { StartupItemManager.openLoginItemsSettings() }
                }
                .padding(.vertical, 2)
            }

            if manager.scanning && !manager.loaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for startup items…").foregroundStyle(.secondary)
                    }
                }
            }
            if !manager.message.isEmpty {
                Section { Label(manager.message, systemImage: "info.circle") }
            }

            if manager.loaded {
                ForEach(StartupItem.Scope.allCases, id: \.self) { scope in
                    let list = manager.items.filter { $0.scope == scope }
                    Section {
                        if list.isEmpty {
                            Text("None").foregroundStyle(.secondary)
                        }
                        ForEach(list) { item in row(item) }
                    } header: {
                        Label(scope.title, systemImage: scope.symbol)
                    } footer: {
                        Text(scope.footer)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(manager.items.count) \(manager.items.count == 1 ? "item starts" : "items start") automatically")
                        .font(.headline).monospacedDigit()
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") { manager.scan() }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(manager.scanning)
                Button("Remove Items of Deleted Apps…", role: .destructive) { confirmingCleanup = true }
                    .prominentGlassButton()
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(goneItems.isEmpty || !manager.busy.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog(trashing.map { "Move “\($0.label)” to the Trash?" } ?? "", isPresented: Binding(
            get: { trashing != nil }, set: { if !$0 { trashing = nil } }
        ), presenting: trashing) { item in
            Button("Move to Trash", role: .destructive) { manager.moveToTrash(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("The program it starts is gone. The item is stopped and its file goes to the Trash."
                + (item.scope.needsAdmin ? " macOS will ask for an administrator password." : ""))
        }
        .confirmationDialog("Remove \(goneItems.count) items of deleted apps?", isPresented: $confirmingCleanup) {
            Button("Move to Trash", role: .destructive) { manager.removeAll(goneItems) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each one starts a program that no longer exists. They are stopped and their files go to the Trash."
                + (goneItems.contains { $0.scope.needsAdmin } ? " macOS will ask for an administrator password." : ""))
        }
        .onAppear { if !manager.loaded { manager.scan() } }
    }

    private var summary: String {
        let running = manager.items.filter(\.running).count
        let off = manager.items.filter(\.disabled).count
        var parts = ["\(running) running", "\(off) turned off"]
        if !goneItems.isEmpty { parts.append("\(goneItems.count) from deleted apps") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ item: StartupItem) -> some View {
        HStack(spacing: 10) {
            AppIcon(path: item.appPath, size: 28)
                .opacity(item.disabled ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(item.appName == nil ? (item.program.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? item.label) : item.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                status(item)
            }
            Spacer(minLength: 8)
            if manager.busy.contains(item.id) {
                ProgressView().controlSize(.small)
            }
            if item.scope.needsAdmin {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                    .help("macOS will ask for an administrator password to change this")
            }
            Toggle(item.title, isOn: Binding(get: { !item.disabled }, set: { manager.setEnabled(item, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(manager.busy.contains(item.id))
                .help(item.disabled ? "Turn on" : "Turn off")
            Menu {
                menuItems(item)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
        .padding(.vertical, 1)
        .contextMenu { menuItems(item) }
    }

    @ViewBuilder
    private func status(_ item: StartupItem) -> some View {
        HStack(spacing: 6) {
            if item.appGone {
                Label("App is gone", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if item.disabled {
                Text("Turned off").foregroundStyle(.secondary)
            } else {
                if item.running {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Running")
                    }
                    .foregroundStyle(.secondary)
                }
                let traits = [item.running && (item.runAtLoad || item.keepAlive) ? "" : nil,
                              item.runAtLoad ? "Starts at login" : nil, item.keepAlive ? "Restarts if it quits" : nil].compactMap { $0 }
                if !traits.isEmpty {
                    Text(traits.joined(separator: " · ").trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    @ViewBuilder
    private func menuItems(_ item: StartupItem) -> some View {
        Button(item.disabled ? "Turn On" : "Turn Off") { manager.setEnabled(item, item.disabled) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        if let app = item.appPath {
            Button("Show \(item.appName ?? "App") in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
        }
        if item.appGone {
            Divider()
            Button("Move to Trash…", role: .destructive) { trashing = item }
        }
    }
}
