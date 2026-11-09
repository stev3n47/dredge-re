// IPAuto — standalone auto-transfer / release-on-catch for Pokemon Go v0.435.1.
// Injected alongside iPoGo via LC_LOAD_DYLIB on the PokmonGO stub.
// Self-declared ObjC surface: builds for arm64-apple-ios without an iOS SDK.
//
// Flow (mirrors iPoGo's own design):
//   1. Swizzle -[NSURLSession dataTaskWithRequest:completionHandler:] AND
//      +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:] —
//      UnityWebRequest uses delegate-based sessions, so request bodies come
//      from task.originalRequest and response bodies are accumulated via the
//      delegate's didReceiveData/didCompleteWithError (swizzled per class).
//   2. Sniff POSTs to /plfe/rpc2 -> keep last RequestEnvelope as template
//   3. Match returns[i] to requests[i] method ids (CATCH=103, HOLO_INVENTORY=4)
//   4. Catch success -> hold uid; next inventory delta -> parse PokemonProto,
//      apply keep-rules, splice METHOD_RELEASE_POKEMON into cloned envelope.
//      bag_full_clean additionally batch-releases non-keepers when the
//      inventory count reaches bag_threshold.
// Uncertain field numbers are logged once so a test run can correct them.

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

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
    UIPanGestureRecognizer;

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
extern id dispatch_get_main_queue(void);
extern void dispatch_async(id, id);
extern void *_Block_copy(const void *);

typedef struct { double x, y; } CGPoint;
typedef struct { double x, y, w, h; } CGRect;

#define S(s) sel_registerName(s)
#define C(s) objc_getClass(s)
#define SEND(o, ...) ((id (*)(id, SEL, ...))objc_msgSend)((id)(o), __VA_ARGS__)
typedef void (^RespCB)(NSData *, NSURLResponse *, NSError *);

static NSString *nsstr(const char *c) {
    return (NSString *)SEND(C("NSString"), S("stringWithUTF8String:"), c);
}

// ---- logging -------------------------------------------------------------------
static NSString *gLogPath;
static void ipalog(const char *fmt, ...) {
    char buf[2048];
    va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof buf, fmt, ap); va_end(ap);
    void *p = objc_autoreleasePoolPush();
    id fm = SEND(C("NSFileManager"), S("defaultManager"));
    if (!SEND(fm, S("fileExistsAtPath:"), gLogPath))
        SEND(nsstr(""), S("writeToFile:atomically:encoding:error:"), gLogPath, YES, 4, nil);
    id h = SEND(C("NSFileHandle"), S("fileHandleForWritingAtPath:"), gLogPath);
    SEND(h, S("seekToEndOfFile"));
    id line = SEND(nsstr(buf), S("stringByAppendingString:"), nsstr("\n"));
    SEND(h, S("writeData:"), SEND(line, S("dataUsingEncoding:"), 4));
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
static Class gSwz[8];                  // delegate classes already swizzled
static IMP gSwzData[8], gSwzDone[8];
static int gNSwz;

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

static int cfg_i(const char *k) {
    id n = SEND(gCfg, S("objectForKey:"), nsstr(k));
    return n ? (int)(intptr_t)SEND(n, S("intValue")) : 0;
}

