// feature_tickets — v2.10 "Unlimited Cash" via periodic Add invoke.
//
// Device verify of v2.9: user confirmed CASH balance ticks up (+100
// every 2s) but PREMIUM TICKETS do NOT. So PremiumCurrency.Balance is
// actually career/player CASH, not premium tickets. Despite the class
// name, this is the game's cash wallet. Premium tickets are stored
// somewhere else — we don't know where yet.
//
// v2.10:
//   * Rename the user-facing feature from "Unlimited Tickets" to
//     "Unlimited Cash". Config key stays "tickets_force" for backward
//     compat with saved pfplus.json (users already have that flag=1);
//     only the menu label + meta subline change, plus a new config
//     alias "cash_force" that mirrors it.
//   * Invoke logic unchanged — PremiumCurrency.Add(100) every 2s is
//     doing exactly the right thing for cash.
//   * Add diagnostic: periodically log the current balance by invoking
//     get_Balance() so we can confirm growth on-device.
//   * Add a wider method-name scan for the REAL premium ticket class
//     (get_Tickets / AddTickets / SpendTickets / set_Tickets).

#include "features.h"
#include "pac_swap.h"

#include <string.h>
#include <sys/time.h>

static Il2CppClass *g_wallet = NULL;              // TicketWallet (legacy)
static Il2CppClass *g_prem   = NULL;              // PremiumCurrency (cash)
static const MethodInfo *g_add_mi = NULL;         // PremiumCurrency.Add(int)
static const MethodInfo *g_get_balance_mi = NULL; // PremiumCurrency.get_Balance()
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
        g_get_balance_mi = pfp_il2cpp_find_method(g_prem, "get_Balance", 0);
        if (g_add_mi) {
            pfp_log("tickets: resolved PremiumCurrency.Add(int) @ %p — adds CASH (not premium tickets) when cash/tickets_force=1",
                    (const void *)g_add_mi);
        } else {
            pfp_log("tickets: PremiumCurrency.Add(int) NOT FOUND — cash top-up disabled");
        }

        // v2.10 one-shot: read current balance so user can compare in-game
        // display to our value and confirm what currency this is.
        if (g_get_balance_mi) {
            int ok = 1;
            Il2CppObject *boxed = pfp_il2cpp_invoke0(g_get_balance_mi, NULL, &ok);
            if (ok) {
                int64_t v = pfp_unbox_i32(boxed);
                pfp_log("tickets: PremiumCurrency.get_Balance() returned %lld (this value = CASH per v2.9 device test)",
                        (long long)v);
            }
        }
    } else {
        pfp_log("tickets: PremiumCurrency NOT FOUND — cash top-up feature disabled");
    }

    // v2.10 — hunt the real premium TICKET balance class. TicketWallet
    // has only spend methods (no get_Balance / Add), so the actual
    // ticket balance lives on another class not matched by v2.7's
    // class-name scan. Scan every Assembly-CSharp method for names
    // containing Ticket + get/Add/Spend/set patterns.
    if (pfp_il2cpp_ready() &&
        pfp_il2cpp_domain_get &&
        pfp_il2cpp_domain_get_assemblies &&
        pfp_il2cpp_assembly_get_image &&
        pfp_il2cpp_image_get_name &&
        pfp_il2cpp_image_get_class &&
        pfp_il2cpp_image_get_class_count &&
        pfp_il2cpp_class_get_name &&
        pfp_il2cpp_class_get_methods &&
        pfp_il2cpp_method_get_name) {
        pfp_log("tickets: v2.10 ticket-balance hunt — scanning methods for Ticket get/Add/Spend/set");
        static const char *needles[] = {
            "get_Tickets", "AddTickets", "SpendTickets", "set_Tickets",
            "get_GameTickets", "AddGameTickets", "GameTicketBalance",
            "TicketBalance", "get_TicketCount", "AddTicketReward",
        };
        const int nn = (int)(sizeof(needles) / sizeof(needles[0]));
        Il2CppDomain *dom = pfp_il2cpp_domain_get();
        size_t na = 0;
        const Il2CppAssembly **asms = pfp_il2cpp_domain_get_assemblies(dom, &na);
        int hits_total = 0;
        for (size_t ai = 0; ai < na && hits_total < 64; ai++) {
            const Il2CppImage *img = pfp_il2cpp_assembly_get_image(asms[ai]);
            if (!img) continue;
            const char *in = pfp_il2cpp_image_get_name(img);
            if (!in || strcmp(in, "Assembly-CSharp.dll") != 0) continue;
            size_t nc = pfp_il2cpp_image_get_class_count(img);
            for (size_t ci = 0; ci < nc && hits_total < 64; ci++) {
                Il2CppClass *k = pfp_il2cpp_image_get_class(img, ci);
                if (!k) continue;
                void *iter = NULL;
                const MethodInfo *m;
                while ((m = pfp_il2cpp_class_get_methods(k, &iter)) != NULL) {
                    const char *mn = pfp_il2cpp_method_get_name(m);
                    if (!mn) continue;
                    for (int ni = 0; ni < nn; ni++) {
                        if (strstr(mn, needles[ni])) {
                            const char *kn = pfp_il2cpp_class_get_name(k);
                            uint32_t iflags = 0;
                            uint32_t f = pfp_il2cpp_method_get_flags ?
                                pfp_il2cpp_method_get_flags(m, &iflags) : 0;
                            int is_static = (f & 0x10) ? 1 : 0;
                            int argc = pfp_il2cpp_method_get_param_count ?
                                (int)pfp_il2cpp_method_get_param_count(m) : -1;
                            pfp_log("tickets-hunt: %s.%s argc=%d%s",
                                    kn ? kn : "?", mn, argc,
                                    is_static ? " [static]" : "");
                            hits_total++;
                            break;
                        }
                    }
                    if (hits_total >= 64) break;
                }
            }
        }
        pfp_log("tickets: v2.10 ticket-balance hunt — %d hit(s)", hits_total);
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
