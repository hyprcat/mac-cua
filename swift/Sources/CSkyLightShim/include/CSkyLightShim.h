// CSkyLightShim — C interop surface for the private SkyLight / CoreGraphics
// (CGS) symbols the background-input path needs (US-029).
//
// Every symbol is resolved OPTIONALLY at runtime via dlopen+dlsym
// (`csky_resolve_symbol`) — NONE of them is a hard link dependency. A missing
// symbol resolves to NULL and the Swift caller falls through to the
// always-available CGEvent base path (US-028); it never crashes and never
// foregrounds (Invariant 17/18).
//
// We declare each delivery/lookup prototype as a function-POINTER typedef (not
// an `extern` function) precisely so importing this module creates no link
// requirement against the private frameworks. The Swift side resolves a raw
// pointer with `csky_resolve_symbol(name)` and `unsafeBitCast`s it to the
// matching typedef.
//
// FORBIDDEN — intentionally absent: SLPSSetFrontProcessWithOptions and
// CGSSetConnectionProperty "SetFrontmost" (the Python `micro_activate` path).
// Foregrounding is banned by the Prime Invariant; those symbols are never
// declared here.

#ifndef CSKYLIGHTSHIM_H
#define CSKYLIGHTSHIM_H

#include <stdint.h>

#if defined(__APPLE__)
#include <CoreGraphics/CoreGraphics.h>             // CGEventRef, CGPoint
#include <CoreServices/CoreServices.h>             // ProcessSerialNumber
#include <ApplicationServices/ApplicationServices.h> // AXError, AXObserverRef, AXUIElementRef, CFStringRef

// --- Stable / lookup symbols ------------------------------------------------
typedef uint32_t (*CSky_CGSMainConnectionID)(void);
typedef int32_t  (*CSky_SLSGetWindowOwner)(uint32_t cid, uint32_t wid, uint32_t *ownerCidOut);
typedef int32_t  (*CSky_SLSGetConnectionPSN)(uint32_t cid, ProcessSerialNumber *psnOut);
typedef int32_t  (*CSky_CGSConnectionGetPID)(uint32_t cid, int32_t *pidOut);
typedef int32_t  (*CSky_CGSGetConnectionIDForPID)(uint32_t cid, int32_t pid, uint32_t *cidOut); // pre-26 owner strategy; REMOVED in macOS 26

// --- Targeted-delivery symbols ----------------------------------------------
typedef void (*CSky_SLEventPostToPid)(int32_t pid, CGEventRef event);
typedef void (*CSky_SLEventSetIntegerValueField)(CGEventRef event, uint32_t field, int64_t value); // field 40 = target pid
typedef void (*CSky_SLEventSetAuthenticationMessage)(CGEventRef event, const void *message);       // message = id (CFTypeRef)
typedef void (*CSky_CGEventSetWindowLocation)(CGEventRef event, CGPoint location);                 // window-local coords (SkyLight export)
typedef void (*CSky_CGEventPostToPSN)(ProcessSerialNumber *psn, CGEventRef event);

// --- Remote-aware AX observer registration (US-059) -------------------------
// Private HIServices SPI. Marks an AX observer "remote-aware" so Chromium /
// Electron (Blink) apps keep firing AX notifications even while their window is
// OCCLUDED — the public AXObserverAddNotification does not, so Blink
// short-circuits notifications when occluded.
//
// Resolved OPTIONALLY at runtime via the existing
// `csky_resolve_symbol("_AXObserverAddNotificationAndCheckRemote")`; it is NEVER
// a hard link dependency (Invariant 17). When the symbol is absent the Swift
// caller falls back to the public AXObserverAddNotification — this is purely an
// occluded-Electron notification-liveness + settle-timing optimization, NOT a
// correctness fix (the AX tree re-walk remains the source of truth). No new
// resolver is added; the same `csky_resolve_symbol` lookup is reused.
typedef AXError (*CSky_AXObserverAddNotificationAndCheckRemote)(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *refcon);

// Resolve a private symbol by name via dlsym. Searches the global symbol table
// first (CoreGraphics public exports + already-loaded frameworks), then the
// SkyLight private framework. Returns NULL when absent — the caller falls
// through, never crashes, never foregrounds. Safe to call repeatedly (the
// SkyLight handle is opened once and cached).
void *csky_resolve_symbol(const char *name);
#endif /* __APPLE__ */

// ABI marker the Swift side can assert against.
int csky_shim_abi_version(void);

#endif /* CSKYLIGHTSHIM_H */
