import SwiftUI
import UniformTypeIdentifiers

/// Big files in the home folder, optionally only those nobody has opened for a year.
struct LargeFilesView: View {
    @ObservedObject private var finder = LargeFileFinder.shared
    @AppStorage(Keys.largeFilesMinSize) private var minSize = LargeFileFinder.defaultMinSize
    @AppStorage(Keys.largeFilesOnlyOld) private var onlyOld = false
    @ViewState private var pending: [String] = []
    @ViewState private var confirming = false

    var body: some View {
        let files = finder.visible(minSize: minSize, onlyOld: onlyOld)
        let chosen = files.filter(\.selected)
        Form {
            Section {
                Picker("Larger than", selection: $minSize) {
                    ForEach(LargeFileFinder.sizeChoices, id: \.bytes) { choice in
                        Text(choice.label).tag(choice.bytes)
                    }
                }
                Toggle("Only files not opened in the last year", isOn: $onlyOld)
            } footer: {
                Text("Searches your home folder with Spotlight. Library, apps and the insides of libraries such as Photos are never included.")
            }

            if finder.scanning && !finder.loaded {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
            }
            if finder.spotlightFailed {
                Section {
                    Label("Spotlight couldn't search your home folder. Check that Spotlight indexing is turned on in System Settings.",
                          systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
            if !finder.lastResult.isEmpty {
                Section { Label(finder.lastResult, systemImage: "checkmark.circle.fill") }
            }

            if finder.loaded {
                Section {
                    if files.isEmpty {
                        Text(onlyOld ? "No large files that haven't been opened for a year." : "No files this large.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(files) { file in row(file) }
                } header: {
                    HStack {
                        Text("\(files.count) \(files.count == 1 ? "file" : "files")")
                        Spacer()
                        Text(Fmt.bytes(files.reduce(0) { $0 + $1.size })).monospacedDigit()
                    }
                } footer: {
                    if files.count >= LargeFileFinder.displayLimit {
                        Text("Showing the \(LargeFileFinder.displayLimit) largest files.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Fmt.bytes(chosen.reduce(0) { $0 + $1.size })) selected").font(.headline).monospacedDigit()
                    Text("These are your own files. Nothing is selected for you.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    finder.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .glassButton()
                .controlSize(.large)
                .help("Search again")
                .disabled(finder.scanning)
                Button("Quick Look") { LargeFileFinder.quickLook(chosen.map(\.path)) }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(chosen.isEmpty)
                Button("Move to Trash…", role: .destructive) {
                    pending = chosen.map(\.path)
                    confirming = true
                }
                .prominentGlassButton()
                .tint(.red)
                .controlSize(.large)
                .disabled(finder.scanning || chosen.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .confirmationDialog(pending.count == 1
            ? "Move “\((pending[0] as NSString).lastPathComponent)” to the Trash?"
            : "Move \(pending.count) files to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { finder.trash(pending) }
            Button("Cancel", role: .cancel) {}
        } message: {
            let size = finder.items.filter { pending.contains($0.path) }.reduce(0) { $0 + $1.size }
            Text("\(Fmt.bytes(size)) will be moved to the Trash. The space is freed when you empty the Trash.")
        }
        .onAppear { if !finder.loaded { finder.scan() } }
    }

    private func row(_ file: LargeFileItem) -> some View {
        Toggle(isOn: Binding(get: { file.selected }, set: { finder.setSelected(file.path, $0) })) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(for: file.contentType.flatMap { UTType($0) } ?? .data))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(Fmt.bytes(file.size)).monospacedDigit()
                    Text(lastUsedText(file)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .contextMenu {
            Button("Quick Look") { LargeFileFinder.quickLook([file.path]) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Move to Trash…", role: .destructive) {
                pending = [file.path]
                confirming = true
            }
        }
    }

    private func lastUsedText(_ file: LargeFileItem) -> String {
        if let d = file.lastOpened { return "Opened \(d.formatted(date: .abbreviated, time: .omitted))" }
        if let d = file.modified { return "Modified \(d.formatted(date: .abbreviated, time: .omitted))" }
        return "Never opened"
    }
}
