// IPAuto — standalone auto-transfer / release-on-catch for Pokemon Go v0.435.1.
// Injected alongside iPoGo via LC_LOAD_DYLIB on the PokmonGO stub.
// Self-declared ObjC surface: builds for arm64-apple-ios without an iOS SDK.
//
// Flow (mirrors iPoGo's own design):
//   1. Swizzle -[NSURLSession dataTaskWithRequest:completionHandler:]
//   2. Sniff POSTs to /plfe/rpc2 -> keep last RequestEnvelope as template
//   3. Match returns[i] to requests[i] method ids (CATCH=103, HOLO_INVENTORY=4)
//   4. Catch success -> hold uid; next inventory delta -> parse PokemonProto,
//      apply keep-rules, splice METHOD_RELEASE_POKEMON into cloned envelope.
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
    NSDictionary, NSURL, NSMutableURLRequest, NSURLSession, NSURLResponse,
    NSError, NSFileManager, NSFileHandle;

extern id objc_msgSend();
extern void *objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void *);
extern id objc_retain(id);
extern void objc_release(id);
extern Class objc_getClass(const char *);
extern SEL sel_registerName(const char *);
extern const char *sel_getName(SEL);
extern Method class_getInstanceMethod(Class, SEL);
extern IMP method_getImplementation(Method);
extern IMP method_setImplementation(Method, IMP);
extern void *_Block_copy(const void *);

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
    id d = SEND(C("NSData"), S("dataWithContentsOfFile:"), cfg);
    if (d) {
        gCfg = objc_retain(SEND(C("NSJSONSerialization"), S("JSONObjectWithData:options:error:"), d, 0, nil));
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
        gCfg = objc_retain(SEND(C("NSJSONSerialization"), S("JSONObjectWithData:options:error:"), jd, 0, nil));
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
static void handle_response(NSData *reqBody, NSData *respBody) {
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
            walk_mons(val, len, 0);
        }
    }
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
        gTemplate = objc_retain(body); if (gRPCURL) objc_release(gRPCURL);
        gRPCURL = objc_retain(u);
        NSData *captured = body;
        handler_t orig = (handler_t)completionHandler;
        handler_t wrapped = ^(NSData *d, NSURLResponse *r, NSError *e) {
            void *q = objc_autoreleasePoolPush();
            if (d) handle_response(captured, d);
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

__attribute__((constructor)) static void ipauto_init(void) {
    void *p = objc_autoreleasePoolPush();
    load_config();
    gOwnSession = SEND(C("NSURLSession"), S("sharedSession"));
    SEL s = S("dataTaskWithRequest:completionHandler:");
    Method m = class_getInstanceMethod(C("NSURLSession"), s);
    orig_dt = (DataTaskImp)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_dt);
    ipalog("[IPAuto] hooked %s", sel_getName(s));
    objc_autoreleasePoolPop(p);
}
