// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "M5Blade",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "FanKit", targets: ["FanKit"]),
        .library(name: "PowerKit", targets: ["PowerKit"]),
        .library(name: "ProfileKit", targets: ["ProfileKit"]),
        .library(name: "SensorKit", targets: ["SensorKit"]),
        .library(name: "HistoryKit", targets: ["HistoryKit"]),
        .library(name: "DaemonCore", targets: ["DaemonCore"]),
        .executable(name: "smcfan", targets: ["smcfan"]),
        .executable(name: "m5bladed", targets: ["m5bladed"]),
        .executable(name: "M5BladeApp", targets: ["M5BladeApp"]),
    ],
    targets: [
        .target(name: "SMCKit"),
        .target(name: "DaemonProtocol"),
        // IOReport's C surface. The symbols live in libIOReport (they left
        // IOKit's tbd in macOS 27); the SDK ships a stub for it.
        .target(name: "CIOReport", linkerSettings: [.linkedLibrary("IOReport")]),
        .target(name: "FanKit", dependencies: ["SMCKit"]),
        // Battery health and charge-limit state. Reads are unprivileged;
        // writes exist only behind the daemon (DESIGN §6).
        .target(name: "PowerKit", dependencies: ["SMCKit"]),
        .target(name: "ProfileKit", dependencies: ["FanKit"]),
        // The daemon's policy, split out of the executable so it can be tested
        // without root, hardware, or an XPC listener.
        .target(name: "DaemonCore", dependencies: ["FanKit", "PowerKit", "DaemonProtocol"]),
        .target(name: "SensorKit", dependencies: ["SMCKit", "FanKit", "CIOReport"]),
        // libsqlite3 ships with macOS; the SDK's module map links it, and the
        // explicit setting keeps that true if the map ever changes.
        .target(name: "HistoryKit",
                dependencies: ["FanKit"],
                linkerSettings: [.linkedLibrary("sqlite3")]),

        // Test-only: seeded generators, adversarial traces, and the one
        // definition of the safety contract the stress suite asserts. Not a
        // product, and nothing shipped depends on it.
        .target(name: "SimSupport", dependencies: ["FanKit"]),

        .executableTarget(name: "smcfan", dependencies: ["SMCKit", "FanKit", "SensorKit", "DaemonProtocol"]),
        .executableTarget(name: "m5bladed", dependencies: ["FanKit", "PowerKit", "DaemonCore", "DaemonProtocol"], path: "Sources/m5bladed"),
        .executableTarget(
            name: "M5BladeApp",
            dependencies: ["SMCKit", "FanKit", "PowerKit", "ProfileKit", "SensorKit", "HistoryKit", "DaemonProtocol"],
            path: "Sources/M5Blade"
        ),

        .testTarget(name: "FanKitTests", dependencies: ["FanKit", "SMCKit", "SimSupport"]),
        // The probe tool's release reporting: what `smcfan auto` claims, and
        // what it exits with, when the fans do not actually come back.
        .testTarget(name: "smcfanTests", dependencies: ["smcfan", "FanKit"]),
        .testTarget(name: "PowerKitTests", dependencies: ["PowerKit"]),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit", "FanKit", "SimSupport"]),
        .testTarget(name: "DaemonProtocolTests", dependencies: ["DaemonProtocol"]),
        .testTarget(name: "DaemonCoreTests", dependencies: ["DaemonCore", "FanKit", "DaemonProtocol", "SimSupport"]),
        .testTarget(name: "SensorKitTests", dependencies: ["SensorKit"]),
        .testTarget(name: "HistoryKitTests", dependencies: ["HistoryKit"]),
        // The app target is an executable, but it is testable: the view models,
        // the scales they compute, and the views themselves rendered offscreen.
        .testTarget(name: "M5BladeAppTests", dependencies: ["M5BladeApp", "SimSupport"], path: "Tests/M5BladeAppTests"),
    ]
)
