// feature_fumbles.c — v2a diagnostic probe for No Fumbles.
//
// Scope: READ-ONLY. Resolve FootballFumbleRules (type 2424, m17789-m17798)
// and FootballFumbleSim (type 2427, m17799-m17819) in Assembly-CSharp.dll;
// enumerate their roll/chance-adjacent methods with static/arity flags;
// list live instances on the heap (ScriptableObject-backed rules asset
// should appear once the game has loaded it).
//
// No invokes, no patches — this surface is what the plan will later swap
// via methodPointer behind an on-device PAC probe. We just gather data.

#include "features.h"
#include "pac_swap.h"

static Il2CppClass *g_rules = NULL;
static Il2CppClass *g_sim   = NULL;
static int g_hooks_installed = 0;

static int init(void) {
    g_rules = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballFumbleRules");
    g_sim   = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballFumbleSim");
    if (!g_rules && !g_sim) {
        pfp_log("fumbles: neither FootballFumbleRules nor FootballFumbleSim found — disabled");
        return -1;
    }
    if (g_rules) {
        int n = pfp_il2cpp_count_methods(g_rules);
        pfp_log("fumbles: FootballFumbleRules class=%p method_count=%d (catalog 10)", (void *)g_rules, n);
    } else {
        pfp_log("fumbles: FootballFumbleRules NOT FOUND");
    }
    if (g_sim) {
        int n = pfp_il2cpp_count_methods(g_sim);
        pfp_log("fumbles: FootballFumbleSim class=%p method_count=%d (catalog 21)", (void *)g_sim, n);
    } else {
        pfp_log("fumbles: FootballFumbleSim NOT FOUND");
    }

    static const char *substrs[] = {
        "Chance", "Roll", "Punch", "DriveChance", "DriveRoll",
        "PerTackle", "Fumble", "ExpectedPerTackle",
    };
    static const int substr_count = (int)(sizeof(substrs) / sizeof(substrs[0]));

    if (g_rules) pfp_diag_log_methods("fumbles", g_rules, substrs, substr_count);
    if (g_sim)   pfp_diag_log_methods("fumbles", g_sim,   substrs, substr_count);

    Il2CppClass *classes[2];
    int n_classes = 0;
    if (g_rules) classes[n_classes++] = g_rules;
    if (g_sim)   classes[n_classes++] = g_sim;
    if (n_classes > 0) {
        (void)pfp_diag_log_live_instances("fumbles", classes, n_classes);
    }
    // v2.1: register for periodic rewalk — SO-backed rules usually load
    // when a match starts, not at app boot.
    pfp_register_rewalk("fumbles", g_rules);
    pfp_register_rewalk("fumbles", g_sim);
    return 0;
}

static int tick(void) {
    // v2.2.1: if fumbles_force=1 in pfplus.json, install methodPointer
    // trampolines on the chance/roll methods of FootballFumbleRules and
    // FootballFumbleSim so every fumble roll returns 0.0. One-shot: once
    // hooks install we set g_hooks_installed and the tick returns 0.
    if (g_hooks_installed) return 0;
    if (!pfp_cfg_bool("fumbles_force", 0)) return 0;
    if (pfp_cfg_bool("mp_safe", 0)) {
        static int warned = 0;
        if (!warned) { pfp_log("fumbles: mp_safe=1 — install gated"); warned = 1; }
        return 0;
    }
    if (!g_rules && !g_sim) return 0;

    int installed = 0;
    void *tz = (void *)pfp_tramp_zero_float;
    if (g_rules) {
        const MethodInfo *m;
        m = pfp_il2cpp_find_method(g_rules, "Chance", 1);
        if (m && pfp_pac_hook_install(m, tz, "fumbles.Chance")) installed++;
        m = pfp_il2cpp_find_method(g_rules, "PunchTryChance", 1);
        if (m && pfp_pac_hook_install(m, tz, "fumbles.PunchTryChance")) installed++;
        m = pfp_il2cpp_find_method(g_rules, "ExpectedPerTackle", 3);
        if (m && pfp_pac_hook_install(m, tz, "fumbles.ExpectedPerTackle")) installed++;
    }
    if (g_sim) {
        const MethodInfo *m;
        m = pfp_il2cpp_find_method(g_sim, "DriveChance", 4);
        if (m && pfp_pac_hook_install(m, tz, "fumbles.DriveChance")) installed++;
        m = pfp_il2cpp_find_method(g_sim, "PerTackle", 4);
        if (m && pfp_pac_hook_install(m, tz, "fumbles.PerTackle")) installed++;
    }

    g_hooks_installed = 1;
    pfp_log("fumbles: installed %d methodPointer hook(s) — fumble chance should now be zero", installed);
    return (installed > 0) ? 1 : 0;
}

PfpFeature pfp_feature_fumbles = { "fumbles", init, tick, 0, 0, 0, 0 };
