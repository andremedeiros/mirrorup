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
        .library(name: "MirrorupDevices", targets: ["MirrorupDevices"]),
        .library(name: "MirrorupCanon", targets: ["MirrorupCanon"]),
        .library(name: "MirrorupCameras", targets: ["MirrorupCameras"]),
    ],
    targets: [
        .target(name: "MirrorupDiagnostics", swiftSettings: strict),
        .target(name: "MirrorupPTP", dependencies: ["MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupUSB", dependencies: ["MirrorupPTP", "MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupImageCapture", dependencies: ["MirrorupPTP", "MirrorupDiagnostics"], swiftSettings: strict),
        .target(name: "MirrorupCapture", dependencies: ["MirrorupDiagnostics"], swiftSettings: strict),
        // Vendor-neutral discovery (ImageCaptureCore + IOUSBHost), `CameraDriver` and `CameraRegistry`.
        .target(
            name: "MirrorupDevices",
            dependencies: ["MirrorupPTP", "MirrorupCapture", "MirrorupImageCapture", "MirrorupUSB", "MirrorupDiagnostics"],
            swiftSettings: strict
        ),
        // One module per camera maker; each depends on Devices, never on another driver.
        .target(
            name: "MirrorupCanon",
            dependencies: ["MirrorupPTP", "MirrorupCapture", "MirrorupDevices", "MirrorupDiagnostics"],
            swiftSettings: strict
        ),
        // The list of drivers the app and CLI ship (`CameraRegistry.builtIn`).
        .target(name: "MirrorupCameras", dependencies: ["MirrorupDevices", "MirrorupCanon"], swiftSettings: strict),
        .executableTarget(
            name: "MirrorupCLI",
            dependencies: [
                "MirrorupUSB", "MirrorupPTP", "MirrorupImageCapture", "MirrorupDevices", "MirrorupCameras", "MirrorupCanon",
                "MirrorupCapture", "MirrorupDiagnostics",
            ],
            path: "Tools/MirrorupCLI",
            swiftSettings: strict
        ),
        .testTarget(name: "MirrorupPTPTests", dependencies: ["MirrorupPTP"], resources: [.copy("Fixtures")], swiftSettings: strict),
        .testTarget(name: "MirrorupUSBTests", dependencies: ["MirrorupUSB"], swiftSettings: strict),
        .testTarget(
            name: "MirrorupDevicesTests",
            dependencies: ["MirrorupDevices", "MirrorupCameras", "MirrorupCanon", "MirrorupCapture"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MirrorupCanonTests",
            dependencies: ["MirrorupCanon", "MirrorupPTP", "MirrorupCapture"],
            resources: [.copy("Fixtures")],
            swiftSettings: strict
        ),
        .testTarget(name: "MirrorupCaptureTests", dependencies: ["MirrorupCapture", "MirrorupDiagnostics"], swiftSettings: strict),
        .testTarget(
            name: "MirrorupIntegrationTests",
            dependencies: ["MirrorupCameras", "MirrorupDevices", "MirrorupCanon", "MirrorupCapture", "MirrorupPTP"],
            swiftSettings: strict
        ),
    ]
)