static void load_config(void) {
    id paths = SEND(C("NSFileManager"), S("defaultManager"));
    paths = SEND(paths, S("URLsForDirectory:inDomains:"), 9, 1);
    id docs = SEND(SEND(paths, S("lastObject")), S("path"));
    gLogPath = objc_retain(SEND(docs, S("stringByAppendingPathComponent:"), nsstr("ipauto.log")));
    NSString *cfg = SEND(docs, S("stringByAppendingPathComponent:"), nsstr("ipauto.json"));
    gCfgPath = objc_retain(cfg);
    id d = SEND(C("NSData"), S("dataWithContentsOfFile:"), cfg);
    if (d) {
        gCfg = objc_retain(SEND(SEND(C("NSJSONSerialization"), S("JSONObjectWithData:options:error:"), d, 0, nil), S("mutableCopy")));
    }
    if (!gCfg) {
        // minimal safe defaults — written for user to edit
        const char *json =
            "{\"release_on_catch\":true,\"bag_full_clean\":false,"
            "\"keep_shiny\":true,\"keep_hundo\":true,\"keep_favorite\":true,"
            "\"keep_buddy\":true,\"keep_lucky\":true,\"keep_legendary\":true,"
            "\"iv_pct_min\":90,\"bag_threshold\":1800,"
            "\"keep_species\":[],\"drop_species\":[]}";
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
        896,897,898,905};
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

static int should_keep(const mon_t *m) {
    if (m->egg) return 1;
    if (m->fav && cfg_i("keep_favorite")) return 1;
    if (m->buddy && cfg_i("keep_buddy")) return 1;
    if (m->lucky && cfg_i("keep_lucky")) return 1;
    if (m->shiny && cfg_i("keep_shiny")) return 1;
    if (m->atk == 15 && m->def == 15 && m->sta == 15 && cfg_i("keep_hundo")) return 1;
    if (is_legendary(m->species) && cfg_i("keep_legendary")) return 1;
    if ((m->atk + m->def + m->sta) * 100 / 45 >= cfg_i("iv_pct_min")) return 1;
    if (m->species >= 0) {
        id sp = SEND(C("NSNumber"), S("numberWithInt:"), m->species);
        if (SEND(gKeepSpecies, S("containsObject:"), sp)) return 1;
        if (SEND(gDropSpecies, S("containsObject:"), sp)) return 0;
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

// our own POST — runs on gOwnSession; marker header X-IPAuto stops our hook recursing
static void post_env(NSData *envBody) {
    void *p = objc_autoreleasePoolPush();
    id r = SEND(C("NSMutableURLRequest"), S("requestWithURL:"),
                SEND(C("NSURL"), S("URLWithString:"), gRPCURL));
    SEND(r, S("setHTTPMethod:"), nsstr("POST"));
    SEND(r, S("setHTTPBody:"), envBody);
    SEND(r, S("setValue:forHTTPHeaderField:"), nsstr("1"), nsstr("X-IPAuto"));
    SEND(r, S("setValue:forHTTPHeaderField:"), nsstr("application/x-protobuf"), nsstr("Content-Type"));
    RespCB cb = ^(NSData *d, NSURLResponse *r, NSError *e) {
        ipalog("[IPAuto] release env posted (resp %ldB)",
               (long)(uintptr_t)SEND(d, S("length")));
    };
    id task = SEND(gOwnSession, S("dataTaskWithRequest:completionHandler:"), r, cb);
    SEND(task, S("resume"));
    objc_autoreleasePoolPop(p);
}

static void release_pokemon(uint64_t pid) {
    if (!gTemplate) { ipalog("[IPAuto] no template — release skipped"); return; }
    wbuf msg = {0};
    wb_f64(&msg, 2, pid);  // pokemon_ids (repeated fixed64, field 2)
    wb_f64(&msg, 1, pid);  // pokemon_id  (legacy single,  field 1)
    NSData *req = build_request(M_RELEASE, msg.p, msg.len);
    free(msg.p);
    NSData *env = env_with_request(gTemplate, gRequestsField,
                                  (const uint8_t *)SEND(req, S("bytes")), (size_t)(uintptr_t)SEND(req, S("length")));
    ipalog("[IPAuto] release uid=%llu seq=%lu", pid, ++gSeq);
    post_env(env);
}

// ---- inventory walk: find PokemonProto blobs recursively -------------------------
static void walk_mons(const uint8_t *d, uint32_t n, int depth);

static void handle_mon(const mon_t *m) {
    if (!m->uid || m->species < 0 || m->atk > 15 || m->def > 15 || m->sta > 15) return;
    if (gMode == 1) { gMonCount++; return; }
    if (gMode == 2) {
        if (!should_keep(m)) {
            wb_f64(&gBatch, 2, m->uid); gBatchN++;
            ipalog("[IPAuto] bagclean mark uid=%llu sp=%d iv=%d/%d/%d",
                   m->uid, m->species, m->atk, m->def, m->sta);
        }
        return;
    }
    ipalog("[IPAuto] mon uid=%llu sp=%d iv=%d/%d/%d sh=%d fv=%d bd=%d lk=%d egg=%d",
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
    // detect requests field on first envelope: element whose inner type >= 50
    // (platform request types stay small), else field with most elements
    if (!gLoggedEnv) {
        gLoggedEnv = 1;
        const uint8_t *dd = (const uint8_t *)SEND(reqBody, S("bytes"));
        pb_t bb = { dd, dd + (size_t)(uintptr_t)SEND(reqBody, S("length")) };
        uint32_t num, wire, len; const uint8_t *val; uint64_t v;
        int score[64] = {0};
        while (pb_field(&bb, &num, &wire, &val, &len, &v)) {
            if (wire != 2 || num >= 64 || num < 3) continue;
            pb_t sb = { val, val + len }; uint32_t n2, w2, l2; const uint8_t *v2; uint64_t u;
            if (pb_field(&sb, &n2, &w2, &v2, &l2, &u) && w2 == 0)
                score[num] = (u >= 50) ? 100 : score[num] + 1;
        }
        int best = 4, bs = 0;
        for (int i = 3; i < 64; i++) if (score[i] > bs) { bs = score[i]; best = i; }
        gRequestsField = best;
        ipalog("[IPAuto] requests field = %d", gRequestsField);
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
    if (gSeq++ == 0) {
        char line[600]; int o = 0;
        for (int i = 0; i < nM && o < 580; i++) o += snprintf(line + o, sizeof line - o, "%d ", methods[i]);
        ipalog("[IPAuto] methods: %s", line);
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
            ipalog("[IPAuto] catch status=%llu uid=%llu", status, uid);
            if (status == 1 && uid) {
                if (!gPending) gPending = objc_retain(SEND(SEND(C("NSMutableArray"), S("alloc")), S("init")));
                SEND(gPending, S("addObject:"), SEND(C("NSNumber"), S("numberWithUnsignedLongLong:"), uid));
            }
        } else if (m == M_HOLO_INV) {
            if (cfg_i("bag_full_clean") || gCleanOnce) {
                gMode = 1; gMonCount = 0;
                walk_mons(val, len, 0);
                int thresh = cfg_i("bag_threshold");
                if (gCleanOnce || gMonCount >= (thresh > 0 ? thresh : 1)) {
                    ipalog("[IPAuto] bag clean%s: %d mons%s — cleaning",
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
        NSData *req = build_request(M_RELEASE, gBatch.p, gBatch.len);
        if (gTemplate) {
            NSData *env = env_with_request(gTemplate, gRequestsField,
                (const uint8_t *)SEND(req, S("bytes")), (size_t)(uintptr_t)SEND(req, S("length")));
            ipalog("[IPAuto] bagclean releasing %d mons seq=%lu", gBatchN, ++gSeq);
            post_env(env);
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
    SEND(gCfg, S("setObject:forKey:"), SEND(C("NSNumber"), S("numberWithInt:"), v), nsstr(key));
    persist_cfg();
}

static id front_vc(void) {
    id app = SEND(C("UIApplication"), S("sharedApplication"));
    id wins = SEND(app, S("windows"));
    id win = (uintptr_t)SEND(wins, S("count")) ? SEND(wins, S("objectAtIndex:"), 0) : nil;
    id vc = SEND(win, S("rootViewController"));
    id pvc;
    while ((pvc = SEND(vc, S("presentedViewController")))) vc = pvc;
    return vc;
}

static void present_sheet(void);

typedef void (^ActH)(id);
static void add_act(id alert, id vc, const char *title, int style, ActH h) {
    SEND(alert, S("addAction:"),
         SEND(C("UIAlertAction"), S("actionWithTitle:style:handler:"), nsstr(title), style, h));
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
    if (!vc) { ipalog("[IPAuto] no root vc — sheet skipped"); objc_autoreleasePoolPop(p); return; }
    char msg[160];
    snprintf(msg, sizeof msg, "IV min %d%%   |   bag at %d%s",
             cfg_i("iv_pct_min"), cfg_i("bag_threshold"),
             gCleanOnce ? "   |   clean armed" : "");
    id alert = SEND(C("UIAlertController"), S("alertControllerWithTitle:message:preferredStyle:"),
                    nsstr("IPAuto"), nsstr(msg), 1);
    add_toggle(alert, vc, "release_on_catch", "Release on Catch");
    add_toggle(alert, vc, "bag_full_clean", "Bag-Full Auto Clean");
    add_num(alert, vc, "iv_pct_min", "IV min", 5, 0, 100);
    add_num(alert, vc, "bag_threshold", "bag at", 100, 0, 4000);
    add_toggle(alert, vc, "keep_shiny", "Keep Shiny");
    add_toggle(alert, vc, "keep_hundo", "Keep 100% IV");
    add_toggle(alert, vc, "keep_favorite", "Keep Favorite");
    add_toggle(alert, vc, "keep_buddy", "Keep Buddy");
    add_toggle(alert, vc, "keep_lucky", "Keep Lucky");
    add_toggle(alert, vc, "keep_legendary", "Keep Legendary");
    add_act(alert, vc, gCleanOnce ? "Clean armed — open your bag" : "Clean Bag Now", 2, ^(id a) {
        gCleanOnce = 1;
        ipalog("[IPAuto] manual bag clean armed");
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
    dispatch_async(dispatch_get_main_queue(), ^{
        void *p = objc_autoreleasePoolPush();
        Class tc = objc_allocateClassPair(C("NSObject"), "IPAutoTgt", 0);
        if (tc) {
            class_addMethod(tc, S("ipTap:"), (IMP)tgt_tap, "v@:@");
            class_addMethod(tc, S("ipPan:"), (IMP)tgt_pan, "v@:@");
            objc_registerClassPair(tc);
        } else {
            tc = C("IPAutoTgt");  // already registered on a retry
        }
        gTarget = objc_retain(SEND(SEND((id)tc, S("alloc")), S("init")));

        id app = SEND(C("UIApplication"), S("sharedApplication"));
        id wins = SEND(app, S("windows"));
        id win = (uintptr_t)SEND(wins, S("count")) ? SEND(wins, S("objectAtIndex:"), 0) : nil;
        if (win) {
            id btn = SEND(C("UIButton"), S("buttonWithType:"), 0);
            CGRect f = {18, 130, 52, 52};
            ((void (*)(id, SEL, CGRect))objc_msgSend)(btn, S("setFrame:"), f);
            SEND(btn, S("setTitle:forState:"), nsstr("IP"), 0);
            SEND(btn, S("setTitleColor:forState:"), SEND(C("UIColor"), S("whiteColor")), 0);
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
            ipalog("[IPAuto] UI button added");
        } else {
            gUIInit = 0;
            ipalog("[IPAuto] no window for UI yet");
        }
        objc_autoreleasePoolPop(p);
    });
}

// ---- swizzle ---------------------------------------------------------------------
typedef id (*DataTaskImp)(id, SEL, id, id);
static DataTaskImp orig_dt;

// block-copy helpers (no BlocksRuntime header)
extern void *_Block_copy(const void *);
typedef void (^handler_t)(NSData *, NSURLResponse *, NSError *);

static id hook_dt(id self, SEL _cmd, id request, id completionHandler) {
    void *p = objc_autoreleasePoolPush();
    id result = nil;
    id url = SEND(request, S("URL"));
    NSString *u = SEND(url, S("absoluteString"));
    BOOL ours = SEND(request, S("valueForHTTPHeaderField:"), nsstr("X-IPAuto")) != nil;
    id body = SEND(request, S("HTTPBody"));

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
        result = orig_dt(self, _cmd, request, _Block_copy(wrapped));
    } else {
        result = orig_dt(self, _cmd, request, completionHandler);
    }
    objc_autoreleasePoolPop(p);
    return result;
}

// ---- delegate capture (UnityWebRequest path) ---------------------------------------
// UnityWebRequest sessions carry a delegate; response bodies only arrive via
// URLSession:dataTask:didReceiveData: / task:didCompleteWithError:. We swizzle
// those two methods on each delegate class seen (per-class orig IMPs).
typedef void (*DelImp)(id, SEL, id, id, id);

static void hook_recvdata(id self, SEL _cmd, id session, id task, id data) {
    void *p = objc_autoreleasePoolPush();
    @synchronized ((id)gTaskBuf) {
        id buf = SEND(gTaskBuf, S("objectForKey:"), task);
        if (!buf) {
            buf = SEND(SEND(C("NSMutableData"), S("alloc")), S("init"));
            SEND(gTaskBuf, S("setObject:forKey:"), buf, task);
            SEND(buf, S("release"));
        }
        SEND(buf, S("appendData:"), data);
    }
    for (int i = 0; i < gNSwz; i++)
        if (gSwz[i] == object_getClass(self))
            ((DelImp)gSwzData[i])(self, _cmd, session, task, data);
    objc_autoreleasePoolPop(p);
}

static void hook_done(id self, SEL _cmd, id session, id task, id err) {
    void *p = objc_autoreleasePoolPush();
    id buf = nil;
    @synchronized ((id)gTaskBuf) {
        buf = SEND(gTaskBuf, S("objectForKey:"), task);
        if (buf) { objc_retain(buf); SEND(gTaskBuf, S("removeObjectForKey:"), task); }
    }
    if (buf) {
        id req = SEND(task, S("originalRequest"));
        NSString *u = SEND(SEND(req, S("URL")), S("absoluteString"));
        id body = SEND(req, S("HTTPBody"));
        if (!err && u && SEND(u, S("containsString:"), nsstr("/plfe/rpc2"))) {
            if (body && (uintptr_t)SEND(body, S("length")) > 50)
                handle_response(body, buf, u);
            else if ((uintptr_t)SEND(buf, S("length")) > 20)
                ipalog("[IPAuto] rpc2 task body nil — HTTPBodyStream? resp %ldB",
                       (long)(uintptr_t)SEND(buf, S("length")));
        }
        objc_release(buf);
    }
    for (int i = 0; i < gNSwz; i++)
        if (gSwz[i] == object_getClass(self))
            ((DelImp)gSwzDone[i])(self, _cmd, session, task, err);
    objc_autoreleasePoolPop(p);
}

static void swizzle_delegate(id delegate) {
    if (!delegate) return;
    Class dc = object_getClass(delegate);
    for (int i = 0; i < gNSwz; i++) if (gSwz[i] == dc) return;
    if (gNSwz >= 8) { ipalog("[IPAuto] delegate table full, %s skipped", class_getName(dc)); return; }
    Method md = class_getInstanceMethod(dc, S("URLSession:dataTask:didReceiveData:"));
    Method me = class_getInstanceMethod(dc, S("URLSession:task:didCompleteWithError:"));
    int i = gNSwz;
    gSwz[i] = dc;
    gSwzData[i] = md ? method_setImplementation(md, (IMP)hook_recvdata) : NULL;
    gSwzDone[i] = me ? method_setImplementation(me, (IMP)hook_done) : NULL;
    gNSwz++;
    ipalog("[IPAuto] delegate %s swizzled (data=%d done=%d)", class_getName(dc), !!md, !!me);
}

// +[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]
typedef id (*SessImp)(id, SEL, id, id, id);
static SessImp orig_swc;
static id hook_swc(id self, SEL _cmd, id config, id delegate, id queue) {
    id session = orig_swc(self, _cmd, config, delegate, queue);
    void *p = objc_autoreleasePoolPush();
    swizzle_delegate(delegate);
    objc_autoreleasePoolPop(p);
    return session;
}

__attribute__((constructor)) static void ipauto_init(void) {
    void *p = objc_autoreleasePoolPush();
    load_config();
    gSyncObj = objc_retain(SEND(SEND(C("NSMutableArray"), S("alloc")), S("init")));
    gTaskBuf = objc_retain(SEND(SEND(C("NSMutableDictionary"), S("alloc")), S("init")));
    gOwnSession = SEND(C("NSURLSession"), S("sharedSession"));

    SEL s = S("dataTaskWithRequest:completionHandler:");
    Method m = class_getInstanceMethod(C("NSURLSession"), s);
    orig_dt = (DataTaskImp)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_dt);
    ipalog("[IPAuto] hooked %s", sel_getName(s));

    SEL sw = S("sessionWithConfiguration:delegate:delegateQueue:");
    Method mw = class_getInstanceMethod(object_getClass((id)C("NSURLSession")), sw);
    if (mw) {
        orig_swc = (SessImp)method_setImplementation(mw, (IMP)hook_swc);
        ipalog("[IPAuto] hooked +%s", sel_getName(sw));
    } else {
        ipalog("[IPAuto] +sessionWithConfiguration:delegate:delegateQueue: NOT FOUND");
    }
    objc_autoreleasePoolPop(p);
}
