// Factory that assembles the `Providers` dependency container from the MacCUAKit
// implementations, for the runnable executable (US-015). Phases 3-6 replace the
// individual Kit stubs with real framework code; this factory stays stable as
// each provider is filled in.
//
// Nothing here may foreground / activate / warp / post globally (the Prime
// Invariant) — the factory only wires seams together.

#if os(macOS)
import Foundation
import MacCUACore
import MacCUAServer

/// Build the real (Kit-backed) provider container for the executable.
///
/// As of US-015 only the permission seams (`checkAccessibilityPermission`,
/// `checkScreenRecordingPermission`, `promptScreenRecordingPermission`) are
/// real; every other Kit provider is still a US-014 stub and is implemented in
/// its own later story. The container shape never changes.
public func makeKitProviders() -> Providers {
    // Shared SkyLight provider: gives the input layer its targeted (window-
    // stamped) mouse path (US-030/C2) wired into clicks (US-032). Falls through
    // to the CGEvent base path when the host doesn't resolve the symbols.
    let skyLight = KitSkyLightProvider()
    return Providers(
        apps: KitAppResolver(),
        accessibility: KitAccessibilityProvider(),
        input: KitInputProvider(skyLight: skyLight),
        capture: KitCaptureProvider(),
        clipboard: KitClipboardProvider(),
        ocr: KitOCRProvider(),
        frontmostTracker: KitFrontmostTracker(),
        userInteractionMonitor: KitUserInteractionMonitor(),
        screenLock: KitScreenLockProvider(),
        makeSettleMonitor: { _ in KitSettleMonitor() },
        makeAXOutcomeMonitor: { _ in KitOutcomeMonitor() },
        makeCGEventOutcomeMonitor: { _ in KitOutcomeMonitor() },
        makeMenuTracker: { _ in KitMenuTracker() },
        makeSelectionClient: { _ in KitSelectionProvider() },
        makeEditableText: { _, _ in nil }
    )
}
#endif
