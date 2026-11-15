// feature_research.c — instant research completion.
//
// Target: Assembly-CSharp.dll · BulldogzerMaster.StatUpgrade.StatUpgradeManager
// (TypeDefIndex 386, SingletonBehaviourBase).
//
//   IsResearchComplete(StatUpgradeInfo) -> bool   [instance, pc=1]
//   IsResearchStarted(StatUpgradeInfo)  -> bool   [instance, pc=1]
//   GetRemainingResearchTime(...)       -> TimeSpan [struct return — NOT hooked]
//   SkipResearchTimeByRV(StatUpgradeInfo)         [needs RV ticket]
//   CheatSetStatLevel(EGameModeType, EContinentType, EStatType, int)
//
// Approach: methodPointer-swap IsResearchComplete -> always true. The
// upgrade flow (StartResearch -> wait -> IsResearchComplete -> PayPrice ->
// Upgrade) then completes the moment research starts — combined with
// spend_free (feature_spend) and the money drip, upgrades are instant and
// free.
//
// IsResearchComplete is a NON-virtual instance method on a sealed class.
// v1.1: bd_hook_bool_true inline-patches the generated code so direct
// call sites return true; methodPointer swap is the fallback.
//
// NOT hooked: GetRemainingResearchTime returns TimeSpan (16-byte struct,
// sret/x0+x1 ABI) — a constant trampoline can't fake it safely, and the
// UI countdown label may still tick down visually even though the
// completion gate is already open. Cosmetic only.

#include "features.h"
#include "pac_swap.h"
#include <string.h>

static Il2CppClass      *g_klass = NULL;
static const MethodInfo *g_complete_mi = NULL;
static const MethodInfo *g_started_mi  = NULL;
static int g_installed = 0;

static int init(void) {
    g_klass = bd_il2cpp_find_class("Assembly-CSharp.dll",
                                   "BulldozerMaster.StatUpgrade", "StatUpgradeManager");
    if (!g_klass) {
        bd_log("research: StatUpgradeManager class not found");
        return -1;
    }
    int mc = bd_il2cpp_count_methods(g_klass);
    g_complete_mi = bd_il2cpp_find_method(g_klass, "IsResearchComplete", 1);
    g_started_mi  = bd_il2cpp_find_method(g_klass, "IsResearchStarted", 1);
    bd_log("research: StatUpgradeManager class=%p method_count=%d (catalog expects 31)",
           g_klass, mc);
    bd_log("research: IsResearchComplete=%p IsResearchStarted=%p",
           (void *)g_complete_mi, (void *)g_started_mi);
    if (!g_complete_mi) {
        bd_log("research: IsResearchComplete unresolved — disabling");
        return -1;
    }
    bd_register_rewalk("research", g_klass);
    return 0;
}

static int tick(void) {
    // Feature key IS "research_force" — dispatcher gates on it.
    if (g_installed) return 0;
    int n = bd_hook_bool_true(g_complete_mi, "research.IsResearchComplete");
    g_installed = 1;
    bd_log("research: installed %d hook(s) — research completes instantly", n);
    return n > 0 ? 1 : 0;
}

BdFeature bd_feature_research = { "research_force", init, tick, 0, 0, 0, 0, NULL, 0 };
