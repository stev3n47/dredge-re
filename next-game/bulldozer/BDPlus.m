// BDPlus v1.1 — Bulldozer Master (io.supercent.bulldozermasters 11.7.0)
// economy / ads / progression cheats.
//
// Target: Unity 2022.3.76f1, IL2CPP metadata v31, arm64.
// See next-game/bulldozer/BULLDOZER-FINDINGS.md for the full seam survey.
//
// Architecture (same as PFPlus/SPPlus):
//   - Load as a dylib via LC_LOAD_DYLIB injected into the app stub
//   - __attribute__((constructor)) arms a CFRunLoopTimer on the MAIN
//     runloop (Unity 6 GC-thread-attach lesson from PFPlus v1a.2 — every
//     il2cpp call runs on the Unity-attached main thread)
//   - 10 Hz tick: config reload -> feature registry -> menu install
//   - Features resolve classes/methods via the il2cpp bridge and either
//     poll-and-invoke (statics, getters/setters) or swap MethodInfo
//     methodPointer slots (pac_swap) for return-value overrides.
//
// Config file: Documents/bdplus.json — line-based key=value, reloaded on
// mtime change; the in-game menu writes through bd_cfg_set_bool.
//
//   money=1            CurrencyManager.Obtain_WithoutFX(+1M) drip ~5s
//   money_grant=0      ACTION: one-shot +10M (menu button sets, tick eats)
//   spend_free=1       CheckSpendable/TrySpend -> true (free purchases)
//   no_ads=1           User.NoAds + Interstitial.HasNoAds + Paused off
//   free_rv=1          RewardedVideo.Show/ShowWithExt -> callback(true)
//   infinite_fuel=1    FuelTank.SetOilToMax on every live tank ~5s
//   unlock_skins=1     User.SetSkinUnlockedAll ~30s
//   free_iap=1         InAppShopManager IsPurchased/limits -> true
//   research_force=1   StatUpgradeManager.IsResearchComplete -> true
//   stage_complete=0   ACTION: MineManager.CompleteStage (menu button)
//   sdk_progress=0     OPT-IN RISKY: User.Stage/Level/Coin boost
//   log_each_fire=0
//   tick_hz=10

#include "il2cpp_bridge.h"
#include "features.h"
#include "pac_swap.h"

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

// CoreFoundation forward decls (same pattern as PFPlus v1a.4 — the real
// kCFRunLoopCommonModes global is required; CFRunLoopAddTimer compares the
// mode by POINTER, not content).
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

// -------- logging (cached fd + atomic write(2), PFPlus pattern) ----------

static int g_log_fd = -1;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

static void bd_resolve_doc_path(const char *fname, char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/var/mobile/Containers/Data/Application";
    snprintf(out, cap, "%s/Documents/%s", home, fname);
}

static int bd_log_fd(void) {
    if (g_log_fd >= 0) return g_log_fd;
    pthread_mutex_lock(&g_log_mtx);
    if (g_log_fd < 0) {
        char path[1024];
        bd_resolve_doc_path("bdplus.log", path, sizeof path);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) g_log_fd = fd;
    }
    pthread_mutex_unlock(&g_log_mtx);
    return g_log_fd;
}

void bd_log(const char *fmt, ...) {
    int fd = bd_log_fd();
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

    if (write(fd, line, total) < 0) {
        (void)write(fd, line, total);
    }
}

// -------- config -----------------------------------------------------------

struct cfg {
    int money;
    int money_grant;
    int spend_free;
    int no_ads;
    int free_rv;
    int infinite_fuel;
    int unlock_skins;
    int free_iap;
    int research_force;
    int stage_complete;
    int sdk_progress;
    int log_each_fire;
    int tick_hz;
    time_t mtime;
    int    loaded_ok;
};

