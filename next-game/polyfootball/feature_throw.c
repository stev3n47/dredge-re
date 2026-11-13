// v2a diagnostic — ThrowController (type 4466, m32601-m32796).
//
// Cannon Arm target per PLAN.md. The four interesting velocity methods
// return Vector3 (indirect-sret ABI), so this module does NOT invoke them
// — the point of v2a is to log method signatures + live instances so the
// v2b hook design has real data to work from.
//
// init:
//   1. Resolve ThrowController class in Assembly-CSharp.dll, log method count.
//   2. Dump every method whose name matches one of our substrs (velocity
//      calcs, throw/ballistic/bullet/underthrow/correct/calculate) with
//      argc + static-bit.
//   3. Walk heap once for live ThrowController instances (there's usually
//      one per active play session — may be zero outside a match).
// tick: no-op.

#include "features.h"
#include "pac_swap.h"

static Il2CppClass *g_throw_class = NULL;
static int g_cannon_installed   = 0;
static int g_accuracy_installed = 0;

static int init(void) {
    g_throw_class = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "ThrowController");
    if (!g_throw_class) {
        pfp_log("throw: ThrowController class NOT FOUND in Assembly-CSharp.dll");
        return -1;
    }

    int mc = pfp_il2cpp_count_methods(g_throw_class);
    pfp_log("throw: ThrowController class=%p method_count=%d (catalog expects range m32601-m32796 ~196 methods)",
            g_throw_class, mc);

    // Dump the methods we care about. argc + static-bit are the critical
    // bits: Calculate*Velocity returns Vector3 and takes multiple floats,
    // so the invoke-by-pointer approach from v1 unlocks will NOT work for
    // these. v2b will need methodPointer swap behind a PAC probe.
    static const char *substrs[] = {
        "Velocity",
        "Throw",
        "Ballistic",
        "Bullet",
        "Underthrow",
        "Correct",
        "Calculate",
    };
    pfp_diag_log_methods("throw", g_throw_class, substrs,
                         (int)(sizeof substrs / sizeof substrs[0]));

    // Walk heap for live ThrowController instance(s). Uses the shared
    // helper which follows SPPlus v33+ safety rules (pointer-equality
    // only against pre-resolved whitelist class pointers).
    Il2CppClass * const whitelist[] = { g_throw_class };
    int n = pfp_diag_log_live_instances("throw", whitelist, 1);
    if (n == 0) {
        pfp_log("throw: no live ThrowController on heap (expected when no match is active)");
    }

    // v2.1: ThrowController spawns per play — register for periodic rewalk
    // so we catch it the moment a career match starts.
    pfp_register_rewalk("throw", g_throw_class);
    return 0;
}

static int tick(void) {
    if (!g_throw_class) return 0;
    int fired = 0;
    int mp_safe = pfp_cfg_bool("mp_safe", 0);

    // v2.5 — Cannon Arm: hook get_PassIsBullet to always return true.
    // Every throw gets flagged as a bullet pass, so the game's velocity
    // math picks the max-velocity ballistic path. Avoids needing a
    // Vector3-sret trampoline for CalculateBulletVelocity.
    // v2.5.1 — gated on mp_safe to avoid MP desync.
    if (!g_cannon_installed && pfp_cfg_bool("throw_force", 0) && !mp_safe) {
        int n = 0;
        const MethodInfo *m = pfp_il2cpp_find_method(g_throw_class, "get_PassIsBullet", 0);
        if (m && pfp_pac_hook_install(m, (void *)pfp_tramp_one_int, "throw.get_PassIsBullet")) n++;
        g_cannon_installed = 1;
        pfp_log("throw: installed %d methodPointer hook(s) — every throw is a bullet pass (cannon arm)", n);
        fired = n > 0;
    }

    // v2.5 — Perfect Pass Accuracy: hook get_ThrowSpreadOnTheRun → 0.0.
    // Kills the roll-out spread penalty so throws on the move hit their
    // target. v2.5.1 — gated on mp_safe.
    if (!g_accuracy_installed && pfp_cfg_bool("accuracy_force", 0) && !mp_safe) {
        int n = 0;
        const MethodInfo *m = pfp_il2cpp_find_method(g_throw_class, "get_ThrowSpreadOnTheRun", 0);
        if (m && pfp_pac_hook_install(m, (void *)pfp_tramp_zero_float, "throw.get_ThrowSpreadOnTheRun")) n++;
        g_accuracy_installed = 1;
        pfp_log("throw: installed %d methodPointer hook(s) — run-throw spread pinned to 0 (perfect accuracy)", n);
        fired = fired || (n > 0);
    }

    if (mp_safe && (pfp_cfg_bool("throw_force", 0) || pfp_cfg_bool("accuracy_force", 0))) {
        static int warned = 0;
        if (!warned) { pfp_log("throw: mp_safe=1 — install gated"); warned = 1; }
    }
    return fired ? 1 : 0;
}

PfpFeature pfp_feature_throw = { "throw", init, tick, 0, 0, 0, 0 };
