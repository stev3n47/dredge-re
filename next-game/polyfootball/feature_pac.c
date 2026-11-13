// feature_pac.c — v2.2 PAC probe + methodPointer-swap feasibility test.
//
// Goal: determine whether arm64e PAC (pointer authentication) and page
// protection on PolyFootball / Unity 6 metadata v39 allow us to overwrite
// MethodInfo.methodPointer with our own trampoline pointer. If yes, every
// static (and instance) method on the Tier 2 physics classes becomes
// hookable without needing instance discovery (gc_foreach_heap doesn't
// surface our target classes anyway — see v2.1.1 findings).
//
// Two-phase design:
//
//   Phase 1 (always runs, zero risk):
//     - Resolve PremiumCurrency.UnlockPro MethodInfo* (we already use this
//       method successfully via runtime_invoke, so we have a known-good
//       target).
//     - Read slot[0] (presumed methodPointer) and slot[1] (presumed
//       invoker_method) and log them. If slot[0] is a sane code address
//       in the UnityFramework text segment, the MethodInfo struct layout
//       assumption (methodPointer at offset 0, stable across IL2CPP
//       metadata versions back to v24) holds for metadata v39 too.
//
//   Phase 2 (gated behind `pac_probe=1` in pfplus.json):
//     - Swap slot[0] to our test_trampoline.
//     - Invoke the method via runtime_invoke.
//     - Restore original slot[0] UNCONDITIONALLY.
//     - If trampoline_called flag flipped, PAC permits raw methodPointer
//       writes; v2.2+ can hook any static or instance method by swapping
//       the pointer.
//     - If it didn't flip, PAC or page protection blocks the write; we
//       need `ptrauth_sign_unauthenticated` (with the right discriminator)
//       or `vm_protect` before writes will land.
//
// Target choice: PremiumCurrency.UnlockPro is ideal because:
//   - We already successfully call it via runtime_invoke every boot.
//   - It's static, no args, void return — trampoline signature is simple:
//     `void(const MethodInfo *)`.
//   - It's idempotent — re-invoking with the trampoline (which does
//     nothing) just leaves Pro-ownership state as-is. Even if the probe
//     crashes before restore, the game's state is intact: Pro ownership is
//     server-synced, so a missing Unlock call means at worst Pro doesn't
//     re-apply this session.
//
// Failure modes we're explicitly OK with (phase 2 only):
//   - SIGBUS / KERN_PROTECTION_FAILURE: slot[0] page is RO. Log via
//     crash .ips. Future: add vm_protect + sys_icache_invalidate.
//   - BRK 0xc470 (PAC trap): slot[0] value is PAC-signed and a raw write
//     fails the AUT. Log via .ips. Future: ptrauth_sign_unauthenticated.
//   - SIGSEGV deep in Unity: our offset assumption is wrong; slot[0]
//     wasn't methodPointer; we wrote to the wrong field. Log via .ips.
//     Future: use metadata-v39 struct dump to find the right offset.

#include "features.h"
#include <string.h>

// IL2CPP method pointer calling convention: for a static, zero-arg method
// like UnlockPro, the compiled method function has signature
//   void fn(const MethodInfo *method)
// — the MethodInfo trails as an implicit "which method am I" cookie.
// runtime_invoke goes through invoker_method (slot[1]) which bridges from
// (self, args[]) to this ABI, so even though we pass self=NULL, the
// invoker still calls our trampoline with (method) via the typed fn
// pointer in slot[0].
typedef void (*PfpStaticVoidFn)(const MethodInfo *method);

static volatile int g_trampoline_called = 0;

static void pac_test_trampoline(const MethodInfo *method) {
    (void)method;
    g_trampoline_called = 1;
}

static int init(void) {
    // Resolve PremiumCurrency.UnlockPro as the probe target.
    Il2CppClass *klass = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "PremiumCurrency");
    if (!klass) {
        pfp_log("pac: PremiumCurrency class not found — probe skipped");
        return -1;
    }
    const MethodInfo *mi = pfp_il2cpp_find_method(klass, "UnlockPro", 0);
    if (!mi) {
        pfp_log("pac: UnlockPro MethodInfo not found — probe skipped");
        return -1;
    }

    // Phase 1: log-only. Zero risk — a plain memory read of the first few
    // uintptr_t slots of MethodInfo. If slot[0] lands in the UnityFramework
    // text segment range we know methodPointer is at offset 0 as expected.
    void * const *mp_slot = (void * const *)mi;
    void *slot0 = mp_slot[0];
    void *slot1 = mp_slot[1];
    void *slot2 = mp_slot[2];
    void *slot3 = mp_slot[3];
    pfp_log("pac: PremiumCurrency.UnlockPro MethodInfo=%p "
            "slot[0]=%p slot[1]=%p slot[2]=%p slot[3]=%p",
            (void *)mi, slot0, slot1, slot2, slot3);
    pfp_log("pac: (expected layout: slot[0]=methodPointer, slot[1]=invoker_method)");

    // If pac_probe=0 (default), stop here. Steve/user reads phase 1 output
    // and decides whether to flip the flag to attempt the swap.
    if (!pfp_cfg_bool("pac_probe", 0)) {
        pfp_log("pac: phase 1 (read-only) done. Flip pac_probe=1 in pfplus.json "
                "to attempt phase 2 methodPointer swap.");
        return 0;
    }

    // Phase 2: swap slot[0] to our trampoline, invoke, restore.
    pfp_log("pac: phase 2 — writing trampoline %p into MethodInfo slot[0]",
            (void *)pac_test_trampoline);

    void **wmp_slot = (void **)mi;  // drop const for the write attempt
    void *orig = wmp_slot[0];
    g_trampoline_called = 0;

    wmp_slot[0] = (void *)pac_test_trampoline;
    int ok = 1;
    pfp_il2cpp_invoke0(mi, NULL, &ok);

    // ALWAYS restore original before returning, whether or not the swap
    // took effect. If we survived to this line, the write and the invoke
    // did not crash the process.
    wmp_slot[0] = orig;

    if (g_trampoline_called) {
        pfp_log("pac: SUCCESS — trampoline fired. methodPointer swap works "
                "on this build. v2.2+ can hook any static or instance method "
                "by swapping MethodInfo slot[0].");
    } else {
        pfp_log("pac: INCONCLUSIVE — invoke returned ok=%d but trampoline did "
                "NOT fire. Either (a) the write was silently reverted/blocked, "
                "(b) slot[0] isn't methodPointer on v39, or (c) invoker_method "
                "called the original pointer via its own cached copy. "
                "v2.2.1 will add vm_protect + ptrauth_sign_unauthenticated.",
                ok);
    }
    return 0;
}

static int tick(void) {
    return 0;  // one-shot init-time probe, no per-tick work
}

PfpFeature pfp_feature_pac = { "pac", init, tick, 0, 0, 0, 0 };
