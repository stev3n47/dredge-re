// feature_profile.c — Supercent SDK User + AdsHelper flag management.
//
// Targets (all static, verified against dump.cs):
//   User (TypeDefIndex 2626, Assembly-CSharp.dll)
//     NoAds {get;set;}            -> re-assert true
//     IsOnOpenAppAds {get;set;}   -> re-assert false
//     SetSkinUnlockedAll()        -> periodic invoke (skins toggle)
//     Stage/Level/Coin {get;set;} -> sdk_progress opt-in boost
//   AdsHelper.Interstitial (2285, nested — resolved by verified lookup)
//     HasNoAds {get;set;}         -> re-assert true
//     IsOnSkippedCheat {get;set;} -> re-assert false (telemetry hygiene)
//   AdsHelper.Paused (2288)
//     IsEnabled {get; private set;} -> re-assert false
//   AdsHelper.RewardedVideo (2290)
//     IsOnSkippedCheat {get;set;} -> re-assert false
//
// Poll-and-set pattern (PFPlus Tier-1 style): getter check, setter only on
// drift, ~2s cadence. No methodPointer swaps here — everything has a real
// setter we can invoke.

#include "features.h"
#include <string.h>

// Resolved MethodInfos (all static -> self=NULL at invoke).
static const MethodInfo *g_user_get_noads, *g_user_set_noads;
static const MethodInfo *g_user_get_openapp, *g_user_set_openapp;
static const MethodInfo *g_user_set_skins;
static const MethodInfo *g_user_get_stage, *g_user_set_stage;
static const MethodInfo *g_user_get_level, *g_user_set_level;
static const MethodInfo *g_user_get_coin, *g_user_set_coin;

static const MethodInfo *g_it_get_noads, *g_it_set_noads;
static const MethodInfo *g_it_get_skcheat, *g_it_set_skcheat;

static const MethodInfo *g_pu_get_enabled, *g_pu_set_enabled;

static const MethodInfo *g_rv_get_skcheat, *g_rv_set_skcheat;

static int tick_count = 0;
static int logged_once = 0;

// Invoke a static bool setter with `value` (uint8_t arg).
static int set_bool1(const MethodInfo *m, int value) {
    if (!m) return 0;
    uint8_t b = value ? 1 : 0;
    int ok = 1;
    bd_il2cpp_invoke1(m, NULL, &b, &ok);
    return ok;
}

// Invoke a static int getter; returns -1 on failure.
static int get_int0(const MethodInfo *m) {
    if (!m) return -1;
    int ok = 1;
    Il2CppObject *r = bd_il2cpp_invoke0(m, NULL, &ok);
    if (!ok || !r) return -1;
    return bd_unbox_i32(r);
}

// Re-assert pattern: if getter reports the "bad" value, invoke setter.
// bad==0 -> set to 1; bad==1 -> set to 0. Returns 1 when it fired.
static int reassert(const MethodInfo *getter, const MethodInfo *setter,
                    int bad_value, const char *tag) {
    int cur = get_int0(getter);
    if (cur < 0) return 0;          // getter unresolved or threw
    if (cur == bad_value) {
        if (set_bool1(setter, !bad_value)) {
            bd_log("profile: %s re-asserted (was %d)", tag, cur);
            return 1;
        }
    }
    return 0;
}

static void resolve_user(void) {
    Il2CppClass *k = bd_find_class_verified("Assembly-CSharp.dll",
                                            "User", "get_NoAds", 0);
    if (!k) {
        bd_log("profile: User class (verified get_NoAds) not found");
        return;
    }
    bd_log("profile: User class=%p", (void *)k);
    g_user_get_noads   = bd_il2cpp_find_method(k, "get_NoAds", 0);
    g_user_set_noads   = bd_il2cpp_find_method(k, "set_NoAds", 1);
    g_user_get_openapp = bd_il2cpp_find_method(k, "get_IsOnOpenAppAds", 0);
    g_user_set_openapp = bd_il2cpp_find_method(k, "set_IsOnOpenAppAds", 1);
    g_user_set_skins   = bd_il2cpp_find_method(k, "SetSkinUnlockedAll", 0);
    g_user_get_stage   = bd_il2cpp_find_method(k, "get_Stage", 0);
    g_user_set_stage   = bd_il2cpp_find_method(k, "set_Stage", 1);
    g_user_get_level   = bd_il2cpp_find_method(k, "get_Level", 0);
    g_user_set_level   = bd_il2cpp_find_method(k, "set_Level", 1);
    g_user_get_coin    = bd_il2cpp_find_method(k, "get_Coin", 0);
    g_user_set_coin    = bd_il2cpp_find_method(k, "set_Coin", 1);
    bd_log("profile: User NoAds=%p/%p OpenApp=%p/%p Skins=%p Stage=%p/%p Level=%p/%p Coin=%p/%p",
           (void *)g_user_get_noads, (void *)g_user_set_noads,
           (void *)g_user_get_openapp, (void *)g_user_set_openapp,
           (void *)g_user_set_skins,
           (void *)g_user_get_stage, (void *)g_user_set_stage,
           (void *)g_user_get_level, (void *)g_user_set_level,
           (void *)g_user_get_coin, (void *)g_user_set_coin);
}

