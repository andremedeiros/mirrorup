// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Mirrorup",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "mirrorup", targets: ["MirrorupCLI"]),
        .library(name: "MirrorupDiagnostics", targets: ["MirrorupDiagnostics"]),
        .library(name: "MirrorupPTP", targets: ["MirrorupPTP"]),
        .library(name: "MirrorupUSB", targets: ["MirrorupUSB"]),
        .library(name: "MirrorupImageCapture", targets: ["MirrorupImageCapture"]),
        .library(name: "MirrorupCapture", targets: ["MirrorupCapture"]),
        .library(name: "MirrorupCanon", targets: ["MirrorupCanon"]),
    ],
    targets: [
        .target(name: "MirrorupDiagnostics", swiftSettings: strict),
        .target(name: "MirrorupPTP", dependencies: ["MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupUSB", dependencies: ["MirrorupPTP", "MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupImageCapture", dependencies: ["MirrorupPTP", "MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupCapture", dependencies: ["MirrorupDiagnostics"], swiftSettings: strict),
        .target(
            name: "MirrorupCanon",
            dependencies: ["MirrorupPTP", "MirrorupCapture", "MirrorupImageCapture", "MirrorupUSB", "MirrorupDiagnostics"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MirrorupCLI",
            dependencies: ["MirrorupUSB", "MirrorupPTP", "MirrorupImageCapture", "MirrorupCanon", "MirrorupCapture", "MirrorupDiagnostics"],
            path: "Tools/MirrorupCLI",
            swiftSettings: strict
        ),
        .testTarget(name: "MirrorupPTPTests", dependencies: ["MirrorupPTP"], resources: [.copy("Fixtures")], swiftSettings: strict),
        .testTarget(name: "MirrorupUSBTests", dependencies: ["MirrorupUSB"], swiftSettings: strict),
        .testTarget(
            name: "MirrorupCanonTests",
            dependencies: ["MirrorupCanon", "MirrorupPTP", "MirrorupCapture"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(name: "MirrorupCaptureTests", dependencies: ["MirrorupCapture", "MirrorupDiagnostics"], swiftSettings: strict),
        .testTarget(
            name: "MirrorupIntegrationTests",
            dependencies: ["MirrorupCanon", "MirrorupCapture", "MirrorupImageCapture", "MirrorupUSB", "MirrorupPTP"],
            swiftSettings: strict
        ),
    ]
)
