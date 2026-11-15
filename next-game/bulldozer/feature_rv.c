// feature_rv.c — free rewarded-video rewards.
//
// Target: AdsHelper.RewardedVideo (TypeDefIndex 2290, static class,
// namespace Supercent.LaunchOps.Ads — resolved by verified name lookup).
//
//   Show(ERewardedPlacement placement, Action<bool> doneCallback)
//   ShowWithExt(ERewardedPlacement placement, string extInfo, Action<bool> doneCallback)
//
// Both funnel into _ShowRewardedVideo which talks to the ad SDK. We swap
// methodPointer on the two public entry points with trampolines that skip
// the ad entirely and invoke doneCallback(true) — every RV placement
// (money_rv, fuel_add, offline_reward, upgrade skips, boosts, …) grants
// its reward for free.
//
// Trampoline ABI (IL2CPP static method convention):
//   Show:      (int32 placement, Il2CppObject *cb,        MethodInfo *mi)
//   ShowWithExt:(int32 placement, Il2CppString *ext,     Il2CppObject *cb, MethodInfo *mi)
// We ignore everything except the Action<bool> delegate and invoke its
// `Invoke(bool)` via il2cpp_runtime_invoke — the standard delegate-call
// pattern. The delegate's Invoke MethodInfo is resolved once per delegate
// class and cached.
//
// Anti-cheat note: KEY_IS_SKIPPED_CHEAT ("ah_rv_sk") is only written inside
// the real _ShowRewardedVideo path, which we never reach — the flag stays
// clean. feature_profile additionally re-asserts IsOnSkippedCheat=false.

#include "features.h"
#include "pac_swap.h"
#include <string.h>
#include <stdint.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_show_mi    = NULL;   // Show, argc=2
static const MethodInfo *g_showx_mi   = NULL;   // ShowWithExt, argc=3
static int g_installed = 0;

// Delegate Invoke cache — Action<bool> closures usually share one class,
// but be safe and key on the class pointer.
static Il2CppClass      *g_cb_klass   = NULL;
static const MethodInfo *g_cb_invoke  = NULL;
static unsigned long     g_cb_fires   = 0;

// Invoke `cb`'s Invoke(true). Safe to call from the trampoline: we're on
// the game's own thread inside a methodPointer-swapped call, and we only
// runtime_invoke a DIFFERENT MethodInfo (the delegate's Invoke).
static void rv_grant(Il2CppObject *cb, const char *tag) {
    if (!cb) return;
    if (!bd_il2cpp_object_get_class || !bd_il2cpp_class_get_method_from_name ||
        !bd_il2cpp_runtime_invoke) return;

    Il2CppClass *k = bd_il2cpp_object_get_class(cb);
    if (!k) return;

    if (k != g_cb_klass) {
        const MethodInfo *inv = bd_il2cpp_class_get_method_from_name(k, "Invoke", 1);
        if (!inv) {
            bd_log("rv: callback class=%p has no Invoke(1) — cannot grant", (void *)k);
            g_cb_klass = k;
            g_cb_invoke = NULL;
            return;
        }
        g_cb_klass = k;
        g_cb_invoke = inv;
        bd_log("rv: resolved delegate Invoke=%p on class=%p", (void *)inv, (void *)k);
    }
    if (!g_cb_invoke) return;

    uint8_t t = 1;
    void *args[1] = { &t };
    Il2CppObject *exc = NULL;
    bd_il2cpp_runtime_invoke(g_cb_invoke, cb, args, &exc);
    g_cb_fires++;
    if (g_cb_fires <= 20 || (g_cb_fires % 50) == 0) {
        bd_log("rv: granted reward via %s callback (%lu total)", tag, g_cb_fires);
    }
}

// IL2CPP compiled signature for static Show(int32, Action<bool>):
//   ret func(int32_t arg0, Il2CppObject *arg1, const MethodInfo *method)
__attribute__((noinline))
static void bd_rv_show_tramp(int32_t placement, Il2CppObject *cb, void *method) {
    (void)placement; (void)method;
    rv_grant(cb, "Show");
}

// ShowWithExt(int32, string, Action<bool>):
//   ret func(int32_t arg0, void *arg1, Il2CppObject *arg2, const MethodInfo *method)
__attribute__((noinline))
static void bd_rv_showx_tramp(int32_t placement, void *ext, Il2CppObject *cb, void *method) {
    (void)placement; (void)ext; (void)method;
    rv_grant(cb, "ShowWithExt");
}

static int init(void) {
    g_klass = bd_find_class_verified("Assembly-CSharp.dll",
                                     "RewardedVideo", "Show", 2);
    if (!g_klass) {
        bd_log("rv: RewardedVideo class (verified Show/2) not found");
        return -1;
    }
    g_show_mi  = bd_il2cpp_find_method(g_klass, "Show", 2);
    g_showx_mi = bd_il2cpp_find_method(g_klass, "ShowWithExt", 3);
    bd_log("rv: RewardedVideo class=%p Show=%p ShowWithExt=%p",
           (void *)g_klass, (void *)g_show_mi, (void *)g_showx_mi);
    if (!g_show_mi && !g_showx_mi) {
        bd_log("rv: no entry points resolved — disabling");
        return -1;
    }
    return 0;
}

static int tick(void) {
    if (g_installed) return 0;
    int n = 0;
    // v1.1: inline branch patch replaces Show/ShowWithExt code entirely —
    // every call path (direct call, vtable, runtime_invoke, delegates)
    // lands in our grant callback. methodPointer swap is the fallback.
    if (g_show_mi) {
        n += bd_hook_branch(g_show_mi, (void *)bd_rv_show_tramp, "rv.Show");
    }
    if (g_showx_mi) {
        n += bd_hook_branch(g_showx_mi, (void *)bd_rv_showx_tramp, "rv.ShowWithExt");
    }
    g_installed = 1;
    bd_log("rv: installed %d hook(s) — rewarded ads auto-grant", n);
    return n > 0 ? 1 : 0;
}

BdFeature bd_feature_rv = { "free_rv", init, tick, 0, 0, 0, 0, NULL, 0 };
