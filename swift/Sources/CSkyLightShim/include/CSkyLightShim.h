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
#include <CoreGraphics/CoreGraphics.h>   // CGEventRef, CGPoint
#include <CoreServices/CoreServices.h>   // ProcessSerialNumber

// --- Stable / lookup symbols ------------------------------------------------
typedef uint32_t (*CSky_CGSMainConnectionID)(void);
typedef int32_t  (*CSky_SLSGetWindowOwner)(uint32_t cid, uint32_t wid, uint32_t *ownerCidOut);
typedef int32_t  (*CSky_SLSGetConnectionPSN)(uint32_t cid, ProcessSerialNumber *psnOut);
typedef int32_t  (*CSky_CGSConnectionGetPID)(uint32_t cid, int32_t *pidOut);

// --- Targeted-delivery symbols ----------------------------------------------
typedef void (*CSky_SLEventPostToPid)(int32_t pid, CGEventRef event);
typedef void (*CSky_SLEventSetIntegerValueField)(CGEventRef event, uint32_t field, int64_t value); // field 40 = target pid
typedef void (*CSky_SLEventSetAuthenticationMessage)(CGEventRef event, const void *message);       // message = id (CFTypeRef)
typedef void (*CSky_CGEventSetWindowLocation)(CGEventRef event, CGPoint location);                 // window-local coords (SkyLight export)
typedef void (*CSky_CGEventPostToPSN)(ProcessSerialNumber *psn, CGEventRef event);

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
