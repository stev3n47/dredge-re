// pac_swap.h — v2.2.1 methodPointer swap helper.
//
// v2.2's probe confirmed arm64e PAC + page protection on this build
// permit a raw write to MethodInfo.slot[0] and runtime_invoke routes the
// call through our trampoline. This header exposes the generalized
// install helper so feature modules don't reinvent the swap.
//
// Safety rules (same as v2.2 probe):
//  - Caller must resolve the MethodInfo via `pfp_il2cpp_find_method`
//    (SPPlus v33 rule: never from a heap-derived class pointer).
//  - Trampoline signature must match the real method's ABI. Mismatches
//    corrupt the stack. For a static method `R fn(a1, …, an)` the
//    actual compiled form takes a trailing `const MethodInfo *method`
//    arg per IL2CPP convention — trampoline signature must include it.
//  - No restore helper: once installed, the hook lives for the session.
//    If callers need to undo, they save slot[0] themselves.

#ifndef PFP_PAC_SWAP_H
#define PFP_PAC_SWAP_H

#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Install a trampoline over `mi`'s methodPointer. Logs the old/new
// pointers with the given tag for traceability. Returns 1 on apparent
// success (the write landed; verifying the hook fires is the caller's
// job via a test invoke). Returns 0 if mi or trampoline is NULL.
int  pfp_pac_hook_install(const MethodInfo *mi, void *trampoline, const char *tag);

// Variant that writes the pre-swap slot[0] to *out_original for
// callers that want to restore later.
int  pfp_pac_hook_install_save(const MethodInfo *mi, void *trampoline,
                                void **out_original, const char *tag);

#ifdef __cplusplus
}
#endif

#endif  // PFP_PAC_SWAP_H
