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

#include <stddef.h>

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
    return 0;
}

static int tick(void) {
    // Pure diagnostic — nothing happens per tick in v2a. v2b will swap
    // methodPointer on selected targets after the PAC probe passes.
    return 0;
}

PfpFeature pfp_feature_tackle = { "tackle", init, tick, 0, 0, 0, 0 };
