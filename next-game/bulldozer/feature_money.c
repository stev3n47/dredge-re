// feature_money.c — CurrencyManager money drip + one-shot grant.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.Currency.CurrencyManager
// (TypeDefIndex 1848, all-static API per dump.cs):
//   Obtain_WithoutFX(ECurrency currencyType, int added, ECurrencyObtain obtainType)
//   GetAmount(ECurrency) -> int
//   CheckSpendable(ECurrency, int) -> bool      [hooked by feature_spend]
//   TrySpend(ECurrency, int, ECurrencySpend) -> bool  [hooked by feature_spend]
//
// ECurrency: Unknown=0, Money=1. ECurrencyObtain.Unknown=0.
//
// `money` toggle: every ~5s invoke Obtain_WithoutFX(Money, +1_000_000, 0).
// Pure poll-and-invoke, no hooks — HUD/currency-changed events fire
// normally because we call the real Obtain path.
//
// `money_grant` action key: menu button sets it to 1; next tick invokes
// Obtain_WithoutFX(Money, +10_000_000, 0) once and resets the key.
//
// The feature key is "money_mod" (not a cfg field) so the tick always
// runs — the one-shot grant must work even when the drip toggle is off.

#include "features.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_obtain_mi = NULL;   // Obtain_WithoutFX, 3 args
static const MethodInfo *g_get_mi    = NULL;   // GetAmount, 1 arg (log only)

static int tick_count = 0;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.Currency", "CurrencyManager");
    if (!g_klass) {
        bd_log("money: CurrencyManager class not found");
        return -1;
    }
    int mc = bd_il2cpp_count_methods(g_klass);
    bd_log("money: CurrencyManager class=%p method_count=%d (catalog expects 64)",
           g_klass, mc);

    g_obtain_mi = bd_il2cpp_find_method(g_klass, "Obtain_WithoutFX", 3);
    g_get_mi    = bd_il2cpp_find_method(g_klass, "GetAmount", 1);
    if (!g_obtain_mi) {
        // Fallback: plain Obtain (plays FX) if WithoutFX is absent.
        g_obtain_mi = bd_il2cpp_find_method(g_klass, "Obtain", 3);
        bd_log("money: Obtain_WithoutFX unresolved — using Obtain(3)");
    }
    bd_log("money: Obtain=%p GetAmount=%p", (void *)g_obtain_mi, (void *)g_get_mi);

    if (!g_obtain_mi) {
        bd_log("money: no Obtain method resolved — disabling");
        return -1;
    }
    return 0;
}

static int fire_obtain(int32_t amount, const char *why) {
    int32_t cur = 1;    // ECurrency.Money
    int32_t obt = 0;    // ECurrencyObtain.Unknown
    void *args[3] = { &cur, &amount, &obt };
    int ok = 1;
    bd_il2cpp_invoke(g_obtain_mi, NULL, args, &ok);
    if (ok) {
        bd_log("money: Obtain_WithoutFX(Money,+%d) ok (%s)", amount, why);
        return 1;
    }
    bd_log("money: Obtain_WithoutFX threw (%s)", why);
    return 0;
}

static int tick(void) {
    tick_count++;

    // Action key: one-shot +10M grant.
    if (bd_cfg_bool("money_grant", 0)) {
        bd_cfg_set_bool("money_grant", 0);
        if (fire_obtain(10000000, "grant")) return 1;
    }

    // Drip: +1M every ~5s while `money` is on (checked here because the
    // feature key is a sentinel, not the cfg field).
    if (bd_cfg_bool("money", 0) && (tick_count % 50) == 0) {
        if (fire_obtain(1000000, "drip")) return 1;
    }
    return 0;
}

BdFeature bd_feature_money = { "money_mod", init, tick, 0, 0, 0, 0, NULL, 0 };
