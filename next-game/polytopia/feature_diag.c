// feature_diag.c — STPlus v1 boot diagnostic.
//
// Dumps every method on the two hook-target classes (PurchaseManager,
// PlayerState) to stplus.log once per session. Purpose:
//   - proves the class + MethodInfo resolution actually works on this build
//   - shows argc/static flags so wrong hook targets surface immediately
//   - gives the method inventory needed for Tier-2 planning (tech, actions)
//
// Read-only: enumerates image metadata only, no heap walk, no invokes.

#include "features.h"

static int g_dumped = 0;

static void dump(const char *image, const char *name) {
    Il2CppClass *k = stp_il2cpp_find_class(image, NULL, name);
    if (!k) k = stp_il2cpp_find_class(NULL, NULL, name);
    if (!k) {
        stp_log("diag: %s class NOT FOUND", name);
        return;
    }
    stp_log("diag: %s class=%p method_count=%d", name, (void *)k,
            stp_il2cpp_count_methods(k));
    stp_diag_log_methods("diag", k, NULL, 0);
}

// v1.0.2 — dump only the methods matching `substrs` (big classes like
// GameManager have 112 methods; the full dump truncates at 32). Used to
// surface the GameManager -> GameState -> local-PlayerState navigation
// accessors needed to build the invoke-based stars feature (STPLUS-REVIEW.md).
static void dump_filtered(const char *image, const char *name,
                          const char **substrs, int nsub) {
    Il2CppClass *k = stp_il2cpp_find_class(image, NULL, name);
    if (!k) k = stp_il2cpp_find_class(NULL, NULL, name);
    if (!k) {
        stp_log("diag: %s class NOT FOUND", name);
        return;
    }
    stp_log("diag: %s class=%p method_count=%d (filtered)", name, (void *)k,
            stp_il2cpp_count_methods(k));
    stp_diag_log_methods("diag", k, substrs, nsub);
}

static int diag_init(void) {
    if (g_dumped) return 0;
    dump("PolytopiaAssembly.dll", "PurchaseManager");
    dump("PolytopiaAssembly.dll", "UnityPlatformPurchaseManager");
    dump("GameLogicAssembly.dll", "PlayerState");

    // v1.0.2 — navigation accessors for the stars rework. We need a path
    // from a singleton to the live local PlayerState so feature_stars.c can
    // invoke set_Currency on it (not the AI). Dump the likely entry points.
    static const char *nav[] = {
        "Instance", "Client", "Game", "State", "Player",
        "Current", "Local", "Active", "Session",
    };
    const int nnav = (int)(sizeof(nav) / sizeof(nav[0]));
    dump_filtered("PolytopiaAssembly.dll", "GameManager", nav, nnav);
    dump_filtered("PolytopiaAssembly.dll", "ClientBase",  nav, nnav);
    dump_filtered("GameLogicAssembly.dll", "GameState",   nav, nnav);

    g_dumped = 1;
    return 0;
}

static int diag_tick(void) { return 0; }

StpFeature stp_feature_diag = {
    "diag", diag_init, diag_tick, 0, 0, 0, 0, NULL, 0
};
