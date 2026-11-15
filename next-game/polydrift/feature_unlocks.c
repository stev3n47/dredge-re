// feature_unlocks.c — PDPlus v1 invoke-writer engine (PolyDrift2).
//
// Polytopia v1.0.2 proved methodPointer/vtable swaps don't reach
// direct-call sites. PolyDrift2's unlock/currency surface is mostly
// WRITER methods (AddVehicleUnlock, GiveGold, set_Coins, Save*) — and
// writers ARE reachable through il2cpp_runtime_invoke. This module
// resolves targets at runtime by name (declaring classes unconfirmed
// offline — the .dat section layout is irregular on this build), finds
// the instance via static-singleton getters or a heap walk, and invokes
// the writers on the main runloop.
//
// Features (cfg keys):
//   vehicles=1  AddVehicleUnlock(uid) over the discoverable UID range,
//               then SaveUnlockedVehiclesUID() to persist. One-shot.
//   gold=0      GetPlayerGold() -> if low, GiveGold(top-up). 5s re-check.
//   coins=0     set_Coins/set_CoinsEarnt pinned at 999,999,999 per tick.
//   noads=0     invoke RemoveAds/DisableAds/set_AdsEnabled(false) if found;
//               pac-hook every Show*/Load*Ad method on ad classes.
//   boost=0     pin set_SpeedMultiplier(2.0)/set_SpeedBoostActive(true).
//
// Every invoke is exception-checked (exc != NULL => log + skip). Writers
// that turn out instance-bound fall back to the heap-walk self path.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

#define PDP_AMT 999999999
#define MAX_UID 256

// ---------- generic resolvers ----------

// Class scan by exact name or substring (matches diag's keyword pass).
static Il2CppClass *find_class_loose(const char *name) {
    Il2CppClass *k = pdp_il2cpp_find_class(NULL, NULL, name);
    if (k) return k;
    const char *subs[1] = { name };
    Il2CppClass *out[4];
    int n = pdp_find_classes_by_name(subs, 1, out, 4);
    return n ? out[0] : NULL;
}

// Find a class that DECLARES a method with this name (scan all classes).
static Il2CppClass *find_class_owning(const char *meth_name) {
    if (!pdp_il2cpp_domain_get || !pdp_il2cpp_domain_get_assemblies ||
        !pdp_il2cpp_assembly_get_image || !pdp_il2cpp_image_get_class_count ||
        !pdp_il2cpp_image_get_class || !pdp_il2cpp_class_get_methods ||
        !pdp_il2cpp_method_get_name)
        return NULL;
    Il2CppDomain *dom = pdp_il2cpp_domain_get();
    if (!dom) return NULL;
    size_t nasm = 0;
    const Il2CppAssembly **asms = pdp_il2cpp_domain_get_assemblies(dom, &nasm);
    if (!asms) return NULL;
    static const char *SKIP[] = {
        "System", "mscorlib", "UnityEngine", "Unity.", "netstandard",
        "Mono.", "UnityEngine.", "Il2Cpp",
    };
    for (size_t a = 0; a < nasm; a++) {
        const Il2CppImage *img = pdp_il2cpp_assembly_get_image(asms[a]);
        if (!img) continue;
        if (pdp_il2cpp_image_get_name) {
            const char *in = pdp_il2cpp_image_get_name(img);
            int skip = 0;
            if (in) for (unsigned s = 0; s < sizeof(SKIP)/sizeof(SKIP[0]); s++)
                if (!strncmp(in, SKIP[s], strlen(SKIP[s]))) { skip = 1; break; }
            if (skip) continue;
        }
        size_t nc = pdp_il2cpp_image_get_class_count(img);
        for (size_t c = 0; c < nc; c++) {
            Il2CppClass *k = pdp_il2cpp_image_get_class(img, c);
            if (!k) continue;
            void *iter = NULL;
            const MethodInfo *m;
            while ((m = pdp_il2cpp_class_get_methods(k, &iter))) {
                const char *mn = pdp_il2cpp_method_get_name(m);
                if (mn && !strcmp(mn, meth_name)) return k;
            }
        }
    }
    return NULL;
}

