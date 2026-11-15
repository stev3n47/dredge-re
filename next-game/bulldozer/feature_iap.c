// feature_iap.c — free IAP via InAppShopManager owned-flag hooks.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.InAppShop.InAppShopManager
// (TypeDefIndex 1714, SingletonBehaviourBase, sealed).
//
//   IsPurchased(product)              -> bool  [hooked -> true]
//   IsValidProduct(product)           -> bool  [hooked -> true]
//   IsProductAvailable(product)       -> bool  [hooked -> true]
//   IsPurchaseLimitAvailable(product) -> bool  [hooked -> true]
//   GetRemainingPurchaseCount(product)-> int   [hooked -> 999,999,999]
//
// Effect: the shop treats every product as owned/valid/unlimited. For
// one-time unlock products (NoAds pack, ad-skip ticket, permanent boosts)
// this IS the unlock. For consumable packs the "already owned" state may
// hide the buy button — those still work through the normal purchase
// flow, which we do not intercept (TryPurchase/PurchaseProcess are left
// alone so StoreKit receipts stay honest).
//
// All targets are non-virtual instance methods on a sealed class.
// v1.1: bd_hook_bool_true / bd_hook_int_imm inline-patch the generated
// code (mov w0,#1;ret / movz+movk+ret) so direct call sites are caught;
// methodPointer swap is the automatic fallback.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_is_purchased, *g_is_valid, *g_is_avail, *g_is_limit;
static const MethodInfo *g_remaining;
static int g_installed = 0;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.InAppShop", "InAppShopManager");
    if (!g_klass) {
        bd_log("iap: InAppShopManager class not found");
        return -1;
    }
    int mc = bd_il2cpp_count_methods(g_klass);
    g_is_purchased = bd_il2cpp_find_method(g_klass, "IsPurchased", 1);
    g_is_valid     = bd_il2cpp_find_method(g_klass, "IsValidProduct", 1);
    g_is_avail     = bd_il2cpp_find_method(g_klass, "IsProductAvailable", 1);
    g_is_limit     = bd_il2cpp_find_method(g_klass, "IsPurchaseLimitAvailable", 1);
    g_remaining    = bd_il2cpp_find_method(g_klass, "GetRemainingPurchaseCount", 1);
    bd_log("iap: InAppShopManager class=%p method_count=%d (catalog expects 26)",
           g_klass, mc);
    bd_log("iap: IsPurchased=%p IsValidProduct=%p IsProductAvailable=%p "
           "IsPurchaseLimitAvailable=%p GetRemainingPurchaseCount=%p",
           (void *)g_is_purchased, (void *)g_is_valid, (void *)g_is_avail,
           (void *)g_is_limit, (void *)g_remaining);
    if (!g_is_purchased && !g_is_valid && !g_is_avail && !g_is_limit) {
        bd_log("iap: no query methods resolved — disabling");
        return -1;
    }
    bd_register_rewalk("iap", g_klass);
    return 0;
}

static int tick(void) {
    // Feature key IS "free_iap".
    if (g_installed) return 0;
    int n = 0;
    if (g_is_purchased) n += bd_hook_bool_true(g_is_purchased, "iap.IsPurchased");
    if (g_is_valid)     n += bd_hook_bool_true(g_is_valid,     "iap.IsValidProduct");
    if (g_is_avail)     n += bd_hook_bool_true(g_is_avail,     "iap.IsProductAvailable");
    if (g_is_limit)     n += bd_hook_bool_true(g_is_limit,     "iap.IsPurchaseLimitAvailable");
    if (g_remaining)    n += bd_hook_int_imm(g_remaining, 999999999u, "iap.GetRemainingPurchaseCount");
    g_installed = 1;
    bd_log("iap: installed %d hook(s) — all products owned/valid/unlimited", n);
    return n > 0 ? 1 : 0;
}

BdFeature bd_feature_iap = { "free_iap", init, tick, 0, 0, 0, 0, NULL, 0 };
