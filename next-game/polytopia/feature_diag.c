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

static void dump(const char *name) {
    Il2CppClass *k = stp_il2cpp_find_class("PolytopiaAssembly.dll", NULL, name);
    if (!k) k = stp_il2cpp_find_class(NULL, NULL, name);
    if (!k) {
        stp_log("diag: %s class NOT FOUND", name);
        return;
    }
    stp_log("diag: %s class=%p method_count=%d", name, (void *)k,
            stp_il2cpp_count_methods(k));
    stp_diag_log_methods("diag", k, NULL, 0);
}

static int diag_init(void) {
    if (g_dumped) return 0;
    dump("PurchaseManager");
    dump("PlayerState");
    g_dumped = 1;
    return 0;
}

static int diag_tick(void) { return 0; }

StpFeature stp_feature_diag = {
    "diag", diag_init, diag_tick, 0, 0, 0, 0, NULL, 0
};
