// pac_swap.h — v2.2.1 methodPointer swap helper.
//
// v2.2's probe confirmed arm64e PAC + page protection on this build
// permit a raw write to MethodInfo.slot[0] and runtime_invoke routes the
// call through our trampoline. This header exposes the generalized
// install helper so feature modules don't reinvent the swap.
//
// Safety rules (same as v2.2 probe):
//  - Caller must resolve the MethodInfo via `bd_il2cpp_find_method`
//    (SPPlus v33 rule: never from a heap-derived class pointer).
//  - Trampoline signature must match the real method's ABI. Mismatches
//    corrupt the stack. For a static method `R fn(a1, …, an)` the
//    actual compiled form takes a trailing `const MethodInfo *method`
//    arg per IL2CPP convention — trampoline signature must include it.
//  - No restore helper: once installed, the hook lives for the session.
//    If callers need to undo, they save slot[0] themselves.

#ifndef BD_PAC_SWAP_H
#define BD_PAC_SWAP_H

#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Install a trampoline over `mi`'s methodPointer. Logs the old/new
// pointers with the given tag for traceability. Returns 1 on apparent
// success (the write landed; verifying the hook fires is the caller's
// job via a test invoke). Returns 0 if mi or trampoline is NULL.
int  bd_pac_hook_install(const MethodInfo *mi, void *trampoline, const char *tag);

// Variant that writes the pre-swap slot[0] to *out_original for
// callers that want to restore later.
int  bd_pac_hook_install_save(const MethodInfo *mi, void *trampoline,
                                void **out_original, const char *tag);

// Shared stub trampolines. These ignore every arg and just set the
// return register. arm64 AAPCS puts integer/pointer returns in x0 and
// float returns in s0, independently — so these work for any arity of
// the real method as long as we never read the args and the real
// return type matches. Signatures declared as `(void)` so the compiler
// emits "mov x0, #0; ret" or "fmov s0, wzr; ret" with no frame access.
float   bd_tramp_zero_float(void);
float   bd_tramp_one_float(void);
int64_t bd_tramp_zero_int(void);
int64_t bd_tramp_one_int(void);
// v2.5 — "huge" int return for Infinite Save-Cap. Returns 999,999,999
// which fits both int32 (max ~2.1B) and int64 interpretations of the
// hooked method's return type. Picked under INT32_MAX so callers that
// multiply / add won't overflow into negative.
int64_t bd_tramp_huge_int(void);
// v2.6 — constant 2.0 for Super Speed scalar hooks. Used where a
// multiplier method ordinarily returns ~1.0 and we want to double it.
float   bd_tramp_two_float(void);

// ---- v1.1 inline-patch hooks ------------------------------------------
//
// methodPointer swap only intercepts paths that consult MethodInfo
// (runtime_invoke, reflection, delegates). IL2CPP compiles ordinary
// call/callvirt sites to direct function calls / vtable slots, which
// never read MethodInfo->methodPointer. The reliable interception for
// those is patching the generated code itself at the methodPointer
// address (slot[0] of MethodInfo = runtime VA of the function entry).
//
// bd_hook_* helpers try the inline patch FIRST (catches every call
// path); on write failure they fall back to bd_pac_hook_install so
// runtime_invoke/delegate paths are still covered.
//
// Inline patch forms (all arm64, written via mach_vm_write which the
// kernel mediates — bypasses user page protections where permitted):
//   bd_hook_bool_true : `mov w0,#1 ; ret`          — any ->bool/int method
//   bd_hook_int_imm   : `movz/movk w0,#imm ; ret`  — any ->int32 method
//   bd_hook_branch    : `adrp/add/br x16 -> target`— void/bool method
//                      fully replaced by `target` (matching compiled ABI,
//                      incl. trailing MethodInfo* arg). Original code is
//                      NOT preserved — target must not need to call it.

// Returns 1 if EITHER the inline patch or the methodPointer fallback
// was installed. 0 = both failed (feature should log + disable).
int  bd_hook_bool_true(const MethodInfo *mi, const char *tag);
int  bd_hook_int_imm(const MethodInfo *mi, uint32_t imm, const char *tag);
int  bd_hook_branch(const MethodInfo *mi, void *target, const char *tag);
// v1.2 variants: constant-false for ->bool methods, bare `ret` for void.
int  bd_hook_bool_false(const MethodInfo *mi, const char *tag);
int  bd_hook_ret_only(const MethodInfo *mi, const char *tag);

#ifdef __cplusplus
}
#endif

#endif  // BD_PAC_SWAP_H
