// PDPlus v1 — PolyDrift 2 (com.FiredreamLabs.PolyDrift2 2.1.1)
//
// Scope for v1 (per next-game/polydrift/FINDINGS.md):
//   - Load as a dylib via __mod_init_func
//   - Open Documents/pdplus.log (raw write(2), no stdio — SPPlus v23 lesson)
//   - Read Documents/pdplus.json (line-based key=value)
//   - Resolve il2cpp bridge on the main runloop (Unity 6 GC thread rule)
//   - Invoke-writer features (feature_unlocks.c): Polytopia v1.0.2 proved
//     methodPointer/vtable swaps don't reach compiled direct-call sites,
//     but PolyDrift2's unlock/currency surface is WRITER methods —
//     AddVehicleUnlock, GiveGold, set_Coins — which ARE reachable via
//     il2cpp_runtime_invoke on the main runloop.
//   - Boot class-scan diagnostic (feature_diag.c) dumps every candidate
//     class + signatures; drives v1.1's hook table.
//   - In-game UIKit menu (pdplus_menu.m), atomic cfg persistence.
//
// Config file format (Documents/pdplus.json — misnomer, line-based):
//   vehicles=1
//   gold=0
//   coins=0
//   noads=0
//   boost=0
//   mp_safe=0
//   log_each_fire=0
//   tick_hz=10
//
// File is reloaded at each tick when its mtime changes, so the user can
// toggle features live with the Files app.

#include "il2cpp_bridge.h"
#include "features.h"
#include "pac_swap.h"

#include <errno.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <stdbool.h>
#include <unistd.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>

// CoreFoundation forward decls. CF is linked with -framework CoreFoundation
// (v1a.4) so symbols are explicit load commands rather than flat-namespace
// dynamic-lookup.
//
// v1a.3 created its own CFString with content "kCFRunLoopCommonModes" and
// passed it to CFRunLoopAddTimer. That silently failed because CoreFoundation
// compares modes by **pointer** (modeName == kCFRunLoopCommonModes) not by
// content â€” see CFRunLoop.c in Apple's open source. Our custom string had a
// different pointer, so the timer was added to a mode named literally
// "kCFRunLoopCommonModes" that no runloop services. v1a.4 externs the real
// kCFRunLoopCommonModes global so the pointer check hits.
typedef struct __CFRunLoop *CFRunLoopRef;
typedef struct __CFRunLoopTimer *CFRunLoopTimerRef;
typedef const struct __CFString *CFStringRef;
typedef double CFTimeInterval;
typedef double CFAbsoluteTime;
typedef void *CFAllocatorRef;
typedef long CFIndex;
typedef unsigned long CFOptionFlags;
typedef struct {
    CFIndex version;
    void *info;
    const void *(*retain)(const void *info);
    void (*release)(const void *info);
    CFStringRef (*copyDescription)(const void *info);
} CFRunLoopTimerContext;
extern CFRunLoopRef CFRunLoopGetMain(void);
extern CFRunLoopTimerRef CFRunLoopTimerCreate(
    CFAllocatorRef, CFAbsoluteTime, CFTimeInterval, CFOptionFlags, CFIndex,
    void (*)(CFRunLoopTimerRef, void *), CFRunLoopTimerContext *);
extern void CFRunLoopAddTimer(CFRunLoopRef, CFRunLoopTimerRef, CFStringRef);
extern CFAbsoluteTime CFAbsoluteTimeGetCurrent(void);
extern const CFStringRef kCFRunLoopCommonModes;
extern const CFStringRef kCFRunLoopDefaultMode;

// -------- forward decls --------

static unsigned long now_ms(void);

// -------- logging --------
//
// SPPlus v23 (18.3s 0x8BADF00D watchdog) traced to libc stdio FILE-lock
// contention between our logger and Unity's console writer under
// `libsystem_c` fwrite/flockfile. SPPlus's permanent fix was NSFileHandle.
// We go one step lower: cached fd + atomic write(2). Benefits:
//   - no FILE lock to contend on
//   - write() of lines < PIPE_BUF is atomic across processes & threads
//   - no stderr branch, so nothing routes through libc stderr that Unity
//     may also touch on diagnostic code paths
//
// Buffer size caps at 1 KiB per line; longer lines are truncated. Caller
// never holds g_log_mtx across I/O â€” it protects only fd init.

static int g_log_fd = -1;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

static void pdp_resolve_doc_path(const char *fname, char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/var/mobile/Containers/Data/Application";
    snprintf(out, cap, "%s/Documents/%s", home, fname);
}

static int pdp_log_fd(void) {
    if (g_log_fd >= 0) return g_log_fd;
    pthread_mutex_lock(&g_log_mtx);
    if (g_log_fd < 0) {
        char path[1024];
        pdp_resolve_doc_path("pdplus.log", path, sizeof path);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) g_log_fd = fd;
    }
    pthread_mutex_unlock(&g_log_mtx);
    return g_log_fd;
}

void pdp_log(const char *fmt, ...) {
    int fd = pdp_log_fd();
    if (fd < 0) return;

    char line[1024];
    struct timeval tv;
    gettimeofday(&tv, NULL);
    time_t t = tv.tv_sec;
    struct tm lt;
    localtime_r(&t, &lt);
    int w = snprintf(line, sizeof line, "[%02d:%02d:%02d.%03d] ",
                     lt.tm_hour, lt.tm_min, lt.tm_sec, (int)(tv.tv_usec / 1000));
    if (w < 0) return;
    if ((size_t)w >= sizeof line) w = sizeof(line) - 2;

    va_list ap;
    va_start(ap, fmt);
    int w2 = vsnprintf(line + w, sizeof(line) - w - 1, fmt, ap);
    va_end(ap);
    if (w2 < 0) w2 = 0;

    size_t total = (size_t)w + (size_t)w2;
    if (total >= sizeof line - 1) total = sizeof(line) - 2;
    line[total++] = '\n';

    // Single atomic write â€” no libc FILE lock, no stdio buffering. write()
    // to a plain file on iOS doesn't short-write; one retry handles the
    // rare EINTR.
    if (write(fd, line, total) < 0) {
        (void)write(fd, line, total);
    }
}

