// feature_speed.c — v2a diagnostic: Super Speed surface.
//
// Scope: READ-ONLY on-device discovery for the locomotion / speed-scalar
// classes named in PLAN.md's Tier 2 "Super Speed" row. No methodPointer
// swaps, no field writes — just log the method inventory and live
// instance addresses so a future v2b can design the actual hook from
// real data.
//
// Target classes (Assembly-CSharp.dll):
//   - CarrierMoveControls           (~15 methods at m7947)
//   - FootballJoystickLocomotion    (reference class)
//   - FootballDefenseSpeeds         (~5 methods at m17617)
// Plus: enumerate every class with a method whose name contains
// "PocketMoveSpeedMultiplier" (the m32647 reference pattern lives on an
// unknown parent class).

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass *g_throw_class_for_speed = NULL;
static int g_speed_hooks_installed = 0;

static Il2CppClass *g_carrier_move_controls   = NULL;
static Il2CppClass *g_joystick_locomotion     = NULL;
static Il2CppClass *g_defense_speeds          = NULL;

static int init(void) {
    int total_hits = 0;  // classes resolved + pattern methods found

    // Resolve the three named locomotion classes.
    g_carrier_move_controls = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "CarrierMoveControls");
    g_joystick_locomotion   = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballJoystickLocomotion");
    g_defense_speeds        = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "FootballDefenseSpeeds");
    if (g_carrier_move_controls) total_hits++;
    if (g_joystick_locomotion)   total_hits++;
    if (g_defense_speeds)        total_hits++;
    pfp_log("speed: class CarrierMoveControls=%p FootballJoystickLocomotion=%p FootballDefenseSpeeds=%p",
            (void *)g_carrier_move_controls,
            (void *)g_joystick_locomotion,
            (void *)g_defense_speeds);

    // Dump methods matching speed-shaped names on each resolved class.
    const char *name_substrs[] = {
        "Speed", "Multiplier", "Scalar", "Pocket", "Move", "Locomotion"
    };
    const int substr_count = (int)(sizeof(name_substrs) / sizeof(name_substrs[0]));
    if (g_carrier_move_controls) {
        pfp_diag_log_methods("speed", g_carrier_move_controls, name_substrs, substr_count);
    }
    if (g_joystick_locomotion) {
        pfp_diag_log_methods("speed", g_joystick_locomotion, name_substrs, substr_count);
    }
    if (g_defense_speeds) {
        pfp_diag_log_methods("speed", g_defense_speeds, name_substrs, substr_count);
    }

    // Hunt for the "PocketMoveSpeedMultiplier" pattern method. It lives on
    // some parent class we haven't named yet. Enumerate every class in
    // Assembly-CSharp and list those with a matching method, bounded.
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
        int hits = 0;
        const int cap = 16;
        Il2CppDomain *dom = pfp_il2cpp_domain_get();
        size_t na = 0;
        const Il2CppAssembly **asms = pfp_il2cpp_domain_get_assemblies(dom, &na);
        for (size_t ai = 0; ai < na && hits < cap; ai++) {
            const Il2CppImage *img = pfp_il2cpp_assembly_get_image(asms[ai]);
            if (!img) continue;
            const char *in = pfp_il2cpp_image_get_name(img);
            if (!in || strcmp(in, "Assembly-CSharp.dll") != 0) continue;
            size_t nc = pfp_il2cpp_image_get_class_count(img);
            for (size_t ci = 0; ci < nc && hits < cap; ci++) {
                Il2CppClass *k = pfp_il2cpp_image_get_class(img, ci);
                if (!k) continue;
                void *iter = NULL;
                const MethodInfo *m;
                while ((m = pfp_il2cpp_class_get_methods(k, &iter)) != NULL) {
                    const char *mn = pfp_il2cpp_method_get_name(m);
                    if (!mn) continue;
                    if (strstr(mn, "PocketMoveSpeedMultiplier")) {
                        const char *kn = pfp_il2cpp_class_get_name(k);
                        uint32_t iflags = 0;
                        uint32_t f = pfp_il2cpp_method_get_flags ?
                            pfp_il2cpp_method_get_flags(m, &iflags) : 0;
                        int is_static = (f & 0x10) ? 1 : 0;
                        pfp_log("speed: pattern-method %s.%s%s class=%p",
                                kn ? kn : "?", mn,
                                is_static ? " [static]" : "", (void *)k);
                        hits++;
                        if (hits >= cap) break;
                    }
                }
            }
        }
        if (hits == 0) {
            pfp_log("speed: pattern-method PocketMoveSpeedMultiplier NOT FOUND in Assembly-CSharp");
        } else if (hits >= cap) {
            pfp_log("speed: pattern-method hits truncated at %d", cap);
        }
        total_hits += hits;
    }

    // Walk heap for live instances of the three locomotion classes.
    Il2CppClass *targets[3];
    int tcount = 0;
    if (g_carrier_move_controls) targets[tcount++] = g_carrier_move_controls;
    if (g_joystick_locomotion)   targets[tcount++] = g_joystick_locomotion;
    if (g_defense_speeds)        targets[tcount++] = g_defense_speeds;
    if (tcount > 0) {
        pfp_diag_log_live_instances("speed", targets, tcount);
    }

    // v2.1: register locomotion classes for periodic rewalk (match-time spawn).
    pfp_register_rewalk("speed", g_carrier_move_controls);
    pfp_register_rewalk("speed", g_joystick_locomotion);
    pfp_register_rewalk("speed", g_defense_speeds);

    // v2.6 — resolve ThrowController too for QB pocket-move speed hook.
    g_throw_class_for_speed = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "ThrowController");

    // Critic 6: distinguish "working" from "completely missed all targets"
    // in the status log. Return -1 on total miss so init_failed shows 'x'.
    if (total_hits == 0) {
        pfp_log("speed: all 3 classes missing AND pattern scan found 0 — disabling");
        return -1;
    }
    return 0;
}

