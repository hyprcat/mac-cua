// swift-tools-version: 6.0
import PackageDescription

// mac-cua Swift port.
//
// Phase 0-2 targets (MacCUACore, MacCUAServer + their tests) are pure logic and
// build/test on Linux. The macOS-only adapter layer (MacCUAKit, CSkyLightShim,
// the mac-cua executable) is added in later phases behind #if os(macOS) guards
// so the Linux CI build of Core/Server stays green.
let package = Package(
    name: "mac-cua",
    products: [
        .library(name: "MacCUACore", targets: ["MacCUACore"]),
    ],
    targets: [
        // PURE LOGIC — builds + tests on Linux.
        .target(
            name: "MacCUACore"
        ),
        .testTarget(
            name: "MacCUACoreTests",
            dependencies: ["MacCUACore"]
        ),
    ]
)