// -------- config --------

struct cfg {
    // v1 invoke-writer features (feature_unlocks.c)
    int vehicles;    // AddVehicleUnlock over UID range + SaveUnlockedVehiclesUID
    int gold;        // GetPlayerGold -> GiveGold top-up
    int coins;       // set_Coins / set_CoinsEarnt pinned
    int noads;       // pac-hook ad-class Show*/Load* methods
    int boost;       // pin set_SpeedMultiplier / set_SpeedBoostActive
    // Safety gate: 1 = block install of mp_unsafe hooks
    int mp_safe;
    // Housekeeping
    int log_each_fire;
    int tick_hz;
    time_t mtime;
    int    loaded_ok;
    off_t  size;
};

static struct cfg g_cfg = {
    .vehicles = 1, .gold = 0, .coins = 0, .noads = 0, .boost = 0,
    .mp_safe = 0,
    .log_each_fire = 0, .tick_hz = 10, .mtime = 0, .loaded_ok = 0,
};

static pthread_mutex_t g_cfg_mtx = PTHREAD_MUTEX_INITIALIZER;

static int parse_bool_or_int(const char *v, int fallback) {
    if (!v || !*v) return fallback;
    if (!strcasecmp(v, "true"))  return 1;
    if (!strcasecmp(v, "false")) return 0;
    if (!strcasecmp(v, "yes"))   return 1;
    if (!strcasecmp(v, "no"))    return 0;
    if (!strcasecmp(v, "on"))    return 1;
    if (!strcasecmp(v, "off"))   return 0;
    return atoi(v);
}

// Reload config from disk. Returns 1 on change, 0 otherwise.
static int pdp_cfg_reload_if_changed(void) {
    char path[1024];
    pdp_resolve_doc_path("pdplus.json", path, sizeof path);
    struct stat st;
    if (stat(path, &st) != 0) {
        // Write defaults on first run so the user has something to edit.
        // Do the write + log OUTSIDE the mutex (SPPlus v16 "ipalog out of
        // lock" pattern): we only need the mutex to serialize the
        // loaded_ok flag flip.
        int should_write = 0;
        pthread_mutex_lock(&g_cfg_mtx);
        if (!g_cfg.loaded_ok) { g_cfg.loaded_ok = 1; should_write = 1; }
        pthread_mutex_unlock(&g_cfg_mtx);
        if (should_write) {
            int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                const char *defaults =
                    "# PDPlus v1 config — one key=value per line\n"
                    "# Edit in Files app or via SSH; reloaded automatically.\n"
                    "vehicles=1\n"
                    "# gold=1 -> GetPlayerGold + GiveGold top-up to 999,999,999\n"
                    "gold=0\n"
                    "# coins=1 -> set_Coins/set_CoinsEarnt pinned at 999,999,999\n"
                    "coins=0\n"
                    "# noads=1 -> pac-hook ad-class Show*/Load* methods\n"
                    "noads=0\n"
                    "# boost=1 -> pin SpeedMultiplier=2x + SpeedBoostActive\n"
                    "boost=0\n"
                    "# mp_safe=1 blocks gameplay-affecting hooks. Flip ON\n"
                    "# before joining any online mode.\n"
                    "mp_safe=0\n"
                    "log_each_fire=0\n"
                    "tick_hz=10\n";
                (void)write(fd, defaults, strlen(defaults));
                close(fd);
                pdp_log("cfg: wrote default config to %s", path);
            }
        }
        return 0;
    }
    pthread_mutex_lock(&g_cfg_mtx);
    if (st.st_mtime == g_cfg.mtime && st.st_size == g_cfg.size && g_cfg.loaded_ok) {
        pthread_mutex_unlock(&g_cfg_mtx);
        return 0;
    }
    FILE *f = fopen(path, "r");
    if (!f) {
        pthread_mutex_unlock(&g_cfg_mtx);
        return 0;
    }
    char line[256];
    struct cfg next = g_cfg;
    while (fgets(line, sizeof line, f)) {
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '#' || *s == '\n' || *s == '\0') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = s;
        char *v = eq + 1;
        // trim
        char *e = k + strlen(k);
        while (e > k && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        char *ve = v + strlen(v);
        while (ve > v && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) *--ve = 0;
        if      (!strcmp(k, "vehicles"))     next.vehicles = parse_bool_or_int(v, next.vehicles);
        else if (!strcmp(k, "gold"))         next.gold = parse_bool_or_int(v, next.gold);
        else if (!strcmp(k, "coins"))        next.coins = parse_bool_or_int(v, next.coins);
        else if (!strcmp(k, "noads"))        next.noads = parse_bool_or_int(v, next.noads);
        else if (!strcmp(k, "boost"))        next.boost = parse_bool_or_int(v, next.boost);
        else if (!strcmp(k, "mp_safe"))      next.mp_safe = parse_bool_or_int(v, next.mp_safe);
        else if (!strcmp(k, "log_each_fire"))next.log_each_fire = parse_bool_or_int(v, next.log_each_fire);
        else if (!strcmp(k, "tick_hz")) {
            int hz = atoi(v);
            if (hz < 1) hz = 1;
            if (hz > 60) hz = 60;
            next.tick_hz = hz;
        }
    }
    fclose(f);
    next.mtime = st.st_mtime;
    next.size  = st.st_size;
    next.loaded_ok = 1;
    g_cfg = next;
    pthread_mutex_unlock(&g_cfg_mtx);
    pdp_log("cfg: reloaded (vehicles=%d gold=%d coins=%d noads=%d boost=%d mp_safe=%d tick_hz=%d log=%d)",
            next.vehicles, next.gold, next.coins, next.noads, next.boost,
            next.mp_safe, next.tick_hz, next.log_each_fire);
    return 1;
}

