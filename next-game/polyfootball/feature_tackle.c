// feature_tackle.c — v2a diagnostic for Never Tackled targets.
//
// Scope: READ-ONLY. Resolves the Tier 2 tackle/locomotion classes from
// Assembly-CSharp metadata, dumps interesting method names (with static
// bit + argc) via pfp_diag_log_methods, and performs one heap walk to log
// any live instances. Does NOT patch or invoke anything.
//
// Rationale per PLAN.md Tier 2 "Never Tackled":
//   FootballCarrierMoveRules.{BreakChance, ShoveChance, AnkleBreakChance,
//     SpinEscapeChance}  — single-scalar rolls, candidate methodPointer-swap
//     targets once the PAC probe lands in v2b.
//   FootballTackleStyle.Pick  — picks tackle style vs our carrier.
//   CarrierMoveControls, FootballJoystickLocomotion, FootballDefenseSpeeds
//     — speed scalars for Super Speed; share this diagnostic since they
//     cluster with the carrier move pipeline.
//
// The diagnostic output lets us (a) confirm the catalog names still
// resolve on 4.5.3, (b) see which methods are static vs instance to pick
// an invoke-vs-patch strategy, and (c) see whether any of these classes
// have live instances during a running match (vs being pure utility
// types whose rolls happen on stack-allocated structs).

#include "features.h"
#include "pac_swap.h"

#include <stddef.h>

static int g_tackle_hooks_installed = 0;
static const char *k_image = "Assembly-CSharp.dll";

// Classes we try to resolve. NULLs tolerated — init logs each miss and
// keeps going.
// Critic 5: the three locomotion classes (CarrierMoveControls,
// FootballJoystickLocomotion, FootballDefenseSpeeds) are owned by
// feature_speed.c. Keep tackle focused on tackle-specific classes to
// avoid duplicate heap walks and duplicate method dumps on first boot.
static const char *k_classes[] = {
    "FootballCarrierMoveRules",
    "FootballTackleStyle",
    // Locomotion classes (CarrierMoveControls, FootballJoystickLocomotion,
    // FootballDefenseSpeeds) are owned by feature_speed.c to avoid
    // duplicate heap walks and duplicate method dumps.
};
#define NUM_CLASSES (int)(sizeof(k_classes) / sizeof(k_classes[0]))

// Method-name substrings of interest for dumping flags + arity.
static const char *k_method_substrs[] = {
    "BreakChance",
    "ShoveChance",
    "AnkleBreakChance",
    "SpinEscapeChance",
    "Pick",
    "Chance",
    "Speed",
    "Scalar",
};
#define NUM_METHOD_SUBSTRS (int)(sizeof(k_method_substrs) / sizeof(k_method_substrs[0]))

static int init(void) {
    Il2CppClass *resolved[NUM_CLASSES];
    int nr = 0;
    for (int i = 0; i < NUM_CLASSES; i++) {
        Il2CppClass *k = pfp_il2cpp_find_class(k_image, NULL, k_classes[i]);
        if (!k) {
            pfp_log("tackle: class %s NOT FOUND in %s", k_classes[i], k_image);
            continue;
        }
        pfp_log("tackle: class %s @ %p", k_classes[i], (void *)k);
        resolved[nr++] = k;
        pfp_diag_log_methods("tackle", k, k_method_substrs, NUM_METHOD_SUBSTRS);
    }

    if (nr == 0) {
        pfp_log("tackle: no target classes resolved — diagnostic inactive");
        return -1;
    }

    pfp_diag_log_live_instances("tackle", resolved, nr);
    pfp_log("tackle: diagnostic complete (%d/%d classes resolved)", nr, NUM_CLASSES);

    // v2.1: register resolved classes for periodic rewalk during gameplay.
    for (int i = 0; i < nr; i++) pfp_register_rewalk("tackle", resolved[i]);
    return 0;
}

static int tick(void) {
    if (g_tackle_hooks_installed) return 0;
    if (!pfp_cfg_bool("tackle_force", 0)) return 0;
    int installed = 0;
    void *tof = (void *)pfp_tramp_one_float;
    const char *img = "Assembly-CSharp.dll";

    // FootballCarrierMoveRules: BreakChance/ShoveChance/SpinEscapeChance/
    // AnkleBreakChance all return float — higher = carrier breaks free
    // more often. Maxing them to 1.0 makes the carrier practically
    // untackleable. Overloads (argc=1 AND argc=3 for BreakChance; argc=3
    // AND argc=4 for ShoveChance) get hooked separately.
    Il2CppClass *k = pfp_il2cpp_find_class(img, NULL, "FootballCarrierMoveRules");
    if (k) {
        const MethodInfo *m;
        m = pfp_il2cpp_find_method(k, "BreakChance", 1);
        if (m && pfp_pac_hook_install(m, tof, "tackle.BreakChance[1]")) installed++;
        m = pfp_il2cpp_find_method(k, "BreakChance", 3);
        if (m && pfp_pac_hook_install(m, tof, "tackle.BreakChance[3]")) installed++;
        m = pfp_il2cpp_find_method(k, "ShoveChance", 3);
        if (m && pfp_pac_hook_install(m, tof, "tackle.ShoveChance[3]")) installed++;
        m = pfp_il2cpp_find_method(k, "ShoveChance", 4);
        if (m && pfp_pac_hook_install(m, tof, "tackle.ShoveChance[4]")) installed++;
        m = pfp_il2cpp_find_method(k, "SpinEscapeChance", 3);
        if (m && pfp_pac_hook_install(m, tof, "tackle.SpinEscapeChance")) installed++;
        m = pfp_il2cpp_find_method(k, "AnkleBreakChance", 6);
        if (m && pfp_pac_hook_install(m, tof, "tackle.AnkleBreakChance")) installed++;
    }

    g_tackle_hooks_installed = 1;
    pfp_log("tackle: installed %d methodPointer hook(s) — carrier break/shove/spin/ankle-break chances maxed to 1.0", installed);
    return installed > 0 ? 1 : 0;
}

PfpFeature pfp_feature_tackle = { "tackle", init, tick, 0, 0, 0, 0 };
