// SpooferProPlus — add-our-own-on-top-of-theirs automation for the
// SpooferPro 0.435.1 (Pokémon GO 0.743) IPA.
//
// ARCHITECTURAL CAVEAT — read before trusting any release/catch feature:
//
// iPoGo and SpooferPro BOTH invoke il2cpp runtime directly (strings
// auditing — see SPOOFERPRO-FINDINGS.md "Why IPAuto never worked right").
// Neither of them splices rpc2 from their own NSURLSession. The reason is
// Niantic's anti-cheat: the game's own rpc2 envelopes carry a signed
// platform_request[5] (HasAbrLookup) with packed timing metadata; any
// envelope with a different shape (e.g. ours, shipping a RELEASE_POKEMON
// method from a fresh session) is a strong anti-cheat signal.
//
// This dylib is still a rpc2-based implementation because the il2cpp path
// requires per-PoGo-version UnityFramework offset tables (UnityFramework
// exports a 24-byte empty trie, so symbols are not available at runtime —
// every il2cpp_* must be resolved by file offset into the mapped image).
// Dumping offsets for v0.743 (metadata v39) needs Il2CppInspectorRedux —
// a multi-session project.
//
// So: our release_on_catch / bag_full_clean / auto_catch are LIKELY to
// be rejected or shadow-banned by Niantic. Treat them as experimental.
// The safe features (encounter_log and the on-screen UI) work fine.
// For reliable automation, use the iPoGo IPA directly (which has the
// il2cpp bridge for PoGo v0.435.1) and run SpooferProPlus alongside only
// for its logging and UI — see SPOOFERPRO-FINDINGS.md.
//
// --------------
// This file is a feature-parity fork of next-game/pogo/IPAuto.m with:
//   - renamed entry point   (ipauto_init    -> spplus_init)
//   - renamed log/config    (ipauto.log/json -> sppro_plus.log/json)
//   - renamed UI button      ("IP"           -> "SP+")
//   - renamed sheet title    ("IPAuto"       -> "SpooferProPlus")
//   - renamed hook-recursion header (X-IPAuto -> X-SpooferProPlus)
//
// Added to the IPAuto base:
//   - dry_run default true, with on-screen DRY-RUN/LIVE indicator
//   - bag_clean_max safety abort (release >N% of bag -> refuse)
//   - parse_looks_broken() fail-safe in should_keep (PokemonProto
//     fields are ASSUMED; a broken parse is kept, not released)
//   - should_keep: drop_species evaluates BEFORE IV% (IPAuto's order
//     let a 40/45 Rattata in drop_species slip through as "kept")
//   - IV% rounded-to-nearest (matches in-game display 89% for 40/45,
//     not IPAuto's truncated 88%)
//   - requests_field hardcoded to 4 (Niantic convention since v0.117)
//     with config override; removed the fragile >=50 auto-detector
//   - auto_catch (ENCOUNTER=102/DISK=145 -> splice CATCH_POKEMON=103
//     with configured ball + excellent + curveball, respects dry_run)
//   - encounter blocker scaffold (block_non_shiny / _hundo / _shundo;
//     needs a flee_method_id captured by watching the log during one
//     manual Run-away)
//
// Safety: release_on_catch, bag_full_clean, auto_catch all default off
// AND the top-level dry_run defaults on. Even flipping those on will
// not post anything unless dry_run is also flipped off.

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include "il2cpp_bridge.h"
#include "il2cpp_offsets_pogo0743.h"

// ---- minimal ObjC runtime surface (SDK headers are partially symlink-broken) --
typedef void *IMP;
typedef void *Method;
typedef int BOOL;
#define YES ((BOOL)1)
#define NO  ((BOOL)0)
#define nil ((id)0)
typedef struct objc_object NSString, NSData, NSNumber, NSArray, NSMutableArray,
    NSMutableData, NSMutableDictionary, NSDictionary, NSURL, NSMutableURLRequest,
    NSURLSession, NSURLSessionTask, NSURLResponse, NSError, NSFileManager, NSFileHandle,
    UIApplication, UIWindow, UIView, UIButton, UIColor, UIAlertController, UIAlertAction,
    UIPanGestureRecognizer, NSTimer;

extern id objc_msgSend();
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);
extern id objc_retain(id);
extern void objc_release(id);
extern Class objc_getClass(const char *);
extern Class object_getClass(id);
extern const char *class_getName(Class);
extern SEL sel_registerName(const char *);
extern const char *sel_getName(SEL);
extern Method class_getInstanceMethod(Class, SEL);
extern IMP method_getImplementation(Method);
extern IMP method_setImplementation(Method, IMP);
extern int objc_sync_enter(id);
extern int objc_sync_exit(id);
extern Class objc_allocateClassPair(Class, const char *, size_t);
extern void objc_registerClassPair(Class);
extern BOOL class_addMethod(Class, SEL, IMP, const char *);
// No dispatch_* here: dispatch_get_main_queue binds flat-namespace under
// -undefined dynamic_lookup and resolved to 0 on-device (PC=0 inside dyld's
// initializer loop — the silent launch crash). All main-thread deferral uses
// ObjC: NSOperationQueue.mainQueue / NSTimer+NSRunLoop.mainRunLoop.
extern void *_Block_copy(const void *);
extern int objc_getClassList(Class *, int);
extern Class class_getSuperclass(Class);

typedef struct { double x, y; } CGPoint;
typedef struct { double x, y, w, h; } CGRect;

#define S(s) sel_registerName(s)
#define C(s) objc_getClass(s)

// --- SEND macro — arm64 Darwin ABI fix --------------------------------------
// IPAuto's original SEND cast objc_msgSend to a VARIADIC signature:
//   ((id (*)(id, SEL, ...))objc_msgSend)((id)o, ...)
// On Darwin arm64, variadic calls put arguments on the stack. objc_msgSend's
// implementation only reads x0..x7 — so args went to the stack and were
// never seen by the resolved IMP. The crash showed up as a NULL/garbage
// deref inside the first `+[NSString stringWithUTF8String:]` call during
// spplus_init (confirmed by the ips log dated 2026-11-09 21:18:35).
//
// Fix: non-variadic casts, one signature per arity. A dispatch macro picks
// the right arity by counting commas in __VA_ARGS__; every call site stays
// unchanged.
#define _SP_SEND0(o, s)             \
    ((id (*)(id, SEL))objc_msgSend)((id)(o), (SEL)(s))
#define _SP_SEND1(o, s, a1)         \
    ((id (*)(id, SEL, uintptr_t))objc_msgSend)((id)(o), (SEL)(s), (uintptr_t)(uintptr_t)(a1))
#define _SP_SEND2(o, s, a1, a2)     \
    ((id (*)(id, SEL, uintptr_t, uintptr_t))objc_msgSend)((id)(o), (SEL)(s), (uintptr_t)(a1), (uintptr_t)(a2))
#define _SP_SEND3(o, s, a1, a2, a3) \
    ((id (*)(id, SEL, uintptr_t, uintptr_t, uintptr_t))objc_msgSend)((id)(o), (SEL)(s), (uintptr_t)(a1), (uintptr_t)(a2), (uintptr_t)(a3))
#define _SP_SEND4(o, s, a1, a2, a3, a4) \
    ((id (*)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t))objc_msgSend)((id)(o), (SEL)(s), (uintptr_t)(a1), (uintptr_t)(a2), (uintptr_t)(a3), (uintptr_t)(a4))
