// feature_money.c — CurrencyManager money: obtain drip + balance pin.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.Currency.CurrencyManager
// (TypeDefIndex 1848, all-static API per dump.cs):
//   Obtain_WithoutFX(ECurrency, int, ECurrencyObtain)   void
//   GetAmount(ECurrency) -> int                        [static]
//   SetAmount(ECurrency, int)                          [static]
//   DEV_ShowMeTheMoreMoney()                           [static, dev cheat]
//
// ECurrency: Unknown=0, Money=1. ECurrencyObtain.Unknown=0.
//
// v1.2 changes after on-device log showed Obtain "ok" but no visible
// balance change:
//   - GetAmount is invoked after every obtain/set and the value logged —
//     proves whether the wallet actually moved (diagnostic for the next
//     log pull).
//   - `money` toggle now ALSO pins the balance: every ~10s
//     SetAmount(Money, 2_000_000_000). Spends drain it but the pin
//     restores it — effectively infinite money, and CheckSpendable
//     passes naturally so spend_free becomes belt-and-suspenders.
//   - `money_grant` action: GetAmount -> SetAmount(+10M) so the bump is
//     a real delta on top of whatever the balance currently is.
//   - DEV_ShowMeTheMoreMoney is resolved as a fallback grant path (the
//     devs' own cheat — if it moves the balance, the wallet seam is
//     confirmed live).
//
// The feature key is "money_mod" (not a cfg field) so the tick always
// runs — the one-shot grant must work even when the drip toggle is off.

#include "features.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_obtain_mi = NULL;   // Obtain_WithoutFX, 3 args
static const MethodInfo *g_get_mi    = NULL;   // GetAmount, 1 arg
static const MethodInfo *g_set_mi    = NULL;   // SetAmount, 2 args
static const MethodInfo *g_dev_mi    = NULL;   // DEV_ShowMeTheMoreMoney, 0 args

static int tick_count = 0;

static int32_t wallet_amount(void) {
    if (!g_get_mi) return -1;
    int32_t cur = 1;
    void *args[1] = { &cur };
    int ok = 1;
    Il2CppObject *r = bd_il2cpp_invoke(g_get_mi, NULL, args, &ok);
    if (!ok || !r) return -1;
    return bd_unbox_i32(r);
}

static void wallet_set(int32_t amount) {
    if (!g_set_mi) return;
    int32_t cur = 1;
    void *args[2] = { &cur, &amount };
    int ok = 1;
    bd_il2cpp_invoke(g_set_mi, NULL, args, &ok);
    if (!ok) bd_log("money: SetAmount threw");
}

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
    if (!g_obtain_mi) {
        g_obtain_mi = bd_il2cpp_find_method(g_klass, "Obtain", 4);
        if (!g_obtain_mi) g_obtain_mi = bd_il2cpp_find_method(g_klass, "Obtain", 3);
        bd_log("money: Obtain_WithoutFX unresolved — using Obtain fallback");
    }
    g_get_mi = bd_il2cpp_find_method(g_klass, "GetAmount", 1);
    g_set_mi = bd_il2cpp_find_method(g_klass, "SetAmount", 2);
    g_dev_mi = bd_il2cpp_find_method(g_klass, "DEV_ShowMeTheMoreMoney", 0);
    bd_log("money: Obtain=%p GetAmount=%p SetAmount=%p DevMoreMoney=%p",
           (void *)g_obtain_mi, (void *)g_get_mi, (void *)g_set_mi,
           (void *)g_dev_mi);

    if (!g_obtain_mi && !g_set_mi && !g_dev_mi) {
        bd_log("money: no wallet methods resolved — disabling");
        return -1;
    }
    return 0;
}

static int fire_obtain(int32_t amount, const char *why) {
    int32_t before = wallet_amount();
    int32_t cur = 1;    // ECurrency.Money
    int32_t amt = amount;
    int32_t zero = 0;   // fxCount / obtainType — both 0, order irrelevant
    // 4-slot array covers Obtain_WithoutFX(ECurrency,int,ECurrencyObtain)
    // AND Obtain(ECurrency,int,int,ECurrencyObtain): trailing slots are
    // ignored by the 3-param form, and both extra params are 0 anyway.
    void *args[4] = { &cur, &amt, &zero, &zero };
    int ok = 1;
    bd_il2cpp_invoke(g_obtain_mi, NULL, args, &ok);
    if (!ok) {
        bd_log("money: Obtain threw (%s)", why);
        return 0;
    }
    int32_t after = wallet_amount();
    bd_log("money: Obtain(+%d) %s — balance %d -> %d", amount, why, before, after);
    return 1;
}

static int fire_pin(void) {
    int32_t before = wallet_amount();
    wallet_set(2000000000);
    int32_t after = wallet_amount();
    bd_log("money: pin SetAmount(2e9) — balance %d -> %d", before, after);
    return after > 1000000000 ? 1 : 0;
}

static int fire_grant(void) {
    int32_t cur_bal = wallet_amount();
    if (cur_bal >= 0 && g_set_mi) {
        wallet_set(cur_bal + 10000000);
        int32_t after = wallet_amount();
        bd_log("money: grant +10M via SetAmount — balance %d -> %d", cur_bal, after);
        return 1;
    }
    if (g_dev_mi) {
        int ok = 1;
        bd_il2cpp_invoke0(g_dev_mi, NULL, &ok);
        int32_t after = wallet_amount();
        bd_log("money: grant via DEV_ShowMeTheMoreMoney ok=%d — balance -> %d", ok, after);
        return ok ? 1 : 0;
    }
    return fire_obtain(10000000, "grant");
}

static int tick(void) {
    tick_count++;

    // Action key: one-shot +10M grant.
    if (bd_cfg_bool("money_grant", 0)) {
        bd_cfg_set_bool("money_grant", 0);
        if (fire_grant()) return 1;
    }

    if (!bd_cfg_bool("money", 0)) return 0;

    // Drip: +1M every ~5s.
    if ((tick_count % 50) == 0) {
        if (g_obtain_mi && fire_obtain(1000000, "drip")) return 1;
    }
    // Pin: SetAmount(2e9) every ~10s — survives even if Obtain is a no-op.
    if ((tick_count % 100) == 0) {
        if (g_set_mi && fire_pin()) return 1;
    }
    return 0;
}

BdFeature bd_feature_money = { "money_mod", init, tick, 0, 0, 0, 0, NULL, 0 };
