// v1b: free skill points — CareerSkillCosts.
//
// Plan intent: CareerSkillCosts.Cost (m9231) -> 0, .Spent (m9232) -> 0.
// Making a getter return 0 requires a methodPointer swap (v2b territory
// per PLAN.md). At v1b scope — static invoke only — we cannot force a
// getter's return value.
//
// So this feature does two things:
//   init() — enumerate every method on CareerSkillCosts, log name + static
//            bit + argc. That gives the on-device picture we need to
//            decide between a methodPointer swap in v2b or an SO-field
//            patch. Also look for any static arity-0 "reset-shaped"
//            method (Reset / Clear / Zero) and cache it; those genuinely
//            CAN be invoked.
//   tick() — if a reset-shaped method was found, invoke once per 60 s.
//            Otherwise return 0 (no meaningful work).
//
// Safety: static-only invokes with self=NULL, exc checked, no heap-derived
// pointers touched.

#include "features.h"

#include <string.h>
#include <sys/time.h>

#define MAX_RESET 4

static Il2CppClass      *g_klass;
static const MethodInfo *g_reset_mi[MAX_RESET];
static const char       *g_reset_name[MAX_RESET];
static int               g_reset_n;
static unsigned long     g_last_fire_ms;

static unsigned long skills_now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static int looks_like_reset(const char *mn) {
    return (strstr(mn, "Reset") || strstr(mn, "Clear") || strstr(mn, "Zero"));
}

static int init(void) {
    g_klass = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "CareerSkillCosts");
    if (!g_klass) {
        pfp_log("skills: CareerSkillCosts class NOT FOUND");
        return -1;
    }
    pfp_log("skills: CareerSkillCosts class=%p (expect 5 methods per catalog m9231)", (void *)g_klass);

    if (!pfp_il2cpp_class_get_methods) {
        pfp_log("skills: class_get_methods unavailable — cannot enumerate");
        return 0;  // init still ok; tick will just no-op
    }

    void *iter = NULL;
    const MethodInfo *m;
    int seen = 0;
    while ((m = pfp_il2cpp_class_get_methods(g_klass, &iter)) != NULL) {
        const char *mn = pfp_il2cpp_method_get_name ? pfp_il2cpp_method_get_name(m) : NULL;
        if (!mn) continue;
        uint32_t iflags = 0;
        uint32_t f = pfp_il2cpp_method_get_flags ? pfp_il2cpp_method_get_flags(m, &iflags) : 0;
        int is_static = (f & 0x10) ? 1 : 0;
        int argc = pfp_il2cpp_method_get_param_count ? (int)pfp_il2cpp_method_get_param_count(m) : -1;
        pfp_log("skills: method %s argc=%d%s", mn, argc, is_static ? " [static]" : "");
        seen++;
        if (is_static && argc == 0 && looks_like_reset(mn) && g_reset_n < MAX_RESET) {
            g_reset_mi[g_reset_n]   = m;
            g_reset_name[g_reset_n] = mn;
            g_reset_n++;
        }
    }
    pfp_log("skills: enumerated %d method(s), %d reset-shaped candidate(s)",
            seen, g_reset_n);
    if (g_reset_n == 0) {
        pfp_log("skills: Cost/Spent are pure getters — forcing 0 needs methodPointer "
                "swap (v2b). v1b tick() will no-op.");
    }
    return 0;
}

static int tick(void) {
    if (g_reset_n == 0) return 0;
    // Critic 2: Reset/Clear/Zero-shaped methods on CareerSkillCosts could
    // be destructive (e.g. wipe player progression). Gate the actual
    // invocation behind an explicit opt-in flag `skills_force=1` in
    // pfplus.json. Default: log what was discovered, never auto-fire.
    if (!pfp_cfg_bool("skills_force", 0)) {
        static int warned = 0;
        if (!warned) {
            pfp_log("skills: %d reset-shaped method(s) discovered; auto-fire "
                    "GATED behind skills_force=1 in pfplus.json "
                    "(potentially destructive, needs device-log confirmation first)",
                    g_reset_n);
            warned = 1;
        }
        return 0;
    }
    unsigned long t = skills_now_ms();
    if (g_last_fire_ms && (t - g_last_fire_ms) < 60000UL) return 0;

    int any = 0;
    for (int i = 0; i < g_reset_n; i++) {
        if (!g_reset_mi[i]) continue;
        int ok = 1;
        pfp_il2cpp_invoke0(g_reset_mi[i], NULL, &ok);
        if (ok) {
            pfp_log("skills: invoked %s (skills_force=1)",
                    g_reset_name[i] ? g_reset_name[i] : "?");
            any = 1;
        } else {
            pfp_log("skills: %s threw on invoke — clearing from reset list",
                    g_reset_name[i] ? g_reset_name[i] : "?");
            g_reset_mi[i] = NULL;
        }
    }
    if (any) g_last_fire_ms = t;
    return any;
}

PfpFeature pfp_feature_skills = { "skills", init, tick, 0, 0, 0, 0 };