// Count args AFTER (o, s), dispatch to the right arity. Works for 0..4 extras.
#define _SP_SEND_NARG_(_1,_2,_3,_4,_5,N,...) N
#define _SP_SEND_COUNT(...) _SP_SEND_NARG_(_, ##__VA_ARGS__, 4, 3, 2, 1, 0)
#define _SP_SEND_CAT_(a,b) a##b
#define _SP_SEND_CAT(a,b) _SP_SEND_CAT_(a,b)
#define _SP_SEND_PICK(N) _SP_SEND_CAT(_SP_SEND, N)
// When __VA_ARGS__ has only the selector (no extras), _SP_SEND_COUNT returns 0
// and we call _SP_SEND0 with (o, s). Otherwise it matches the arity exactly.
#define SEND(o, s, ...)                                                       \
    _SP_SEND_PICK(_SP_SEND_COUNT(__VA_ARGS__))(o, s, ##__VA_ARGS__)
// A second name for the same dispatch: a macro is never re-expanded inside
// its own expansion, so a nested SEND(...) inside another SEND's argument
// list would stay literal ("undeclared function SEND"). Use SENDN for the
// inner call.
#define SENDN(o, s, ...)                                                      \
    _SP_SEND_PICK(_SP_SEND_COUNT(__VA_ARGS__))(o, s, ##__VA_ARGS__)
// --- end arm64 ABI fix ----------------------------------------------------

typedef void (^RespCB)(NSData *, NSURLResponse *, NSError *);

static NSString *nsstr(const char *c) {
    return (NSString *)SEND(C("NSString"), S("stringWithUTF8String:"), c);
}

// ---- main-queue helpers ----------------------------------------------------
// ObjC-only equivalents of dispatch_async/_after on the main queue. The
// unscheduled-timer + mainRunLoop.addTimer form works from ANY thread —
// unlike scheduledTimerWithTimeInterval: which binds to the caller's run
// loop (NSURLSession delegate callbacks don't run on one).
typedef id (*TimerFactoryImp)(id, SEL, double, int, id);
static void run_on_main(id blk) {
    SENDN(SEND(C("NSOperationQueue"), S("mainQueue")), S("addOperationWithBlock:"), blk);
}
static void run_on_main_later(double secs, id blk) {
    id t = ((TimerFactoryImp)objc_msgSend)(C("NSTimer"),
        S("timerWithTimeInterval:repeats:block:"), secs, 0, blk);
    SENDN(SEND(C("NSRunLoop"), S("mainRunLoop")), S("addTimer:forMode:"),
          t, nsstr("kCFRunLoopDefaultMode"));
}

// ---- logging -------------------------------------------------------------------
// Rotates at ~1 MB to .1 to keep Documents from growing unboundedly over a
// long play session (ipalog hit count is dominated by HOLO_INV mon dumps).
#define IPA_LOG_MAX (1 * 1024 * 1024)
static NSString *gLogPath, *gLogPath1;
// External linkage so il2cpp_bridge.c (a separate translation unit) can
// log through the same rotating file.
void ipalog(const char *fmt, ...) {
    char buf[2048];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    void *p = objc_autoreleasePoolPush();
    id fm = SEND(C("NSFileManager"), S("defaultManager"));
    if (!SEND(fm, S("fileExistsAtPath:"), gLogPath))
        SEND(nsstr(""), S("writeToFile:atomically:encoding:error:"), gLogPath, YES, 4, nil);
    // rotate if oversized
    id attrs = SEND(fm, S("attributesOfItemAtPath:error:"), gLogPath, nil);
    id sz = attrs ? SEND(attrs, S("objectForKey:"), nsstr("NSFileSize")) : nil;
    if (sz && (long long)(intptr_t)SEND(sz, S("longLongValue")) > IPA_LOG_MAX && gLogPath1) {
        SEND(fm, S("removeItemAtPath:error:"), gLogPath1, nil);
        SEND(fm, S("moveItemAtPath:toPath:error:"), gLogPath, gLogPath1, nil);
        SEND(nsstr(""), S("writeToFile:atomically:encoding:error:"), gLogPath, YES, 4, nil);
    }
    id h = SEND(C("NSFileHandle"), S("fileHandleForWritingAtPath:"), gLogPath);
    SEND(h, S("seekToEndOfFile"));
    id line = SEND(nsstr(buf), S("stringByAppendingString:"), nsstr("\n"));
    SEND(h, S("writeData:"), SENDN(line, S("dataUsingEncoding:"), 4));
    SEND(h, S("closeFile"));
    objc_autoreleasePoolPop(p);
}

// ---- protobuf wire (pure C) ------------------------------------------------------
typedef struct { const uint8_t *p, *end; } pb_t;
static int pb_varint(pb_t *b, uint64_t *out) {
    uint64_t v = 0; int s = 0;
    while (b->p < b->end) {
        uint8_t c = *b->p++;
        v |= (uint64_t)(c & 0x7f) << s;
        if (!(c & 0x80)) { *out = v; return 1; }
        if ((s += 7) > 63) return 0;
    }
    return 0;
}
// Iterate fields. For wire==0 the decoded value goes to *v (val/len unused).
// For 1/2/5, val+len describe the payload.
static int pb_field(pb_t *b, uint32_t *num, uint32_t *wire,
                    const uint8_t **val, uint32_t *len, uint64_t *v) {
    uint64_t tag;
    if (!pb_varint(b, &tag)) return 0;
    *num = (uint32_t)(tag >> 3); *wire = (uint32_t)(tag & 7);
    switch (*wire) {
        case 0: return pb_varint(b, v);
        case 2: { uint64_t l; if (!pb_varint(b, &l) || b->p + l > b->end) return 0;
                  *val = b->p; *len = (uint32_t)l; b->p += l; return 1; }
        case 5: { if (b->p + 4 > b->end) return 0; *val = b->p; *len = 4; b->p += 4;
                uint32_t t; memcpy(&t, *val, 4); *v = t; return 1; }
        case 1: if (b->p + 8 > b->end) return 0; *val = b->p; *len = 8; b->p += 8;
                memcpy(v, *val, 8); return 1;
    }
    return 0;
}

typedef struct { uint8_t *p; size_t cap, len; } wbuf;
static void wb_put(wbuf *w, const void *d, size_t n) {
    if (w->len + n > w->cap) { w->cap = (w->cap + n + 64) * 2; w->p = realloc(w->p, w->cap); }
    memcpy(w->p + w->len, d, n); w->len += n;
}
static void wb_varint(wbuf *w, uint64_t v) { uint8_t c; do { c = v & 0x7f; v >>= 7; if (v) c |= 0x80; wb_put(w, &c, 1); } while (v); }
static void wb_tag(wbuf *w, uint32_t num, uint32_t wire) { wb_varint(w, ((uint64_t)num << 3) | wire); }
static void wb_f64(wbuf *w, uint32_t num, uint64_t v) { wb_tag(w, num, 1); wb_put(w, &v, 8); }
static void wb_var(wbuf *w, uint32_t num, uint64_t v) { wb_tag(w, num, 0); wb_varint(w, v); }
static void wb_bytes(wbuf *w, uint32_t num, const void *d, size_t n) { wb_tag(w, num, 2); wb_varint(w, n); wb_put(w, d, n); }

// ---- globals ---------------------------------------------------------------------
static NSData *gTemplate;
static NSString *gRPCURL;
static NSURLSession *gOwnSession;
static NSMutableArray *gPending;      // caught uids awaiting inventory evaluation
static NSDictionary *gCfg;
static NSArray *gKeepSpecies, *gDropSpecies;
static int gRequestsField = 4;       // auto-detected; classic default
static int gLoggedEnv = 0;
static unsigned long gSeq;

// delegate-capture state (UnityWebRequest path)
static NSMutableDictionary *gTaskBuf;  // NSURLSessionTask -> NSMutableData
static id gSyncObj;
// Grown dynamically — Unity + iPoGo + WebKit + any plugin stack can each
// bring its own delegate class, and a fixed 8-slot table silently dropped
// later ones. NULL until first swizzle_delegate.
static Class *gSwz;
static IMP *gSwzData, *gSwzDone;
static int gNSwz, gSwzCap;
// Nearest registered swizzle entry up the superclass chain — an inherited
// hook can fire for subclasses that aren't in gSwz directly.
static IMP find_swz(Class c, IMP *tab) {
    IMP f = NULL;
    @synchronized ((id)gSyncObj) {
        for (Class p = c; p; p = class_getSuperclass(p))
            for (int i = 0; i < gNSwz; i++)
                if (gSwz[i] == p) { f = tab[i]; goto out; }
    }
out:
    return f;
}

// inventory walk modes
static int gMode;                      // 0=none 1=count 2=clean 3=pending
static int gMonCount;
static wbuf gBatch;                    // field-2 fixed64 uids for batch release
static int gBatchN;

// on-screen UI (floating IP button + alert-sheet toggles)
static NSString *gCfgPath;
static id gBtn, gTarget;
static int gUIInit, gCleanOnce;

#define M_HOLO_INV   4
#define M_ENCOUNTER 102
#define M_CATCH     103
#define M_RELEASE   112
#define M_RECYCLE   137
#define M_DISK_ENC  145
// RUN_FROM_ENCOUNTER / flee method id is uncertain for v0.743; Niantic has
// historically used both 106 (legacy) and client-side-only flees. The
// encounter blocker below logs the method ids seen on a non-shiny wild and
// leaves the flee splice disabled until the user supplies the right id in
// the config under "flee_method_id". Keeping the ENCOUNTER=102 response
// parse working in the interim gives a shiny-detection alert / log.

static int cfg_i(const char *k) {
    id n = SEND(gCfg, S("objectForKey:"), nsstr(k));
    return n ? (int)(intptr_t)SEND(n, S("intValue")) : 0;
}

static void load_config(void) {
    id paths = SEND(C("NSFileManager"), S("defaultManager"));
    paths = SEND(paths, S("URLsForDirectory:inDomains:"), 9, 1);
    id docs = SEND(SEND(paths, S("lastObject")), S("path"));
    gLogPath = objc_retain(SEND(docs, S("stringByAppendingPathComponent:"), nsstr("sppro_plus.log")));
    gLogPath1 = objc_retain(SEND(docs, S("stringByAppendingPathComponent:"), nsstr("sppro_plus.log.1")));
    NSString *cfg = SEND(docs, S("stringByAppendingPathComponent:"), nsstr("sppro_plus.json"));
    gCfgPath = objc_retain(cfg);
    id d = SEND(C("NSData"), S("dataWithContentsOfFile:"), cfg);
    if (d) {
        gCfg = objc_retain(SEND(SEND(C("NSJSONSerialization"), S("JSONObjectWithData:options:error:"), d, 0, nil), S("mutableCopy")));
    }
    if (!gCfg) {
        // Defaults are safe-by-default: release_on_catch OFF until the user
        // has reviewed sppro_plus.log and confirmed the first logged catch shows
        // the correct uid and the first logged mon shows the correct
        // shiny/fav/buddy/lucky fields — PokemonProto field numbers for
        // v0.435 are inferred, not read from a .proto. If any of them are
        // wrong, release_on_catch=true would transfer a desired keeper.
        const char *json =
            // Safety-first defaults — flip off once sppro_plus.log confirms
            // every PokemonProto field (shiny/fav/buddy/lucky/atk/def/sta/
            // uid) is parsing correctly for your Pokémon GO version. See
            // SPOOFERPRO-FINDINGS.md "on-device verification order".
            //
            // release_mode: "rpc2" (default, experimental), "il2cpp" (try
            // il2cpp first, fall back to rpc2), "il2cpp_only" (il2cpp only,
            // skip release if not ready). il2cpp is the architecturally
            // correct path; see the il2cpp bridge probe output in the log.
            "{\"dry_run\":true,\"bag_clean_max\":50,\"release_mode\":\"rpc2\","
            "\"release_on_catch\":false,\"bag_full_clean\":false,"
            "\"keep_shiny\":true,\"keep_hundo\":true,\"keep_favorite\":true,"
            "\"keep_buddy\":true,\"keep_lucky\":true,\"keep_legendary\":true,"
            "\"iv_pct_min\":90,\"bag_threshold\":1800,"
            "\"keep_species\":[],\"drop_species\":[],"
            "\"encounter_log\":true,"
            "\"block_non_shiny\":false,\"block_non_hundo\":false,"
            "\"block_non_shundo\":false,\"flee_method_id\":0,"
            "\"auto_catch\":false,\"auto_catch_ball\":1,"
            "\"auto_catch_delay_ms\":1200}";
        id jd = SEND(nsstr(json), S("dataUsingEncoding:"), 4);
        gCfg = objc_retain(SEND(SEND(C("NSJSONSerialization"), S("JSONObjectWithData:options:error:"), jd, 0, nil), S("mutableCopy")));
        SEND(jd, S("writeToFile:atomically:"), cfg, YES);
    }
    gKeepSpecies = objc_retain(SEND(gCfg, S("objectForKey:"), nsstr("keep_species")));
    gDropSpecies = objc_retain(SEND(gCfg, S("objectForKey:"), nsstr("drop_species")));
}

// ---- pokemon record ---------------------------------------------------------------
typedef struct { uint64_t uid; int species, atk, def, sta, fav, shiny, buddy, lucky, egg; } mon_t;

static int is_legendary(int s) {
    static const int L[] = {144,145,146,150,151,243,244,245,249,250,251,377,378,379,380,381,
        382,383,384,385,386,480,481,482,483,484,485,486,487,488,489,490,491,492,493,494,
        638,639,640,641,642,643,644,645,646,647,648,649,716,717,718,719,720,721,785,786,
        787,788,789,790,791,792,800,801,802,807,808,809,888,889,890,891,892,893,894,895,
        896,897,898,905,
        // Gen 9 legendaries/mythicals/paradox (Scarlet/Violet + DLC)
        984,985,986,987,988,989,990,991,992,993,994,995,996,997,998,999,1000,1001,
        1002,1003,1004,1005,1006,1007,1008,1009,1010,
        1014,1015,1016,1017,  // Loyal Three
        1020,1021,1022,1023,1024,1025};
    for (unsigned i = 0; i < sizeof L / sizeof *L; i++) if (L[i] == s) return 1;
    return 0;
}

// PokemonProto field nums marked ASSUMED (v0.435: verify against first logged delta)
static void parse_mon(const uint8_t *d, uint32_t n, mon_t *m) {
    pb_t b = { d, d + n }; uint32_t num, wire, len; const uint8_t *val; uint64_t v;
    memset(m, 0, sizeof *m); m->species = -1;
    while (pb_field(&b, &num, &wire, &val, &len, &v)) {
        switch (num) {
            case 1: if (wire == 1 || wire == 0) m->uid = v; break;
            case 2: m->species = (int)v; break;
            case 5: m->atk = (int)v; break;   // individual_attack  ASSUMED
            case 6: m->def = (int)v; break;   // individual_defense ASSUMED
            case 7: m->sta = (int)v; break;   // individual_stamina ASSUMED
            case 11: m->fav = (int)v; break;  // favorite           ASSUMED
            case 19: m->buddy = (int)v; break;// ASSUMED
            case 20: m->lucky = (int)v; break;// ASSUMED
            case 23: m->egg = (int)v; break;  // ASSUMED
            case 8: if (wire == 2) {          // pokemon_display — shiny inside  ASSUMED
                pb_t sb = { val, val + len }; uint32_t n2, w2, l2; const uint8_t *v2; uint64_t u;
                while (pb_field(&sb, &n2, &w2, &v2, &l2, &u))
                    if (n2 == 2) m->shiny = (int)u;
            } break;
        }
    }
}

// Fail-safe keep check: returns 1 if the mon's parsed state looks like a
// proto-field miss (so we won't release what we don't understand). The
// condition is intentionally loose — a legitimate parse of a wild mon has
// species in [1..1025], and at least one of the IV/flag fields takes a
// non-default value with overwhelming probability.
static int parse_looks_broken(const mon_t *m) {
    if (m->species <= 0 || m->species > 1500) return 1;
    // All zeros across every scalar we extract is the signature of wrong
    // field numbers: on a real parse, uid != 0 (set by field 1) and at
    // least one of atk/def/sta is ≥ 1 for ~99.9% of mons, OR one of the
    // binary flags is set, OR egg is set.
    if (m->atk == 0 && m->def == 0 && m->sta == 0 &&
        m->fav == 0 && m->shiny == 0 && m->buddy == 0 &&
        m->lucky == 0 && m->egg == 0) return 1;
    return 0;
}

static int should_keep(const mon_t *m) {
    // Fail-safe: if the parse looks broken (ASSUMED field numbers wrong),
    // keep by default. Prevents mass unintended release when the port
    // hasn't been verified against the current PokemonGO build.
    if (parse_looks_broken(m)) return 1;

    if (m->egg) return 1;

    // Species-level overrides evaluate BEFORE IV% so drop_species actually
    // drops (the prior order let IV% ≥ min short-circuit the drop).
    if (m->species >= 0) {
        id sp = SEND(C("NSNumber"), S("numberWithInt:"), m->species);
        if (SEND(gKeepSpecies, S("containsObject:"), sp)) return 1;
        if (SEND(gDropSpecies, S("containsObject:"), sp)) return 0;
    }

    if (m->fav && cfg_i("keep_favorite")) return 1;
    if (m->buddy && cfg_i("keep_buddy")) return 1;
    if (m->lucky && cfg_i("keep_lucky")) return 1;
    if (m->shiny && cfg_i("keep_shiny")) return 1;
    if (m->atk == 15 && m->def == 15 && m->sta == 15 && cfg_i("keep_hundo")) return 1;
    if (is_legendary(m->species) && cfg_i("keep_legendary")) return 1;
    // IV% uses rounded-to-nearest not truncated-down, so 40/45 reads 89%
    // (matches in-game display) instead of 88%.
    int iv_min = cfg_i("iv_pct_min");
    if (iv_min > 0) {
        int sum = m->atk + m->def + m->sta;
        int pct = (sum * 100 + 22) / 45;  // +22 rounds to nearest
        if (pct >= iv_min) return 1;
    }
    return 0;
}

// ---- envelope splice/send ------------------------------------------------------------
static NSData *env_with_request(NSData *env, int reqField, const uint8_t *req, size_t reqLen) {
    const uint8_t *d = (const uint8_t *)SEND(env, S("bytes"));
    pb_t b = { d, d + (size_t)(uintptr_t)SEND(env, S("length")) };
    uint32_t num, wire, len; const uint8_t *val; uint64_t v;
    wbuf w = {0};
    while (pb_field(&b, &num, &wire, &val, &len, &v)) {
        if ((int)num == reqField) continue;
        if (wire == 0) wb_var(&w, num, v);
        else if (wire == 1) { wb_tag(&w, num, 1); wb_put(&w, val, 8); }
        else if (wire == 5) { wb_tag(&w, num, 5); wb_put(&w, val, 4); }
        else wb_bytes(&w, num, val, len);
    }
    wb_bytes(&w, reqField, req, reqLen);
    id out = SEND(C("NSData"), S("dataWithBytes:length:"), w.p, w.len);
    free(w.p); return out;
}

static NSData *build_request(uint32_t method, const uint8_t *msg, size_t msgLen) {
    wbuf w = {0};
    wb_var(&w, 1, method);
    wb_bytes(&w, 2, msg, msgLen);
    id r = SEND(C("NSData"), S("dataWithBytes:length:"), w.p, w.len);
    free(w.p); return r;
}

// our own POST — runs on gOwnSession; marker header X-SpooferProPlus stops our hook recursing
static void post_env(NSData *envBody) {
    void *p = objc_autoreleasePoolPush();
    id r = SEND(C("NSMutableURLRequest"), S("requestWithURL:"),
                SENDN(C("NSURL"), S("URLWithString:"), gRPCURL));
    SEND(r, S("setHTTPMethod:"), nsstr("POST"));
    SEND(r, S("setHTTPBody:"), envBody);
    SEND(r, S("setValue:forHTTPHeaderField:"), nsstr("1"), nsstr("X-SpooferProPlus"));
    SEND(r, S("setValue:forHTTPHeaderField:"), nsstr("application/x-protobuf"), nsstr("Content-Type"));
    RespCB cb = ^(NSData *d, NSURLResponse *r, NSError *e) {
        ipalog("[SP+] release env posted (resp %ldB)",
               (long)(uintptr_t)SEND(d, S("length")));
    };
    id task = SEND(gOwnSession, S("dataTaskWithRequest:completionHandler:"), r, cb);
    SEND(task, S("resume"));
    objc_autoreleasePoolPop(p);
}

static void release_pokemon(uint64_t pid) {
    if (cfg_i("dry_run")) {
        ipalog("[SP+] DRY-RUN release uid=%llu (dry_run=1; set to 0 to really release)",
               pid);
        return;
    }

    // release_mode selects the underlying path:
    //   "il2cpp" — preferred; calls IPokemonBag.ReleasePokemon via the
    //     game's own C# so the request is signed correctly and sails
    //     past anti-cheat. Needs spp_il2cpp_ready() AND the Zenject
    //     chain resolved (Phase 4). Falls through to rpc2 on failure
    //     unless release_mode="il2cpp_only".
    //   "rpc2" (default) — the original splice path. Experimental;
    //     may be detected by Niantic anti-cheat signals on
    //     platform_request[5].
    //   "il2cpp_only" — only try il2cpp; if the bridge isn't ready,
    //     skip the release instead of falling back to rpc2.
    id mode_obj = SEND(gCfg, S("objectForKey:"), nsstr("release_mode"));
    const char *mode = mode_obj ? (const char *)SEND(mode_obj, S("UTF8String")) : "rpc2";
    if (!mode) mode = "rpc2";
    int try_il2cpp = (strcmp(mode, "il2cpp") == 0 || strcmp(mode, "il2cpp_only") == 0);
    int fallback_rpc2 = (strcmp(mode, "il2cpp_only") != 0);

    if (try_il2cpp) {
        int rc = spp_il2cpp_release_pokemon(pid);
        if (rc == 0) return;          // success
        if (!fallback_rpc2) {
            ipalog("[SP+] il2cpp_only release skipped uid=%llu rc=%d", pid, rc);
            return;
        }
        ipalog("[SP+] il2cpp release unavailable (rc=%d); falling back to rpc2", rc);
    }

    if (!gTemplate) { ipalog("[SP+] no template — release skipped"); return; }

    // First live rpc2 release this session: log the architectural warning
    // so the user knows what they're getting. One line per session.
    static int warned_live;
    if (!warned_live) {
        warned_live = 1;
        ipalog("[SP+] WARNING: rpc2-based release is EXPERIMENTAL. iPoGo and "
               "SpooferPro both use il2cpp invoke (see SPOOFERPRO-FINDINGS.md); "
               "our rpc2 envelope shape may be detected by Niantic anti-cheat. "
               "If releases silently fail or your account gets shadow-banned, "
               "flip dry_run back on and use release_mode=\"il2cpp_only\" (once "
               "Phase 4 lands).");
    }
    wbuf msg = {0};
    wb_f64(&msg, 2, pid);  // pokemon_ids (repeated fixed64, field 2)
    wb_f64(&msg, 1, pid);  // pokemon_id  (legacy single,  field 1)
    NSData *req = build_request(M_RELEASE, msg.p, msg.len);
    free(msg.p);
    NSData *env = env_with_request(gTemplate, gRequestsField,
                                  (const uint8_t *)SEND(req, S("bytes")), (size_t)(uintptr_t)SEND(req, S("length")));
    ipalog("[SP+] release uid=%llu seq=%lu", pid, ++gSeq);
    post_env(env);
}

// ---- auto-catch -----------------------------------------------------------------
// CatchPokemonProto fields (community-reversed proto, cross-checked against
// v0.241+ builds — field numbers have been stable since v0.117):
//   1 fixed64 encounter_id
//   2 varint  pokeball        (ITEM_POKE_BALL=1, GREAT=2, ULTRA=3, MASTER=4)
//   3 float32 normalized_reticle_size  (1.0 = fully closed, 1.95 ~ excellent)
//   4 string  spawn_point_id
//   5 bool    hit_pokemon
//   6 float32 spin_modifier   (1.0 = perfect curveball)
//   7 float32 normalized_hit_position  (0..1)
//
// The ENCOUNTER=102 response (EncounterOutProto) carries wild_pokemon in
// field 1 (per v0.241 community proto). WildPokemonProto fields observed:
//   1 fixed64 encounter_id
//   2 string  spawn_point_id   (ALTERNATIVELY nested inside pokemon_display;
//                               proto versions have varied — we scan both.)
// We walk the response conservatively: capture any fixed64 at depth <=2 as a
// candidate encounter_id and any string of length 12..64 as spawn_point_id.
static void parse_encounter_ids(const uint8_t *d, uint32_t n,
                                uint64_t *out_eid, char *out_spawn,
                                size_t spawn_cap) {
    *out_eid = 0; out_spawn[0] = 0;
    pb_t b = { d, d + n };
    uint32_t num, wire, len; const uint8_t *val; uint64_t v;
    while (pb_field(&b, &num, &wire, &val, &len, &v)) {
        if (wire == 1 && !*out_eid) {
            // fixed64 — plausible encounter_id (16 hex digits in logs)
            *out_eid = v;
        } else if (wire == 2) {
            // Could be a string spawn_point_id, or a submessage to recurse.
            // spawn_point_id is 12..64 printable chars, all hex digits.
            int looks_spawn = (len >= 12 && len <= 64);
            for (unsigned i = 0; i < len && looks_spawn; i++) {
                uint8_t c = val[i];
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                      (c >= 'A' && c <= 'F'))) { looks_spawn = 0; break; }
            }
            if (looks_spawn && !out_spawn[0]) {
                unsigned clip = (unsigned)(len < spawn_cap - 1 ? len : spawn_cap - 1);
                memcpy(out_spawn, val, clip); out_spawn[clip] = 0;
            } else if (len >= 8 && !(*out_eid && out_spawn[0])) {
                // recurse one level
                uint64_t eid2 = 0; char spawn2[64] = {0};
                parse_encounter_ids(val, len, &eid2, spawn2, sizeof spawn2);
                if (eid2 && !*out_eid) *out_eid = eid2;
                if (spawn2[0] && !out_spawn[0]) {
                    strncpy(out_spawn, spawn2, spawn_cap - 1);
                    out_spawn[spawn_cap - 1] = 0;
                }
            }
        }
    }
}

