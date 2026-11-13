// feature_catch — v2a diagnostic probe for Magnet Hands target classes.
//
// Resolves the three catch-pipeline classes named in PLAN.md, dumps their
// catch-relevant methods (name, static bit, argc), and heap-walks for
// live instances. Pure read-only logging; no invokes, no patches. The
// output tells us (a) whether the method names in the plan actually
// resolve on this build, (b) whether they're static or instance, and
// (c) whether the config SOs exist on the live heap so a v2b patcher
// can find them.
//
// All class pointers come from image metadata (safe). The heap walk
// obeys the SPPlus v33+ rule: callback only reads obj->klass and does
// pointer equality against pre-resolved whitelist classes.

#include "features.h"

#include <stddef.h>

static Il2CppClass *g_reach  = NULL;
static Il2CppClass *g_style  = NULL;
static Il2CppClass *g_rules  = NULL;

static int init(void) {
    g_reach = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballCatchReach");
    g_style = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballCatchStyle");
    g_rules = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "CareerWrCatchRules");

    pfp_log("catch: FootballCatchReach=%p FootballCatchStyle=%p CareerWrCatchRules=%p",
            (void *)g_reach, (void *)g_style, (void *)g_rules);

    static const char *subs[] = {
        "TrySolve", "Confidence", "InFront", "RollState", "Rng", "Chance", "Catch"
    };
    static const int n_subs = (int)(sizeof(subs) / sizeof(subs[0]));

    if (g_reach) pfp_diag_log_methods("catch", g_reach, subs, n_subs);
    if (g_style) pfp_diag_log_methods("catch", g_style, subs, n_subs);
    if (g_rules) pfp_diag_log_methods("catch", g_rules, subs, n_subs);

    Il2CppClass *targets[3];
    int nt = 0;
    if (g_reach) targets[nt++] = g_reach;
    if (g_style) targets[nt++] = g_style;
    if (g_rules) targets[nt++] = g_rules;

    if (nt > 0) {
        pfp_diag_log_live_instances("catch", targets, nt);
    } else {
        pfp_log("catch: no target classes resolved — nothing to walk");
    }

    // v2.1: register resolved catch classes for periodic rewalk.
    pfp_register_rewalk("catch", g_reach);
    pfp_register_rewalk("catch", g_style);
    pfp_register_rewalk("catch", g_rules);
    // Diagnostic succeeded regardless of partial misses — still useful.
    return 0;
}

static int tick(void) {
    // Pure diagnostic: all work happens in init(). No per-tick behaviour.
    return 0;
}

PfpFeature pfp_feature_catch = { "catch", init, tick, 0, 0, 0, 0 };
