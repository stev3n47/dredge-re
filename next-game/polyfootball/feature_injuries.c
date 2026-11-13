// feature_injuries.c — v2a diagnostic probe for injury-related classes.
//
// Scope: resolve each candidate class by name in Assembly-CSharp.dll, dump
// the names/flags/arg-count of its injury-relevant methods, then do ONE
// heap walk to find any live instances. All operations are read-only; no
// methodPointer swaps, no field writes.
//
// The dispatcher calls tick() every 100 ms but this feature does its work
// once in init() and tick() is a no-op — nothing changes on subsequent
// ticks and we don't want to re-log every frame.

#include "features.h"
#include "pac_swap.h"
#include <stddef.h>

static int g_injuries_hooks_installed = 0;

// Candidate class names per PLAN.md Tier 2 injuries section. We don't
// fail init if a sub-class is missing — any resolved class is useful
// diagnostic data for v2b planning.
static const char *K_CLASSES[] = {
    "FootballTackleInjuries",   // type 2663, m19618-m19623
    "InjuryCatalog",            // type 3495, m24434-m24459
    "CareerInjuryRecovery",
    "FranchiseInjuryCare",
    "CareerInjuryDecision",
    "CpuDriveInjury",
    "FranchiseInjuryRules",
};
static const int K_CLASS_COUNT = (int)(sizeof(K_CLASSES) / sizeof(K_CLASSES[0]));

// Substrings to filter method names when dumping — covers roll / mark /
// chance / stays-down / aggravation / injury / recovery / rehab.
static const char *METHOD_SUBSTRS[] = {
    "Roll",
    "Mark",
    "StaysDown",
    "Chance",
    "Aggravation",
    "Injury",
    "Recovery",
    "Rehab",
};
static const int METHOD_SUBSTR_COUNT =
    (int)(sizeof(METHOD_SUBSTRS) / sizeof(METHOD_SUBSTRS[0]));

static int init(void) {
    Il2CppClass *resolved[16];
    int resolved_n = 0;

    for (int i = 0; i < K_CLASS_COUNT && resolved_n < 16; i++) {
        Il2CppClass *k = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL,
                                               K_CLASSES[i]);
        if (!k) {
            // Fall back to a cross-image lookup; some builds re-namespace.
            k = pfp_il2cpp_find_class(NULL, NULL, K_CLASSES[i]);
        }
        if (k) {
            pfp_log("injuries: resolved %s @ %p", K_CLASSES[i], (void *)k);
            resolved[resolved_n++] = k;
        } else {
            pfp_log("injuries: NOT FOUND %s", K_CLASSES[i]);
        }
    }

    if (resolved_n == 0) {
        pfp_log("injuries: no candidate classes resolved — disabling feature");
        return -1;
    }

    // Dump filtered method sets for each resolved class.
    for (int i = 0; i < resolved_n; i++) {
        pfp_diag_log_methods("injuries", resolved[i],
                             METHOD_SUBSTRS, METHOD_SUBSTR_COUNT);
    }

    // One heap walk across the whole resolved-class whitelist. Logs class
    // name + instance pointer post-walk (safe — we pass pre-resolved class
    // pointers from image metadata, not heap-derived klass pointers).
    pfp_diag_log_live_instances("injuries", resolved, resolved_n);

    // v2.1: register all resolved injury classes for periodic rewalk.
    for (int i = 0; i < resolved_n; i++) pfp_register_rewalk("injuries", resolved[i]);
    return 0;
}

static int tick(void) {
    if (g_injuries_hooks_installed) return 0;
    if (!pfp_cfg_bool("injuries_force", 0)) return 0;
    int installed = 0;
    void *tzf = (void *)pfp_tramp_zero_float;
    void *tzi = (void *)pfp_tramp_zero_int;
    const char *img = "Assembly-CSharp.dll";

    // AggravationChance exists on multiple classes; all return float.
    Il2CppClass *k;
    const MethodInfo *m;
    k = pfp_il2cpp_find_class(img, NULL, "InjuryCatalog");
    if (k) {
        m = pfp_il2cpp_find_method(k, "AggravationChance", 2);
        if (m && pfp_pac_hook_install(m, tzf, "injuries.InjuryCatalog.AggravationChance")) installed++;
    }
    k = pfp_il2cpp_find_class(img, NULL, "FranchiseInjuryCare");
    if (k) {
        m = pfp_il2cpp_find_method(k, "AggravationChance", 1);
        if (m && pfp_pac_hook_install(m, tzf, "injuries.FranchiseInjuryCare.AggravationChance")) installed++;
    }
    k = pfp_il2cpp_find_class(img, NULL, "CareerInjuryDecision");
    if (k) {
        m = pfp_il2cpp_find_method(k, "AggravationChance", 1);
        if (m && pfp_pac_hook_install(m, tzf, "injuries.CareerInjuryDecision.AggravationChance")) installed++;
    }
    // StaysDown(args) → bool: return false (0 in x0) so tackled players
    // get back up. Keeps roster healthy in-game.
    k = pfp_il2cpp_find_class(img, NULL, "FootballTackleInjuries");
    if (k) {
        m = pfp_il2cpp_find_method(k, "StaysDown", 3);
        if (m && pfp_pac_hook_install(m, tzi, "injuries.StaysDown")) installed++;
    }

    g_injuries_hooks_installed = 1;
    pfp_log("injuries: installed %d methodPointer hook(s) — injury chances suppressed, tackled players stay up", installed);
    return installed > 0 ? 1 : 0;
}

PfpFeature pfp_feature_injuries = { "injuries", init, tick, 0, 0, 0, 0 };