static struct cfg g_cfg = {
    .money = 1, .money_grant = 0, .spend_free = 1,
    .no_ads = 1, .free_rv = 1, .infinite_fuel = 1, .unlock_skins = 1,
    .free_iap = 1, .research_force = 1,
    .stage_complete = 0, .sdk_progress = 0,
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

static const char *k_cfg_keys[] = {
    "money", "money_grant", "spend_free", "no_ads", "free_rv",
    "infinite_fuel", "unlock_skins", "free_iap", "research_force",
    "stage_complete", "sdk_progress", "log_each_fire", "tick_hz",
};
#define NUM_CFG_KEYS ((int)(sizeof(k_cfg_keys) / sizeof(k_cfg_keys[0])))

// Field-offset table kept in sync with struct cfg by hand — the config
// file is the only consumer, so a missed key just means "not editable".
static int *cfg_field(const char *k) {
    if      (!strcmp(k, "money"))          return &g_cfg.money;
    else if (!strcmp(k, "money_grant"))    return &g_cfg.money_grant;
    else if (!strcmp(k, "spend_free"))     return &g_cfg.spend_free;
    else if (!strcmp(k, "no_ads"))         return &g_cfg.no_ads;
    else if (!strcmp(k, "free_rv"))        return &g_cfg.free_rv;
    else if (!strcmp(k, "infinite_fuel"))  return &g_cfg.infinite_fuel;
    else if (!strcmp(k, "unlock_skins"))   return &g_cfg.unlock_skins;
    else if (!strcmp(k, "free_iap"))       return &g_cfg.free_iap;
    else if (!strcmp(k, "research_force")) return &g_cfg.research_force;
    else if (!strcmp(k, "stage_complete")) return &g_cfg.stage_complete;
    else if (!strcmp(k, "sdk_progress"))   return &g_cfg.sdk_progress;
    else if (!strcmp(k, "log_each_fire"))  return &g_cfg.log_each_fire;
    else if (!strcmp(k, "tick_hz"))        return &g_cfg.tick_hz;
    return NULL;
}

static int cfg_read_locked(const char *k, int defval) {
    int *f = cfg_field(k);
    return f ? *f : defval;
}

static void cfg_write_locked(const char *k, int v) {
    int *f = cfg_field(k);
    if (f) *f = v;
}

// Reload config from disk. Returns 1 on change, 0 otherwise.
static int bd_cfg_reload_if_changed(void) {
    char path[1024];
    bd_resolve_doc_path("bdplus.json", path, sizeof path);
    struct stat st;
    if (stat(path, &st) != 0) {
        int should_write = 0;
        pthread_mutex_lock(&g_cfg_mtx);
        if (!g_cfg.loaded_ok) { g_cfg.loaded_ok = 1; should_write = 1; }
        pthread_mutex_unlock(&g_cfg_mtx);
        if (should_write) {
            int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0) {
                const char *defaults =
                    "# BDPlus v1.1 config — one key=value per line\n"
                    "# Edit in Files app or via SSH; reloaded automatically.\n"
                    "money=1\n"
                    "# money_grant / stage_complete are ACTION keys: the\n"
                    "# menu sets them to 1, the next tick consumes and\n"
                    "# resets to 0. Hand-setting 1 also works.\n"
                    "money_grant=0\n"
                    "spend_free=1\n"
                    "no_ads=1\n"
                    "free_rv=1\n"
                    "infinite_fuel=1\n"
                    "unlock_skins=1\n"
                    "free_iap=1\n"
                    "research_force=1\n"
                    "stage_complete=0\n"
                    "# sdk_progress writes User.Stage/Level/Coin — may\n"
                    "# desync server-side progression. Opt-in only.\n"
                    "sdk_progress=0\n"
                    "log_each_fire=0\n"
                    "tick_hz=10\n";
                (void)write(fd, defaults, strlen(defaults));
                close(fd);
                bd_log("cfg: wrote default config to %s", path);
            }
        }
        return 0;
    }
    pthread_mutex_lock(&g_cfg_mtx);
    if (st.st_mtime == g_cfg.mtime && g_cfg.loaded_ok) {
        pthread_mutex_unlock(&g_cfg_mtx);
        return 0;
    }
    FILE *f = fopen(path, "r");
    if (!f) {
        pthread_mutex_unlock(&g_cfg_mtx);
        return 0;
    }
    char line[256];
    while (fgets(line, sizeof line, f)) {
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        if (*s == '#' || *s == '\n' || *s == '\0') continue;
        char *eq = strchr(s, '=');
        if (!eq) continue;
        *eq = 0;
        char *k = s;
        char *v = eq + 1;
        char *e = k + strlen(k);
        while (e > k && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        char *ve = v + strlen(v);
        while (ve > v && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) *--ve = 0;
        if (!strcmp(k, "tick_hz")) {
            int hz = atoi(v);
            if (hz < 1) hz = 1;
            if (hz > 60) hz = 60;
            g_cfg.tick_hz = hz;
            continue;
        }
        int *fld = cfg_field(k);
        if (fld) *fld = parse_bool_or_int(v, *fld);
    }
    fclose(f);
    g_cfg.mtime = st.st_mtime;
    g_cfg.loaded_ok = 1;
    struct cfg snap = g_cfg;
    pthread_mutex_unlock(&g_cfg_mtx);
    bd_log("cfg: reloaded (money=%d/spend=%d no_ads=%d rv=%d fuel=%d skins=%d iap=%d research=%d sdk=%d hz=%d)",
           snap.money, snap.spend_free, snap.no_ads, snap.free_rv,
           snap.infinite_fuel, snap.unlock_skins, snap.free_iap,
           snap.research_force, snap.sdk_progress, snap.tick_hz);
    return 1;
}

// Write the full in-memory g_cfg back to Documents/bdplus.json atomically.
// Called with g_cfg_mtx held.
static void bd_cfg_save_locked(void) {
    char path[1024];
    bd_resolve_doc_path("bdplus.json", path, sizeof path);
    char tmp[1024];
    int tn = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (tn <= 0 || tn >= (int)sizeof tmp) return;

    FILE *f = fopen(tmp, "w");
    if (!f) return;
    fprintf(f,
        "# BDPlus config — one key=value per line\n"
        "# Written by the in-game menu. Hand-edits are preserved across\n"
        "# restarts; the next menu toggle will re-serialize the file.\n");
    for (int i = 0; i < NUM_CFG_KEYS; i++) {
        const char *k = k_cfg_keys[i];
        if (!strcmp(k, "tick_hz")) continue;  // written last, clamped
        fprintf(f, "%s=%d\n", k, cfg_read_locked(k, 0));
    }
    fprintf(f, "tick_hz=%d\n", g_cfg.tick_hz);
    fflush(f);
    fclose(f);

    if (rename(tmp, path) == 0) {
        struct stat st;
        if (stat(path, &st) == 0) g_cfg.mtime = st.st_mtime;
    } else {
        unlink(tmp);
    }
}

// Public helpers for feature modules (features.h).
int bd_cfg_bool(const char *key, int defval) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = cfg_read_locked(key, defval);
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

int bd_cfg_int(const char *key, int defval) {
    return bd_cfg_bool(key, defval);
}

void bd_cfg_set_bool(const char *key, int value) {
    pthread_mutex_lock(&g_cfg_mtx);
    cfg_write_locked(key, value ? 1 : 0);
    bd_cfg_save_locked();
    pthread_mutex_unlock(&g_cfg_mtx);
}

// ---------------- Diagnostic helpers (features.h) -------------------------

int bd_find_classes_by_name(const char **substrs, int substr_count,
                            Il2CppClass **out_classes, int cap) {
    if (!bd_il2cpp_ready() || !substrs || substr_count <= 0) return 0;
    int n = 0;
    Il2CppDomain *dom = bd_il2cpp_domain_get();
    if (!dom) return 0;
    size_t na = 0;
    const Il2CppAssembly **asms = bd_il2cpp_domain_get_assemblies(dom, &na);
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = bd_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        const char *in = bd_il2cpp_image_get_name(img);
        if (!in || strcmp(in, "Assembly-CSharp.dll") != 0) continue;
        size_t nc = bd_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = bd_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kn = bd_il2cpp_class_get_name(k);
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

// Simple-name match tolerant of IL2CPP nested-type naming: the runtime
// name may be "Interstitial", "AdsHelper.Interstitial", or
// "AdsHelper/Interstitial" depending on metadata version. Compare the
// last '.'/'/'-separated segment.
static int simple_name_eq(const char *runtime_name, const char *want) {
    if (!runtime_name || !want) return 0;
    if (!strcmp(runtime_name, want)) return 1;
    const char *slash = strrchr(runtime_name, '/');
    const char *dot   = strrchr(runtime_name, '.');
    const char *seg   = slash > dot ? slash : dot;
    if (seg && !strcmp(seg + 1, want)) return 1;
    return 0;
}

// Verified class lookup — name match + signature method must resolve.
// Handles IL2CPP nested types (AdsHelper.Interstitial etc.) whose runtime
// name/namespace may differ from the C# display path.
Il2CppClass *bd_find_class_verified(const char *image_name,
                                    const char *cls_name,
                                    const char *method_name, int argc) {
    if (!bd_il2cpp_ready() || !cls_name || !method_name) return NULL;
    Il2CppDomain *dom = bd_il2cpp_domain_get();
    if (!dom) return NULL;
    size_t na = 0;
    const Il2CppAssembly **asms = bd_il2cpp_domain_get_assemblies(dom, &na);
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = bd_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        if (image_name) {
            const char *in = bd_il2cpp_image_get_name(img);
            if (!in || strcmp(in, image_name) != 0) continue;
        }
        size_t nc = bd_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = bd_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kn = bd_il2cpp_class_get_name(k);
            if (!simple_name_eq(kn, cls_name)) continue;
            if (bd_il2cpp_runtime_class_init) bd_il2cpp_runtime_class_init(k);
            if (bd_il2cpp_class_get_method_from_name(k, method_name, argc)) {
                return k;
            }
        }
    }
    return NULL;
}

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
    Il2CppClass *k = bd_il2cpp_object_get_class(obj);
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

