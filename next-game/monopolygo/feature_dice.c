// feature_dice.c — MGOPlus "see the next roll" predictor.
//
// Fully read-only: no hooks, no methodPointer swaps, no __TEXT writes.
// We heap-walk for the live BoardState, read its synced RNG bookkeeping
// (RandomStates["DICE_ROLL"]), and replay the exact math the game will
// use when the roll button is tapped (see MONOPOLYGO-FINDINGS.md for the
// disasm provenance of every constant here).
//
// Roll pipeline (RollCommonExecutor.<ExecuteAsync>d__3.MoveNext 0x4CBF92C):
//   offset = (RollMultiplier*83 + TokenPosition*73 + 13) % 211 + 1
//   rng    = BoardStateLogic.GetRandomWithOffset(state, "DICE_ROLL", offset)
//          = CappedRandomStateDecorator(randomState, 2000, offset)
//   roll   = Roll.RollDice(Die.StandardDice /* 2 x d6 */, rng)
//
// CappedRandomStateDecorator.ctor (0x2558658):
//   _random = new PseudoRandom(state.Seed ^ state.Iteration ^ offset)
//   burn state.State calls of _random.Next()  (each = 1 CMWC step)
// CappedRandomStateDecorator.Next(min,max) (0x2558ab4):
//   if (cap >= 1 && state.State >= cap) {           // reseed at cap
//       state.State = 0; state.Iteration++;
//       _random = new PseudoRandom(state.Seed ^ state.Iteration)  // no offset
//   }
//   v = _random.Next(min,max); state.State = _random.Stage (write-back)
// RollDice/RollDie: face = die.FaceValues[rng.Next(0, FaceValues.Length)]
//   → exactly ONE CMWC step per die. StandardDice = { Die.Standard x2 },
//   FaceValues = {1,2,3,4,5,6} (Die.cctor 0x5292960 → int[6] init blob).

#include "features.h"
#include <string.h>

// ---------- managed layout constants (dump.cs, 1.82.0) -------------------
//
// BoardState : ObservableModel (TypeDefIndex 21570). Auto-prop backing
// fields — offsets are absolute (base-class fields already accounted).
#define BS_TOKEN_POSITION   0x20   // int        <TokenPosition>
#define BS_RANDOM_STATES    0x30   // List<...>  <RandomStates>
#define BS_SCRIPTED_ROLLS   0x60   // List<int>  <ScriptedRolls>
#define BS_ROLL_MULTIPLIER  0x68   // int        <RollMultiplier>

// RandomState (TypeDefIndex 39275)
#define RS_CONTEXT   0x10   // Il2CppString* <Context>
#define RS_STATE     0x18   // int           <State>
#define RS_SEED      0x20   // long          <Seed>
#define RS_ITERATION 0x28   // long          <Iteration>

// il2cpp container layouts (stable across Unity 6):
//   List<T>:    +0x10 T[] _items; +0x18 int _size
//   array:      +0x18 int len;    +0x20 data
//   string:     +0x10 int length; +0x14 UTF-16 chars
#define LIST_ITEMS 0x10
#define LIST_SIZE  0x18
#define ARR_DATA   0x20
#define STR_LEN    0x10
#define STR_CHARS  0x14

#define DICE_STATE_CAP 2000   // StatefulRandomFactory.STATE_CAP (SRF.cctor 0x255a18c)
#define DICE_FACES     6      // Die.Standard FaceValues.Length
#define DICE_COUNT     2      // Die.StandardDice.Length
#define MAX_PEEK       6

// ---------- CMWC (PierPlay.Common.PseudoRandom port) ---------------------
//
// PseudoRandom fields: uint[] Q@0x20, c@0x28, i@0x2C, Stage@0x30.
// .ctor(long): allocs Q[16] (c=0, i=0 — zeroed object), calls SetSeed.
// SetSeed (0x255769c): xorshift32 chain fills Q[0..14];
//   Q[15] = (u32)(seed>>32) ^ (u32)seed; Stage=0. seed==0 → ArgumentException.
// Cmwc (0x2557134):  i=(i+1)&15; t=Q[i]*0x1D0AF6E + c;
//   c=t>>32; x=c+(u32)t; if (c>x){c++;x++;} Q[i]=0xFFFFFFFE-x; ret Q[i].
// Next(min,max): min + trunc(u/2^32 * (max-min)) — max-exclusive.