// -------- hook table --------

// -------- hook table --------
//
// v1 uses the PFPlus v2.2.1 methodPointer-swap pattern (PAC-proven on this
// Unity 6 / metadata-v39 engine lineage): install a constant-return
// trampoline over the target method's slot[0]. Works identically for
// static and instance methods — the swap is on MethodInfo, so no
// instance discovery or heap walk is needed. Disabling a feature writes
// the saved original slot[0] back (live restore, no relaunch).

// Each row is one (image, class, method) target. A cfg key may own several
// rows — one cfg key can own several rows (base + impl class),
// UnityPlatformPurchaseManager impl, because the runtime object is the impl
// and callvirt dispatches on ITS vtable. Every row patches two slots:
//   1. MethodInfo.methodPointer  — covers il2cpp_runtime_invoke / delegates
//   2. klass->vtable[i].methodPtr — covers callvirt (interface dispatch)
// Non-virtual methods reachable only via direct `bl` (no vtable entry) are
// logged as "no-vtable" — an honest signal that the invoke path is needed.
struct hook {
    const char *key;          // config flag name
    const char *image;        // owning image (exact match first)
    const char *class_name;   // C# class
    const char *method;       // method name
    int         argc;         // arg count; -1 = wildcard match
    void       *tramp;        // constant-return trampoline to install
    int         mp_unsafe;    // 1 = install blocked while mp_safe=1
    const MethodInfo *mi;
    void       *mi_orig;      // saved MethodInfo.methodPointer
    void      **vslot;        // located &vtable[i].methodPtr (NULL if n/a)
    void       *v_orig;       // saved vtable methodPtr
    int         installed;
    int         blocked_logged;
    int         miss_logged;
    int         novtable_logged;
    unsigned long fires;      // install count
};

// v1 ships no hook rows: PolyDrift2's declaring classes are unconfirmed
// offline (.dat section layout irregular on this build) and Polytopia
// showed getter-swaps don't reach direct callsites anyway. All v1 work
// happens in feature_unlocks.c which self-discovers classes at runtime.
// The machinery stays — v1.1 adds rows once diag confirms class names.
static struct hook g_hooks[1];

static const int NUM_HOOKS = sizeof(g_hooks) / sizeof(g_hooks[0]);

// Public helpers for feature modules (features.h). Linear-dispatch on the
// known keys registered above. defval returned when the key is unknown
// (should never happen in practice â€” all features' keys are compile-time).
int pdp_cfg_bool(const char *key, int defval) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = defval;
    if      (!strcmp(key, "vehicles"))     v = g_cfg.vehicles;
    else if (!strcmp(key, "gold"))         v = g_cfg.gold;
    else if (!strcmp(key, "coins"))        v = g_cfg.coins;
    else if (!strcmp(key, "noads"))        v = g_cfg.noads;
    else if (!strcmp(key, "boost"))        v = g_cfg.boost;
    else if (!strcmp(key, "mp_safe"))      v = g_cfg.mp_safe;
    else if (!strcmp(key, "log_each_fire"))v = g_cfg.log_each_fire;
    else if (!strcmp(key, "tick_hz"))      v = g_cfg.tick_hz;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

int pdp_cfg_int(const char *key, int defval) {
    // Future: expose tick_hz etc. For now, same as bool.
    return pdp_cfg_bool(key, defval);
}

// v2.5.1 â€” write the full in-memory g_cfg back to Documents/pdplus.json
// atomically (write to .tmp, rename over the original). Called from
// pdp_cfg_set_bool so menu toggles survive a cold restart. Must be
// called WITH g_cfg_mtx held so the snapshot is consistent.
static void pdp_cfg_save_locked(void) {
    char path[1024];
    pdp_resolve_doc_path("pdplus.json", path, sizeof path);
    char tmp[1024];
    int tn = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (tn <= 0 || tn >= (int)sizeof tmp) return;

    FILE *f = fopen(tmp, "w");
    if (!f) return;

    fprintf(f, "# PDPlus config -- one key=value per line%c", 10);
    fprintf(f, "# Written by the in-game menu. Hand-edits are preserved%c", 10);
    fprintf(f, "# across restarts; the next menu toggle re-serializes.%c", 10);
    fprintf(f, "vehicles=%d%c",      g_cfg.vehicles,      10);
    fprintf(f, "gold=%d%c",          g_cfg.gold,          10);
    fprintf(f, "coins=%d%c",         g_cfg.coins,         10);
    fprintf(f, "noads=%d%c",         g_cfg.noads,         10);
    fprintf(f, "boost=%d%c",         g_cfg.boost,         10);
    fprintf(f, "mp_safe=%d%c",       g_cfg.mp_safe,       10);
    fprintf(f, "log_each_fire=%d%c", g_cfg.log_each_fire, 10);
    fprintf(f, "tick_hz=%d%c",       g_cfg.tick_hz,       10);
    fclose(f);
    if (rename(tmp, path) != 0) {
        pdp_log("cfg: save failed -- rename %s -> %s errno=%d", tmp, path, errno);
    }
    // Keep g_cfg.mtime in sync so our own save doesn't trigger a
    // spurious re-parse + "cfg: reloaded" log next tick.
    struct stat st2;
    if (stat(path, &st2) == 0) { g_cfg.mtime = st2.st_mtime; g_cfg.size = st2.st_size; }
}

