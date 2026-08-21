// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "FanKit", targets: ["FanKit"]),
        .library(name: "ProfileKit", targets: ["ProfileKit"]),
        .library(name: "SensorKit", targets: ["SensorKit"]),
        .library(name: "HistoryKit", targets: ["HistoryKit"]),
        .library(name: "DaemonCore", targets: ["DaemonCore"]),
        .executable(name: "smcfan", targets: ["smcfan"]),
        .executable(name: "fancontrold", targets: ["fancontrold"]),
        .executable(name: "FanControlApp", targets: ["FanControlApp"]),
    ],
    targets: [
        .target(name: "SMCKit"),
        .target(name: "DaemonProtocol"),
        // The daemon's policy, split out of the executable so it can be tested
        // without root, hardware, or an XPC listener.
        .target(name: "DaemonCore", dependencies: ["FanKit", "DaemonProtocol"]),
        .target(name: "FanKit", dependencies: ["SMCKit"]),
        .target(name: "ProfileKit", dependencies: ["FanKit"]),
        .target(name: "SensorKit", dependencies: ["SMCKit", "FanKit"]),
        // libsqlite3 ships with macOS; the SDK's module map links it, and the
        // explicit setting keeps that true if the map ever changes.
        .target(name: "HistoryKit",
                dependencies: ["FanKit"],
                linkerSettings: [.linkedLibrary("sqlite3")]),

        // Test-only: seeded generators, adversarial traces, and the one
        // definition of the safety contract the stress suite asserts. Not a
        // product, and nothing shipped depends on it.
        .target(name: "SimSupport", dependencies: ["FanKit"]),

        .executableTarget(name: "smcfan", dependencies: ["SMCKit", "FanKit", "SensorKit"]),
        .executableTarget(name: "fancontrold", dependencies: ["FanKit", "DaemonCore", "DaemonProtocol"]),
        .executableTarget(
            name: "FanControlApp",
            dependencies: ["SMCKit", "FanKit", "ProfileKit", "SensorKit", "HistoryKit", "DaemonProtocol"],
            path: "Sources/FanControl"
        ),

        .testTarget(name: "FanKitTests", dependencies: ["FanKit", "SMCKit", "SimSupport"]),
        // The probe tool's release reporting: what `smcfan auto` claims, and
        // what it exits with, when the fans do not actually come back.
        .testTarget(name: "smcfanTests", dependencies: ["smcfan", "FanKit"]),
        .testTarget(name: "ProfileKitTests", dependencies: ["ProfileKit", "FanKit", "SimSupport"]),
        .testTarget(name: "DaemonProtocolTests", dependencies: ["DaemonProtocol"]),
        .testTarget(name: "DaemonCoreTests", dependencies: ["DaemonCore", "FanKit", "DaemonProtocol", "SimSupport"]),
        .testTarget(name: "SensorKitTests", dependencies: ["SensorKit"]),
        .testTarget(name: "HistoryKitTests", dependencies: ["HistoryKit"]),
        // The app target is an executable, but it is testable: the view models,
        // the scales they compute, and the views themselves rendered offscreen.
        .testTarget(name: "FanControlAppTests", dependencies: ["FanControlApp", "SimSupport"]),
    ]
)
