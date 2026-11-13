// pac_swap.h — v2.2.1 methodPointer swap helper.
//
// v2.2's probe confirmed arm64e PAC + page protection on this build
// permit a raw write to MethodInfo.slot[0] and runtime_invoke routes the
// call through our trampoline. This header exposes the generalized
// install helper so feature modules don't reinvent the swap.
//
// Safety rules (same as v2.2 probe):
//  - Caller must resolve the MethodInfo via `stp_il2cpp_find_method`
//    (SPPlus v33 rule: never from a heap-derived class pointer).
//  - Trampoline signature must match the real method's ABI. Mismatches
//    corrupt the stack. For a static method `R fn(a1, …, an)` the
//    actual compiled form takes a trailing `const MethodInfo *method`
//    arg per IL2CPP convention — trampoline signature must include it.
//  - No restore helper: once installed, the hook lives for the session.
//    If callers need to undo, they save slot[0] themselves.

#ifndef STP_PAC_SWAP_H
#define STP_PAC_SWAP_H

#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Install a trampoline over `mi`'s methodPointer. Logs the old/new
// pointers with the given tag for traceability. Returns 1 on apparent
// success (the write landed; verifying the hook fires is the caller's
// job via a test invoke). Returns 0 if mi or trampoline is NULL.
int  stp_pac_hook_install(const MethodInfo *mi, void *trampoline, const char *tag);

// Variant that writes the pre-swap slot[0] to *out_original for
// callers that want to restore later.
int  stp_pac_hook_install_save(const MethodInfo *mi, void *trampoline,
                                void **out_original, const char *tag);

// STPlus v1 — write `original` back into slot[0] (undo an install). Enables
// live toggle-off without a relaunch. Returns 1 on write, 0 on NULL args.
int  stp_pac_hook_restore(const MethodInfo *mi, void *original, const char *tag);

// Shared stub trampolines. These ignore every arg and just set the
// return register. arm64 AAPCS puts integer/pointer returns in x0 and
// float returns in s0, independently — so these work for any arity of
// the real method as long as we never read the args and the real
// return type matches. Signatures declared as `(void)` so the compiler
// emits "mov x0, #0; ret" or "fmov s0, wzr; ret" with no frame access.
float   stp_tramp_zero_float(void);
float   stp_tramp_one_float(void);
int64_t stp_tramp_zero_int(void);
int64_t stp_tramp_one_int(void);
// v2.5 — "huge" int return for Infinite Save-Cap. Returns 999,999,999
// which fits both int32 (max ~2.1B) and int64 interpretations of the
// hooked method's return type. Picked under INT32_MAX so callers that
// multiply / add won't overflow into negative.
int64_t stp_tramp_huge_int(void);
// v2.6 — constant 2.0 for Super Speed scalar hooks. Used where a
// multiplier method ordinarily returns ~1.0 and we want to double it.
float   stp_tramp_two_float(void);

// v1.0.2 — instrumented "return 1" trampoline. Same ABI/return as
// stp_tramp_one_int but increments stp_tramp_true_hits on each call, so
// callers can prove (or disprove) that the hooked path actually fires.
#include <stdatomic.h>
extern _Atomic unsigned long stp_tramp_true_hits;
int64_t stp_tramp_one_int_counted(void);

#ifdef __cplusplus
}
#endif

#endif  // STP_PAC_SWAP_H
