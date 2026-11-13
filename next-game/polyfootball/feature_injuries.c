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
#include <stddef.h>

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
    // Diagnostic-only; no per-tick work. init() ran once and logged all
    // findings. Returning 0 keeps the fires counter at 0 so the status
    // line shows `injuries=0i` (initialised, no fires), which is correct.
    return 0;
}

PfpFeature pfp_feature_injuries = { "injuries", init, tick, 0, 0, 0, 0 };
