// pac_swap.c — generalized methodPointer swap (see pac_swap.h).

#include "pac_swap.h"
#include "features.h"

int pfp_pac_hook_install_save(const MethodInfo *mi, void *trampoline,
                               void **out_original, const char *tag) {
    if (!mi || !trampoline) {
        pfp_log("pac-swap: %s invalid args (mi=%p trampoline=%p)",
                tag ? tag : "?", (const void *)mi, trampoline);
        return 0;
    }
    void **slot = (void **)mi;     // slot[0] = methodPointer per v2.2 probe
    void *orig = slot[0];
    if (out_original) *out_original = orig;
    slot[0] = trampoline;
    pfp_log("pac-swap: %s installed · MethodInfo=%p orig=%p -> trampoline=%p",
            tag ? tag : "?", (const void *)mi, orig, trampoline);
    return 1;
}

int pfp_pac_hook_install(const MethodInfo *mi, void *trampoline, const char *tag) {
    return pfp_pac_hook_install_save(mi, trampoline, NULL, tag);
}

// Shared trampolines. Declared `(void)` so the compiler doesn't touch
// the stack. `no_sanitize("address")` just in case a future ASan build
// probes the frame.
__attribute__((no_sanitize("address")))
float pfp_tramp_zero_float(void) { return 0.0f; }

__attribute__((no_sanitize("address")))
float pfp_tramp_one_float(void) { return 1.0f; }

__attribute__((no_sanitize("address")))
int64_t pfp_tramp_zero_int(void) { return 0; }

__attribute__((no_sanitize("address")))
int64_t pfp_tramp_one_int(void) { return 1; }

__attribute__((no_sanitize("address")))
int64_t pfp_tramp_huge_int(void) { return 999999999LL; }

__attribute__((no_sanitize("address")))
float pfp_tramp_two_float(void) { return 2.0f; }