typedef struct { uint32_t q[16]; uint32_t c; int i; } cmwc_t;

static void cmwc_seed(cmwc_t *r, int64_t seed) {
    uint32_t w = (uint32_t)seed;
    for (int k = 0; k < 15; k++) {
        w ^= w << 13;
        w ^= w >> 17;
        w ^= w << 5;
        r->q[k] = w;
    }
    r->q[15] = (uint32_t)(seed >> 32) ^ (uint32_t)seed;
    r->c = 0;
    r->i = 0;
}

static uint32_t cmwc_next(cmwc_t *r) {
    r->i = (r->i + 1) & 15;
    uint64_t t = (uint64_t)r->q[r->i] * 0x1d0af6eULL + r->c;
    uint32_t c = (uint32_t)(t >> 32);
    uint32_t x = c + (uint32_t)t;
    if (x < c) { c++; x++; }        // disasm: cmp c,x ; cinc hi on both
    r->c = c;
    r->q[r->i] = 0xfffffffeu - x;
    return r->q[r->i];
}

// min + trunc(u * 2^-32 * (max-min)) — ucvtf d0,w,#0x20 then fcvtzs.
static int cmwc_range(cmwc_t *r, int mn, int mx) {
    uint32_t u = cmwc_next(r);
    double f = (double)u * (1.0 / 4294967296.0);
    return mn + (int)(f * (double)(mx - mn));
}

// ---------- snapshot shared with the menu --------------------------------

static mgo_dice_snapshot_t g_dice_snap;

void mgo_dice_get_snapshot(mgo_dice_snapshot_t *out) {
    memcpy(out, &g_dice_snap, sizeof g_dice_snap);
}

// ---------- BoardState discovery + parse ----------------------------------

static Il2CppClass *g_bs_klass = NULL;
// BoardState + every derived class we found at init. Heap objects of
// derived types have a different klass pointer than the base, so pointer-
// equality against just g_bs_klass would miss them even though the field
// layout at 0x20/0x30/0x60/0x68 is inherited and still valid.
#define MGO_BS_MAX_KLASSES 16
static Il2CppClass *g_bs_klasses[MGO_BS_MAX_KLASSES];
static int          g_n_bs_klasses = 0;
static void        *g_bs_inst  = NULL;
static void        *g_bs_bad   = NULL;   // instance that failed parse — skip on re-walk
static unsigned long g_last_walk_ms = 0;
static unsigned long g_dice_init_ms = 0;
static int           g_hist_done = 0;

static unsigned long now_ms(void);

// Parse RandomStates for the "DICE_ROLL" entry. All reads are bounded
// sanity-checked because the cached instance may have been freed/reused.
static int read_dice_rng(void *bs, int32_t *out_state, int64_t *out_seed,
                         int64_t *out_iter) {
    void *list = *(void **)((char *)bs + BS_RANDOM_STATES);
    if (!list) return 0;
    int32_t size = *(int32_t *)((char *)list + LIST_SIZE);
    void *items = *(void **)((char *)list + LIST_ITEMS);
    if (!items || size < 1 || size > 64) return 0;

    static const uint16_t want[9] = { 'D','I','C','E','_','R','O','L','L' };
    for (int i = 0; i < size; i++) {
        void *rs = *(void **)((char *)items + ARR_DATA + i * 8);
        if (!rs) continue;
        void *ctx = *(void **)((char *)rs + RS_CONTEXT);
        if (!ctx) continue;
        if (*(int32_t *)((char *)ctx + STR_LEN) != 9) continue;
        if (memcmp((char *)ctx + STR_CHARS, want, sizeof want) != 0) continue;
        *out_state = *(int32_t *)((char *)rs + RS_STATE);
        *out_seed  = *(int64_t *)((char *)rs + RS_SEED);
        *out_iter  = *(int64_t *)((char *)rs + RS_ITERATION);
        return 1;
    }
    return 0;
}

