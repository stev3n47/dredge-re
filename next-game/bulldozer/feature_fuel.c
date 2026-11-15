// feature_fuel.c — infinite fuel via FuelTank code patches (+ poll backup).
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.Mine.Instances.FuelTank
// (TypeDefIndex 1191). All fuel methods are VIRTUAL instance methods:
//   get_IsOilEmpty()    bool   -> patched `mov w0,#0; ret`  (never empty)
//   ConsumeOil(float)   void   -> patched `ret`             (never drains)
//   SetOilToMax()        void   [kept for the poll fallback]
//
// v1.2 rewrite: the v1.0 heap-walk for live FuelTank instances never
// matched (gc_foreach_heap klass pointers don't line up with image
// metadata classes on this build — see bdplus.log rewalk-sample).
// Patching the method CODE covers every instance and every dispatch
// path (direct call + vtable) with zero instance discovery.
// NullFuelTank (1192) overrides these methods separately and is left
// alone — it's the "no fuel system" stub.
//
// Fallback: the original SetOilToMax poll stays — if the text patches
// fail (vm_protect refused), it still tops up any instance the walk
// can find.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_isempty_mi = NULL;
static const MethodInfo *g_consume_mi = NULL;
static const MethodInfo *g_setmax_mi  = NULL;

static int g_patched = 0;
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
    g_isempty_mi = bd_il2cpp_find_method(g_klass, "get_IsOilEmpty", 0);
    g_consume_mi = bd_il2cpp_find_method(g_klass, "ConsumeOil", 1);
    g_setmax_mi  = bd_il2cpp_find_method(g_klass, "SetOilToMax", 0);
    bd_log("fuel: FuelTank class=%p method_count=%d IsOilEmpty=%p ConsumeOil=%p SetOilToMax=%p",
           g_klass, mc, (void *)g_isempty_mi, (void *)g_consume_mi,
           (void *)g_setmax_mi);
    if (!g_isempty_mi && !g_consume_mi && !g_setmax_mi) {
        bd_log("fuel: no target methods resolved — disabling");
        return -1;
    }
    return 0;
}

static int tick(void) {
    tick_count++;

    // One-shot code patches.
    if (!g_patched) {
        int n = 0;
        if (g_isempty_mi) n += bd_hook_bool_false(g_isempty_mi, "fuel.IsOilEmpty");
        if (g_consume_mi) n += bd_hook_ret_only(g_consume_mi, "fuel.ConsumeOil");
        g_patched = 1;
        bd_log("fuel: installed %d code patch(es) — oil never drains, never empty", n);
    }

    // Backup poll: SetOilToMax on any live instance the walk finds.
    if (!g_setmax_mi || (tick_count % 50) != 0) return 0;
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