static void wb_fixed32(wbuf *w, uint32_t num, uint32_t v) {
    wb_tag(w, num, 5); wb_put(w, &v, 4);
}

static void auto_catch(uint64_t eid, const char *spawn_id) {
    if (!gTemplate) { ipalog("[SP+] auto-catch: no template"); return; }
    if (!eid || !spawn_id || !*spawn_id) {
        ipalog("[SP+] auto-catch: missing eid=%llu or spawn='%s'", eid, spawn_id);
        return;
    }
    if (cfg_i("dry_run")) {
        ipalog("[SP+] DRY-RUN auto-catch eid=%llu spawn=%s (dry_run=1; nothing posted)",
               eid, spawn_id);
        return;
    }
    int ball = cfg_i("auto_catch_ball");
    if (ball < 1 || ball > 4) ball = 1;  // default Poké Ball
    // Reticle 1.95 = Excellent. Spin 1.0 = curveball. Hit position center.
    float reticle = 1.95f, spin = 1.0f, hit_pos = 0.5f;
    uint32_t rb, sb, hb;
    memcpy(&rb, &reticle, 4); memcpy(&sb, &spin, 4); memcpy(&hb, &hit_pos, 4);

    wbuf msg = {0};
    // field 1 fixed64 encounter_id
    wb_tag(&msg, 1, 1);
    wb_put(&msg, &eid, 8);
    // field 2 varint pokeball
    wb_var(&msg, 2, (uint64_t)ball);
    // field 3 float32 normalized_reticle_size
    wb_fixed32(&msg, 3, rb);
    // field 4 string spawn_point_id
    wb_bytes(&msg, 4, spawn_id, strlen(spawn_id));
    // field 5 bool hit_pokemon
    wb_var(&msg, 5, 1);
    // field 6 float32 spin_modifier
    wb_fixed32(&msg, 6, sb);
    // field 7 float32 normalized_hit_position
    wb_fixed32(&msg, 7, hb);

    NSData *req = build_request(M_CATCH, msg.p, msg.len);
    free(msg.p);
    NSData *env = env_with_request(gTemplate, gRequestsField,
        (const uint8_t *)SEND(req, S("bytes")),
        (size_t)(uintptr_t)SEND(req, S("length")));
    ipalog("[SP+] auto-catch eid=%llu ball=%d spawn=%s seq=%lu",
           eid, ball, spawn_id, ++gSeq);
    post_env(env);
}