// Cheap liveness probe: the object's first word must still be one of our
// known BoardState klass pointers. If the slot was freed and reused, this
// fails fast.
static int bs_alive(void *bs) {
    if (!bs || g_n_bs_klasses == 0) return 0;
    void *k = *(void **)bs;
    for (int i = 0; i < g_n_bs_klasses; i++)
        if (k == (void *)g_bs_klasses[i]) return 1;
    return 0;
}

// Heap-walk for BoardState instances; prefer one that actually parses a
// DICE_ROLL entry (guards against lookalike/stale copies). Throttled —
// the walk is stop-the-world over the whole managed heap.
static void *resolve_boardstate(void) {
    if (g_bs_inst && bs_alive(g_bs_inst)) return g_bs_inst;
    g_bs_inst = NULL;
    if (!g_bs_klass) return NULL;

    unsigned long t = now_ms();
    if (g_last_walk_ms && (t - g_last_walk_ms) < 2000UL) return NULL;
    g_last_walk_ms = t;

    void *found[16];
    int n = mgo_il2cpp_find_instances_any(g_bs_klasses, g_n_bs_klasses, found, 16);
    if (n <= 0) return NULL;

    int32_t st; int64_t sd, it;
    for (int i = 0; i < n; i++) {
        if (found[i] == g_bs_bad) continue;
        if (read_dice_rng(found[i], &st, &sd, &it)) {
            g_bs_inst = found[i];
            mgo_log("dice: BoardState %p chosen (candidate %d of %d)", found[i], i + 1, n);
            return g_bs_inst;
        }
    }
    mgo_log("dice: %d BoardState instance(s) found but none parses DICE_ROLL", n);
    return NULL;
}

// ---------- prediction ----------------------------------------------------

// Offset formula from MoveNext: (mult*83 + pos*73 + 13) % 211 + 1.
// Operands kept in 64-bit; the game computes in 32-bit — mult/pos are
// small positive ints so plain int math matches.
static int roll_offset(int mult, int pos) {
    return (mult * 83 + pos * 73 + 13) % 211 + 1;
}

// Replay `n` rolls of the decorator simulation forward.
static void predict_rolls(int64_t seed, int64_t iter, int32_t state,
                          int offset, int n, mgo_roll_t *out) {
    int64_t it = iter;
    int32_t st = state;
    for (int k = 0; k < n; k++) {
        cmwc_t p;
        cmwc_seed(&p, seed ^ it ^ offset);   // ctor: fresh seed per roll
        for (int32_t b = 0; b < st; b++)     // ctor: burn state.State Next()s
            cmwc_next(&p);

        mgo_roll_t *r = &out[k];
        r->n = DICE_COUNT;
        r->sum = 0;
        r->doubles = (DICE_COUNT > 1);
        for (int d = 0; d < DICE_COUNT; d++) {
            if (st >= DICE_STATE_CAP) {      // Next() cap branch
                st = 0;
                it++;
                cmwc_seed(&p, seed ^ it);    // reseed WITHOUT offset
            }
            int idx = cmwc_range(&p, 0, DICE_FACES);  // one CMWC step
            st++;                                   // Stage write-back
            if (idx < 0) idx = 0;
            if (idx >= DICE_FACES) idx = DICE_FACES - 1;
            r->d[d] = idx + 1;             // FaceValues = {1..6}
            r->sum += r->d[d];
            if (d > 0 && r->d[d] != r->d[0]) r->doubles = 0;
        }
    }
}

// ---------- feature --------------------------------------------------------


// Signature of the inputs that affect prediction — recompute + re-log only
// when one of these moves (position changes mid-animation, state advances
// per roll, iteration bumps at cap, multiplier toggles with boosts).
typedef struct { int32_t st, mult, pos; int64_t it, sd; int32_t nscr; } sig_t;
static sig_t g_last_sig = { -1, -1, -1, -1, -1, -1 };
static int   g_last_peek = -1;