static int tick(void) {
    // v2.6 — Super Speed: hook the AnimatorSpeed scalar on
    // FootballJoystickLocomotion plus the pocket-move multiplier on
    // ThrowController. Both return float speed multipliers (typically
    // ~1.0); pinning them to 2.0 roughly doubles the player's run+turn
    // and the QB's scrambling speed.
    if (g_speed_hooks_installed) return 0;
    if (!pfp_cfg_bool("speed_force", 0)) return 0;
    if (pfp_cfg_bool("mp_safe", 0)) {
        static int warned = 0;
        if (!warned) { pfp_log("speed: mp_safe=1 — install gated"); warned = 1; }
        return 0;
    }

    int installed = 0;
    void *tf2 = (void *)pfp_tramp_two_float;

    if (g_joystick_locomotion) {
        const MethodInfo *m = pfp_il2cpp_find_method(g_joystick_locomotion,
                                                     "AnimatorSpeed", 5);
        if (m && pfp_pac_hook_install(m, tf2, "speed.AnimatorSpeed")) installed++;
    }

    if (g_throw_class_for_speed) {
        const MethodInfo *m = pfp_il2cpp_find_method(
            g_throw_class_for_speed,
            "GetPocketMoveSpeedMultiplierForCurrentCareerArchetype",
            0);
        if (m && pfp_pac_hook_install(m, tf2, "speed.PocketMoveSpeedMultiplier")) installed++;
    }

    g_speed_hooks_installed = 1;
    pfp_log("speed: installed %d methodPointer hook(s) — AnimatorSpeed + PocketMoveSpeedMultiplier pinned to 2.0 (super speed)", installed);
    return installed > 0 ? 1 : 0;
}

PfpFeature pfp_feature_speed = { "speed", init, tick, 0, 0, 0, 0 };
