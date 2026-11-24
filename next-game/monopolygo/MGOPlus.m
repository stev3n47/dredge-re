// MGOPlus v1 — Monopoly GO (com.scopely.monopolygo 1.82.0) "see the next
// roll" overlay.
//
// Scope for v1:
//   - Load as a dylib via __mod_init_func
//   - Open Documents/mgoplus.log
//   - Read Documents/mgoplus.json (line-based key=value)
//   - Resolve the il2cpp bridge, find Tophat.Common.Board.State.BoardState
//   - On a 10 Hz tick on the MAIN RUNLOOP (Unity 6 GC-thread requirement):
//       * heap-walk for the live BoardState instance (cached, klass-checked)
//       * read RandomStates["DICE_ROLL"] + RollMultiplier + TokenPosition
//       * replay the CMWC the game will draw → next N rolls (peek=3)
//       * drive the floating-orb / panel UI with the prediction
//   - Zero hooks, zero code-page writes, zero managed invokes. Pure reads.
//
// Deferred / rejected on purpose:
//   - Forcing rolls (prefilling RollClientActionV2.RollResult or writing
//     ScriptedRolls): server-side RngIndex validation risk + needs the
//     hooking surface PlaygamiSwizzler probably watches. Out of scope.
//   - ESCAPE_JAIL / CHANCE_CARDS contexts: same math, different context
//     string — easy follow-up once the DICE_ROLL path validates on-device.
//
// Config file format (Documents/mgoplus.json — line-based):
//   # comments allowed
//   dice=1        master toggle for prediction + UI
//   peek=3        how many rolls ahead to show (1..6)
//   log_rolls=1   log every predicted next-roll change (validation aid)
//   tick_hz=10    dispatcher cadence
//
// File is reloaded when its mtime changes; the orb toggle also flips the
// in-memory value directly.

#include "il2cpp_bridge.h"
#include "features.h"

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

// CoreFoundation forward decls — linked with -framework CoreFoundation so
// kCFRunLoopCommonModes resolves as a real load-command symbol (PFPlus
// v1a.3 lesson: CFRunLoopAddTimer compares mode pointers, not contents).
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

// -------- forward decls --------

static unsigned long now_ms(void);

// -------- logging --------
//
// Same SPPlus-proven pattern: cached fd + atomic write(2), no libc FILE
// lock to contend with Unity's console writer.

static int g_log_fd = -1;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

static void mgo_resolve_doc_path(const char *fname, char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/var/mobile/Containers/Data/Application";
    snprintf(out, cap, "%s/Documents/%s", home, fname);
}

static int mgo_log_fd(void) {
    if (g_log_fd >= 0) return g_log_fd;
    pthread_mutex_lock(&g_log_mtx);
    if (g_log_fd < 0) {
        char path[1024];
        mgo_resolve_doc_path("mgoplus.log", path, sizeof path);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) g_log_fd = fd;
    }
    pthread_mutex_unlock(&g_log_mtx);
    return g_log_fd;
}