// v2.3 â€” in-memory config write path used by the UIKit menu so toggles
// take effect immediately without an mtime-based file reload. Uses the
// same stringâ†’field dispatch as pdp_cfg_bool, mutating g_cfg under the
// mutex. v2.5.1 â€” also persists to disk via pdp_cfg_save_locked so
// toggles survive a cold restart.
void pdp_cfg_set_bool(const char *key, int value) {
    pthread_mutex_lock(&g_cfg_mtx);
    if      (!strcmp(key, "vehicles")) g_cfg.vehicles = value;
    else if (!strcmp(key, "gold"))     g_cfg.gold = value;
    else if (!strcmp(key, "coins"))    g_cfg.coins = value;
    else if (!strcmp(key, "noads"))    g_cfg.noads = value;
    else if (!strcmp(key, "boost"))    g_cfg.boost = value;
    else if (!strcmp(key, "mp_safe"))  g_cfg.mp_safe = value;
    pdp_cfg_save_locked();
    pthread_mutex_unlock(&g_cfg_mtx);
}

// ---------------- Diagnostic helpers (features.h) -------------------------

// Enumerate every class in Assembly-CSharp whose name contains any of the
// `substrs`. Returns count written to out_classes.
int pdp_find_classes_by_name(const char **substrs, int substr_count,
                             Il2CppClass **out_classes, int cap) {
    if (!out_classes || cap <= 0 || !pdp_il2cpp_domain_get ||
        !pdp_il2cpp_domain_get_assemblies || !pdp_il2cpp_assembly_get_image ||
        !pdp_il2cpp_image_get_name || !pdp_il2cpp_image_get_class_count ||
        !pdp_il2cpp_image_get_class || !pdp_il2cpp_class_get_name) return 0;
    if (!pdp_il2cpp_ready() || !substrs || substr_count <= 0) return 0;
    int n = 0;
    Il2CppDomain *dom = pdp_il2cpp_domain_get();
    if (!dom) return 0;
    size_t na = 0;
    const Il2CppAssembly **asms = pdp_il2cpp_domain_get_assemblies(dom, &na);
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = pdp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        // Scan every image: PolyDrift2's game/SDK classes may live outside
        // Assembly-CSharp (asmdef splits are common for bundled SDKs).
        // The diag dump records the image name per hit so v1.1 knows
        // where each target lives.
        const char *in = pdp_il2cpp_image_get_name(img);
        (void)in;
        size_t nc = pdp_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = pdp_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kn = pdp_il2cpp_class_get_name(k);
            if (!kn) continue;
            for (int i = 0; i < substr_count; i++) {
                if (substrs[i] && strstr(kn, substrs[i])) {
                    if (n < cap) out_classes[n++] = k;
                    break;
                }
            }
        }
    }
    return n;
}

// Shared context for diag heap walk. walk_cb collects obj + obj->klass
// pointers that match the whitelist; post-walk resolution of class names
// happens on the pre-resolved whitelist pointers (always safe).
struct diag_walk {
    Il2CppClass * const *whitelist;
    int whitelist_n;
    void *hits_obj[64];
    Il2CppClass *hits_klass[64];
    int n;
    long scanned;
};

static void diag_walk_cb(void *obj, void *user) {
    struct diag_walk *w = (struct diag_walk *)user;
    w->scanned++;
    if (!obj || w->n >= 64) return;
    Il2CppClass *k = pdp_il2cpp_object_get_class(obj);
    if (!k) return;
    for (int i = 0; i < w->whitelist_n; i++) {
        if (w->whitelist[i] == k) {
            w->hits_obj[w->n] = obj;
            w->hits_klass[w->n] = k;
            w->n++;
            return;
        }
    }
}

int pdp_diag_log_live_instances(const char *prefix,
                                Il2CppClass * const *target_classes,
                                int target_count) {
    if (!pdp_il2cpp_ready() || !target_classes || target_count <= 0) return 0;
    if (!pdp_il2cpp_gc_foreach_heap || !pdp_il2cpp_object_get_class) return 0;
    struct diag_walk w = { target_classes, target_count, {0}, {0}, 0, 0 };
    pdp_il2cpp_gc_foreach_heap(diag_walk_cb, &w);
    pdp_log("%s: heap walk scanned %ld objects, %d live instance(s) of %d target class(es)",
            prefix, w.scanned, w.n, target_count);
    // Post-walk: safe to resolve class names on target_classes (pre-resolved
    // from image metadata, not from the heap).
    for (int i = 0; i < w.n; i++) {
        const char *nm = pdp_il2cpp_class_get_name(w.hits_klass[i]);
        pdp_log("%s:   live %s @ %p", prefix, nm ? nm : "?", w.hits_obj[i]);
    }
    return w.n;
}

void pdp_diag_log_methods(const char *prefix, Il2CppClass *klass,
                          const char **name_substrs, int substr_count) {
    if (!pdp_il2cpp_ready() || !klass || !pdp_il2cpp_class_get_methods ||
        !pdp_il2cpp_method_get_name) return;
    const char *kn = pdp_il2cpp_class_get_name(klass);
    void *iter = NULL;
    int logged = 0;
    const MethodInfo *m;
    while ((m = pdp_il2cpp_class_get_methods(klass, &iter)) != NULL) {
        const char *mn = pdp_il2cpp_method_get_name(m);
        if (!mn) continue;
        if (substr_count > 0 && name_substrs) {
            int match = 0;
            for (int i = 0; i < substr_count; i++) {
                if (name_substrs[i] && strstr(mn, name_substrs[i])) { match = 1; break; }
            }
            if (!match) continue;
        }
        uint32_t iflags = 0;
        uint32_t f = pdp_il2cpp_method_get_flags ? pdp_il2cpp_method_get_flags(m, &iflags) : 0;
        int is_static = (f & 0x10) ? 1 : 0;
        int argc = pdp_il2cpp_method_get_param_count ? (int)pdp_il2cpp_method_get_param_count(m) : -1;
        pdp_log("%s: method %s.%s argc=%d%s", prefix, kn ? kn : "?", mn, argc,
                is_static ? " [static]" : "");
        if (++logged >= 32) { pdp_log("%s: (methods truncated at 32)", prefix); break; }
    }
}

