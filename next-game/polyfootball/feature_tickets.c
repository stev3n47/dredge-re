// feature_tickets — v2.9 "Unlimited Premium Tickets" via periodic invoke.
//
// Prior attempts (hooks) failed:
//   v2.5.x: hooked TicketWallet.TrySpend* — wrong class (game-ticket API,
//           not premium). No effect on premium balance.
//   v2.8:   hooked PremiumCurrency.get_Balance → huge_int and
//           PremiumCurrency.TrySpend → true. Hooks installed cleanly
//           but BLANKED the user's cash + ticket balance to 0.
//           Likely cause: the real return type of get_Balance isn't
//           plain int (maybe a struct or nullable wrapper), so our
//           int64 trampoline writes to the wrong register and the UI
//           reads 0. Or anti-cheat kicked in on save.
//
// v2.9 pivot: INVOKE the game's own Add() method periodically. This
// uses the normal "earn tickets" code path the game already has — no
// ABI mismatch risk, no anti-cheat flag, no replaced method bodies.
//
//   PremiumCurrency.Add(int)  argc=1 [static]
//
// Every 2 seconds while tickets_force=1, invoke Add(100). Net: +50
// tickets per second. Over 1 min = +3000. Visible, safe, reversible.
// User can flip the toggle off at any time and the Add stops.

#include "features.h"
#include "pac_swap.h"

#include <sys/time.h>

static Il2CppClass *g_wallet = NULL;              // TicketWallet (legacy)
static Il2CppClass *g_prem   = NULL;              // PremiumCurrency
static const MethodInfo *g_add_mi = NULL;         // PremiumCurrency.Add(int)
static unsigned long g_last_add_ms = 0;

static unsigned long tickets_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

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
        g_add_mi = pfp_il2cpp_find_method(g_prem, "Add", 1);
        if (g_add_mi) {
            pfp_log("tickets: resolved PremiumCurrency.Add(int) @ %p — will invoke periodically when tickets_force=1",
                    (const void *)g_add_mi);
        } else {
            pfp_log("tickets: PremiumCurrency.Add(int) NOT FOUND — tickets_force cannot top up");
        }
    } else {
        pfp_log("tickets: PremiumCurrency NOT FOUND — premium ticket feature disabled");
    }
    if (!g_prem && !g_wallet) return -1;

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
    if (!pfp_cfg_bool("tickets_force", 0)) return 0;
    if (!g_add_mi) return 0;

    // Throttle: Add(100) every 2000ms. Yields +50/s = ~3000/min.
    unsigned long now = tickets_now_ms();
    if (g_last_add_ms && (now - g_last_add_ms) < 2000UL) return 0;
    g_last_add_ms = now;

    // Invoke PremiumCurrency.Add(int amount). Static method, so self=NULL.
    // invoke1 boxes the int arg via pfp_il2cpp_runtime_invoke; we pass
    // a pointer to a local int32 holding our amount.
    int32_t amount = 100;
    int ok = 1;
    pfp_il2cpp_invoke1(g_add_mi, NULL, &amount, &ok);
    if (!ok) {
        static int warned = 0;
        if (!warned) {
            pfp_log("tickets: PremiumCurrency.Add(%d) invoke threw — disabling", amount);
            warned = 1;
            g_add_mi = NULL;
        }
        return 0;
    }

    // Only log occasionally so we don't spam the file.
    static int fire_count = 0;
    fire_count++;
    if (fire_count == 1 || (fire_count % 30) == 0) {
        pfp_log("tickets: PremiumCurrency.Add(%d) invoked (total fires=%d)", amount, fire_count);
    }
    return 1;
}

PfpFeature pfp_feature_tickets = { "tickets", init, tick, 0, 0, 0, 0 };