static void resolve_ads(void) {
    Il2CppClass *it = bd_find_class_verified("Assembly-CSharp.dll",
                                             "Interstitial", "get_HasNoAds", 0);
    if (it) {
        bd_log("profile: AdsHelper.Interstitial class=%p", (void *)it);
        g_it_get_noads   = bd_il2cpp_find_method(it, "get_HasNoAds", 0);
        g_it_set_noads   = bd_il2cpp_find_method(it, "set_HasNoAds", 1);
        g_it_get_skcheat = bd_il2cpp_find_method(it, "get_IsOnSkippedCheat", 0);
        g_it_set_skcheat = bd_il2cpp_find_method(it, "set_IsOnSkippedCheat", 1);
    } else {
        bd_log("profile: Interstitial class (verified get_HasNoAds) not found");
    }

    Il2CppClass *pu = bd_find_class_verified("Assembly-CSharp.dll",
                                             "Paused", "get_IsEnabled", 0);
    if (pu) {
        bd_log("profile: AdsHelper.Paused class=%p", (void *)pu);
        g_pu_get_enabled = bd_il2cpp_find_method(pu, "get_IsEnabled", 0);
        g_pu_set_enabled = bd_il2cpp_find_method(pu, "set_IsEnabled", 1);
        bd_log("profile: Paused.IsEnabled set=%p (private setter — invoke ignores accessibility)",
               (void *)g_pu_set_enabled);
    } else {
        bd_log("profile: Paused class (verified get_IsEnabled) not found");
    }

    Il2CppClass *rv = bd_find_class_verified("Assembly-CSharp.dll",
                                             "RewardedVideo", "get_IsAdReady", 0);
    if (rv) {
        bd_log("profile: AdsHelper.RewardedVideo class=%p", (void *)rv);
        g_rv_get_skcheat = bd_il2cpp_find_method(rv, "get_IsOnSkippedCheat", 0);
        g_rv_set_skcheat = bd_il2cpp_find_method(rv, "set_IsOnSkippedCheat", 1);
    } else {
        bd_log("profile: RewardedVideo class (verified get_IsAdReady) not found");
    }
}

static int init(void) {
    resolve_user();
    resolve_ads();
    if (!g_user_set_noads && !g_it_set_noads && !g_user_set_skins &&
        !g_rv_set_skcheat) {
        bd_log("profile: nothing resolved — disabling");
        return -1;
    }
    return 0;
}

static void set_int1(const MethodInfo *m, int32_t v, const char *tag) {
    if (!m) return;
    int ok = 1;
    bd_il2cpp_invoke1(m, NULL, &v, &ok);
    if (!ok) bd_log("profile: %s setter threw", tag);
}

static int tick(void) {
    tick_count++;
    int did = 0;

    // ~2s cadence for drift checks (tick_hz=10 default).
    int slow = (tick_count % 20) == 0;

    if (bd_cfg_bool("no_ads", 0)) {
        // User.NoAds -> true (bad value = 0)
        did |= reassert(g_user_get_noads, g_user_set_noads, 0, "User.NoAds");
        // Interstitial.HasNoAds -> true
        did |= reassert(g_it_get_noads, g_it_set_noads, 0, "Interstitial.HasNoAds");
        // Interstitial.IsOnSkippedCheat -> false (bad = 1)
        did |= reassert(g_it_get_skcheat, g_it_set_skcheat, 1, "Interstitial.IsOnSkippedCheat");
        // RewardedVideo.IsOnSkippedCheat -> false
        did |= reassert(g_rv_get_skcheat, g_rv_set_skcheat, 1, "RewardedVideo.IsOnSkippedCheat");
        // User.IsOnOpenAppAds -> false
        did |= reassert(g_user_get_openapp, g_user_set_openapp, 1, "User.IsOnOpenAppAds");
        // Paused.IsEnabled -> false (private setter, invoke ignores accessibility)
        did |= reassert(g_pu_get_enabled, g_pu_set_enabled, 1, "Paused.IsEnabled");
    }

    // Skins: invoke SetSkinUnlockedAll on a slow cadence. It's a one-shot
    // "mark everything owned" sweep; re-firing every ~30s covers save
    // reloads without spamming.
    if (bd_cfg_bool("unlock_skins", 0) && g_user_set_skins && slow) {
        int ok = 1;
        bd_il2cpp_invoke0(g_user_set_skins, NULL, &ok);
        if (ok) {
            bd_log("profile: SetSkinUnlockedAll invoked");
            did = 1;
        }
    }

    // sdk_progress — OPT-IN, writes Supercent profile Stage/Level/Coin.
    // These sync server-side in some titles; flagged risky in the menu.
    if (bd_cfg_bool("sdk_progress", 0) && slow) {
        int fired = 0;
        int32_t stage = 100, level = 100, coin = 999999999;
        if (g_user_set_stage) { set_int1(g_user_set_stage, stage, "User.Stage"); fired = 1; }
        if (g_user_set_level) { set_int1(g_user_set_level, level, "User.Level"); fired = 1; }
        if (g_user_set_coin)  { set_int1(g_user_set_coin,  coin,  "User.Coin");  fired = 1; }
        if (fired) {
            bd_log("profile: sdk_progress boost applied (Stage=%d Level=%d Coin=%d)",
                   stage, level, coin);
            did = 1;
        }
    }

    if (!logged_once) {
        logged_once = 1;
        bd_log("profile: first tick — no_ads=%d skins=%d sdk=%d",
               bd_cfg_bool("no_ads", 0), bd_cfg_bool("unlock_skins", 0),
               bd_cfg_bool("sdk_progress", 0));
    }
    return did;
}

BdFeature bd_feature_profile = { "profile", init, tick, 0, 0, 0, 0, NULL, 0 };
