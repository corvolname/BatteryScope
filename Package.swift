// swift-tools-version:6.0
import PackageDescription

// NOTE: builds must be run with a compatible SDK selected, because the macOS 27 SDK turns
// SwiftUI's `@State` into a macro backed by the `SwiftUIMacros` compiler plugin, and that
// plugin ships only inside Xcode. With a Command Line Tools toolchain every SwiftUI view
// fails with "plugin for module 'SwiftUIMacros' not found".
//
// Always build through the Makefile / Scripts/build-app.sh, which export SDKROOT pointing at
// the newest installed SDK where SwiftUI's property wrappers are still plain property
// wrappers (macOS 26.5 on this machine). A bare `swift build` uses the default 27.0 SDK and
// will not compile the UI. See README.md.
//
// Do not try to fix this with `.unsafeFlags(["-sdk", ...])`: SwiftPM still passes its own
// `-sdk` for some compilation units, producing a mixture of SDKs rather than an override.

// `@Observable` macros and Swift 6 strict-concurrency checking are both avoided on purpose,
// so the project stays buildable with a Command Line Tools-only toolchain.
let swift5Mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "BatteryScope",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatteryScope", targets: ["BatteryScope"]),
        .executable(name: "batteryscope-cli", targets: ["BatteryScopeCLI"]),
        .library(name: "BatteryKit", targets: ["BatteryKit"]),
    ],
    targets: [
        .target(
            name: "BatteryKit",
            path: "Sources/BatteryKit",
            swiftSettings: swift5Mode,
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "BatteryScope",
            dependencies: ["BatteryKit"],
            path: "Sources/BatteryScope",
            swiftSettings: swift5Mode,
            // Records a modern SDK version in LC_BUILD_VERSION while keeping the deployment
            // target at macOS 14.
            //
            // macOS picks an app's *compatibility appearance* from the SDK version the executable
            // declares it was linked against: declaring 14.0 got the pre-Tahoe controls (a white
            // pill in the segmented control instead of the current blue capsule). SwiftPM writes
            // the deployment target into both fields, so the SDK has to be set explicitly here.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-platform_version",
                "-Xlinker", "macos",
                "-Xlinker", "14.0",
                "-Xlinker", "26.5",
            ])]
        ),
        .executableTarget(
            name: "BatteryScopeCLI",
            dependencies: ["BatteryKit"],
            path: "Sources/BatteryScopeCLI",
            swiftSettings: swift5Mode
        ),
    ]
)