int bd_diag_log_live_instances(const char *prefix,
                               Il2CppClass * const *target_classes,
                               int target_count) {
    if (!bd_il2cpp_ready() || !target_classes || target_count <= 0) return 0;
    if (!bd_il2cpp_gc_foreach_heap || !bd_il2cpp_object_get_class) return 0;
    struct diag_walk w = { target_classes, target_count, {0}, {0}, 0, 0 };
    bd_il2cpp_gc_foreach_heap(diag_walk_cb, &w);
    bd_log("%s: heap walk scanned %ld objects, %d live instance(s) of %d target class(es)",
           prefix, w.scanned, w.n, target_count);
    for (int i = 0; i < w.n; i++) {
        const char *nm = bd_il2cpp_class_get_name(w.hits_klass[i]);
        bd_log("%s:   live %s @ %p", prefix, nm ? nm : "?", w.hits_obj[i]);
    }
    return w.n;
}

void bd_diag_log_methods(const char *prefix, Il2CppClass *klass,
                         const char **name_substrs, int substr_count) {
    if (!bd_il2cpp_ready() || !klass || !bd_il2cpp_class_get_methods) return;
    const char *kn = bd_il2cpp_class_get_name(klass);
    void *iter = NULL;
    int logged = 0;
    const MethodInfo *m;
    while ((m = bd_il2cpp_class_get_methods(klass, &iter)) != NULL) {
        const char *mn = bd_il2cpp_method_get_name(m);
        if (!mn) continue;
        if (substr_count > 0 && name_substrs) {
            int match = 0;
            for (int i = 0; i < substr_count; i++) {
                if (name_substrs[i] && strstr(mn, name_substrs[i])) { match = 1; break; }
            }
            if (!match) continue;
        }
        uint32_t iflags = 0;
        uint32_t f = bd_il2cpp_method_get_flags ? bd_il2cpp_method_get_flags(m, &iflags) : 0;
        int is_static = (f & 0x10) ? 1 : 0;
        int argc = bd_il2cpp_method_get_param_count ? (int)bd_il2cpp_method_get_param_count(m) : -1;
        bd_log("%s: method %s.%s argc=%d%s", prefix, kn ? kn : "?", mn, argc,
               is_static ? " [static]" : "");
        if (++logged >= 32) { bd_log("%s: (methods truncated at 32)", prefix); break; }
    }
}

