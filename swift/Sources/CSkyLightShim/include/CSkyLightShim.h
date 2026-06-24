// CSkyLightShim — C interop surface for the private SkyLight / CoreGraphics
// (CGS) symbols the background-input path needs.
//
// Phase 3+ (US-029) extern-declares the stable + delivery symbols here with
// their exact prototypes and resolves each one optionally via dlopen+dlsym, so
// a missing symbol falls through (never a hard link dependency, never a crash,
// never a foregrounding trigger — Invariant 17).
//
// US-014 establishes the target so it compiles and is importable from
// MacCUAKit. It is intentionally declaration-light here; the symbol surface is
// filled in by US-029.

#ifndef CSKYLIGHTSHIM_H
#define CSKYLIGHTSHIM_H

// Placeholder so the module has a translation unit / public surface to export.
// Returns the ABI marker the Swift side can assert against once the real symbol
// table lands (US-029).
int csky_shim_abi_version(void);

#endif /* CSKYLIGHTSHIM_H */
