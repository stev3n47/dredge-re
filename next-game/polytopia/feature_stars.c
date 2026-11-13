// feature_stars.c — unlimited stars, v1.0.2.
//
// Replaces the v1.0.1 PlayerState.get_Currency methodPointer swap, which the
// 14:55 device run proved inert (status `intercepts: true=0` all session) and
// which was wrong anyway: get_Currency is a direct-call instance getter read
// for EVERY player (AI included), and pinning a getter never changes the
// stored balance.
//
// This drives the game's own setter instead, via il2cpp_runtime_invoke — the
// one dispatch path v2.2 proved our bridge reaches. Each throttled tick:
//
//     PlayerState* lp = GameManager.get_LocalPlayer();   // static, argc 0
//     if (lp && lp->klass == PlayerState)                // SPPlus v33 safety
//         PlayerState.set_Currency(lp, STARS_VALUE);     // instance, argc 1
//
// Symbols confirmed from the 14:55 diag dump:
//   GameManager.get_LocalPlayer  argc=0 [static]   (PolytopiaAssembly.dll)
//   PlayerState.set_Currency     argc=1            (GameLogicAssembly.dll)
//   PlayerState.get_Currency     argc=0            (read-back for logging)
//
// Human-only by construction: get_LocalPlayer returns the local human's
// PlayerState, so AI balances are never touched — no self-check trampoline
// needed. Still match-sim state, so the mp_safe gate is honoured here too.

#include "features.h"
#include "il2cpp_bridge.h"

#include <stdint.h>
#include <sys/time.h>

// ~999,999 — comfortably inside int32 and large enough to be "unlimited" in
// practice, without pushing score/÷ math toward overflow the way 999,999,999
// might. Re-applied on the throttle below so spending tops back up.
#define STP_STARS_VALUE 999999

static Il2CppClass      *g_gm_klass = NULL;    // GameManager
static Il2CppClass      *g_ps_klass = NULL;    // PlayerState (for class-match)
static const MethodInfo *g_get_local_player = NULL;   // GameManager.get_LocalPlayer [static]
static const MethodInfo *g_set_currency = NULL;       // PlayerState.set_Currency(int)
static const MethodInfo *g_get_currency = NULL;       // PlayerState.get_Currency() -> int

static int g_mp_blocked_logged = 0;
static int g_first_write_logged = 0;
static int g_no_player_logged = 0;
static unsigned long g_last_write_ms = 0;

static unsigned long stp_stars_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static int init(void) {
    g_gm_klass = stp_il2cpp_find_class("PolytopiaAssembly.dll", NULL, "GameManager");
    if (!g_gm_klass) g_gm_klass = stp_il2cpp_find_class(NULL, NULL, "GameManager");
    g_ps_klass = stp_il2cpp_find_class("GameLogicAssembly.dll", NULL, "PlayerState");
    if (!g_ps_klass) g_ps_klass = stp_il2cpp_find_class(NULL, NULL, "PlayerState");

    if (!g_gm_klass || !g_ps_klass) {
        stp_log("stars: class resolve failed (GameManager=%p PlayerState=%p) -- disabled",
                (void *)g_gm_klass, (void *)g_ps_klass);
        return -1;
    }

    g_get_local_player = stp_il2cpp_find_method(g_gm_klass, "get_LocalPlayer", 0);
    g_set_currency     = stp_il2cpp_find_method(g_ps_klass, "set_Currency", 1);
    g_get_currency     = stp_il2cpp_find_method(g_ps_klass, "get_Currency", 0);

    stp_log("stars: resolved get_LocalPlayer=%p set_Currency=%p get_Currency=%p",
            (void *)g_get_local_player, (void *)g_set_currency, (void *)g_get_currency);

    if (!g_get_local_player || !g_set_currency) {
        stp_log("stars: required method(s) unresolved -- disabled for session");
        return -1;
    }
    if (!stp_il2cpp_object_get_class) {
        stp_log("stars: object_get_class unresolved -- can't verify player type, disabled");
        return -1;
    }
    return 0;
}

static int tick(void) {
    // Match-sim write: respect the MP safety gate exactly like the old hook did.
    if (stp_cfg_bool("mp_safe", 0)) {
        if (!g_mp_blocked_logged) {
            stp_log("stars: skipped -- mp_safe=1 (match-sim write)");
            g_mp_blocked_logged = 1;
        }
        return 0;
    }
    g_mp_blocked_logged = 0;

    // Throttle to ~2 Hz: topping up twice a second is plenty and keeps the
    // runtime_invoke load trivial.
    unsigned long t = stp_stars_now_ms();
    if (g_last_write_ms && (t - g_last_write_ms) < 500UL) return 0;

    // GameManager.get_LocalPlayer() -- static, no args. Returns NULL outside a
    // match (menus); that's expected, not an error.
    int ok = 0;
    Il2CppObject *lp = stp_il2cpp_invoke0(g_get_local_player, NULL, &ok);
    if (!ok) {
        // Managed exception inside the accessor -- back off a beat, don't spam.
        g_last_write_ms = t;
        return 0;
    }
    if (!lp) {
        if (!g_no_player_logged) {
            stp_log("stars: no local player yet (not in a match) -- waiting");
            g_no_player_logged = 1;
        }
        g_last_write_ms = t;
        return 0;
    }
    g_no_player_logged = 0;

    // SPPlus v33 safety: before invoking an instance method on an object we
    // got back from the runtime, confirm its class is the PlayerState we
    // resolved from metadata (pointer equality only -- no calls through a
    // possibly-bogus klass pointer).
    Il2CppClass *k = stp_il2cpp_object_get_class(lp);
    if (k != g_ps_klass) {
        if (!g_first_write_logged) {
            stp_log("stars: get_LocalPlayer returned class=%p (expected PlayerState=%p) "
                    "-- not writing", (void *)k, (void *)g_ps_klass);
            g_first_write_logged = 1;  // reuse as "logged a problem once"
        }
        g_last_write_ms = t;
        return 0;
    }

    int32_t value = STP_STARS_VALUE;
    ok = 0;
    (void)stp_il2cpp_invoke1(g_set_currency, lp, &value, &ok);
    g_last_write_ms = t;

    if (!ok) {
        stp_log("stars: set_Currency invoke raised -- will retry next tick");
        return 0;
    }

    if (!g_first_write_logged) {
        int readback = -1;
        if (g_get_currency) {
            int ok2 = 0;
            Il2CppObject *cur = stp_il2cpp_invoke0(g_get_currency, lp, &ok2);
            if (ok2) readback = stp_unbox_i32(cur);
        }
        stp_log("stars: set local player currency to %d (readback=%d) on PlayerState@%p",
                STP_STARS_VALUE, readback, (void *)lp);
        g_first_write_logged = 1;
    }
    return 1;
}

StpFeature stp_feature_stars = {
    "stars", init, tick, 0, 0, 0, 0, NULL, 0
};