static void auto_catch_delayed(uint64_t eid, const char *spawn_id) {
    int delay_ms = cfg_i("auto_catch_delay_ms");
    if (delay_ms < 0) delay_ms = 0;
    if (delay_ms > 60000) delay_ms = 60000;  // sanity cap
    // Copy spawn_id into a heap buffer the block captures.
    size_t slen = strlen(spawn_id);
    char *copy = (char *)malloc(slen + 1);
    memcpy(copy, spawn_id, slen + 1);
    void (^fire)(void) = ^{
        auto_catch(eid, copy);
        free(copy);
    };
    if (delay_ms == 0) {
        fire();
    } else {
        run_on_main_later(delay_ms / 1000.0, (id)^(NSTimer *t){ fire(); });
    }
}

// ---- inventory walk: find PokemonProto blobs recursively -------------------------
static void walk_mons(const uint8_t *d, uint32_t n, int depth);

static void handle_mon(const mon_t *m) {
    if (!m->uid || m->species < 0 || m->atk > 15 || m->def > 15 || m->sta > 15) return;
    if (gMode == 1) { gMonCount++; return; }
    if (gMode == 2) {
        if (!should_keep(m)) {
            wb_f64(&gBatch, 2, m->uid); gBatchN++;
            ipalog("[SP+] bagclean mark uid=%llu sp=%d iv=%d/%d/%d",
                   m->uid, m->species, m->atk, m->def, m->sta);
        }
        return;
    }
    ipalog("[SP+] mon uid=%llu sp=%d iv=%d/%d/%d sh=%d fv=%d bd=%d lk=%d egg=%d",
           m->uid, m->species, m->atk, m->def, m->sta, m->shiny, m->fav, m->buddy, m->lucky, m->egg);
    if (gPending && (uintptr_t)SEND(gPending, S("count"))) {
        // release_on_catch path: only mons we just caught are candidates
        id sp = SEND(C("NSNumber"), S("numberWithUnsignedLongLong:"), m->uid);
        if (SEND(gPending, S("containsObject:"), sp)) {
            SEND(gPending, S("removeObject:"), sp);
            if (!should_keep(m)) release_pokemon(m->uid);
        }
    }
}

static void walk_mons(const uint8_t *d, uint32_t n, int depth) {
    if (depth > 6 || !d) return;
    pb_t b = { d, d + n }; uint32_t num, wire, len; const uint8_t *val; uint64_t v;
    while (pb_field(&b, &num, &wire, &val, &len, &v)) {
        if (wire != 2 || len < 16) continue;
        mon_t m; parse_mon(val, len, &m);
        if (m.uid && m.species > 0) handle_mon(&m);
        else walk_mons(val, len, depth + 1);
    }
}

