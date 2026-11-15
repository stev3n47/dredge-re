// feature_fuel.c — infinite fuel via FuelTank.SetOilToMax polling.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.Mine.Instances.FuelTank
// (TypeDefIndex 1191). Methods are VIRTUAL instance methods:
//   SetOilToMax()          void
//   ConsumeOil(float)      void
//   get_IsOilEmpty()       bool
//   get_OilRemainingRate() float
//
// Why poll-and-invoke instead of methodPointer hooks: virtual dispatch
// resolves through the klass vtable, which snapshots methodPointer at
// class-init — a MethodInfo swap may not reach callvirt sites. Invoking
// the real SetOilToMax through runtime_invoke dispatches correctly and
// fires the tank's OnOilChanging event so UI/HUD stays consistent.
//
// Every ~5s: heap-walk for live FuelTank instances (cap 8 — player +
// worker tanks if they're separate objects) and SetOilToMax each.
// NullFuelTank (1192) is a different class and is intentionally NOT
// targeted — it's the "no fuel system" stub.

#include "features.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_setmax_mi = NULL;

static int tick_count = 0;
static int walks = 0;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.Mine.Instances", "FuelTank");
    if (!g_klass) {
        bd_log("fuel: FuelTank class not found");
        return -1;
    }
    int mc = bd_il2cpp_count_methods(g_klass);
    g_setmax_mi = bd_il2cpp_find_method(g_klass, "SetOilToMax", 0);
    bd_log("fuel: FuelTank class=%p method_count=%d SetOilToMax=%p",
           g_klass, mc, (void *)g_setmax_mi);
    if (!g_setmax_mi) {
        bd_log("fuel: SetOilToMax unresolved — disabling");
        return -1;
    }
    // Late-spawning tanks (new stage/worker) — the periodic rewalk gives
    // us a log line when they appear; the 5s action walk finds them anyway.
    bd_register_rewalk("fuel", g_klass);
    return 0;
}

static int tick(void) {
    tick_count++;
    if ((tick_count % 50) != 0) return 0;   // ~5s at 10 Hz

    void *found[8] = {0};
    int n = bd_il2cpp_find_instances(g_klass, found, 8);
    walks++;
    if (n <= 0) {
        if (walks <= 3 || (walks % 12) == 0) {
            bd_log("fuel: walk %d — no live FuelTank instances yet", walks);
        }
        return 0;
    }
    int topped = 0;
    for (int i = 0; i < n; i++) {
        int ok = 1;
        bd_il2cpp_invoke0(g_setmax_mi, found[i], &ok);
        if (ok) topped++;
    }
    if (topped > 0) {
        bd_log("fuel: SetOilToMax on %d/%d tank(s) (walk %d)", topped, n, walks);
        return 1;
    }
    return 0;
}

BdFeature bd_feature_fuel = { "infinite_fuel", init, tick, 0, 0, 0, 0, NULL, 0 };
