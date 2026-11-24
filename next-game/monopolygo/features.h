// MGOPlus feature registry.
//
// Each feature lives in its own C file (feature_<name>.c) and provides one
// `MgoFeature` struct that the central dispatcher in MGOPlus.m calls on
// every tick. Features are independent — adding/removing one is a single
// entry in g_feature_registry[] in MGOPlus.m.
//
// Contract (same as PFPlus):
//   int init(void)   — called once after il2cpp is ready. Resolve classes,
//                      cache in file-local statics. Return 0 on success.
//                      Non-zero disables this feature for the session.
//   int tick(void)   — called on each 10 Hz main-runloop tick. Return 1
//                      if the feature did meaningful work (bumps fires).
//
// Heap-walk safety rule (SPPlus v33+): inside a gc_foreach_heap callback,
// read ONLY obj->klass via mgo_il2cpp_object_get_class() and do pointer
// equality compares against classes pre-resolved from image metadata.
// Never call class_get_name, is_assignable_from, or any other il2cpp API
// on a heap-derived class pointer — it crashes.

#ifndef MGO_FEATURES_H
#define MGO_FEATURES_H

#include <stdint.h>
#include "il2cpp_bridge.h"

#ifdef __cplusplus
extern "C" {
#endif

// Helpers exposed by MGOPlus.m to feature modules.
void mgo_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int  mgo_cfg_bool(const char *key, int defval);
int  mgo_cfg_int (const char *key, int defval);
void mgo_cfg_set_bool(const char *key, int value);
void mgo_menu_install(void);
void mgo_menu_refresh(void);

typedef struct {
    const char *key;               // config key AND log name
    int (*init)(void);
    int (*tick)(void);
    int initialised;               // set by dispatcher
    int init_failed;               // set if init returned non-zero
    unsigned long fires;           // dispatcher bumps if tick returns 1
    unsigned long last_tick_ms;    // dispatcher updates on each tick
} MgoFeature;

// Features declared here, defined in feature_<name>.c.
extern MgoFeature mgo_feature_dice;      // v1: see-the-next-roll predictor

// Snapshot produced by feature_dice.c each time the RNG inputs change.
// The menu reads it via mgo_dice_get_snapshot() on the main runloop —
// single writer, so no locking needed.
typedef struct {
    int d[4];      // face values per die (1..6)
    int n;         // dice count
    int sum;
    int doubles;   // all dice equal
} mgo_roll_t;

typedef struct {
    int  valid;            // 0 = no live BoardState parsed yet
    int  n_rolls;
    mgo_roll_t rolls[6];
    int  roll_mult;        // BoardState.RollMultiplier
    int  token_pos;        // BoardState.TokenPosition
    int  rng_state;        // RandomState.State (draws consumed, /2000 cap)
    int  iter;             // RandomState.Iteration
    long long seed;        // RandomState.Seed
    int  n_scripted;
    int  scripted[16];     // ScriptedRolls contents (upcoming distances)
    int  scripted_present;
} mgo_dice_snapshot_t;

void mgo_dice_get_snapshot(mgo_dice_snapshot_t *out);

#ifdef __cplusplus
}
#endif

#endif  // MGO_FEATURES_H