static int dice_init(void) {
    const char *via = NULL;
    // 1.82.0 ships BoardState in Tophat.Common.dll, not Assembly-CSharp.dll
    // (confirmed by the init enumeration from the previous diagnostic build).
    g_bs_klass = mgo_il2cpp_find_class("Tophat.Common.dll",
                                     "Tophat.Common.Board.State", "BoardState");
    if (g_bs_klass) via = "image+ns";
    if (!g_bs_klass) {
        g_bs_klass = mgo_il2cpp_find_class(NULL, "Tophat.Common.Board.State", "BoardState");
        if (g_bs_klass) via = "ns-only";
    }
    if (!g_bs_klass) {
        g_bs_klass = mgo_il2cpp_find_class(NULL, NULL, "BoardState");
        if (g_bs_klass) via = "name-only (UNSAFE)";
    }
    if (!g_bs_klass) {
        mgo_log("dice: BoardState class NOT FOUND");
        return -1;
    }
    const char *ns = mgo_il2cpp_class_get_namespace(g_bs_klass);
    const char *nm = mgo_il2cpp_class_get_name(g_bs_klass);
    int mc = mgo_il2cpp_count_methods(g_bs_klass);
    mgo_log("dice: BoardState class=%p via=%s ns=%s name=%s method_count=%d",
            (void *)g_bs_klass, via, ns ? ns : "(null)", nm ? nm : "(null)", mc);

    g_bs_klasses[g_n_bs_klasses++] = g_bs_klass;

    // The prior build matched zero live objects in the heap walk even on
    // the correct base class. Most likely the game instantiates a derived
    // type (e.g. a game-mode-specific state), whose klass pointer differs
    // from the base — pointer-equality against g_bs_klass can't catch it.
    // Enumerate every class that is_assignable_from(BoardState, k) and
    // include them in the heap-walk target set. The field layout at
    // 0x20/0x30/0x60/0x68 is inherited, so read_dice_rng still works.
    Il2CppDomain *dom = mgo_il2cpp_domain_get();
    if (dom && mgo_il2cpp_domain_get_assemblies && mgo_il2cpp_class_is_assignable_from) {
        size_t n_asm = 0;
        const Il2CppAssembly **asms = mgo_il2cpp_domain_get_assemblies(dom, &n_asm);
        for (size_t ai = 0; ai < n_asm && g_n_bs_klasses < MGO_BS_MAX_KLASSES; ai++) {
            const Il2CppImage *img = mgo_il2cpp_assembly_get_image(asms[ai]);
            if (!img) continue;
            const char *in = mgo_il2cpp_image_get_name(img);
            size_t ncl = mgo_il2cpp_image_get_class_count(img);
            for (size_t ci = 0; ci < ncl && g_n_bs_klasses < MGO_BS_MAX_KLASSES; ci++) {
                Il2CppClass *k = mgo_il2cpp_image_get_class(img, ci);
                if (!k || k == g_bs_klass) continue;
                if (!mgo_il2cpp_class_is_assignable_from(g_bs_klass, k)) continue;
                const char *kn  = mgo_il2cpp_class_get_name(k);
                const char *kns = mgo_il2cpp_class_get_namespace(k);
                mgo_log("dice: subclass %p image=%s ns=%s name=%s",
                        (void *)k, in ? in : "(null)",
                        kns ? kns : "(null)", kn ? kn : "(null)");
                g_bs_klasses[g_n_bs_klasses++] = k;
            }
        }
    }
    mgo_log("dice: %d BoardState class(es) total (base + subclasses)", g_n_bs_klasses);

    // Build the known-klass set so the fallback heap histogram (dice_tick)
    // can safely call class_get_name on klass pointers collected during
    // gc_foreach_heap.
    mgo_il2cpp_build_klass_set();

    g_dice_init_ms = now_ms();
    return 0;
}