// ---------------- Periodic rewalk registry (v2.1) -------------------------
//
// Features whose init-time heap walk turned up 0 live instances (common
// for match-only objects like ThrowController) register their target
// class here. Every ~60s we do ONE heap walk against the combined set
// and log any first-time hits per feature prefix.

#define PDP_MAX_REWALK_TARGETS 64
struct pdp_rewalk_entry {
    const char *prefix;
    Il2CppClass *klass;
    int done;
};
static struct pdp_rewalk_entry g_rewalk[PDP_MAX_REWALK_TARGETS];
static int g_rewalk_count = 0;
static unsigned long g_last_rewalk_ms = 0;

void pdp_register_rewalk(const char *prefix, Il2CppClass *klass) {
    if (!prefix || !klass) return;
    if (g_rewalk_count >= PDP_MAX_REWALK_TARGETS) {
        pdp_log("rewalk: registry full at %d â€” dropping %s target",
                PDP_MAX_REWALK_TARGETS, prefix);
        return;
    }
    // Dedup: don't register the same (prefix,class) twice.
    for (int i = 0; i < g_rewalk_count; i++) {
        if (g_rewalk[i].klass == klass && g_rewalk[i].prefix == prefix) return;
    }
    g_rewalk[g_rewalk_count].prefix = prefix;
    g_rewalk[g_rewalk_count].klass = klass;
    g_rewalk[g_rewalk_count].done = 0;
    g_rewalk_count++;
}

#define PDP_KLASS_SAMPLE_CAP 16
struct pdp_rewalk_ctx {
    void *found_obj[PDP_MAX_REWALK_TARGETS];
    Il2CppClass *found_klass[PDP_MAX_REWALK_TARGETS];
    int n_found;
    long scanned;
    // v2.1.1 klass-sampling diagnostic (SPPlus v35 pattern):
    // collect distinct obj->klass pointers seen during the walk so we can
    // verify gc_foreach_heap is handing us real metadata-comparable klass
    // pointers. If NONE of these match our resolved metadata class pointers
    // we know gc_foreach_heap is useless for instance discovery on this
    // build and v2.2 needs a different path (Zenject-provider walk, etc).
    Il2CppClass *sampled_klass[PDP_KLASS_SAMPLE_CAP];
    int n_sampled;
    int do_sample;
};

static void pdp_rewalk_cb(void *obj, void *user) {
    struct pdp_rewalk_ctx *c = (struct pdp_rewalk_ctx *)user;
    c->scanned++;
    if (!obj) return;
    Il2CppClass *k = pdp_il2cpp_object_get_class(obj);
    if (!k) return;

    // Pointer-equality check against the whitelist (SPPlus v33 rule).
    for (int i = 0; i < g_rewalk_count; i++) {
        if (g_rewalk[i].done) continue;
        if (g_rewalk[i].klass == k) {
            if (c->n_found < PDP_MAX_REWALK_TARGETS) {
                // Dedup within this walk â€” one hit per class is enough.
                for (int j = 0; j < c->n_found; j++) {
                    if (c->found_klass[j] == k) return;
                }
                c->found_obj[c->n_found] = obj;
                c->found_klass[c->n_found] = k;
                c->n_found++;
            }
            return;
        }
    }

    // Diagnostic klass sampling â€” collect first N distinct klass pointers
    // that did NOT match the whitelist. One probe only (first rewalk).
    if (c->do_sample && c->n_sampled < PDP_KLASS_SAMPLE_CAP) {
        for (int j = 0; j < c->n_sampled; j++) {
            if (c->sampled_klass[j] == k) return;
        }
        c->sampled_klass[c->n_sampled++] = k;
    }
}