// ---------------- Periodic rewalk registry --------------------------------

#define BD_MAX_REWALK_TARGETS 64
struct bd_rewalk_entry {
    const char *prefix;
    Il2CppClass *klass;
    int done;
};
static struct bd_rewalk_entry g_rewalk[BD_MAX_REWALK_TARGETS];
static int g_rewalk_count = 0;
static unsigned long g_last_rewalk_ms = 0;

void bd_register_rewalk(const char *prefix, Il2CppClass *klass) {
    if (!prefix || !klass) return;
    if (g_rewalk_count >= BD_MAX_REWALK_TARGETS) {
        bd_log("rewalk: registry full at %d — dropping %s target",
               BD_MAX_REWALK_TARGETS, prefix);
        return;
    }
    for (int i = 0; i < g_rewalk_count; i++) {
        if (g_rewalk[i].klass == klass && g_rewalk[i].prefix == prefix) return;
    }
    g_rewalk[g_rewalk_count].prefix = prefix;
    g_rewalk[g_rewalk_count].klass = klass;
    g_rewalk[g_rewalk_count].done = 0;
    g_rewalk_count++;
}

#define BD_KLASS_SAMPLE_CAP 16
struct bd_rewalk_ctx {
    void *found_obj[BD_MAX_REWALK_TARGETS];
    Il2CppClass *found_klass[BD_MAX_REWALK_TARGETS];
    int n_found;
    long scanned;
    Il2CppClass *sampled_klass[BD_KLASS_SAMPLE_CAP];
    int n_sampled;
    int do_sample;
};