// ---- response dispatch -----------------------------------------------------------
static void ensure_ui(void);
static void handle_response(NSData *reqBody, NSData *respBody, NSString *url) {
    @synchronized (gSyncObj) {
    ensure_ui();
    // refresh envelope template (session/auth values ride the game's own)
    if (gTemplate) objc_release(gTemplate);
    gTemplate = objc_retain(reqBody);
    if (gRPCURL) objc_release(gRPCURL);
    gRPCURL = objc_retain(url);

    // collect request method ids in order (each request blob = {type varint, msg bytes})
    // Niantic's RequestEnvelope has used field 4 for the repeated `requests`
    // list since v0.117+ (community-reversed proto). We default to 4 and
    // only override from a user-provided "requests_field" config value — the
    // old auto-detect was prone to picking wrong when the first observed
    // envelope only carried a low-id method (e.g., HOLO_INV=4 < 50). Log the
    // first envelope's top-level field layout once so a user-visible
    // mismatch is obvious in sppro_plus.log.
    if (!gLoggedEnv) {
        gLoggedEnv = 1;
        int override = cfg_i("requests_field");
        if (override >= 3 && override < 64) {
            gRequestsField = override;
        }
        // Dump the top-level field layout for diagnosis.
        const uint8_t *dd = (const uint8_t *)SEND(reqBody, S("bytes"));
        pb_t bb = { dd, dd + (size_t)(uintptr_t)SEND(reqBody, S("length")) };
        uint32_t num, wire, len; const uint8_t *val; uint64_t v;
        char layout[400]; int lo = 0;
        int field_count[64] = {0};
        while (pb_field(&bb, &num, &wire, &val, &len, &v) && num < 64) {
            field_count[num]++;
        }
        for (int i = 0; i < 64 && lo < 380; i++)
            if (field_count[i]) lo += snprintf(layout + lo, sizeof layout - lo,
                                               "f%d×%d ", i, field_count[i]);
        ipalog("[SP+] rpc2 envelope layout: %s", layout);
        ipalog("[SP+] requests field = %d (override via sppro_plus.json "
               "\"requests_field\" if your build differs)", gRequestsField);
    }
    // collect request method ids in order, only from the requests field
    uint32_t methods[64]; int nM = 0;
    const uint8_t *d = (const uint8_t *)SEND(reqBody, S("bytes"));
    pb_t b = { d, d + (size_t)(uintptr_t)SEND(reqBody, S("length")) };
    uint32_t num, wire, len; const uint8_t *val; uint64_t v;
    while (pb_field(&b, &num, &wire, &val, &len, &v) && nM < 64) {
        if (wire != 2 || (int)num != gRequestsField) continue;
        pb_t sb = { val, val + len }; uint32_t n2, w2, l2; const uint8_t *v2; uint64_t u;
        if (pb_field(&sb, &n2, &w2, &v2, &l2, &u) && w2 == 0 && u > 0 && u < 1000)
            methods[nM++] = (uint32_t)u;
    }
    gSeq++;
    static int logged_methods;
    if (!logged_methods) {
        logged_methods = 1;
        char line[600]; int o = 0;
        for (int i = 0; i < nM && o < 580; i++) o += snprintf(line + o, sizeof line - o, "%d ", methods[i]);
        ipalog("[SP+] methods: %s", line);
    }

    // returns = field 100 repeated bytes, positionally matching requests
    int idx = 0;
    const uint8_t *rd = (const uint8_t *)SEND(respBody, S("bytes"));
    pb_t rb = { rd, rd + (size_t)(uintptr_t)SEND(respBody, S("length")) };
    while (pb_field(&rb, &num, &wire, &val, &len, &v)) {
        if (num != 100 || wire != 2) continue;
        if (idx >= nM) break;
        uint32_t m = methods[idx++] & 0xffff;
        if (m == M_CATCH && cfg_i("release_on_catch")) {
            pb_t sb = { val, val + len }; uint32_t n2, w2, l2; const uint8_t *v2; uint64_t u;
            uint64_t status = 0, uid = 0;
            while (pb_field(&sb, &n2, &w2, &v2, &l2, &u)) {
                if (n2 == 1) status = u;
                else if (n2 == 3 && w2 == 0) uid = u;   // captured uid ASSUMED
            }
            ipalog("[SP+] catch status=%llu uid=%llu", status, uid);
            if (status == 1 && !uid) {
                // field 3 guess wrong: dump the whole blob hex so the user
                // can eyeball the correct field for their game version.
                char hex[513]; unsigned n = len < 256 ? len : 256;
                for (unsigned i = 0; i < n; i++) snprintf(hex + i*2, 3, "%02x", val[i]);
                hex[n*2] = 0;
                ipalog("[SP+] CATCH blob len=%u (uid field unknown): %s", len, hex);
            }
            if (status == 1 && uid) {
                if (!gPending) gPending = objc_retain(SEND(SEND(C("NSMutableArray"), S("alloc")), S("init")));
                SEND(gPending, S("addObject:"), SENDN(C("NSNumber"), S("numberWithUnsignedLongLong:"), uid));
            }
        } else if (m == M_ENCOUNTER || m == M_DISK_ENC) {
            // Auto-catch path: fire CATCH_POKEMON=103 with configured ball
            // + excellent reticle + curveball. Reads encounter_id and
            // spawn_point_id from the ENCOUNTER response via conservative
            // field scan (see parse_encounter_ids). Composes with
            // release_on_catch — after a successful catch the uid lands
            // in gPending and the next HOLO_INV handles the keep rules.
            if (cfg_i("auto_catch")) {
                uint64_t eid = 0; char spawn[64] = {0};
                parse_encounter_ids(val, len, &eid, spawn, sizeof spawn);
                if (eid && spawn[0]) {
                    auto_catch_delayed(eid, spawn);
                } else {
                    ipalog("[SP+] auto-catch skipped (eid=%llu spawn='%s')",
                           eid, spawn);
                }
            }
            // Encounter blocker (block-non-shiny / block-non-hundo /
            // block-non-shundo). Parse the wild Pokemon's display and
            // either log it (diagnostic) or splice a flee request.
            //
            // The encounter blocker is deliberately diagnostic-only until
            // the user has verified (a) the correct PokemonProto fields
            // for shiny / IV on their game build, visible in the log, AND
            // (b) a valid flee_method_id in the config. Logging alone is
            // enough to confirm shiny encounters are observed server-side.
            if (cfg_i("encounter_log") || cfg_i("block_non_shiny") ||
                cfg_i("block_non_hundo") || cfg_i("block_non_shundo")) {
                // ENCOUNTER response layout (observed in v0.241 proto, drift
                // flagged at runtime): field 1 = wild_pokemon (message),
                // which carries a PokemonData/PokemonProto under field 2.
                pb_t sb = { val, val + len };
                uint32_t n2, w2, l2; const uint8_t *v2; uint64_t u;
                mon_t m_enc; memset(&m_enc, 0, sizeof m_enc); m_enc.species = -1;
                while (pb_field(&sb, &n2, &w2, &v2, &l2, &u)) {
                    if (w2 == 2 && l2 >= 16) {
                        // recursive-ish: parse this submessage for a mon.
                        // walk_mons depth-6 heuristic from the inventory path
                        // works for encounter too since the PokemonProto is
                        // the same shape.
                        parse_mon(v2, l2, &m_enc);
                        if (m_enc.uid && m_enc.species > 0) break;
                        mon_t tmp; memset(&tmp, 0, sizeof tmp); tmp.species = -1;
                        parse_mon(v2, l2, &tmp);  // nested one level in
                        if (tmp.uid && tmp.species > 0) { m_enc = tmp; break; }
                    }
                }
                if (m_enc.uid && m_enc.species > 0) {
                    int is_hundo = (m_enc.atk == 15 && m_enc.def == 15 && m_enc.sta == 15);
                    ipalog("[SP+] encounter: sp=%d iv=%d/%d/%d sh=%d (hundo=%d)",
                           m_enc.species, m_enc.atk, m_enc.def, m_enc.sta,
                           m_enc.shiny, is_hundo);
                    int block = 0;
                    if (cfg_i("block_non_shiny") && !m_enc.shiny) block = 1;
                    if (cfg_i("block_non_hundo") && !is_hundo) block = 1;
                    if (cfg_i("block_non_shundo") && !(m_enc.shiny && is_hundo)) block = 1;
                    int flee_m = cfg_i("flee_method_id");
                    if (block && flee_m > 0) {
                        // Splice a flee into our own envelope. The flee
                        // method id is user-supplied because it varies by
                        // Pokemon GO version; running the app without this
                        // set leaves the block as a log-only annotation.
                        wbuf req = {0};
                        // flee requests in observed PGO versions only carry
                        // the encounter_id (field 1, fixed64) — if the
                        // server version expects more, it will reject;
                        // detect via the log and extend later.
                        wb_var(&req, 1, m_enc.uid);
                        NSData *r = build_request((uint32_t)flee_m, req.p, req.len);
                        free(req.p);
                        if (gTemplate) {
                            NSData *env = env_with_request(gTemplate, gRequestsField,
                                (const uint8_t *)SEND(r, S("bytes")),
                                (size_t)(uintptr_t)SEND(r, S("length")));
                            ipalog("[SP+] flee method=%d uid=%llu seq=%lu",
                                   flee_m, m_enc.uid, ++gSeq);
                            post_env(env);
                        }
                    } else if (block) {
                        ipalog("[SP+] block criteria matched but flee_method_id "
                               "not set — leaving to game (edit sppro_plus.json)");
                    }
                }
            }
        } else if (m == M_HOLO_INV) {
            if (cfg_i("bag_full_clean") || gCleanOnce) {
                gMode = 1; gMonCount = 0;
                walk_mons(val, len, 0);
                int thresh = cfg_i("bag_threshold");
                if (gCleanOnce || gMonCount >= (thresh > 0 ? thresh : 1)) {
                    ipalog("[SP+] bag clean%s: %d mons%s — cleaning",
                           gCleanOnce ? " (manual)" : "", gMonCount,
                           gCleanOnce ? "" : " >= threshold");
                    gCleanOnce = 0;
                    gMode = 2; walk_mons(val, len, 0);
                }
                gMode = 0;
            }
            gMode = 3; walk_mons(val, len, 0); gMode = 0;
        }
    }
    // one batched METHOD_RELEASE_POKEMON for bag cleanup (repeated pokemon_ids)
    if (gBatchN) {
        // Safety abort: if the keep-rule evaluator says "release more than
        // half the bag" on a single HOLO_INVENTORY, almost certainly the
        // PokemonProto field numbers (ASSUMED) are wrong for this game
        // build — every mon parses as 0/0/0 IV with no flags set and
        // `should_keep` says 0. Abort with a loud log instead of wiping
        // the user's collection; the parse_looks_broken() fail-safe in
        // should_keep catches the common case, this is the last-chance
        // backstop for a pathological parse that slips past it.
        int bag_size = gMonCount;  // populated by the earlier mode=1 walk
        int cap = cfg_i("bag_clean_max");
        if (cap <= 0) cap = 50;    // never release more than this % of bag
        if (bag_size > 0 && (gBatchN * 100 / bag_size) > cap) {
            ipalog("[SP+] bagclean ABORT: would release %d of %d mons (>%d%%) — "
                   "parse likely wrong, check the encounter log and "
                   "sppro_plus.json first", gBatchN, bag_size, cap);
        } else if (cfg_i("dry_run")) {
            ipalog("[SP+] DRY-RUN bagclean %d mons of %d (dry_run=1; set to 0 "
                   "to really release)", gBatchN, bag_size);
        } else {
            NSData *req = build_request(M_RELEASE, gBatch.p, gBatch.len);
            if (gTemplate) {
                NSData *env = env_with_request(gTemplate, gRequestsField,
                    (const uint8_t *)SEND(req, S("bytes")),
                    (size_t)(uintptr_t)SEND(req, S("length")));
                ipalog("[SP+] bagclean releasing %d of %d mons seq=%lu",
                       gBatchN, bag_size, ++gSeq);
                post_env(env);
            }
        }
        free(gBatch.p); gBatch.p = NULL; gBatch.cap = gBatch.len = 0; gBatchN = 0;
    }
    }
}