static void pdp_periodic_rewalk(void) {
    if (g_rewalk_count == 0) return;
    if (!pdp_il2cpp_ready() || !pdp_il2cpp_gc_foreach_heap ||
        !pdp_il2cpp_object_get_class) return;

    unsigned long t = now_ms();
    // First call: skip the immediate rewalk (init-time walk just happened).
    // After that: every 60s.
    if (!g_last_rewalk_ms) { g_last_rewalk_ms = t; return; }
    if ((t - g_last_rewalk_ms) < 60000UL) return;
    g_last_rewalk_ms = t;

    // Count how many classes still need finding.
    int pending = 0;
    for (int i = 0; i < g_rewalk_count; i++) if (!g_rewalk[i].done) pending++;
    if (pending == 0) return;

    // v2.1.1: enable klass-sampling on the FIRST rewalk only (one-shot).
    static int sample_done = 0;
    struct pdp_rewalk_ctx ctx = { {0}, {0}, 0, 0, {0}, 0, !sample_done };
    pdp_il2cpp_gc_foreach_heap(pdp_rewalk_cb, &ctx);

    // Post-walk klass-sampling diagnostic (SPPlus v35 pattern). Determine
    // whether gc_foreach_heap is handing us klass pointers that COULD match
    // our resolved metadata classes. If every sampled klass falls far
    // outside the metadata range of our resolved classes, the heap walk
    // is useless for instance discovery on this build.
    if (ctx.do_sample && ctx.n_sampled > 0 && !sample_done) {
        sample_done = 1;
        // Compute the metadata range of our resolved classes +/- 64MB margin.
        uintptr_t lo = (uintptr_t)-1, hi = 0;
        for (int i = 0; i < g_rewalk_count; i++) {
            uintptr_t p = (uintptr_t)g_rewalk[i].klass;
            if (!p) continue;
            if (p < lo) lo = p;
            if (p > hi) hi = p;
        }
        uintptr_t safe_lo = (lo > 0x4000000) ? lo - 0x4000000 : 0;
        uintptr_t safe_hi = hi + 0x4000000;
        pdp_log("rewalk-sample: %d distinct klass ptrs sampled; "
                "metadata range of our %d resolved targets: [0x%lx..0x%lx]",
                ctx.n_sampled, g_rewalk_count, (long)lo, (long)hi);
        int in_range = 0;
        for (int i = 0; i < ctx.n_sampled; i++) {
            uintptr_t p = (uintptr_t)ctx.sampled_klass[i];
            int ok = (p >= safe_lo && p <= safe_hi);
            // v2.5.1 â€” do NOT call class_get_name on a heap-derived klass
            // pointer, per the SPPlus v33 rule. Even gated by a Â±64MB
            // metadata window, a bogus pointer from a non-managed alloc
            // can pass and trap inside type->name deref. The pointer
            // alone + the in-range flag is enough diagnostic signal.
            pdp_log("rewalk-sample: [%2d] klass=%p %s",
                    i, (void *)ctx.sampled_klass[i],
                    ok ? "IN-RANGE" : "OUT-OF-RANGE");
            if (ok) in_range++;
        }
        if (in_range == 0) {
            pdp_log("rewalk-sample: ZERO in-range klass pointers â€” "
                    "gc_foreach_heap matches SPPlus v35 pattern (walked objs "
                    "don't carry real metadata klass ptrs). "
                    "Instance discovery needs a different path (v2.2).");
        } else {
            pdp_log("rewalk-sample: %d/%d klass pointers in metadata range â€” "
                    "heap walk is usable; target classes just aren't live yet",
                    in_range, ctx.n_sampled);
        }
    }

    if (ctx.n_found == 0) {
        pdp_log("rewalk: scanned %ld objects, %d class(es) still unfound",
                ctx.scanned, pending);
        return;
    }
    // Post-walk, log hits and mark done.
    for (int i = 0; i < ctx.n_found; i++) {
        for (int j = 0; j < g_rewalk_count; j++) {
            if (g_rewalk[j].klass == ctx.found_klass[i] && !g_rewalk[j].done) {
                const char *kn = pdp_il2cpp_class_get_name(g_rewalk[j].klass);
                pdp_log("%s: rewalk found live %s @ %p (scanned=%ld)",
                        g_rewalk[j].prefix, kn ? kn : "?", ctx.found_obj[i],
                        ctx.scanned);
                g_rewalk[j].done = 1;
            }
        }
    }
}

// ---------------- Feature registry ----------------------------------------

static PdpFeature *g_feature_registry[] = {
    &pdp_feature_diag,
    &pdp_feature_vehicles,
    &pdp_feature_gold,
    &pdp_feature_coins,
    &pdp_feature_noads,
    &pdp_feature_boost,
};
static const int NUM_FEATURES = sizeof(g_feature_registry) / sizeof(g_feature_registry[0]);

static void run_features_tick(void) {
    for (int i = 0; i < NUM_FEATURES; i++) {
        PdpFeature *f = g_feature_registry[i];
        if (!f || f->init_failed) continue;
        if (!pdp_cfg_bool(f->key, 1)) continue;
        if (!f->initialised) {
            if (!f->init) { f->init_failed = 1; continue; }
            int rc = f->init();
            if (rc != 0) {
                pdp_log("feature: %s init failed (rc=%d) â€” disabled for session", f->key, rc);
                f->init_failed = 1;
                continue;
            }
            f->initialised = 1;
            pdp_log("feature: %s init ok", f->key);
        }
        if (f->tick) {
            int did = f->tick();
            if (did > 0) {
                f->fires++;
                f->last_tick_ms = now_ms();
            }
        }
        // Per-feature rewalk callback (optional; currently unused â€” the
        // global pdp_periodic_rewalk below handles all registered classes).
        if (f->rewalk) {
            unsigned long t = now_ms();
            if (!f->last_rewalk_ms || (t - f->last_rewalk_ms) >= 60000UL) {
                f->rewalk();
                f->last_rewalk_ms = t;
            }
        }
    }
    // v2.1: global periodic rewalk across all registered classes.
    pdp_periodic_rewalk();
}

// -------- target resolution --------

// -------- target resolution --------
//
// Tiny class cache (<=8 entries) — find_class walks every image's class
// table on first call per name, then we keep the pointer. Class pointers
// come from image metadata, not the heap — safe to cache for the session.
static Il2CppClass *resolve_class(const char *image, const char *name) {
    static struct { const char *name; Il2CppClass *k; } cache[8];
    static int n = 0;
    for (int i = 0; i < n; i++) {
        if (!strcmp(cache[i].name, name)) return cache[i].k;
    }
    // Exact image first (PlayerState lives in GameLogicAssembly.dll, NOT
    // Assembly-CSharp — a wildcard scan could grab a same-named UI class
    // and hook the wrong get_Currency). Wildcard fallback only as a
    // last resort and only for the purchase classes (distinctive names).
    Il2CppClass *k = pdp_il2cpp_find_class(image, NULL, name);
    if (!k && !strstr(name, "PlayerState"))
        k = pdp_il2cpp_find_class(NULL, NULL, name);
    if (!k) {
        // Log the miss once per class, then retry quietly at the caller's
        // cadence — avoids 10 Hz "NOT FOUND" spam forever (800k lines/day).
        static char miss_logged[8][64];
        static int nmiss = 0;
        int seen = 0;
        for (int i = 0; i < nmiss; i++) {
            if (!strcmp(miss_logged[i], name)) { seen = 1; break; }
        }
        if (!seen) {
            pdp_log("resolve: %s class NOT FOUND (will retry)", name);
            if (nmiss < 8) { snprintf(miss_logged[nmiss], 64, "%s", name); nmiss++; }
        }
        return NULL;
    }
    if (n < 8) { cache[n].name = name; cache[n].k = k; n++; }
    pdp_log("resolve: %s class=%p method_count=%d", name, (void *)k,
            pdp_il2cpp_count_methods(k));
    return k;
}

