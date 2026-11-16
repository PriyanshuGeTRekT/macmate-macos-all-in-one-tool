// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacMate",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MacMate",
            path: "Sources/MacMate",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Vision"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("CoreAudio"),
            ]
        )
    ]
)
