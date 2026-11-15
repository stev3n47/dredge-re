// feature_spend.c — free purchases via CheckSpendable/TrySpend -> true.
//
// Target: same CurrencyManager as feature_money.
//   CheckSpendable(ECurrency, int) -> bool       [static, 2 args]
//   TrySpend(ECurrency, int, ECurrencySpend) -> bool  [static, 3 args]
//
// TrySpend IS the deduction path: returning true without running the body
// means the purchase "succeeds" and the balance is never touched. Callers
// that gate UI on CheckSpendable see affordable; callers that commit via
// TrySpend get a free grant downstream.
//
// Hooking (v1.1): bd_hook_bool_true patches the generated code at the
// methodPointer address (`mov w0,#1; ret`) so EVERY call path — direct
// call, vtable, runtime_invoke, delegates — reports success. Falls back
// to a methodPointer swap (runtime_invoke/delegate paths only) if the
// text write is refused.
//
// NOTE: swaps are one-way for the session (no un-swap path). Turning
// spend_free off in the menu prevents RE-install but does not restore the
// originals — same caveat as PFPlus force flags.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_check_mi = NULL;
static const MethodInfo *g_try_mi   = NULL;
static int g_installed = 0;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.Currency", "CurrencyManager");
    if (!g_klass) {
        bd_log("spend: CurrencyManager class not found");
        return -1;
    }
    g_check_mi = bd_il2cpp_find_method(g_klass, "CheckSpendable", 2);
    g_try_mi   = bd_il2cpp_find_method(g_klass, "TrySpend", 3);
    if (!g_check_mi && !g_try_mi) {
        bd_log("spend: neither CheckSpendable(2) nor TrySpend(3) resolved — disabling");
        return -1;
    }
    bd_log("spend: CheckSpendable=%p TrySpend=%p",
           (void *)g_check_mi, (void *)g_try_mi);
    return 0;
}

static int tick(void) {
    // Feature key IS "spend_free" — dispatcher only calls tick while on.
    if (g_installed) return 0;
    int n = 0;
    if (g_check_mi) {
        n += bd_hook_bool_true(g_check_mi, "spend.CheckSpendable");
    }
    if (g_try_mi) {
        n += bd_hook_bool_true(g_try_mi, "spend.TrySpend");
    }
    g_installed = 1;
    bd_log("spend: installed %d hook(s) — all spends report success, balance untouched", n);
    return n > 0 ? 1 : 0;
}

BdFeature bd_feature_spend = { "spend_free", init, tick, 0, 0, 0, 0, NULL, 0 };