void mgo_log(const char *fmt, ...) {
    int fd = mgo_log_fd();
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

// -------- config --------

struct cfg {
    int dice;         // master: predictor + UI
    int peek;         // rolls ahead (1..6)
    int log_rolls;    // log each predicted next-roll change
    int tick_hz;
    time_t mtime;
    int    loaded_ok;
};

static struct cfg g_cfg = {
    .dice = 1, .peek = 3, .log_rolls = 1, .tick_hz = 10,
    .mtime = 0, .loaded_ok = 0,
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

int mgo_cfg_bool(const char *key, int defval) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = defval;
    if      (!strcmp(key, "dice"))      v = g_cfg.dice;
    else if (!strcmp(key, "log_rolls")) v = g_cfg.log_rolls;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

int mgo_cfg_int(const char *key, int defval) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = defval;
    if      (!strcmp(key, "peek"))    v = g_cfg.peek;
    else if (!strcmp(key, "tick_hz")) v = g_cfg.tick_hz;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

void mgo_cfg_set_bool(const char *key, int value) {
    pthread_mutex_lock(&g_cfg_mtx);
    if      (!strcmp(key, "dice"))      g_cfg.dice = value ? 1 : 0;
    else if (!strcmp(key, "log_rolls")) g_cfg.log_rolls = value ? 1 : 0;
    pthread_mutex_unlock(&g_cfg_mtx);
}

// Reload config from disk. Returns 1 on change, 0 otherwise.
static int mgo_cfg_reload_if_changed(void) {
    char path[1024];
    mgo_resolve_doc_path("mgoplus.json", path, sizeof path);
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
                    "# MGOPlus v1 config — one key=value per line\n"
                    "# Edit in Files app or via SSH; reloaded automatically.\n"
                    "dice=1\n"
                    "peek=3\n"
                    "log_rolls=1\n"
                    "tick_hz=10\n";
                (void)write(fd, defaults, strlen(defaults));
                close(fd);
                mgo_log("cfg: wrote default config to %s", path);
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
        char *e = k + strlen(k);
        while (e > k && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        char *ve = v + strlen(v);
        while (ve > v && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) *--ve = 0;
        if      (!strcmp(k, "dice"))      next.dice = parse_bool_or_int(v, next.dice);
        else if (!strcmp(k, "peek"))      next.peek = parse_bool_or_int(v, next.peek);
        else if (!strcmp(k, "log_rolls")) next.log_rolls = parse_bool_or_int(v, next.log_rolls);
        else if (!strcmp(k, "tick_hz")) {
            int hz = atoi(v);
            if (hz < 1) hz = 1;
            if (hz > 60) hz = 60;
            next.tick_hz = hz;
        }
    }
    fclose(f);
    next.mtime = st.st_mtime;
    next.loaded_ok = 1;
    g_cfg = next;
    pthread_mutex_unlock(&g_cfg_mtx);
    mgo_log("cfg: reloaded (dice=%d peek=%d log_rolls=%d tick_hz=%d)",
            next.dice, next.peek, next.log_rolls, next.tick_hz);
    return 1;
}

// -------- feature registry --------

static MgoFeature *g_feature_registry[] = {
    &mgo_feature_dice,
};
#define NUM_FEATURES ((int)(sizeof(g_feature_registry) / sizeof(g_feature_registry[0])))

static void run_features_tick(void) {
    for (int i = 0; i < NUM_FEATURES; i++) {
        MgoFeature *f = g_feature_registry[i];
        if (!f || f->init_failed) continue;
        if (!mgo_cfg_bool(f->key, 1)) continue;
        if (!f->initialised) {
            if (!f->init) { f->init_failed = 1; continue; }
            int rc = f->init();
            if (rc != 0) {
                mgo_log("feature: %s init failed (rc=%d) — disabled for session", f->key, rc);
                f->init_failed = 1;
                continue;
            }
            f->initialised = 1;
            mgo_log("feature: %s init ok", f->key);
        }
        if (f->tick) {
            int did = f->tick();
            if (did > 0) {
                f->fires++;
                f->last_tick_ms = now_ms();
            }
        }
    }
}

// -------- tick --------

static unsigned long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static void tick_once(void) {
    mgo_cfg_reload_if_changed();
    if (!mgo_il2cpp_ready()) return;
    run_features_tick();
    // Install + refresh the overlay once UIKit's key window exists.
    // Both are idempotent / cheap when nothing changed.
    mgo_menu_install();
    mgo_menu_refresh();
}

// -------- main-runloop driver --------
//
// PFPlus v1a lesson (debug/crashes/INDEX.md): on Unity 6000.x even
// il2cpp_domain_get is unsafe on a non-GC-registered thread. EVERY il2cpp
// call runs inside this CFRunLoopTimer on the main runloop, where Unity's
// own thread is attached by the runtime itself.

static CFRunLoopTimerRef g_timer = NULL;

static int  g_init_warned = 0;

static void main_tick_cb(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;

    mgo_cfg_reload_if_changed();

    if (!mgo_il2cpp_ready()) {
        char err[256];
        int rc = mgo_il2cpp_init(err, sizeof err);
        if (rc != 0) {
            if ((g_init_warned++ % 30) == 0) {
                mgo_log("main: waiting for il2cpp (rc=%d, %s)", rc, err);
            }
            return;
        }
        mgo_log("main: il2cpp ready");
    }

    tick_once();
}

// -------- entry --------

__attribute__((constructor))
static void mgo_ctor(void) {
    mgo_log("boot: MGOPlus v1 up · target com.scopely.monopolygo 1.82.0 · Unity 6 / metadata v39");
    mgo_log("boot: running on main runloop (Unity 6 GC-thread-attach requirement)");
    mgo_cfg_reload_if_changed();

    CFRunLoopRef rl = CFRunLoopGetMain();
    if (!rl) {
        mgo_log("boot: CFRunLoopGetMain returned NULL — MGOPlus disabled");
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
        mgo_log("boot: CFRunLoopTimerCreate failed — MGOPlus disabled");
        return;
    }
    CFRunLoopAddTimer(rl, g_timer, kCFRunLoopCommonModes);
    mgo_log("boot: main-runloop timer armed in kCFRunLoopCommonModes (first fire +500ms, 100ms interval)");
}
