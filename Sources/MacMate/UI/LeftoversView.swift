import SwiftUI

/// Data left behind by apps that are no longer installed, grouped by the app or vendor it probably came from.
struct LeftoversView: View {
    @ObservedObject private var scanner = LeftoverScanner.shared
    @ViewState private var confirming = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Files from deleted apps")
                        Text("Settings, caches and data named after apps that are no longer on this Mac. Anything that could belong to an installed or running app, or that changed in the last week, is left out.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }

            if scanner.scanning {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for leftovers…").foregroundStyle(.secondary)
                    }
                }
            }
            if !scanner.lastResult.isEmpty {
                Section { Label(scanner.lastResult, systemImage: "checkmark.circle.fill") }
            }
            if scanner.loaded && !scanner.scanning && scanner.groups.isEmpty {
                Section {
                    Label("No leftovers found", systemImage: "checkmark.seal")
                    Text("Nothing on this Mac looks like it belongs to a deleted app.").foregroundStyle(.secondary)
                }
            }

            ForEach($scanner.groups) { $group in
                Section {
                    ForEach($group.items) { $item in
                        Toggle(isOn: $item.selected) {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Text("\(item.category) · \(((item.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath)")
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
                                if let size = item.size {
                                    Text(Fmt.bytes(size)).monospacedDigit().foregroundStyle(.secondary)
                                } else {
                                    Label("Protected", systemImage: "lock.shield")
                                        .foregroundStyle(.secondary)
                                        .help("macOS keeps other apps out of this folder, so its size is hidden. Finder moves it to the Trash for you.")
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title)
                            Text(group.subtitle).font(.caption).foregroundStyle(.secondary).fontWeight(.regular)
                        }
                        Spacer()
                        Text(Fmt.bytes(group.totalSize)).monospacedDigit()
                        let all = group.items.allSatisfy(\.selected)
                        Button(all ? "Deselect All" : "Select All") { scanner.setAll(!all, in: group.id) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            let protectedSelected = scanner.selectedItems.contains(where: \.isProtected)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.bytes(scanner.selectedSize))\(protectedSelected ? " or more" : "") selected")
                        .font(.headline).monospacedDigit()
                    Text(scanner.loaded
                        ? "\(scanner.itemCount) items, \(Fmt.bytes(scanner.totalSize)). Everything goes to the Trash, so you can put it back."
                        : "Everything goes to the Trash, so you can put it back.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Rescan") { scanner.scan() }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(scanner.scanning)
                Button("Move to Trash…", role: .destructive) { confirming = true }
                    .prominentGlassButton()
                    .tint(.red)
                    .controlSize(.large)
                    .disabled(scanner.scanning || scanner.selectedItems.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog("Move \(scanner.selectedItems.count) items to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { scanner.trashSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(scanner.selectedItems.contains { $0.needsAdmin || $0.isProtected }
                ? "Protected items are moved by Finder, which may ask for permission. You can put everything back from the Trash."
                : "You can put them back from the Trash.")
        }
        .onAppear { if !scanner.loaded { scanner.scan() } }
    }
}