// -------- vtable discovery --------
//
// methodPointer swap alone only intercepts il2cpp_runtime_invoke — the
// game's compiled call sites use direct `bl` (non-virtual) or
// `callvirt` -> klass->vtable[i].methodPtr (a snapshot pointer, not a
// MethodInfo lookup). Since PurchaseManager's impls dispatch through an
// interface, IsTribeUnlocked/IsSkinUnlocked are virtual: every caller
// goes through the live impl's vtable. Patching vtable[i].methodPtr
// therefore intercepts all callvirt sites.
//
// We discover the vtable pointer + slot at RUNTIME rather than relying on
// an Il2CppClass layout offset: scan the class object's first 64 pointer
// fields for an array of VirtualInvokeData { methodPtr, method } whose
// .method equals our resolved MethodInfo*. All reads go through a
// mach_vm probe so a non-pointer field can't fault us.

// mach_vm.h is macOS-only in the iOS SDK — declare the entry points with
// primitive types (mach_port_t=u32, mach_vm_address_t/mach_vm_size_t=u64).
extern unsigned int mach_task_self(void);
extern int mach_vm_read_overwrite(unsigned int task, unsigned long long addr,
                                  unsigned long long size, unsigned long long data,
                                  unsigned long long *outsz);

static int safe_read(const void *addr, void *buf, unsigned long n) {
    unsigned long long out = 0;
    return mach_vm_read_overwrite(mach_task_self(),
                                  (unsigned long long)(uintptr_t)addr, (unsigned long long)n,
                                  (unsigned long long)(uintptr_t)buf, &out) == 0
           && out == (unsigned long long)n;
}

// Returns &vtable[i].methodPtr on success.
//
// v1.0.1 crash fix: the original matcher accepted ANY {ptr, mi} pair —
// but klass->methods is an array of consecutive MethodInfo*, where the
// pair {methods[i-1], methods[i]} ALSO satisfies it. We "patched"
// methods[i-1] with our trampoline; the next class_get_method_from_name
// dereferenced the trampoline as a MethodInfo -> read its machine code
// (stp;ret = 0xa9be4ff4d65f03c0) as a pointer -> KERN_INVALID crash in
// UnityFramework. Airtight fix: a real VirtualInvokeData entry for this
// method holds the method's own CODE pointer — mi[0] (methodPointer) or
// mi[1] (virtualMethodPointer). Require BOTH ent.method==mi AND
// ent.methodPtr==mi[0]/mi[1]. A MethodInfo* can never equal a code ptr.
static void **find_vtable_slot(Il2CppClass *klass, const MethodInfo *mi) {
    void *kp[64];
    if (!safe_read(klass, kp, sizeof kp)) return NULL;
    const void * const *mp = (const void * const *)mi;
    const void *code0 = mp[0];               // methodPointer
    const void *code1 = mp[1];               // virtualMethodPointer
    for (int f = 0; f < 64; f++) {
        void *cand = kp[f];
        if (!cand) continue;
        for (int i = 0; i < 256; i++) {
            struct { void *methodPtr; const MethodInfo *method; } ent;
            if (!safe_read((char *)cand + i * sizeof ent, &ent, sizeof ent)) break;
            if (!ent.methodPtr && !ent.method) break;   // vtables end {NULL,NULL}
            if (((unsigned long)ent.method & 0x7) ||
                ((unsigned long)ent.methodPtr & 0x7)) break;  // not a ptr pair
            if (ent.method == mi &&
                (ent.methodPtr == code0 || ent.methodPtr == code1)) {
                return (void **)((char *)cand + i * sizeof ent);
            }
        }
    }
    return NULL;
}

// -------- tick --------

static unsigned long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static void tick_once(void) {
    pdp_cfg_reload_if_changed();

    if (!pdp_il2cpp_ready()) return;

    int mp_safe = pdp_cfg_bool("mp_safe", 0);
    for (int i = 0; i < NUM_HOOKS; i++) {
        struct hook *h = &g_hooks[i];
        if (!h->key) continue;   // v1 ships an empty table — rows arrive in v1.1
        int want = pdp_cfg_bool(h->key, 0);
        if (h->mp_unsafe && want && mp_safe) {
            if (!h->blocked_logged) {
                pdp_log("%s: install blocked -- mp_safe=1 (match-sim hook)", h->key);
                h->blocked_logged = 1;
            }
            want = 0;
        } else {
            h->blocked_logged = 0;
        }

        if (want && !h->installed) {
            if (!h->mi) {
                Il2CppClass *k = resolve_class(h->image, h->class_name);
                if (k) {
                    h->mi = pdp_il2cpp_find_method(k, h->method, h->argc);
                    // Only scan for a vtable slot when we have a real
                    // MethodInfo — a NULL mi would false-match the
                    // {NULL,NULL} vtable terminator entry.
                    if (h->mi) h->vslot = find_vtable_slot(k, h->mi);
                }
                if (!h->miss_logged) {
                    pdp_log("resolve: %s -> %s.%s(argc=%d) mi=%p vslot=%p%s",
                            h->key, h->class_name, h->method, h->argc,
                            (void *)h->mi, (void *)h->vslot,
                            h->mi ? "" : " (will retry)");
                    h->miss_logged = 1;
                }
                if (h->mi) h->miss_logged = 0;
            }
            if (h->mi) {
                int ok = pdp_pac_hook_install_save(h->mi, h->tramp,
                                                   &h->mi_orig, h->key);
                if (ok && h->vslot) {
                    h->v_orig = *h->vslot;
                    *h->vslot = h->tramp;
                    pdp_log("vtable-swap: %s methodPtr %p -> tramp=%p",
                            h->key, h->v_orig, h->tramp);
                } else if (ok && !h->novtable_logged) {
                    pdp_log("vtable: %s no vtable slot (non-virtual/direct-call) "
                            "-- methodPointer swap only, may not reach game callsites",
                            h->key);
                    h->novtable_logged = 1;
                }
                if (ok) { h->installed = 1; h->fires++; }
            }
        } else if (!want && h->installed) {
            if (h->vslot && h->v_orig) *h->vslot = h->v_orig;
            if (pdp_pac_hook_restore(h->mi, h->mi_orig, h->key)) {
                h->installed = 0;
                h->mi_orig = h->v_orig = NULL;
            }
        }
    }

    // Registered features run after the unlock hooks.
    run_features_tick();

    // Install the in-game menu once UIKit's key window exists; idempotent.
    pdp_menu_install();
}

