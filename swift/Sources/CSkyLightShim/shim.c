#include "CSkyLightShim.h"

#if defined(__APPLE__)
#include <dlfcn.h>
#include <stddef.h>

// The SkyLight private framework hosts the SLEvent*/SLSGet*/CGEventSetWindowLocation
// exports. We dlopen it lazily and cache the handle; CoreGraphics-public symbols
// (e.g. CGEventPostToPSN) resolve through RTLD_DEFAULT without it.
static void *csky_skylight_handle(void) {
    static void *handle = NULL;
    if (handle == NULL) {
        handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY | RTLD_LOCAL);
    }
    return handle;
}

void *csky_resolve_symbol(const char *name) {
    if (name == NULL) {
        return NULL;
    }
    // Try the global symbol table first (public CoreGraphics exports + frameworks
    // already linked into the process).
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym != NULL) {
        return sym;
    }
    void *handle = csky_skylight_handle();
    if (handle == NULL) {
        return NULL;  // SkyLight unavailable — fall through, never crash.
    }
    return dlsym(handle, name);
}
#endif /* __APPLE__ */

int csky_shim_abi_version(void) { return 1; }