static const MethodInfo *find_method_any(Il2CppClass *k, const char *name) {
    if (!k || !pdp_il2cpp_class_get_methods || !pdp_il2cpp_method_get_name)
        return NULL;
    void *iter = NULL;
    const MethodInfo *m;
    while ((m = pdp_il2cpp_class_get_methods(k, &iter))) {
        const char *mn = pdp_il2cpp_method_get_name(m);
        if (mn && !strcmp(mn, name)) return m;
    }
    return NULL;
}

static int m_static(const MethodInfo *m) {
    if (!m || !pdp_il2cpp_method_get_flags) return -1;
    uint32_t ifl = 0;
    uint32_t fl = pdp_il2cpp_method_get_flags(m, &ifl);
    return (fl & 0x10) ? 1 : 0;
}

static int m_argc(const MethodInfo *m) {
    if (!m || !pdp_il2cpp_method_get_param_count) return -1;
    return (int)pdp_il2cpp_method_get_param_count(m);
}

// Instance cache — il2cpp (Boehm) GC doesn't move objects, so a live
// instance pointer stays valid for the session. Negative results are NOT
// cached (the object may not exist yet early in boot).
static void *find_self(Il2CppClass *k) {
    static struct { Il2CppClass *k; void *self; } cache[16];
    static int ncache = 0;
    for (int i = 0; i < ncache; i++)
        if (cache[i].k == k) return cache[i].self;

    // 1) static instance getters (Singleton patterns).
    static const char *GETTERS[] = {
        "get_Instance", "get_instance", "get_Shared", "get_shared",
        "get_Current", "get_current", "get_Default", "get_Singleton",
        "get_Main", "get_State", "get_Data",
    };
    void *self = NULL;
    for (unsigned i = 0; i < sizeof(GETTERS)/sizeof(GETTERS[0]); i++) {
        const MethodInfo *g = find_method_any(k, GETTERS[i]);
        if (g && m_static(g) == 1 && m_argc(g) == 0) {
            int ok = 0;
            Il2CppObject *o = pdp_il2cpp_invoke0(g, NULL, &ok);
            if (ok && o) { self = o; break; }
        }
    }
    // 2) heap walk fallback.
    if (!self) {
        void *insts[4];
        int n = pdp_il2cpp_find_instances(k, insts, 4);
        self = n ? insts[0] : NULL;
    }
    if (self && ncache < 16) {
        cache[ncache].k = k;
        cache[ncache].self = self;
        ncache++;
    }
    return self;
}

// Invoke a writer method, picking self for instance methods.
static int call_writer(const MethodInfo *m, Il2CppClass *k, void *self,
                       int arg_kind, int ival, float fval) {
    if (!m) return -1;
    int argc = m_argc(m);
    void *th = self;
    if (m_static(m) != 1 && !th) {
        th = find_self(k);
        if (!th) return -2;
    }
    int ok = 0;
    if (argc <= 0) {
        pdp_il2cpp_invoke0(m, th, &ok);
    } else {
        void *a0 = (arg_kind == 1) ? (void *)&fval : (void *)&ival;
        pdp_il2cpp_invoke1(m, th, a0, &ok);
    }
    return ok ? 1 : 0;
}

// ---------- feature: vehicles ----------

static Il2CppClass    *g_uv_class;
static const MethodInfo *g_add_unlock, *g_unlock_count, *g_save_unlock,
                      *g_check_unlock, *g_first_unlock;
static int g_uv_done;

