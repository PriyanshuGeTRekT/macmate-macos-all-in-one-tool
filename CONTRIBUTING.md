# Contributing to MacMate

Thanks for helping make MacMate better. Bug reports, ideas and pull requests are all welcome.

- **Found a bug?** Open a [bug report](https://github.com/PriyanshuGeTRekT/macmate-macos-all-in-one-tool/issues/new/choose).
- **Have an idea?** Open a [feature request](https://github.com/PriyanshuGeTRekT/macmate-macos-all-in-one-tool/issues/new/choose). For bigger changes, please open an issue before you start coding so we can agree on the approach.
- **Found a security problem?** Please don't open an issue. See [SECURITY.md](SECURITY.md).

## Requirements

- A Mac with Apple silicon running **macOS 26 or later**.
- The **Xcode Command Line Tools**. Full Xcode is not needed, and the project is deliberately kept buildable without it.

```bash
xcode-select --install
```

## Building

```bash
git clone https://github.com/PriyanshuGeTRekT/macmate-macos-all-in-one-tool.git
cd macmate-macos-all-in-one-tool
./build.sh
```

`build.sh` runs `swift build -c release`, assembles `dist/MacMate.app`, adds the icon and signs it ad hoc. To try your build:

```bash
ditto dist/MacMate.app /Applications/MacMate.app && open /Applications/MacMate.app
```

Quit any copy of MacMate that is already running first. Each rebuild changes the ad-hoc signature, so macOS may ask for Accessibility access again: switch MacMate off and on in **System Settings › Privacy & Security › Accessibility**.

For a quick compile check without packaging, `swift build` is enough.

## The self-test

MacMate has a built-in self-test that exercises the non-visual parts (battery, energy counters, system monitor, uninstaller rules and more) and prints `PASS` or `FAIL` for each check. Run it before and after your change:

```bash
dist/MacMate.app/Contents/MacOS/MacMate --selftest
```

It exits with a non-zero status if any check fails. CI runs the same test with `--ci`, which skips checks that need real hardware (a battery, displays, audio devices, mice) or installed third-party apps:

```bash
.build/release/MacMate --selftest --ci
```

If you add a feature with logic that can be tested without a screen, add checks for it in `Sources/MacMate/App/SelfTest.swift` using `SelfTest.check(name, condition, detail)`. Wrap anything that needs real hardware in `if !ci { ... }`.

`MacMate --snapshot <folder>` renders the panel tabs off screen with sample data. That is how the images in `docs/screenshots` are made; update them if you change how a tab looks.

## The `@ViewState` rule

**Never write `@State` in a SwiftUI view. Use `@ViewState` instead.**

```swift
@ViewState private var showAll = false
```

The `@State` macro needs a compiler plugin that ships only with full Xcode, so it does not compile with the Command Line Tools. `@ViewState` is a type alias for `SwiftUI.State` (defined in `UI/Panel.swift`) and behaves exactly the same. Initialise it in an `init` with `_name = ViewState(initialValue: ...)`. The same applies to other macros: avoid anything that needs a compiler plugin, such as `@Observable`, `@Entry` and `#Preview`. Use `ObservableObject` with `@Published`, and `@ObservedObject` in views.

## Project layout

```
Package.swift            Swift package, macOS 26, linked system frameworks
build.sh                 Builds dist/MacMate.app with the Command Line Tools
Packaging/               Info.plist, app icon and the script that draws it
Sources/MacMate/
├── main.swift           Entry point: --selftest, --snapshot or the app
├── App/                 App delegate, menu bar item, panel tabs, self-test, snapshots
├── Core/                Event tap, hotkeys, settings keys, formatting helpers
├── Services/            Battery, energy, system monitor, windows, mouse, uninstaller, tools
└── UI/                  SwiftUI views for the panel tabs and the Cleanup window
docs/                    Website (GitHub Pages), icon and screenshots
Casks/                   Homebrew cask for the tap in this repository
```

Services hold the logic and state and are usually singletons (`BatteryService.shared`, `WindowManager.shared`) that publish changes with `@Published`. Views stay thin and read from them.

## How panel sections are structured

Each tab of the panel is one SwiftUI view in `Sources/MacMate/UI/`. A tab is a `Form` made of `Section`s. The panel applies `.formStyle(.grouped)` and hides the scroll background, so tabs look like System Settings without extra styling.

```swift
struct ExampleTab: View {
    @ObservedObject private var service = ExampleService.shared
    @AppStorage(Keys.exampleEnabled) private var enabled = true
    @ViewState private var showDetails = false

    var body: some View {
        Form {
            AccessibilityNotice(reason: "MacMate needs it to ...")   // only if the tab needs Accessibility
            Section {
                Toggle("Enable example", isOn: $enabled)
            }
            Section("Options") {
                // controls
            } footer: {
                Text("One or two sentences that explain the options above.")
            }
        }
    }
}
```

To add a tab:

1. Add a case to `PanelTab` in `App/App.swift` with a `title` and an SF Symbol in `symbol`.
2. Show your view for that case in the `switch` in `UI/Panel.swift`.
3. Add settings keys to `enum Keys` in `Core/Util.swift` and their defaults to `UserDefaults.registerMacMateDefaults()`.
4. Add self-test checks, and a snapshot if the tab has a screenshot.

Keep each tab fitting the 400 × 620 pt panel. Put rarely used options behind a disclosure or in a footer rather than adding more rows.

## Code style

- Follow the style of the surrounding code: four-space indentation, Swift API Design Guidelines naming, `// MARK: -` to separate parts of a file.
- Use system controls, SF Symbols and system colors. No custom fonts, images or third-party packages.
- Write UI text in plain, short sentences in sentence case, as Apple does in System Settings.
- Add a `///` doc comment to types and to anything that is not obvious, especially private API or IOKit calls.
- Do work off the main thread when it can take time (file scans, energy sampling), and publish results back on the main thread.
- **Privacy:** no network requests other than the existing update check, no analytics, no logging of user data.
- **Safety:** anything that removes files must move them to the Trash and go through the uninstaller's safety rules.
- Keep it light. MacMate should stay near 0% CPU when idle; avoid timers that run while the panel is closed unless the feature needs them.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change, keeping each pull request focused on one thing.
3. Run `./build.sh` and the self-test, and try the change in the running app.
4. Update `README.md` and `CHANGELOG.md` if users will notice the change, and attach screenshots for UI changes.
5. Open a pull request and fill in the template. CI builds the app and runs the self-test on every pull request.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