static int dice_tick(void) {
    void *bs = resolve_boardstate();
    if (!bs) {
        // Fallback diagnostic: if BoardState hasn't been found ~20s after
        // init, dump every Tophat.* class with a live instance. Tells us
        // whether BoardState is literally on the heap under a klass pointer
        // that differs from the one image metadata hands us (closed-generic
        // instantiation, runtime-synthesized type), or whether gameplay
        // state isn't live at all.
        if (!g_hist_done && g_dice_init_ms &&
            (now_ms() - g_dice_init_ms) > 20000UL) {
            g_hist_done = 1;
            mgo_log("dice: no BoardState for 20s after init — dumping Tophat.* heap histogram");
            mgo_il2cpp_heap_histogram("Tophat.");
        }
        if (g_dice_snap.valid) {
            memset(&g_dice_snap, 0, sizeof g_dice_snap);
            mgo_log("dice: BoardState lost — snapshot cleared");
        }
        return 0;
    }

    int32_t st; int64_t sd, it;
    if (!read_dice_rng(bs, &st, &sd, &it)) {
        // Object alive but content shifted — mark it so the re-walk picks
        // a different candidate instead of re-selecting this one forever.
        mgo_log("dice: instance %p failed DICE_ROLL parse — skipping it", bs);
        g_bs_bad = bs;
        g_bs_inst = NULL;
        return 0;
    }
    int mult = *(int32_t *)((char *)bs + BS_ROLL_MULTIPLIER);
    int pos  = *(int32_t *)((char *)bs + BS_TOKEN_POSITION);

    // ScriptedRolls (List<int>): literal upcoming roll distances when the
    // server queues them. Read verbatim, capped at 16.
    int nscr = 0;
    int scr[16] = {0};
    void *slist = *(void **)((char *)bs + BS_SCRIPTED_ROLLS);
    if (slist) {
        int32_t sz = *(int32_t *)((char *)slist + LIST_SIZE);
        void *it_arr = *(void **)((char *)slist + LIST_ITEMS);
        if (it_arr && sz > 0 && sz <= 1024) {
            nscr = sz > 16 ? 16 : sz;
            for (int i = 0; i < nscr; i++)
                scr[i] = *(int32_t *)((char *)it_arr + ARR_DATA + i * 4);
        } else {
            nscr = 0;
        }
    }

    int peek = mgo_cfg_int("peek", 3);
    if (peek < 1) peek = 1;
    if (peek > MAX_PEEK) peek = MAX_PEEK;

    sig_t sig = { st, mult, pos, it, sd, nscr };
    // Memberwise compare — memcmp would drag in uninitialized padding.
    // peek included so a config edit re-renders even when state is static.
    if (g_dice_snap.valid && peek == g_last_peek &&
        sig.st == g_last_sig.st && sig.mult == g_last_sig.mult &&
        sig.pos == g_last_sig.pos && sig.it == g_last_sig.it &&
        sig.sd == g_last_sig.sd && sig.nscr == g_last_sig.nscr)
        return 0;   // nothing changed — keep the snapshot as-is
    g_last_sig = sig;
    g_last_peek = peek;

    mgo_dice_snapshot_t s;
    memset(&s, 0, sizeof s);
    s.valid = 1;
    s.n_rolls = peek;
    s.roll_mult = mult;
    s.token_pos = pos;
    s.rng_state = st;
    s.iter = (int)it;
    s.seed = (long long)sd;
    s.n_scripted = nscr;
    s.scripted_present = nscr > 0;
    memcpy(s.scripted, scr, sizeof(int) * nscr);

    int off = roll_offset(mult, pos);
    predict_rolls(sd, it, st, off, peek, s.rolls);
    g_dice_snap = s;

    mgo_roll_t *r0 = &s.rolls[0];
    if (mgo_cfg_bool("log_rolls", 1)) {
        mgo_log("dice: next=%d+%d=%d%s | mult=%d pos=%d st=%d it=%lld off=%d%s",
                r0->d[0], r0->d[1], r0->sum, r0->doubles ? " DOUBLES" : "",
                mult, pos, st, (long long)it, off,
                nscr ? " [scripted]" : "");
    }
    return 1;
}

MgoFeature mgo_feature_dice = {
    .key = "dice",
    .init = dice_init,
    .tick = dice_tick,
    .initialised = 0,
    .init_failed = 0,
    .fires = 0,
    .last_tick_ms = 0,
};

// One shared timebase with MGOPlus.m's (file-local there too — duplicate
// tiny helper rather than export plumbing for 8 lines).
#include <sys/time.h>
static unsigned long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}