// ---- on-screen UI ---------------------------------------------------------------
static void persist_cfg(void) {
    id d = SEND(C("NSJSONSerialization"), S("dataWithJSONObject:options:error:"), gCfg, 0, nil);
    SEND(d, S("writeToFile:atomically:"), gCfgPath, YES);
}

static void cfg_set(const char *key, int v) {
    SEND(gCfg, S("setObject:forKey:"), SENDN(C("NSNumber"), S("numberWithInt:"), v), nsstr(key));
    persist_cfg();
}

static id game_window(void) {
    id app = SEND(C("UIApplication"), S("sharedApplication"));
    // iOS13+ scene path first: connectedScenes -> UIWindowScene -> windows
    id scenes = SEND(app, S("connectedScenes"));
    id objs = scenes ? SEND(scenes, S("allObjects")) : nil;
    unsigned n = objs ? (unsigned)(uintptr_t)SEND(objs, S("count")) : 0;
    for (unsigned i = 0; i < n; i++) {
        id scene = SEND(objs, S("objectAtIndex:"), i);
        if (!SEND(scene, S("respondsToSelector:"), S("windows"))) continue;
        id sw = SEND(scene, S("windows"));
        if (sw && (uintptr_t)SEND(sw, S("count")))
            return SEND(sw, S("objectAtIndex:"), 0);
    }
    // legacy fallback
    id wins = SEND(app, S("windows"));
    if (wins && (uintptr_t)SEND(wins, S("count")))
        return SEND(wins, S("objectAtIndex:"), 0);
    id kw = SEND(app, S("keyWindow"));
    return kw;
}

static id front_vc(void) {
    id win = game_window();
    id vc = SEND(win, S("rootViewController"));
    id pvc;
    while ((pvc = SEND(vc, S("presentedViewController")))) vc = pvc;
    return vc;
}

static void present_sheet(void);

typedef void (^ActH)(id);
static void add_act(id alert, id vc, const char *title, int style, ActH h) {
    SEND(alert, S("addAction:"),
         SENDN(C("UIAlertAction"), S("actionWithTitle:style:handler:"), nsstr(title), style, h));
}

static void add_toggle(id alert, id vc, const char *key, const char *label) {
    char t[160];
    snprintf(t, sizeof t, "%s:  %s", label, cfg_i(key) ? "ON" : "off");
    add_act(alert, vc, t, 0, ^(id a) {
        cfg_set(key, !cfg_i(key));
        SEND(vc, S("dismissViewControllerAnimated:completion:"), NO,
             ^{ present_sheet(); });
    });
}

static void add_num(id alert, id vc, const char *key, const char *label, int step, int lo, int hi) {
    char t[160];
    int cur = cfg_i(key);
    snprintf(t, sizeof t, "-  %s  (%d)", label, cur);
    add_act(alert, vc, t, 0, ^(id a) {
        int v = cur - step; cfg_set(key, v < lo ? lo : v);
        SEND(vc, S("dismissViewControllerAnimated:completion:"), NO, ^{ present_sheet(); });
    });
    snprintf(t, sizeof t, "+  %s  (%d)", label, cur);
    add_act(alert, vc, t, 0, ^(id a) {
        int v = cur + step; cfg_set(key, v > hi ? hi : v);
        SEND(vc, S("dismissViewControllerAnimated:completion:"), NO, ^{ present_sheet(); });
    });
}

static void present_sheet(void) {
    void *p = objc_autoreleasePoolPush();
    id vc = front_vc();
    if (!vc) { ipalog("[SP+] no root vc — sheet skipped"); objc_autoreleasePoolPop(p); return; }
    char msg[256];
    snprintf(msg, sizeof msg,
             "%s   |   il2cpp %s   |   IV min %d%%   |   bag at %d%s",
             cfg_i("dry_run") ? "DRY-RUN" : "LIVE",
             spp_il2cpp_ready() ? "READY" : "off",
             cfg_i("iv_pct_min"), cfg_i("bag_threshold"),
             gCleanOnce ? "   |   clean armed" : "");
    id alert = SEND(C("UIAlertController"), S("alertControllerWithTitle:message:preferredStyle:"),
                    nsstr("SpooferProPlus"), nsstr(msg), 1);
    // Dry-run FIRST so users can't miss it. With dry_run on, every release
    // call is logged but nothing is posted — use to validate keep rules
    // against a real inventory before flipping to live.
    add_toggle(alert, vc, "dry_run", "DRY-RUN (log, don't release)");
    add_num(alert, vc, "bag_clean_max", "Bag-clean max % of bag (safety)", 5, 10, 100);
    add_toggle(alert, vc, "release_on_catch", "Release on Catch  [EXPERIMENTAL rpc2]");
    add_toggle(alert, vc, "bag_full_clean", "Bag-Full Auto Clean  [EXPERIMENTAL rpc2]");
    add_num(alert, vc, "iv_pct_min", "IV min", 5, 0, 100);
    add_num(alert, vc, "bag_threshold", "bag at", 100, 0, 4000);
    add_toggle(alert, vc, "keep_shiny", "Keep Shiny");
    add_toggle(alert, vc, "keep_hundo", "Keep 100% IV");
    add_toggle(alert, vc, "keep_favorite", "Keep Favorite");
    add_toggle(alert, vc, "keep_buddy", "Keep Buddy");
    add_toggle(alert, vc, "keep_lucky", "Keep Lucky");
    add_toggle(alert, vc, "keep_legendary", "Keep Legendary");
    add_toggle(alert, vc, "encounter_log", "Log Encounters");
    add_toggle(alert, vc, "auto_catch", "Auto-Catch (excellent + curveball)  [EXPERIMENTAL rpc2]");
    add_num(alert, vc, "auto_catch_ball", "Ball (1=Poké 2=Gt 3=Ult 4=Mstr)", 1, 1, 4);
    add_num(alert, vc, "auto_catch_delay_ms", "Auto-Catch delay (ms)", 200, 0, 10000);
    add_toggle(alert, vc, "block_non_shiny", "Block Non-Shiny (needs flee_method_id)");
    add_toggle(alert, vc, "block_non_hundo", "Block Non-Hundo (needs flee_method_id)");
    add_toggle(alert, vc, "block_non_shundo", "Block Non-Shundo (needs flee_method_id)");
    add_act(alert, vc, gCleanOnce ? "Clean armed — open your bag" : "Clean Bag Now", 2, ^(id a) {
        gCleanOnce = 1;
        ipalog("[SP+] manual bag clean armed");
        SEND(vc, S("dismissViewControllerAnimated:completion:"), YES, nil);
    });
    add_act(alert, vc, "Done", 1, nil);
    SEND(vc, S("presentViewController:animated:completion:"), alert, YES, nil);
    objc_autoreleasePoolPop(p);
}

static void tgt_tap(id self, SEL _c, id sender) { present_sheet(); }

static void tgt_pan(id self, SEL _c, id gr) {
    void *p = objc_autoreleasePoolPush();
    id v = SEND(gr, S("view"));
    CGPoint t = ((CGPoint (*)(id, SEL, id))objc_msgSend)(gr, S("translationInView:"), v);
    CGPoint c = ((CGPoint (*)(id, SEL))objc_msgSend)(v, S("center"));
    c.x += t.x; c.y += t.y;
    ((void (*)(id, SEL, CGPoint))objc_msgSend)(v, S("setCenter:"), c);
    CGPoint z = {0, 0};
    ((void (*)(id, SEL, CGPoint, id))objc_msgSend)(gr, S("setTranslation:inView:"), z, v);
    objc_autoreleasePoolPop(p);
}

