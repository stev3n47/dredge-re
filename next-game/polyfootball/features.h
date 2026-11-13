// PFPlus feature registry.
//
// Each feature lives in its own C file (feature_<name>.c) and provides one
// `PfpFeature` struct that the central dispatcher in PFPlus.m calls on
// every tick. Features are independent — adding/removing one is a single
// entry in g_feature_registry[] in PFPlus.m.
//
// Contract:
//   int init(void)   — called once after il2cpp is ready. Resolve classes
//                      / methods, cache in file-local statics. Return 0 on
//                      success (tick will run). Non-zero disables this
//                      feature for the session. Log via pfp_log(). Must
//                      not keep heap-derived class pointers.
//   int tick(void)   — called on each 10 Hz main-runloop tick. Return 1
//                      if the feature did meaningful work (bumps fires).
//                      Called only after init succeeds AND
//                      pfp_cfg_bool(feature->key, 1) is non-zero.
//
// Heap-walk safety rule (SPPlus v33+): inside a gc_foreach_heap callback,
// read ONLY obj->klass via pfp_il2cpp_object_get_class() and do pointer
// equality compares against classes you pre-resolved from image metadata.
// Never call class_get_name, is_assignable_from, or any other il2cpp API
// on a heap-derived class pointer — it crashes.

#ifndef PFP_FEATURES_H
#define PFP_FEATURES_H

#include <stdint.h>
#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Helpers exposed by PFPlus.m to feature modules.
void pfp_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int  pfp_cfg_bool(const char *key, int defval);
int  pfp_cfg_int (const char *key, int defval);

typedef struct {
    const char *key;               // config key AND log name
    int (*init)(void);
    int (*tick)(void);
    int initialised;               // set by dispatcher
    int init_failed;               // set if init returned non-zero
    unsigned long fires;            // dispatcher bumps if tick returns 1
    unsigned long last_tick_ms;     // dispatcher updates on each tick
} PfpFeature;

// Features declared here, defined in feature_<name>.c.
// Order in g_feature_registry[] = execution order on each tick.
extern PfpFeature pfp_feature_money;     // v1b: free career money
extern PfpFeature pfp_feature_skills;    // v1b: free skill points
extern PfpFeature pfp_feature_iap;       // v1.5: IAP receipt bypass (Stores.dll)
extern PfpFeature pfp_feature_sync;      // v1e: server-sync short-circuit
extern PfpFeature pfp_feature_fumbles;   // v2a: diagnostic, FootballFumbleRules
extern PfpFeature pfp_feature_injuries;  // v2a: diagnostic, InjuryCatalog
extern PfpFeature pfp_feature_tackle;    // v2a: diagnostic, FootballCarrierMoveRules
extern PfpFeature pfp_feature_catch;     // v2a: diagnostic, FootballCatchReach
extern PfpFeature pfp_feature_throw;     // v2a: diagnostic, ThrowController
extern PfpFeature pfp_feature_speed;     // v2a: diagnostic, CarrierMoveControls

// Convenience helpers shared by diagnostic features. Implemented in PFPlus.m.

// Enumerate every class in Assembly-CSharp whose name contains any of the
// `substrs`. Writes up to `cap` entries into `out_classes`. Returns count.
// Safe (operates on image metadata, not heap pointers).
int pfp_find_classes_by_name(const char **substrs, int substr_count,
                             Il2CppClass **out_classes, int cap);

// Walk the managed heap once. For each live object whose class is one of
// `target_classes[target_count]`, logs `prefix: class=<name> inst=<ptr>`
// via pfp_log (post-walk, so class_get_name is safe). Returns total
// matches logged. Follows SPPlus v33+ safety rules.
int pfp_diag_log_live_instances(const char *prefix,
                                Il2CppClass * const *target_classes,
                                int target_count);

// Dump every method on `klass`: name + static-bit + arg count.
// Pre-filtered by containing one of `name_substrs` (NULL/0 = all).
void pfp_diag_log_methods(const char *prefix, Il2CppClass *klass,
                          const char **name_substrs, int substr_count);

#ifdef __cplusplus
}
#endif

#endif  // PFP_FEATURES_H