static int vehicles_init(void) {
    g_uv_class = find_class_owning("AddVehicleUnlock");
    if (!g_uv_class) g_uv_class = find_class_loose("UnlockedVehicles");
    if (!g_uv_class) {
        pdp_log("vehicles: no class owns AddVehicleUnlock — disabled");
        return 1;
    }
    const char *cn = pdp_il2cpp_class_get_name
        ? pdp_il2cpp_class_get_name(g_uv_class) : "?";
    pdp_log("vehicles: class=%s ptr=%p", cn, (void *)g_uv_class);
    if (pdp_il2cpp_runtime_class_init) pdp_il2cpp_runtime_class_init(g_uv_class);
    g_add_unlock   = find_method_any(g_uv_class, "AddVehicleUnlock");
    g_unlock_count = find_method_any(g_uv_class, "GetVehicleUnlockCount");
    g_save_unlock  = find_method_any(g_uv_class, "SaveUnlockedVehiclesUID");
    g_check_unlock = find_method_any(g_uv_class, "CheckIfVehicleUnlockedUID");
    g_first_unlock = find_method_any(g_uv_class, "FindFirstUnlockedVehicleUID");
    pdp_log("vehicles: add=%p(st=%d,ac=%d) count=%p save=%p check=%p first=%p",
            (const void *)g_add_unlock,
            g_add_unlock ? m_static(g_add_unlock) : -1,
            g_add_unlock ? m_argc(g_add_unlock) : -1,
            (const void *)g_unlock_count, (const void *)g_save_unlock,
            (const void *)g_check_unlock, (const void *)g_first_unlock);
    return 0;
}

static int vehicles_tick(void) {
    if (g_uv_done || !g_add_unlock) return 0;
    void *self = (m_static(g_add_unlock) == 1) ? NULL : find_self(g_uv_class);
    if (m_static(g_add_unlock) != 1 && !self) {
        pdp_log("vehicles: instance method but no live instance yet — retrying");
        return 0;   // retry next tick until an instance exists
    }
    int added = 0;
    for (int uid = 0; uid < MAX_UID; uid++) {
        int ok = 0;
        pdp_il2cpp_invoke1(g_add_unlock, self, &uid, &ok);
        if (ok) added++;
    }
    pdp_log("vehicles: AddVehicleUnlock invoked uid=0..%d ok=%d", MAX_UID - 1, added);
    if (g_save_unlock) {
        int ok = 0;
        pdp_il2cpp_invoke0(g_save_unlock, self, &ok);
        pdp_log("vehicles: SaveUnlockedVehiclesUID ok=%d", ok);
    }
    g_uv_done = 1;
    return 1;
}

// ---------- feature: gold ----------

static Il2CppClass    *g_gold_class;
static const MethodInfo *g_give_gold, *g_get_gold;

static int gold_init(void) {
    g_gold_class = find_class_owning("GiveGold");
    if (!g_gold_class) {
        pdp_log("gold: no class owns GiveGold — disabled");
        return 1;
    }
    const char *cn = pdp_il2cpp_class_get_name
        ? pdp_il2cpp_class_get_name(g_gold_class) : "?";
    pdp_log("gold: class=%s ptr=%p", cn, (void *)g_gold_class);
    if (pdp_il2cpp_runtime_class_init) pdp_il2cpp_runtime_class_init(g_gold_class);
    g_give_gold = find_method_any(g_gold_class, "GiveGold");
    g_get_gold  = find_method_any(g_gold_class, "GetPlayerGold");
    pdp_log("gold: give=%p(st=%d,ac=%d) get=%p",
            (const void *)g_give_gold,
            g_give_gold ? m_static(g_give_gold) : -1,
            g_give_gold ? m_argc(g_give_gold) : -1,
            (const void *)g_get_gold);
    return 0;
}

static int gold_tick(void) {
    if (!g_give_gold) return 0;
    void *self = (m_static(g_give_gold) == 1) ? NULL : find_self(g_gold_class);
    if (m_static(g_give_gold) != 1 && !self) return 0;
    int64_t cur = -1;
    if (g_get_gold) {
        int ok = 0;
        Il2CppObject *r = pdp_il2cpp_invoke0(g_get_gold, self, &ok);
        if (ok && r) cur = pdp_unbox_i64(r);
    }
    if (cur >= PDP_AMT) return 1;   // already rich — nothing to do
    int amount = PDP_AMT;
    int ok = 0;
    pdp_il2cpp_invoke1(g_give_gold, self, &amount, &ok);
    if (ok) {
        pdp_log("gold: GiveGold(%d) ok (was %lld)", amount, (long long)cur);
        return 1;
    }
    return 0;
}

