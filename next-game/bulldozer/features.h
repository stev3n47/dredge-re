// BDPlus feature registry.
//
// Each feature lives in its own C file (feature_<name>.c) and provides one
// `BdFeature` struct that the central dispatcher in BDPlus.m calls on
// every tick. Features are independent — adding/removing one is a single
// entry in g_feature_registry[] in BDPlus.m.
//
// Contract:
//   int init(void)   — called once after il2cpp is ready. Resolve classes
//                      / methods, cache in file-local statics. Return 0 on
//                      success (tick will run). Non-zero disables this
//                      feature for the session. Log via bd_log(). Must
//                      not keep heap-derived class pointers.
//   int tick(void)   — called on each 10 Hz main-runloop tick. Return 1
//                      if the feature did meaningful work (bumps fires).
//                      Called only after init succeeds AND
//                      bd_cfg_bool(feature->key, 1) is non-zero.
//
// Heap-walk safety rule (SPPlus v33+ / PFPlus v1a.2): inside a
// gc_foreach_heap callback, read ONLY obj->klass via
// bd_il2cpp_object_get_class() and do pointer-equality compares against
// classes you pre-resolved from image metadata. Never call class_get_name
// or any other il2cpp API on a heap-derived class pointer — it crashes.

#ifndef BD_FEATURES_H
#define BD_FEATURES_H

#include <stdint.h>
#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Helpers exposed by BDPlus.m to feature modules.
void bd_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int  bd_cfg_bool(const char *key, int defval);
int  bd_cfg_int (const char *key, int defval);
void bd_cfg_set_bool(const char *key, int value);
void bd_menu_install(void);

typedef struct {
    const char *key;               // config key AND log name
    int (*init)(void);
    int (*tick)(void);
    int initialised;               // set by dispatcher
    int init_failed;               // set if init returned non-zero
    unsigned long fires;            // dispatcher bumps if tick returns 1
    unsigned long last_tick_ms;     // dispatcher updates on each tick
    int (*rewalk)(void);           // optional per-feature rewalk (~60s)
    unsigned long last_rewalk_ms;
} BdFeature;

// Features declared here, defined in feature_<name>.c.
// Order in g_feature_registry[] = execution order on each tick.
extern BdFeature bd_feature_money;      // CurrencyManager: drip + one-shot grant
extern BdFeature bd_feature_spend;      // CurrencyManager: CheckSpendable/TrySpend -> true
extern BdFeature bd_feature_profile;    // User + AdsHelper no-ads/skins flags
extern BdFeature bd_feature_rv;         // RewardedVideo.Show -> auto-grant
extern BdFeature bd_feature_fuel;       // FuelTank.SetOilToMax polling
extern BdFeature bd_feature_stage;      // MineManager.CompleteStage action
extern BdFeature bd_feature_research;   // StatUpgradeManager instant research
extern BdFeature bd_feature_iap;        // InAppShopManager owned-flag hooks

// Find a class in `image_name` (NULL = any image) whose simple name equals
// `cls_name` AND which declares a method `method_name` with `argc` params
// (-1 = any arity). Used for IL2CPP nested types (AdsHelper.Interstitial
// etc.) whose runtime name/namespace differ from the C# display name.
// Returns NULL when not found. Safe — operates on image metadata only.
Il2CppClass *bd_find_class_verified(const char *image_name,
                                    const char *cls_name,
                                    const char *method_name, int argc);

// Convenience helpers shared by feature modules. Implemented in BDPlus.m.

// Enumerate every class in Assembly-CSharp whose name contains any of the
// `substrs`. Writes up to `cap` entries into `out_classes`. Returns count.
int bd_find_classes_by_name(const char **substrs, int substr_count,
                            Il2CppClass **out_classes, int cap);

// Walk the managed heap once. For each live object whose class is one of
// `target_classes[target_count]`, logs `prefix: class=<name> inst=<ptr>`
// via bd_log (post-walk, so class_get_name is safe). Returns total matches.
int bd_diag_log_live_instances(const char *prefix,
                               Il2CppClass * const *target_classes,
                               int target_count);

// Dump every method on `klass`: name + static-bit + arg count.
// Pre-filtered by containing one of `name_substrs` (NULL/0 = all).
void bd_diag_log_methods(const char *prefix, Il2CppClass *klass,
                         const char **name_substrs, int substr_count);

// Periodic rewalk registry — same contract as PFPlus: features register
// target classes here; BDPlus.m re-walks the heap every ~60s and logs
// first-time hits. Pass a class resolved from image metadata (never a
// heap-derived pointer). NULL is silently ignored.
void bd_register_rewalk(const char *prefix, Il2CppClass *klass);

#ifdef __cplusplus
}
#endif

#endif  // BD_FEATURES_H
