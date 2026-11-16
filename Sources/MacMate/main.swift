import AppKit

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}
if let i = arguments.firstIndex(of: "--snapshot"), i + 1 < arguments.count {
    Snapshot.run(directory: arguments[i + 1])
    exit(0)
}
let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