// ---------- feature: coins ----------

static Il2CppClass    *g_coin_class;
static const MethodInfo *g_set_coins, *g_set_earnt, *g_set_mult;

static int coins_init(void) {
    g_coin_class = find_class_owning("set_Coins");
    if (!g_coin_class) g_coin_class = find_class_owning("set_CoinsEarnt");
    if (!g_coin_class) g_coin_class = find_class_loose("Coins");
    if (!g_coin_class) {
        pdp_log("coins: no coin class found — disabled");
        return 1;
    }
    const char *cn = pdp_il2cpp_class_get_name
        ? pdp_il2cpp_class_get_name(g_coin_class) : "?";
    pdp_log("coins: class=%s ptr=%p", cn, (void *)g_coin_class);
    if (pdp_il2cpp_runtime_class_init) pdp_il2cpp_runtime_class_init(g_coin_class);
    g_set_coins = find_method_any(g_coin_class, "set_Coins");
    g_set_earnt = find_method_any(g_coin_class, "set_CoinsEarnt");
    g_set_mult  = find_method_any(g_coin_class, "set_CoinCollectionMultiplier");
    pdp_log("coins: set_Coins=%p(st=%d) set_Earnt=%p set_Mult=%p",
            (const void *)g_set_coins,
            g_set_coins ? m_static(g_set_coins) : -1,
            (const void *)g_set_earnt, (const void *)g_set_mult);
    if (!g_set_coins && !g_set_earnt) return 1;
    return 0;
}

static int coins_tick(void) {
    int did = 0;
    int amount = PDP_AMT;
    if (g_set_coins &&
        call_writer(g_set_coins, g_coin_class, NULL, 0, amount, 0) == 1) did = 1;
    if (g_set_earnt &&
        call_writer(g_set_earnt, g_coin_class, NULL, 0, amount, 0) == 1) did = 1;
    return did;
}

// ---------- feature: noads ----------

static Il2CppClass *g_ad_classes[4];
static int g_ad_n;

static int noads_init(void) {
    static const char *NAMES[] = {
        "AdmobAdManager", "AdManager", "Ads", "AdsManager",
    };
    for (unsigned i = 0; i < sizeof(NAMES)/sizeof(NAMES[0]) && g_ad_n < 4; i++) {
        Il2CppClass *k = find_class_loose(NAMES[i]);
        if (k) g_ad_classes[g_ad_n++] = k;
    }
    if (!g_ad_n) {
        pdp_log("noads: no ad-manager class found — disabled");
        return 1;
    }
    // neuter: pac-hook every Show/Load/Present-named method on ad classes,
    // then try disable-writers once.
    for (int i = 0; i < g_ad_n; i++) {
        Il2CppClass *k = g_ad_classes[i];
        if (pdp_il2cpp_runtime_class_init) pdp_il2cpp_runtime_class_init(k);
        const char *cn = pdp_il2cpp_class_get_name
            ? pdp_il2cpp_class_get_name(k) : "?";
        void *iter = NULL;
        const MethodInfo *m;
        int hooked = 0;
        while ((m = pdp_il2cpp_class_get_methods(k, &iter))) {
            const char *mn = pdp_il2cpp_method_get_name
                ? pdp_il2cpp_method_get_name(m) : NULL;
            if (!mn) continue;
            if (!strncmp(mn, "Show", 4) || !strncmp(mn, "Present", 7) ||
                !strncmp(mn, "Load", 4) || strstr(mn, "Interstitial") ||
                strstr(mn, "Rewarded") || strstr(mn, "Banner")) {
                pdp_pac_hook_install(m, (void *)pdp_tramp_zero_int, "noads");
                hooked++;
            }
        }
        pdp_log("noads: %s — %d show/load methods hooked", cn, hooked);
        // disable-style writers (if the game has one, it wins outright)
        static const char *DIS[] = {
            "RemoveAds", "DisableAds", "set_AdsEnabled", "set_ShowAds",
        };
        for (unsigned j = 0; j < sizeof(DIS)/sizeof(DIS[0]); j++) {
            const MethodInfo *dm = find_method_any(k, DIS[j]);
            if (dm) {
                int zero = 0;
                int r = call_writer(dm, k, NULL, 0, zero, 0);
                pdp_log("noads: %s.%s -> %d", cn, DIS[j], r);
            }
        }
    }
    return 0;
}

