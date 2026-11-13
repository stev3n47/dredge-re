// feature_tickets — v2.8 "Unlimited Premium Tickets" (iOSGods-style setter).
//
// v2.7 diagnostic dump revealed the real ticket wallet is PremiumCurrency,
// NOT TicketWallet. PremiumCurrency has:
//   get_Balance    argc=0 [static]   ← ticket balance getter
//   set_Balance    argc=1 [static]
//   Add            argc=1 [static]
//   TrySpend       argc=1 [static]   ← the REAL deduction method
//   plus 18 other methods we'd previously only partially used for
//   Pro/Agent/Triple/Cap unlocks.
//
// TicketWallet (which we were hooking in v2.5.x) has 3 methods with
// argc=2 and was likely the GAME-ticket wallet (different currency).
// Keep those hooks too — they don't hurt and may still help the
// game-ticket spend path.
//
// v2.8 strategy (matches iOSGods' "max balance" approach):
//   - Hook PremiumCurrency.get_Balance → return huge int so every
//     balance read (UI + internal checks) sees max.
//   - Hook PremiumCurrency.TrySpend → return true unconditionally
//     so purchases succeed even if the game bypasses the getter.
//   - Keep legacy TicketWallet.TrySpend* hooks for game-ticket path.

#include "features.h"
#include "pac_swap.h"

static Il2CppClass *g_wallet = NULL;              // TicketWallet
static Il2CppClass *g_prem   = NULL;              // PremiumCurrency
static int g_hooks_installed = 0;

static int init(void) {
    g_wallet = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "TicketWallet");
    g_prem   = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "PremiumCurrency");
    if (g_wallet) {
        int mc = pfp_il2cpp_count_methods(g_wallet);
        pfp_log("tickets: TicketWallet class=%p method_count=%d (game-ticket API)",
                (void *)g_wallet, mc);
    }
    if (g_prem) {
        int mc = pfp_il2cpp_count_methods(g_prem);
        pfp_log("tickets: PremiumCurrency class=%p method_count=%d (premium-ticket balance holder)",
                (void *)g_prem, mc);
    } else {
        pfp_log("tickets: PremiumCurrency NOT FOUND — premium ticket hook disabled");
    }
    if (!g_wallet && !g_prem) return -1;

    // v2.8 — hunt the career-player cash wallet. "Unlimited Money"
    // (in the user's canonical feature list) needs a different class
    // from TeamBudget (which is cap_force). Likely names:
    static const char *cash_subs[] = {
        "CareerFinances", "CareerIncome", "PlayerFunds", "PaycheckAccount",
        "Career.*Cash", "PlayerWallet", "CareerAccount", "Paycheck",
        "Salary",       "Income",       "Earnings",     "Finances",
        "Contract",     "Bonus",
    };
    Il2CppClass *cash_hits[32];
    int cn = pfp_find_classes_by_name(cash_subs,
                                       (int)(sizeof(cash_subs) / sizeof(cash_subs[0])),
                                       cash_hits, 32);
    pfp_log("tickets: v2.8-cash-scan — %d career-cash candidate(s)", cn);
    for (int i = 0; i < cn; i++) {
        const char *kn = pfp_il2cpp_class_get_name
            ? pfp_il2cpp_class_get_name(cash_hits[i]) : NULL;
        int cmc = pfp_il2cpp_count_methods(cash_hits[i]);
        pfp_log("cash-scan: [%2d] class=%s @ %p methods=%d",
                i, kn ? kn : "?", (void *)cash_hits[i], cmc);
        pfp_diag_log_methods("cash-scan", cash_hits[i], NULL, 0);
    }

    return 0;
}

static int tick(void) {
    if (g_hooks_installed) return 0;
    if (!pfp_cfg_bool("tickets_force", 0)) return 0;
    // mp_safe shouldn't apply here — currency stores aren't gameplay-
    // roll surfaces. Server doesn't authority-check them for MP matches.

    int installed = 0;
    void *ti = (void *)pfp_tramp_one_int;
    void *huge = (void *)pfp_tramp_huge_int;

    // --- Primary: PremiumCurrency (the real premium ticket wallet) ---
    // Hook get_Balance → huge: every UI balance read + every internal
    // affordability check sees max. If TrySpend's body does
    // "if (get_Balance() >= cost) set_Balance(get_Balance() - cost)",
    // the first getter returns huge, the second getter also returns
    // huge (post-decrement would be huge-cost = still huge), so
    // persistence stays high even if Balance is a real field.
    if (g_prem) {
        const MethodInfo *m = pfp_il2cpp_find_method(g_prem, "get_Balance", 0);
        if (m && pfp_pac_hook_install(m, huge, "tickets.get_Balance")) installed++;
        // Hook TrySpend → true as insurance for any internal path that
        // bypasses the getter (direct field access).
        m = pfp_il2cpp_find_method(g_prem, "TrySpend", 1);
        if (m && pfp_pac_hook_install(m, ti, "tickets.PremiumCurrency.TrySpend")) installed++;
    }

    // --- Legacy: TicketWallet (game-ticket API, different currency) ---
    // These hooks fire for game tickets (earned via play, rewards, ads).
    if (g_wallet) {
        const MethodInfo *m = pfp_il2cpp_find_method(g_wallet, "TrySpend", 2);
        if (m && pfp_pac_hook_install(m, ti, "tickets.TicketWallet.TrySpend")) installed++;
        m = pfp_il2cpp_find_method(g_wallet, "TrySpendCareer", 2);
        if (m && pfp_pac_hook_install(m, ti, "tickets.TicketWallet.TrySpendCareer")) installed++;
        m = pfp_il2cpp_find_method(g_wallet, "CanAffordCareer", 2);
        if (m && pfp_pac_hook_install(m, ti, "tickets.TicketWallet.CanAffordCareer")) installed++;
    }

    g_hooks_installed = 1;
    pfp_log("tickets: installed %d methodPointer hook(s) — premium balance pinned max + every spend succeeds", installed);
    return installed > 0 ? 1 : 0;
}

PfpFeature pfp_feature_tickets = { "tickets", init, tick, 0, 0, 0, 0 };