// Status dump â€” every 30s log the state so the log is useful without
// Format: `<key>=<state>` where state is on (installed), resolved
// (MethodInfo found, hook off), or ? (not yet resolved).
static void status_dump(void) {
    char line[1024];
    int w = snprintf(line, sizeof line, "status:");
    for (int i = 0; i < NUM_HOOKS; i++) {
        const char *st = g_hooks[i].installed ? "on" :
                         (g_hooks[i].mi ? "resolved" : "?");
        int n = snprintf(line + w, sizeof(line) - w, " %s=%s",
                         g_hooks[i].key, st);
        if (n < 0 || (size_t)n >= sizeof(line) - w) break;
        w += n;
    }
    for (int i = 0; i < NUM_FEATURES; i++) {
        PdpFeature *f = g_feature_registry[i];
        if (!f) continue;
        const char *tag = f->init_failed ? "x" : (f->initialised ? "i" : "-");
        int n = snprintf(line + w, sizeof(line) - w, " %s=%lu%s",
                         f->key, f->fires, tag);
        if (n < 0 || (size_t)n >= sizeof(line) - w) break;
        w += n;
    }
    pdp_log("%s", line);
}

// -------- main-runloop driver --------
//
// v1a and v1a.2 crashed at SIGSEGV 0x135 on a stack-pointer-relative load
// inside Unity's il2cpp runtime, from our pthread. Steve's diagnosis in
// debug/crashes/INDEX.md: on Unity 6000.3.9f1 even `il2cpp_domain_get` is
// unsafe on a non-GC-registered thread â€” the il2cpp exports rely on
// per-thread GC state that only gets populated by `thread_attach`, and
// `thread_attach` itself runs on that same unregistered thread. Chicken +
// egg.
//
// Fix: run EVERY il2cpp call from a CFRunLoopTimer on the main runloop.
// Unity's main thread is attached by the runtime itself at startup, so
// every call from inside this timer callback sees a valid GC thread
// state. 10 Hz tick load on main is negligible.

static CFRunLoopTimerRef g_timer = NULL;

static int  g_init_warned = 0;
static unsigned long g_last_status_ms = 0;

static void main_tick_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;

    pdp_cfg_reload_if_changed();

    if (!pdp_il2cpp_ready()) {
        char err[256];
        int rc = pdp_il2cpp_init(err, sizeof err);
        if (rc != 0) {
            if ((g_init_warned++ % 30) == 0) {
                pdp_log("main: waiting for il2cpp (rc=%d, %s)", rc, err);
            }
            return;
        }
        pdp_log("main: il2cpp ready");
    }

    tick_once();

    unsigned long t = now_ms();
    if (t - g_last_status_ms > 30000) {
        status_dump();
        g_last_status_ms = t;
    }
}

// -------- entry --------

__attribute__((constructor))
static void pdp_ctor(void) {
    pdp_log("boot: PDPlus v1.0.1 up · target com.FiredreamLabs.PolyDrift2 2.1.1 · Unity 6 / metadata v39");
    pdp_log("boot: running on main runloop (Unity 6 GC-thread-attach requirement)");
    pdp_cfg_reload_if_changed();

    CFRunLoopRef rl = CFRunLoopGetMain();
    pdp_log("boot: CFRunLoopGetMain=%p kCFRunLoopCommonModes=%p kCFRunLoopDefaultMode=%p",
            (void *)rl, (void *)kCFRunLoopCommonModes, (void *)kCFRunLoopDefaultMode);
    if (!rl) {
        pdp_log("boot: CFRunLoopGetMain returned NULL â€” PDPlus disabled");
        return;
    }
    g_timer = CFRunLoopTimerCreate(
        NULL,
        CFAbsoluteTimeGetCurrent() + 0.5,  // first fire +500 ms
        0.1,                                // repeat every 100 ms = 10 Hz
        0, 0,
        main_tick_cb,
        NULL);
    if (!g_timer) {
        pdp_log("boot: CFRunLoopTimerCreate failed â€” PDPlus disabled");
        return;
    }
    // Use the REAL kCFRunLoopCommonModes global. CoreFoundation's
    // CFRunLoopAddTimer special-cases this mode via POINTER equality, not
    // CFEqual (see Apple's CFRunLoop.c). v1a.3 used a runtime-created
    // content-equal CFString here, failed the pointer check, and the timer
    // was added to a never-serviced mode name â€” callback never fired.
    CFRunLoopAddTimer(rl, g_timer, kCFRunLoopCommonModes);
    pdp_log("boot: main-runloop timer armed in kCFRunLoopCommonModes (first fire +500ms, 100ms interval)");
}
