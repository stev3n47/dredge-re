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

static Il2CppClass *g_rules = NULL;
static Il2CppClass *g_sim   = NULL;

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
    return 0;  // read-only diagnostic — no per-tick work
}

PfpFeature pfp_feature_fumbles = { "fumbles", init, tick, 0, 0, 0, 0 };
