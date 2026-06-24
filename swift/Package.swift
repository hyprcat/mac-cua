// swift-tools-version: 6.0
import PackageDescription

// mac-cua Swift port.
//
// Phase 0-2 targets (MacCUACore, MacCUAServer + their tests) are pure logic and
// build/test on Linux. The macOS-only adapter layer (MacCUAKit, CSkyLightShim,
// the mac-cua executable) is added behind a host-OS guard in THIS manifest so
// the Linux build of Core/Server stays green by construction: on a non-macOS
// host the Kit targets are simply absent from the package graph.

// PURE LOGIC — builds + tests on Linux.
var targets: [Target] = [
    .target(
        name: "MacCUACore"
    ),
    .testTarget(
        name: "MacCUACoreTests",
        dependencies: ["MacCUACore"]
    ),
    // ORCHESTRATION SPINE — depends only on Core protocol seams, so it
    // builds + tests on Linux against mock providers (Phase 2).
    .target(
        name: "MacCUAServer",
        dependencies: ["MacCUACore"]
    ),
    .testTarget(
        name: "MacCUAServerTests",
        dependencies: ["MacCUAServer", "MacCUACore"]
    ),
]

var products: [Product] = [
    .library(name: "MacCUACore", targets: ["MacCUACore"]),
]

#if os(macOS)
// macOS ADAPTER LAYER — real framework implementations of the Core provider
// seams. Excluded from the package graph on non-macOS hosts so Core/Server stay
// Linux-green.
targets += [
    // C interop shim for the private SkyLight / CGS symbol surface (US-029).
    .target(
        name: "CSkyLightShim"
    ),
    // Real macOS providers (AppKit / ApplicationServices / CoreGraphics /
    // ScreenCaptureKit / Vision). US-014 ships compiling stubs; Phases 3-6 fill
    // in the implementations per provider.
    .target(
        name: "MacCUAKit",
        dependencies: ["MacCUACore", "CSkyLightShim"]
    ),
    .testTarget(
        name: "MacCUAKitTests",
        dependencies: ["MacCUAKit", "MacCUACore"]
    ),
]
products += [
    .library(name: "MacCUAKit", targets: ["MacCUAKit"]),
]
#endif

let package = Package(
    name: "mac-cua",
    products: products,
    targets: targets
)
