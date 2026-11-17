## What this changes

<!-- A short description of the change and why it is needed. Link the issue it fixes, e.g. "Fixes #12". -->

## How I tested it

<!-- Which Mac and macOS version, what you clicked through, and anything you could not test (no external display, no third-party mouse, ...). -->

- [ ] `./build.sh` succeeds with the Command Line Tools
- [ ] `dist/MacMate.app/Contents/MacOS/MacMate --selftest` passes
- [ ] I tried the change in the running app

## Checklist

- [ ] No `@State` (use `@ViewState`; see CONTRIBUTING.md)
- [ ] No new network requests, analytics or third-party dependencies
- [ ] Anything that removes files moves them to the Trash
- [ ] README and CHANGELOG updated if the change is visible to users
- [ ] Screenshots attached for UI changes
