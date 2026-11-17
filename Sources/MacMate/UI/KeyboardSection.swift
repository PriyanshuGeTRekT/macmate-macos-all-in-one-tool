import SwiftUI

/// The keyboard part of the "Mouse & Keyboard" tab: Caps Lock as a Hyper key and simple key remapping.
/// Only `Section`s, so it can be dropped into an existing grouped Form.
struct KeyboardSection: View {
    @ObservedObject private var remapper = KeyRemapper.shared
    @ObservedObject private var state = AppState.shared
    @AppStorage(Keys.keyboardHyper) private var hyper = false
    @AppStorage(Keys.keyboardHyperEscape) private var escapeAlone = true
    @AppStorage(Keys.remapExternalOnly) private var externalOnly = false

    var body: some View {
        Group {
            hyperSection
            remapSection
        }
    }

    // MARK: Hyper key

    private var hyperSection: some View {
        Section {
            Toggle(isOn: $hyper) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Caps Lock as Hyper key")
                        Text("Hold for ⌃⌥⇧⌘")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: hyper ? "capslock.fill" : "capslock")
                        .foregroundStyle(hyper ? Color.accentColor : .secondary)
                }
            }
            .onChange(of: hyper) { _, _ in remapper.apply() }
            Toggle("Press Caps Lock alone for Escape", isOn: $escapeAlone)
                .onChange(of: escapeAlone) { _, _ in remapper.apply() }
                .disabled(!hyper)
            if hyper && !state.accessibilityGranted {
                HStack(alignment: .firstTextBaseline) {
                    Label("Waiting for Accessibility access", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                    Spacer()
                    Button("Open Settings") {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
        } header: {
            Text("Hyper Key")
        } footer: {
            Text("Needs Accessibility access. Use Hyper in shortcuts that no app already claims. Caps Lock keeps working normally until access is granted.")
        }
    }

    // MARK: Remapping

    @ViewBuilder private var remapSection: some View {
        Section("Key Remapping") {
            if remapper.pairs.isEmpty {
                Text("No keys remapped")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(remapper.pairs) { pair in
                    row(pair)
                }
            }
            Button {
                remapper.addRow(hyper: hyper)
            } label: {
                Label("Add Key", systemImage: "plus")
            }
            .disabled(remapper.availableFromKeys(for: nil, hyper: hyper).isEmpty)
        }
        Section {
            Picker("Apply to", selection: $externalOnly) {
                Text("All keyboards").tag(false)
                Text("External keyboards only").tag(true)
            }
            .onChange(of: externalOnly) { _, _ in remapper.apply() }
            LabeledContent("Windows keyboard") {
                Button("Swap ⌘ and ⌥") {
                    remapper.applyCommandOptionPreset()
                    externalOnly = true
                }
                .help("Swaps ⌘ and ⌥ on both sides, on external keyboards only, so the keys sit where a Mac keyboard has them.")
            }
        } footer: {
            Text(remapFooter)
        }
    }

    private func row(_ pair: KeyRemapPair) -> some View {
        HStack(spacing: 4) {
            keyMenu(pair.from, keys: remapper.availableFromKeys(for: pair.id, hyper: hyper)) { remapper.update(pair.id, from: $0) }
            Image(systemName: "arrow.right")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityLabel("to")
            keyMenu(pair.to, keys: KeyRemapKey.allCases) { remapper.update(pair.id, to: $0) }
            Button {
                remapper.removeRow(pair.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .accessibilityLabel("Remove \(pair.from.title)")
        }
        .opacity(hyper && pair.from == .capsLock ? 0.5 : 1)
    }

    private func keyMenu(_ selection: KeyRemapKey, keys: [KeyRemapKey], set: @escaping (KeyRemapKey) -> Void) -> some View {
        Picker("Key", selection: Binding(get: { selection }, set: set)) {
            ForEach(KeyRemapKey.groups, id: \.title) { group in
                let shown = group.keys.filter(keys.contains)
                if !shown.isEmpty {
                    Section(group.title) {
                        ForEach(shown) { key in
                            Text(key.title).tag(key)
                        }
                    }
                }
            }
        }
        .labelsHidden()
        .fixedSize()
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private var remapFooter: String {
        var text = "Remaps need no permission and apply to new keyboards as they connect. MacMate undoes them when it quits."
        if hyper && remapper.pairs.contains(where: { $0.from == .capsLock }) {
            text += " The Caps Lock remap is paused while the Hyper key is on."
        }
        return text
    }
}