static void ensure_ui(void) {
    if (gUIInit) return;
    gUIInit = 1;
    run_on_main((id)^{
        void *p = objc_autoreleasePoolPush();
        Class tc = objc_allocateClassPair(C("NSObject"), "SPPlusTgt", 0);
        if (tc) {
            class_addMethod(tc, S("ipTap:"), (IMP)tgt_tap, "v@:@");
            class_addMethod(tc, S("ipPan:"), (IMP)tgt_pan, "v@:@");
            objc_registerClassPair(tc);
        } else {
            tc = C("SPPlusTgt");  // already registered on a retry
        }
        gTarget = objc_retain(SEND(SEND((id)tc, S("alloc")), S("init")));

        id win = game_window();
        if (win) {
            id btn = SEND(C("UIButton"), S("buttonWithType:"), 0);
            CGRect f = {18, 130, 52, 52};
            ((void (*)(id, SEL, CGRect))objc_msgSend)(btn, S("setFrame:"), f);
            SEND(btn, S("setTitle:forState:"), nsstr("SP+"), 0);
            SEND(btn, S("setTitleColor:forState:"), SENDN(C("UIColor"), S("whiteColor")), 0);
            id bg = ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
                     C("UIColor"), S("colorWithRed:green:blue:alpha:"), 0.08, 0.08, 0.10, 0.65);
            SEND(btn, S("setBackgroundColor:"), bg);
            id lyr = SEND(btn, S("layer"));
            ((void (*)(id, SEL, double))objc_msgSend)(lyr, S("setCornerRadius:"), 26.0);
            SEND(btn, S("addTarget:action:forControlEvents:"), gTarget, S("ipTap:"), 64);
            id pan = SEND(SEND(C("UIPanGestureRecognizer"), S("alloc")),
                          S("initWithTarget:action:"), gTarget, S("ipPan:"));
            SEND(btn, S("addGestureRecognizer:"), pan);
            SEND(win, S("addSubview:"), btn);
            gBtn = objc_retain(btn);
            ipalog("[SP+] UI button added");
        } else {
            static int retries;
            if (++retries < 10) {
                gUIInit = 0;
                run_on_main_later(3.0, (id)^(NSTimer *t){ ensure_ui(); });
            }
            ipalog("[SP+] no window for UI yet (retry %d)", retries);
        }
        objc_autoreleasePoolPop(p);
    });
}

// ---- swizzle ---------------------------------------------------------------------
typedef id (*DataTaskImp)(id, SEL, id, id);
typedef id (*DataTaskImp2)(id, SEL, id);
// Per-class original IMPs. NSURLSession is a class cluster; the concrete
// __NSCFURLSession* subclasses can carry their own IMPs that the abstract
// parent trampolines to (or asserts without). We save each class's own IMP
// and dispatch to it in the hook, so swizzling a subclass doesn't lose
// its implementation when hook_dt forwards.
static Class *gDtCls; static DataTaskImp *gDtOrig; static int gDtN, gDtCap;
static Class *gDt2Cls; static DataTaskImp2 *gDt2Orig; static int gDt2N, gDt2Cap;
static DataTaskImp orig_dt;     // base-class fallback
static DataTaskImp2 orig_dt2;
static DataTaskImp pick_dt(Class c) {
    for (Class p = c; p; p = class_getSuperclass(p))
        for (int i = 0; i < gDtN; i++) if (gDtCls[i] == p) return gDtOrig[i];
    return orig_dt;
}
static DataTaskImp2 pick_dt2(Class c) {
    for (Class p = c; p; p = class_getSuperclass(p))
        for (int i = 0; i < gDt2N; i++) if (gDt2Cls[i] == p) return gDt2Orig[i];
    return orig_dt2;
}
static NSMutableArray *gHosts;         // distinct hosts logged once

static void log_host(id request) {
    NSString *h = SEND(SEND(request, S("URL")), S("host"));
    if (!h) return;
    // dataTask hooks fire on any caller's thread — gHosts mutation needs a
    // lock or concurrent addObject: corrupts the array (wild-ptr crash later
    // inside libobjc, blamed on whatever frame is on the stack).
    @synchronized ((id)gSyncObj) {
        if (!gHosts) gHosts = objc_retain(SEND(SEND(C("NSMutableArray"), S("alloc")), S("init")));
        if (!SEND(gHosts, S("containsObject:"), h)) {
            SEND(gHosts, S("addObject:"), h);
            ipalog("[SP+] req host: %s", SEND(h, S("UTF8String")));
        }
    }
}

// block-copy helpers (no BlocksRuntime header)
extern void *_Block_copy(const void *);
typedef void (^handler_t)(NSData *, NSURLResponse *, NSError *);

static id hook_dt2(id self, SEL _cmd, id request) {
    log_host(request);
    DataTaskImp2 f = pick_dt2(object_getClass(self));
    if (!f) {
        static int logged_null2;
        if (!logged_null2) { logged_null2 = 1;
            ipalog("[SP+] hook_dt2 NULL forward cls=%s", class_getName(object_getClass(self))); }
        return nil;
    }
    return f(self, _cmd, request);
}

static id hook_dt(id self, SEL _cmd, id request, id completionHandler) {
    void *p = objc_autoreleasePoolPush();
    log_host(request);
    id result = nil;
    id url = SEND(request, S("URL"));
    NSString *u = SEND(url, S("absoluteString"));
    BOOL ours = SEND(request, S("valueForHTTPHeaderField:"), nsstr("X-SpooferProPlus")) != nil;
    id body = SEND(request, S("HTTPBody"));

    DataTaskImp forward = pick_dt(object_getClass(self));
    if (!forward) {
        static int logged_null;
        if (!logged_null) { logged_null = 1;
            ipalog("[SP+] hook_dt NULL forward cls=%s", class_getName(object_getClass(self))); }
        objc_autoreleasePoolPop(p);
        return nil;
    }
    if (!ours && u && SEND(u, S("containsString:"), nsstr("/plfe/rpc2")) &&
        body && (uintptr_t)SEND(body, S("length")) > 50 && completionHandler) {
        NSData *captured = body;
        NSString *capturedURL = u;
        handler_t orig = (handler_t)completionHandler;
        handler_t wrapped = ^(NSData *d, NSURLResponse *r, NSError *e) {
            void *q = objc_autoreleasePoolPush();
            if (d) handle_response(captured, d, capturedURL);
            objc_autoreleasePoolPop(q);
            if (orig) orig(d, r, e);
        };
        result = forward(self, _cmd, request, _Block_copy(wrapped));
    } else {
        result = forward(self, _cmd, request, completionHandler);
    }
    objc_autoreleasePoolPop(p);
    return result;
}

// Compile-time bisect for the FBSDK-adjacent crash — the user can't edit
// sppro_plus.json on-device, so variant builds bake the disable flags in.
#ifndef SPP_BISECT_NONET
#define SPP_BISECT_NONET 1
#endif

// ---- delegate capture (UnityWebRequest path) ---------------------------------------
// UnityWebRequest sessions carry a delegate; response bodies only arrive via
// URLSession:dataTask:didReceiveData: / task:didCompleteWithError:. We swizzle
// those two methods on each delegate class seen (per-class orig IMPs).
typedef void (*DelImp)(id, SEL, id, id, id);

static void hook_recvdata(id self, SEL _cmd, id session, id task, id data) {
    void *p = objc_autoreleasePoolPush();
    static int logged_recv;
    if (!logged_recv) {
        logged_recv = 1;
        ipalog("[SP+] delegate didReceiveData hit on %s", class_getName(object_getClass(self)));
    }
    @synchronized ((id)gTaskBuf) {
        id buf = SEND(gTaskBuf, S("objectForKey:"), task);
        if (!buf) {
            buf = SEND(SEND(C("NSMutableData"), S("alloc")), S("init"));
            SEND(gTaskBuf, S("setObject:forKey:"), buf, task);
            SEND(buf, S("release"));
        }
        SEND(buf, S("appendData:"), data);
    }
    IMP f = find_swz(object_getClass(self), gSwzData);
    if (f) ((DelImp)f)(self, _cmd, session, task, data);
    objc_autoreleasePoolPop(p);
}

static void hook_done(id self, SEL _cmd, id session, id task, id err) {
    void *p = objc_autoreleasePoolPush();
    static int logged_done;
    if (!logged_done) {
        logged_done = 1;
        ipalog("[SP+] delegate didComplete hit on %s", class_getName(object_getClass(self)));
    }
    id buf = nil;
    @synchronized ((id)gTaskBuf) {
        buf = SEND(gTaskBuf, S("objectForKey:"), task);
        if (buf) { objc_retain(buf); SEND(gTaskBuf, S("removeObjectForKey:"), task); }
    }
    if (buf) {
        id req = SEND(task, S("originalRequest"));
        NSString *u = SEND(SEND(req, S("URL")), S("absoluteString"));
        id body = SEND(req, S("HTTPBody"));
        if (u && SEND(u, S("containsString:"), nsstr("nianticlabs.com")))
            ipalog("[SP+] niantic task done: %s req=%ldB resp=%ldB err=%d",
                   SEND(u, S("UTF8String")),
                   (long)(uintptr_t)SEND(body, S("length")),
                   (long)(uintptr_t)SEND(buf, S("length")), !!err);
        if (!err && u && SEND(u, S("containsString:"), nsstr("/plfe/rpc2"))) {
            if (body && (uintptr_t)SEND(body, S("length")) > 50)
                handle_response(body, buf, u);
            else if ((uintptr_t)SEND(buf, S("length")) > 20)
                ipalog("[SP+] rpc2 task body nil — HTTPBodyStream? resp %ldB",
                       (long)(uintptr_t)SEND(buf, S("length")));
        }
        objc_release(buf);
    }
    IMP f = find_swz(object_getClass(self), gSwzDone);
    if (f) ((DelImp)f)(self, _cmd, session, task, err);
    objc_autoreleasePoolPop(p);
}

