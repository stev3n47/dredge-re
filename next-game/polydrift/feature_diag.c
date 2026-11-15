// feature_diag.c — PDPlus v1 boot diagnostic (PolyDrift2).
//
// Scans every loaded image for classes whose names contain any of the
// feature keywords (unlock / vehicle / currency / ads / boost / save /
// purchase) and dumps each class's methods with static-bit + argc to
// pdplus.log. This is the discovery payload: the first device log tells
// us the exact declaring classes, signatures and static-ness needed for
// the invoke-writer paths in feature_unlocks.c.
//
// Read-only: image metadata only, no heap walk, no invokes.

#include "features.h"

static int g_dumped = 0;

static const char *CLASS_SUBSTRS[] = {
    "Unlock", "Vehicle", "Coin", "Gold", "Wallet", "Currency",
    "Admob", "AdManager", "Ads", "Boost", "Speed", "Nitro",
    "Fuel", "Save", "PlayerData", "Purchase", "Premium",
    "Upgrade", "Tuning", "Drift", "Progress", "Seasonal",
    "Garage", "Inventory", "Shop",
};

static int diag_init(void) {
    if (g_dumped) return 0;

    Il2CppClass *cls[128];
    int n = pdp_find_classes_by_name(CLASS_SUBSTRS,
                                     (int)(sizeof(CLASS_SUBSTRS)/sizeof(CLASS_SUBSTRS[0])),
                                     cls, 128);
    pdp_log("diag: class scan matched %d classes", n);
    for (int i = 0; i < n; i++) {
        const char *nm = pdp_il2cpp_class_get_name
            ? pdp_il2cpp_class_get_name(cls[i]) : "?";
        const char *ns = pdp_il2cpp_class_get_namespace
            ? pdp_il2cpp_class_get_namespace(cls[i]) : "";
        pdp_log("diag: class=%s ns=%s ptr=%p methods=%d", nm, ns,
                (void *)cls[i], pdp_il2cpp_count_methods(cls[i]));
        pdp_diag_log_methods("diag", cls[i], NULL, 0);
    }
    g_dumped = 1;
    return 0;
}

static int diag_tick(void) { return 0; }

PdpFeature pdp_feature_diag = {
    "diag", diag_init, diag_tick, 0, 0, 0, 0, NULL, 0
};