static void bd_rewalk_cb(void *obj, void *user) {
    struct bd_rewalk_ctx *c = (struct bd_rewalk_ctx *)user;
    c->scanned++;
    if (!obj) return;
    Il2CppClass *k = bd_il2cpp_object_get_class(obj);
    if (!k) return;

    for (int i = 0; i < g_rewalk_count; i++) {
        if (g_rewalk[i].done) continue;
        if (g_rewalk[i].klass == k) {
            if (c->n_found < BD_MAX_REWALK_TARGETS) {
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

    if (c->do_sample && c->n_sampled < BD_KLASS_SAMPLE_CAP) {
        for (int j = 0; j < c->n_sampled; j++) {
            if (c->sampled_klass[j] == k) return;
        }
        c->sampled_klass[c->n_sampled++] = k;
    }
}

static void bd_periodic_rewalk(void) {
    if (g_rewalk_count == 0) return;
    if (!bd_il2cpp_ready() || !bd_il2cpp_gc_foreach_heap ||
        !bd_il2cpp_object_get_class) return;

    unsigned long t = now_ms();
    if (!g_last_rewalk_ms) { g_last_rewalk_ms = t; return; }
    if ((t - g_last_rewalk_ms) < 60000UL) return;
    g_last_rewalk_ms = t;

    int pending = 0;
    for (int i = 0; i < g_rewalk_count; i++) if (!g_rewalk[i].done) pending++;
    if (pending == 0) return;

    static int sample_done = 0;
    struct bd_rewalk_ctx ctx = { {0}, {0}, 0, 0, {0}, 0, !sample_done };
    bd_il2cpp_gc_foreach_heap(bd_rewalk_cb, &ctx);

    if (ctx.do_sample && ctx.n_sampled > 0 && !sample_done) {
        sample_done = 1;
        uintptr_t lo = (uintptr_t)-1, hi = 0;
        for (int i = 0; i < g_rewalk_count; i++) {
            uintptr_t p = (uintptr_t)g_rewalk[i].klass;
            if (!p) continue;
            if (p < lo) lo = p;
            if (p > hi) hi = p;
        }
        uintptr_t safe_lo = (lo > 0x4000000) ? lo - 0x4000000 : 0;
        uintptr_t safe_hi = hi + 0x4000000;
        bd_log("rewalk-sample: %d distinct klass ptrs sampled; "
               "metadata range of our %d resolved targets: [0x%lx..0x%lx]",
               ctx.n_sampled, g_rewalk_count, (long)lo, (long)hi);
        int in_range = 0;
        for (int i = 0; i < ctx.n_sampled; i++) {
            uintptr_t p = (uintptr_t)ctx.sampled_klass[i];
            int ok = (p >= safe_lo && p <= safe_hi);
            bd_log("rewalk-sample: [%2d] klass=%p %s",
                   i, (void *)ctx.sampled_klass[i],
                   ok ? "IN-RANGE" : "OUT-OF-RANGE");
            if (ok) in_range++;
        }
        if (in_range == 0) {
            bd_log("rewalk-sample: ZERO in-range klass pointers — "
                   "gc_foreach_heap matches the SPPlus/PFPlus failure "
                   "pattern; instance features will rely on action-time "
                   "walks only.");
        } else {
            bd_log("rewalk-sample: %d/%d klass pointers in metadata range — "
                   "heap walk is usable", in_range, ctx.n_sampled);
        }
    }

    if (ctx.n_found == 0) {
        bd_log("rewalk: scanned %ld objects, %d class(es) still unfound",
               ctx.scanned, pending);
        return;
    }
    for (int i = 0; i < ctx.n_found; i++) {
        for (int j = 0; j < g_rewalk_count; j++) {
            if (g_rewalk[j].klass == ctx.found_klass[i] && !g_rewalk[j].done) {
                const char *kn = bd_il2cpp_class_get_name(g_rewalk[j].klass);
                bd_log("%s: rewalk found live %s @ %p (scanned=%ld)",
                       g_rewalk[j].prefix, kn ? kn : "?", ctx.found_obj[i],
                       ctx.scanned);
                g_rewalk[j].done = 1;
            }
        }
    }
}

// ---------------- Feature registry -----------------------------------------

static BdFeature *g_feature_registry[] = {
    &bd_feature_money,
    &bd_feature_spend,
    &bd_feature_profile,
    &bd_feature_rv,
    &bd_feature_fuel,
    &bd_feature_stage,
    &bd_feature_research,
    &bd_feature_iap,
};
static const int NUM_FEATURES = sizeof(g_feature_registry) / sizeof(g_feature_registry[0]);

static unsigned long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static void run_features_tick(void) {
    for (int i = 0; i < NUM_FEATURES; i++) {
        BdFeature *f = g_feature_registry[i];
        if (!f || f->init_failed) continue;
        if (!bd_cfg_bool(f->key, 1)) continue;
        if (!f->initialised) {
            if (!f->init) { f->init_failed = 1; continue; }
            int rc = f->init();
            if (rc != 0) {
                bd_log("feature: %s init failed (rc=%d) — disabled for session", f->key, rc);
                f->init_failed = 1;
                continue;
            }
            f->initialised = 1;
            bd_log("feature: %s init ok", f->key);
        }
        if (f->tick) {
            int did = f->tick();
            if (did > 0) {
                f->fires++;
                f->last_tick_ms = now_ms();
            }
        }
        if (f->rewalk) {
            unsigned long t = now_ms();
            if (!f->last_rewalk_ms || (t - f->last_rewalk_ms) >= 60000UL) {
                f->rewalk();
                f->last_rewalk_ms = t;
            }
        }
    }
    bd_periodic_rewalk();
}

static void tick_once(void) {
    bd_cfg_reload_if_changed();
    if (!bd_il2cpp_ready()) return;
    run_features_tick();
    bd_menu_install();
}

static void status_dump(void) {
    char line[1024];
    int w = snprintf(line, sizeof line, "status:");
    for (int i = 0; i < NUM_FEATURES; i++) {
        BdFeature *f = g_feature_registry[i];
        if (!f) continue;
        const char *tag = f->init_failed ? "x" : (f->initialised ? "i" : "-");
        int n = snprintf(line + w, sizeof(line) - w, " %s=%lu%s",
                         f->key, f->fires, tag);
        if (n < 0 || (size_t)n >= sizeof(line) - w) break;
        w += n;
    }
    bd_log("%s", line);
}

// -------- main-runloop driver ----------------------------------------------
//
// Same lesson as PFPlus v1a.2: on Unity il2cpp builds even il2cpp_domain_get
// can be unsafe on a non-GC-registered pthread. Every il2cpp call runs from
// a CFRunLoopTimer on the main runloop where Unity's own thread-attach has
// already populated the GC thread state.

static CFRunLoopTimerRef g_timer = NULL;

static int  g_init_warned = 0;
static unsigned long g_last_status_ms = 0;

static void main_tick_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;

    bd_cfg_reload_if_changed();

    if (!bd_il2cpp_ready()) {
        char err[256];
        int rc = bd_il2cpp_init(err, sizeof err);
        if (rc != 0) {
            if ((g_init_warned++ % 30) == 0) {
                bd_log("main: waiting for il2cpp (rc=%d, %s)", rc, err);
            }
            return;
        }
        bd_log("main: il2cpp ready");
    }

    tick_once();

    unsigned long t = now_ms();
    if (t - g_last_status_ms > 30000) {
        status_dump();
        g_last_status_ms = t;
    }
}

// -------- entry ------------------------------------------------------------

__attribute__((constructor))
static void bd_ctor(void) {
    bd_log("boot: BDPlus v1.1 up · target io.supercent.bulldozermasters 11.7.0 · Unity 2022.3.76f1 / metadata v31");
    bd_log("boot: running on main runloop (GC-thread-attach requirement)");
    bd_cfg_reload_if_changed();

    CFRunLoopRef rl = CFRunLoopGetMain();
    bd_log("boot: CFRunLoopGetMain=%p kCFRunLoopCommonModes=%p kCFRunLoopDefaultMode=%p",
           (void *)rl, (void *)kCFRunLoopCommonModes, (void *)kCFRunLoopDefaultMode);
    if (!rl) {
        bd_log("boot: CFRunLoopGetMain returned NULL — BDPlus disabled");
        return;
    }
    g_timer = CFRunLoopTimerCreate(
        NULL,
        CFAbsoluteTimeGetCurrent() + 0.5,
        0.1,
        0, 0,
        main_tick_cb,
        NULL);
    if (!g_timer) {
        bd_log("boot: CFRunLoopTimerCreate failed — BDPlus disabled");
        return;
    }
    CFRunLoopAddTimer(rl, g_timer, kCFRunLoopCommonModes);
    bd_log("boot: main-runloop timer armed in kCFRunLoopCommonModes (first fire +500ms, 100ms interval)");
}
