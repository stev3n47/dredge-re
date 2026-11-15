// feature_stage.c — stage completion action.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.Mine.MineManager
// (TypeDefIndex 1151, SingletonBehaviourBase<MineManager>).
//
//   CompleteStage()                     void, instance, pc=0  <- wired
//   MoveToStageLevelByCheat(int)        void, instance, pc=1  (logged only)
//   MoveToStageByCheat(int,int,Action)  void, instance, pc=3  (logged only)
//
// `stage_complete` is an ACTION key: the menu's "Complete Stage" button
// sets it to 1; the next tick resolves the live MineManager via the
// SingletonBehaviourBase<MineManager>._instance static field (v1.2 —
// the gc_foreach_heap klass compare doesn't match on this build) and
// invokes CompleteStage() once, then resets the key.
//
// CompleteStage is the same method the game's own stage-clear flow calls
// (it has Co_CompleteStage/Co_CompleteEventStage coroutine helpers), so
// rewards/progression fire through the normal path.

#include "features.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_complete_mi = NULL;
static const MethodInfo *g_move_level_mi = NULL;
static const MethodInfo *g_move_stage_mi = NULL;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.Mine", "MineManager");
    if (!g_klass) {
        bd_log("stage: MineManager class not found");
        return -1;
    }
    int mc = bd_il2cpp_count_methods(g_klass);
    g_complete_mi   = bd_il2cpp_find_method(g_klass, "CompleteStage", 0);
    g_move_level_mi = bd_il2cpp_find_method(g_klass, "MoveToStageLevelByCheat", 1);
    g_move_stage_mi = bd_il2cpp_find_method(g_klass, "MoveToStageByCheat", 3);
    bd_log("stage: MineManager class=%p method_count=%d (catalog expects 70)",
           g_klass, mc);
    bd_log("stage: CompleteStage=%p MoveToStageLevelByCheat=%p MoveToStageByCheat=%p",
           (void *)g_complete_mi, (void *)g_move_level_mi, (void *)g_move_stage_mi);
    if (!g_complete_mi) {
        bd_log("stage: CompleteStage unresolved — disabling");
        return -1;
    }
    bd_register_rewalk("stage", g_klass);
    return 0;
}

static int tick(void) {
    if (!bd_cfg_bool("stage_complete", 0)) return 0;
    // Consume the action key first so a throw can't retrigger it.
    bd_cfg_set_bool("stage_complete", 0);

    // v1.2: singleton _instance field — no heap walk needed.
    void *inst = bd_singleton_instance(g_klass);
    if (!inst) {
        // Fallback: heap walk (known-broken klass compare on this build,
        // but harmless if a future build fixes it).
        void *found[4] = {0};
        int n = bd_il2cpp_find_instances(g_klass, found, 4);
        if (n > 0) inst = found[0];
    }
    if (!inst) {
        bd_log("stage: CompleteStage requested but no live MineManager instance");
        return 0;
    }
    int ok = 1;
    bd_il2cpp_invoke0(g_complete_mi, inst, &ok);
    if (ok) {
        bd_log("stage: CompleteStage() invoked on MineManager @ %p", inst);
        return 1;
    }
    bd_log("stage: CompleteStage threw");
    return 0;
}

BdFeature bd_feature_stage = { "stage", init, tick, 0, 0, 0, 0, NULL, 0 };
