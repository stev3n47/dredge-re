// feature_tickets — v2.5.2 TicketWallet methodPointer hook.
//
// Diagnosis path (v2.5.1 testing):
//   - skills_force=1 installed hooks on CareerSkillCosts.Cost / .Spent,
//     which only drive the UI cost-lookup. The actual spend flow goes
//     through TicketWallet.TrySpend* which still deducted a ticket from
//     the player's wallet. Result: free-skill-points toggle appeared
//     to do nothing in gameplay.
//   - Catalog lookup: type 4468 .TicketWallet, 3 methods starting at
//     m32843: TrySpend(int), CanAffordCareer(int), TrySpendCareer(int).
//
// v2.5.2 fix: hook all three TicketWallet methods to return true. Every
// ticket transaction reports success, no deduction happens — the player
// can buy infinite skill points (and any other ticket-funded unlock).
//
// The REAL skill-point ledger class (where the actual skill-point
// deduction on upgrade lives) is still unknown. feature_skills.c init
// in this release also scans Assembly-CSharp for additional classes
// matching Skill/Points/Wallet/Ledger/Upgrade patterns and dumps their
// methods, so the next device log picks a direct target for v2.5.3.

#include "features.h"
#include "pac_swap.h"

static Il2CppClass *g_wallet = NULL;
static int g_hooks_installed = 0;

static int init(void) {
    g_wallet = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "TicketWallet");
    if (!g_wallet) {
        pfp_log("tickets: TicketWallet class NOT FOUND in Assembly-CSharp.dll");
        return -1;
    }
    int mc = pfp_il2cpp_count_methods(g_wallet);
    pfp_log("tickets: TicketWallet class=%p method_count=%d (catalog expects 3)",
            (void *)g_wallet, mc);
    // Dump method shape so future builds can verify the catalog match.
    static const char *subs[] = { "Spend", "Afford" };
    pfp_diag_log_methods("tickets", g_wallet, subs,
                         (int)(sizeof(subs) / sizeof(subs[0])));
    return 0;
}

static int tick(void) {
    if (g_hooks_installed) return 0;
    if (!pfp_cfg_bool("tickets_force", 0)) return 0;
    if (!g_wallet) return 0;
    // mp_safe shouldn't apply here — TicketWallet is a currency store,
    // not a gameplay-roll surface. Server doesn't authority-check it
    // for MP matches (purchases happen in the shop, not mid-game).

    int installed = 0;
    void *ti = (void *)pfp_tramp_one_int;

    const MethodInfo *m = pfp_il2cpp_find_method(g_wallet, "TrySpend", 1);
    if (m && pfp_pac_hook_install(m, ti, "tickets.TrySpend")) installed++;
    m = pfp_il2cpp_find_method(g_wallet, "TrySpendCareer", 1);
    if (m && pfp_pac_hook_install(m, ti, "tickets.TrySpendCareer")) installed++;
    m = pfp_il2cpp_find_method(g_wallet, "CanAffordCareer", 1);
    if (m && pfp_pac_hook_install(m, ti, "tickets.CanAffordCareer")) installed++;

    g_hooks_installed = 1;
    pfp_log("tickets: installed %d methodPointer hook(s) — every ticket spend succeeds without deducting", installed);
    return installed > 0 ? 1 : 0;
}

PfpFeature pfp_feature_tickets = { "tickets", init, tick, 0, 0, 0, 0 };