static int noads_tick(void) { return 0; }   // one-shot at init

// ---------- feature: boost ----------

static Il2CppClass    *g_boost_class;
static const MethodInfo *g_set_mult, *g_set_boost;

static int boost_init(void) {
    static const char *NAMES[] = {
        "CarController", "VehicleController", "Boost", "Speed",
    };
    for (unsigned i = 0; i < sizeof(NAMES)/sizeof(NAMES[0]); i++) {
        Il2CppClass *k = find_class_loose(NAMES[i]);
        if (!k) continue;
        const MethodInfo *m1 = find_method_any(k, "set_SpeedMultiplier");
        const MethodInfo *m2 = find_method_any(k, "set_SpeedBoostActive");
        if (m1 || m2) {
            g_boost_class = k; g_set_mult = m1; g_set_boost = m2;
            break;
        }
    }
    if (!g_boost_class) {
        pdp_log("boost: no speed/boost class found — disabled");
        return 1;
    }
    const char *cn = pdp_il2cpp_class_get_name
        ? pdp_il2cpp_class_get_name(g_boost_class) : "?";
    pdp_log("boost: class=%s mult=%p boost=%p", cn,
            (const void *)g_set_mult, (const void *)g_set_boost);
    if (pdp_il2cpp_runtime_class_init) pdp_il2cpp_runtime_class_init(g_boost_class);
    return 0;
}

static int boost_tick(void) {
    int did = 0;
    float two = 2.0f; int one = 1;
    if (g_set_mult &&
        call_writer(g_set_mult, g_boost_class, NULL, 1, 0, two) == 1) did = 1;
    if (g_set_boost &&
        call_writer(g_set_boost, g_boost_class, NULL, 0, one, 0) == 1) did = 1;
    return did;
}

// ---------- feature registry entries ----------

static int vh_init(void)  { return vehicles_init(); }
static int vh_tick(void)  { return pdp_cfg_bool("vehicles", 1) ? vehicles_tick() : 0; }
static int gd_init(void)  { return gold_init(); }
static int gd_tick(void)  { return pdp_cfg_bool("gold", 0) ? gold_tick() : 0; }
static int cn_init(void)  { return coins_init(); }
static int cn_tick(void)  { return pdp_cfg_bool("coins", 0) ? coins_tick() : 0; }
static int ad_init(void)  { return noads_init(); }
static int ad_tick(void)  { return 0; }
static int bo_init(void)  { return boost_init(); }
static int bo_tick(void)  { return pdp_cfg_bool("boost", 0) ? boost_tick() : 0; }

PdpFeature pdp_feature_vehicles = { "vehicles", vh_init, vh_tick, 0, 0, 0, 0, NULL, 0 };
PdpFeature pdp_feature_gold     = { "gold",     gd_init, gd_tick, 0, 0, 0, 0, NULL, 0 };
PdpFeature pdp_feature_coins    = { "coins",    cn_init, cn_tick, 0, 0, 0, 0, NULL, 0 };
PdpFeature pdp_feature_noads    = { "noads",    ad_init, ad_tick, 0, 0, 0, 0, NULL, 0 };
PdpFeature pdp_feature_boost    = { "boost",    bo_init, bo_tick, 0, 0, 0, 0, NULL, 0 };
