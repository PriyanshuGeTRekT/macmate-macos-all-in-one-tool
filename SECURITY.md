# Security policy

## Supported versions

Only the [latest release](https://github.com/PriyanshuGeTRekT/macos-all-in-one-tool/releases/latest) of MacMate receives security fixes. Please update to it and check that the problem still happens before reporting.

| Version        | Supported |
| -------------- | --------- |
| Latest release | Yes       |
| Older releases | No        |

## Reporting a vulnerability

**Please do not report security problems in public issues, discussions or pull requests.**

Report them privately through GitHub:

1. Open the [Security tab](https://github.com/PriyanshuGeTRekT/macos-all-in-one-tool/security) of this repository.
2. Click **Report a vulnerability**.
3. Describe the problem, the MacMate and macOS versions affected, and the steps to reproduce it. A proof of concept helps.

You will get a reply as soon as possible, usually within a week. Once the problem is confirmed, a fix is prepared and released, and the advisory is published with credit to you unless you prefer to stay anonymous.

## Scope

Examples of what counts as a security problem in MacMate:

- The uninstaller, junk cleaner or another cleanup tool removing or moving files outside the app-data folders it is allowed to touch.
- Clipboard history recording or exposing content it should not, such as passwords marked as concealed.
- MacMate making network requests other than the update check, or an update being installed without a valid download from this repository's releases.
- Another app or user abusing MacMate's Accessibility access or its event tap.

MacMate is not notarized by Apple, and the "Open Anyway" step on first launch is expected. That alone is not a vulnerability.
