// feature_money.c — v1b free career money (CareerTeamBudget).
//
// Target per PLAN.md:
//   Assembly-CSharp.dll · CareerTeamBudget (type_id 1434 at catalog-types.txt:1434,
//   method_start m9418, method_count 5). Plan: `Fits(int)` → true, `Cap` → huge.
//
// Reality check: `Fits(int cost)` is a budget-affordability PREDICATE —
// returning true requires methodPointer swap (deferred to v2b+ behind the
// PAC probe). We can't force its return value from poll-and-invoke. So at
// v1b scope:
//   - Resolve the class + both target methods.
//   - Log each method's static-bit + arity.
//   - If we identify a clearly safe static setter (e.g. `set_Cap(long)`,
//     static, arity 1), invoke it with a huge value, throttled.
//   - Otherwise log once and no-op — never guess at a method signature.
//
// SAFETY: only static methods are invoked, pass NULL self, wrap every
// invoke in ok-check. No methodPointer swap. No instance discovery.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_fits_mi = NULL;
static const MethodInfo *g_cap_mi = NULL;      // plain `Cap` method, if present
static const MethodInfo *g_get_cap_mi = NULL;  // `get_Cap`
static const MethodInfo *g_set_cap_mi = NULL;  // `set_Cap` — the sweet spot

static int g_fits_static   = 0, g_fits_argc   = -1;
static int g_cap_static    = 0, g_cap_argc    = -1;
static int g_get_cap_static= 0;
static int g_set_cap_static= 0, g_set_cap_argc= -1;

static int tick_count = 0;      // throttle for re-invoke
static int logged_once = 0;

// CareerTeamBudget.Fits typical signature: bool Fits(int cost). arity 1.
// Cap may be a plain method, or auto-property split (get_Cap/set_Cap).
// We try every likely variant and use whatever resolves.
static const MethodInfo *resolve_either(const char *name, int argc) {
    const MethodInfo *m = pfp_il2cpp_find_method(g_klass, name, argc);
    if (m) return m;
    // Fallback: some IL2CPP builds ignore argc in class_get_method_from_name
    // when passed -1 or an exact match isn't found; try arity 0 as a safety.
    if (argc != 0) return pfp_il2cpp_find_method(g_klass, name, 0);
    return NULL;
}

static void probe_flags(const MethodInfo *m, int *is_static, int *argc) {
    if (!m || !pfp_il2cpp_method_get_flags) return;
    uint32_t iflags = 0;
    uint32_t f = pfp_il2cpp_method_get_flags(m, &iflags);
    *is_static = (f & 0x10) ? 1 : 0;
    if (pfp_il2cpp_method_get_param_count) {
        *argc = (int)pfp_il2cpp_method_get_param_count(m);
    }
}

static int init(void) {
    g_klass = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "CareerTeamBudget");
    if (!g_klass) g_klass = pfp_il2cpp_find_class(NULL, NULL, "CareerTeamBudget");
    if (!g_klass) {
        pfp_log("money: CareerTeamBudget class not found in any image");
        return -1;
    }
    int mc = pfp_il2cpp_count_methods(g_klass);
    pfp_log("money: CareerTeamBudget class=%p method_count=%d (catalog expects 5)", g_klass, mc);

    g_fits_mi    = resolve_either("Fits", 1);
    g_cap_mi     = resolve_either("Cap", 0);
    g_get_cap_mi = resolve_either("get_Cap", 0);
    g_set_cap_mi = resolve_either("set_Cap", 1);

    probe_flags(g_fits_mi,    &g_fits_static,    &g_fits_argc);
    probe_flags(g_cap_mi,     &g_cap_static,     &g_cap_argc);
    probe_flags(g_get_cap_mi, &g_get_cap_static, &(int){0});
    probe_flags(g_set_cap_mi, &g_set_cap_static, &g_set_cap_argc);

    pfp_log("money: Fits=%p argc=%d%s",    g_fits_mi,    g_fits_argc,    g_fits_static    ? " [static]" : "");
    pfp_log("money: Cap=%p argc=%d%s",     g_cap_mi,     g_cap_argc,     g_cap_static     ? " [static]" : "");
    pfp_log("money: get_Cap=%p%s",         g_get_cap_mi,                 g_get_cap_static ? " [static]" : "");
    pfp_log("money: set_Cap=%p argc=%d%s", g_set_cap_mi, g_set_cap_argc, g_set_cap_static ? " [static]" : "");

    if (!g_fits_mi && !g_cap_mi && !g_set_cap_mi && !g_get_cap_mi) {
        pfp_log("money: no target methods resolved — disabling");
        return -1;
    }
    return 0;
}

static int g_cap_hook_installed = 0;

static int tick(void) {
    tick_count++;

    // v2.5 — install Cap methodPointer hook when cap_force=1. Returns
    // 999,999,999 so every budget-affordability check sees a huge cap
    // and Fits(cost) effectively always succeeds without needing to
    // hook Fits itself (we don't know its return conventions for sure).
    if (!g_cap_hook_installed
        && g_cap_mi && g_cap_static && g_cap_argc == 0
        && pfp_cfg_bool("cap_force", 0)) {
        int n = pfp_pac_hook_install(g_cap_mi,
                                     (void *)pfp_tramp_huge_int,
                                     "money.Cap");
        g_cap_hook_installed = 1;
        pfp_log("money: installed %d methodPointer hook(s) — Cap pinned to 999,999,999 (infinite save-cap)", n);
        if (n > 0) return 1;
    }

    // v2.1 one-shot summary of what the Nov 13 device log revealed:
    // CareerTeamBudget has 5 methods. Cap is a static getter (argc=0),
    // not a setter. Fits/get_Cap/set_Cap don't exist by those names on
    // this build. v2.5 unblocks this via methodPointer swap above.
    if (!logged_once) {
        if (g_cap_mi && g_cap_static && g_cap_argc == 0) {
            pfp_log("money: Cap is a static getter (argc=0) — "
                    "set cap_force=1 to install methodPointer hook");
        } else if (!g_cap_mi && !g_set_cap_mi && !g_fits_mi) {
            pfp_log("money: no recognisable setter/getter — scope deferred");
        }
        logged_once = 1;
    }

    // v2.1: if the fixed-ABI set_Cap branch ever resolves on a future build,
    // invoke it throttled to 60s. On current build this is dormant.
    if (g_set_cap_mi && g_set_cap_static && g_set_cap_argc == 1) {
        if (tick_count == 1 || (tick_count % 600) == 0) {
            int64_t huge = 1000000000LL;
            int ok = 1;
            pfp_il2cpp_invoke1(g_set_cap_mi, NULL, &huge, &ok);
            if (ok) {
                pfp_log("money: set_Cap(1e9) invoked ok (tick=%d)", tick_count);
                return 1;
            } else {
                pfp_log("money: set_Cap(1e9) threw, giving up this cycle");
            }
        }
    }
    return 0;
}

PfpFeature pfp_feature_money = { "money", init, tick, 0, 0, 0, 0 };