static void swizzle_delegate(id delegate) {
    if (!delegate || cfg_i("disable_delegate_hooks") || SPP_BISECT_NONET) return;
    Class dc = object_getClass(delegate);
    @synchronized ((id)gSyncObj) {
    for (int i = 0; i < gNSwz; i++) if (gSwz[i] == dc) return;
    if (gNSwz >= gSwzCap) {
        int nc = gSwzCap ? gSwzCap * 2 : 8;
        gSwz = (Class *)realloc(gSwz, nc * sizeof *gSwz);
        gSwzData = (IMP *)realloc(gSwzData, nc * sizeof *gSwzData);
        gSwzDone = (IMP *)realloc(gSwzDone, nc * sizeof *gSwzDone);
        gSwzCap = nc;
    }
    SEL sd = S("URLSession:dataTask:didReceiveData:");
    SEL se = S("URLSession:task:didCompleteWithError:");
    Method md = class_getInstanceMethod(dc, sd);
    Method me = class_getInstanceMethod(dc, se);
    int i = gNSwz;
    gSwz[i] = dc;
    // Only method_setImplementation on methods the class OWNS. If the method
    // is inherited, setImplementation replaces the PARENT's IMP — every
    // sibling subclass then routes through our hook, fails the exact-class
    // check, and its original IMP is never called (delegate starved -> the
    // FBSDK crash). For inherited methods, class_addMethod installs the hook
    // on this class only and forwards to the inherited IMP.
    gSwzData[i] = gSwzDone[i] = NULL;
    if (md) {
        Method pm = class_getInstanceMethod(class_getSuperclass(dc), sd);
        IMP mimp = method_getImplementation(md);
        if (!pm || method_getImplementation(pm) != mimp)
            gSwzData[i] = method_setImplementation(md, (IMP)hook_recvdata);
        else if (class_addMethod(dc, sd, (IMP)hook_recvdata, "v@:@@@"))
            gSwzData[i] = mimp;
    }
    if (me) {
        Method pm = class_getInstanceMethod(class_getSuperclass(dc), se);
        IMP mimp = method_getImplementation(me);
        if (!pm || method_getImplementation(pm) != mimp)
            gSwzDone[i] = method_setImplementation(me, (IMP)hook_done);
        else if (class_addMethod(dc, se, (IMP)hook_done, "v@:@@@"))
            gSwzDone[i] = mimp;
    }
    gNSwz++;
    ipalog("[SP+] delegate %s swizzled (data=%d done=%d)", class_getName(dc), !!gSwzData[i], !!gSwzDone[i]);
    }
}

// +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]
typedef id (*SessImp)(id, SEL, id, id, id);
static SessImp orig_swc;
static id hook_swc(id self, SEL _cmd, id config, id delegate, id queue) {
    if (!orig_swc) {
        static int logged_null_swc;
        if (!logged_null_swc) { logged_null_swc = 1;
            ipalog("[SP+] hook_swc NULL orig"); }
        return nil;
    }
    id session = orig_swc(self, _cmd, config, delegate, queue);
    void *p = objc_autoreleasePoolPush();
    if (delegate)
        ipalog("[SP+] session w/ delegate %s", class_getName(object_getClass(delegate)));
    else
        ipalog("[SP+] session w/o delegate");
    swizzle_delegate(delegate);
    objc_autoreleasePoolPop(p);
    return session;
}

__attribute__((constructor)) static void spplus_init(void) {
    void *p = objc_autoreleasePoolPush();
    load_config();
    ipalog("[SP+] init: cfg ok");
    gSyncObj = objc_retain(SEND(SEND(C("NSMutableArray"), S("alloc")), S("init")));
    gTaskBuf = objc_retain(SEND(SEND(C("NSMutableDictionary"), S("alloc")), S("init")));
    gOwnSession = SEND(C("NSURLSession"), S("sharedSession"));
    ipalog("[SP+] init: objs ok");

    // NSURLSession is a class cluster — Foundation's concrete classes
    // (__NSCFURLSession, __NSCFURLSessionLocal, etc) can override the
    // task selectors, so swizzling the abstract parent alone is a no-op
    // for them. Walk the loaded class list and install on every subclass
    // that implements the selectors.
    int en_task = !cfg_i("disable_task_hooks") && !SPP_BISECT_NONET;
    SEL s = S("dataTaskWithRequest:completionHandler:");
    SEL s2 = S("dataTaskWithRequest:");
    Class root = C("NSURLSession");
    Method m = class_getInstanceMethod(root, s);
    orig_dt = m ? (DataTaskImp)method_getImplementation(m) : NULL;
    if (m && en_task) method_setImplementation(m, (IMP)hook_dt);
    Method m2 = class_getInstanceMethod(root, s2);
    orig_dt2 = m2 ? (DataTaskImp2)method_getImplementation(m2) : NULL;
    if (m2 && en_task) method_setImplementation(m2, (IMP)hook_dt2);
    ipalog("[SP+] hooked base NSURLSession (dt=%d dt2=%d en=%d)", !!m, !!m2, en_task);

    int n = en_task ? objc_getClassList(NULL, 0) : 0;
    Class *cls = (Class *)malloc(sizeof(Class) * (n ? n : 1));
    if (n) n = objc_getClassList(cls, n);
    int sub_dt = 0, sub_dt2 = 0;
    for (int i = 0; i < n; i++) {
        Class c = cls[i];
        if (c == root) continue;
        int is_sub = 0;
        for (Class p = class_getSuperclass(c); p; p = class_getSuperclass(p))
            if (p == root) { is_sub = 1; break; }
        if (!is_sub) continue;
        // Install on each subclass that has its OWN method (not inherited).
        // class_getInstanceMethod returns the inherited Method if the class
        // doesn't override; compare its IMP against the parent's to decide.
        Method mm = class_getInstanceMethod(c, s);
        Method parent_m = class_getInstanceMethod(class_getSuperclass(c), s);
        if (mm && (!parent_m || method_getImplementation(mm) != method_getImplementation(parent_m)) &&
            method_getImplementation(mm) != (IMP)hook_dt) {
            if (gDtN >= gDtCap) {
                int nc = gDtCap ? gDtCap * 2 : 4;
                gDtCls = (Class *)realloc(gDtCls, nc * sizeof *gDtCls);
                gDtOrig = (DataTaskImp *)realloc(gDtOrig, nc * sizeof *gDtOrig);
                gDtCap = nc;
            }
            gDtCls[gDtN] = c;
            gDtOrig[gDtN] = (DataTaskImp)method_setImplementation(mm, (IMP)hook_dt);
            gDtN++; sub_dt++;
        }
        Method mm2 = class_getInstanceMethod(c, s2);
        Method parent_m2 = class_getInstanceMethod(class_getSuperclass(c), s2);
        if (mm2 && (!parent_m2 || method_getImplementation(mm2) != method_getImplementation(parent_m2)) &&
            method_getImplementation(mm2) != (IMP)hook_dt2) {
            if (gDt2N >= gDt2Cap) {
                int nc = gDt2Cap ? gDt2Cap * 2 : 4;
                gDt2Cls = (Class *)realloc(gDt2Cls, nc * sizeof *gDt2Cls);
                gDt2Orig = (DataTaskImp2 *)realloc(gDt2Orig, nc * sizeof *gDt2Orig);
                gDt2Cap = nc;
            }
            gDt2Cls[gDt2N] = c;
            gDt2Orig[gDt2N] = (DataTaskImp2)method_setImplementation(mm2, (IMP)hook_dt2);
            gDt2N++; sub_dt2++;
        }
    }
    free(cls);
    ipalog("[SP+] hooked NSURLSession subclasses (dt=%d dt2=%d)", sub_dt, sub_dt2);

    SEL sw = S("sessionWithConfiguration:delegate:delegateQueue:");
    Method mw = class_getInstanceMethod(object_getClass((id)C("NSURLSession")), sw);
    if (mw && !cfg_i("disable_factory_hook") && !SPP_BISECT_NONET) {
        orig_swc = (SessImp)method_setImplementation(mw, (IMP)hook_swc);
        ipalog("[SP+] hooked +%s", sel_getName(sw));
    } else {
        ipalog("[SP+] +sessionWithConfiguration:delegate:delegateQueue: %s", mw ? "disabled" : "NOT FOUND");
    }
    // Initialize the il2cpp bridge once UnityFramework is loaded. The
    // constructor runs before UF is mapped (we're a sibling framework
    // dyld also loads), so defer to a short timer to let the
    // app finish boot — UF comes up during -[NSBundle loadAndReturnError:]
    // from the main exe. 2s is enough on modern devices; the bridge itself
    // is idempotent and we also retry from the first rpc2 hit if init
    // failed the first time.
    run_on_main_later(2.0, (id)^(NSTimer *t){
        char err[128] = {0};
        int rc = spp_il2cpp_init(err, sizeof err);
        if (rc == 0) {
            ipalog("[SP+] il2cpp bridge READY (tag=%s)", SPP_IL2CPP_VERSION_TAG);
            spp_il2cpp_log_classes_once();
            // Probe IPokemonBag.ReleasePokemon so the user can confirm
            // their build's class names in the log before going live.
            spp_il2cpp_probe_release_pokemon();
        } else {
            ipalog("[SP+] il2cpp bridge init failed rc=%d: %s", rc, err);
        }
    });

    // button appears unconditionally — don't wait for first rpc2 hit
    run_on_main_later(4.0, (id)^(NSTimer *t){ ensure_ui(); });
    ipalog("[SP+] init: done");
    objc_autoreleasePoolPop(p);
}
