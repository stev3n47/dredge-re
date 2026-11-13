// PFPlus v1a — PolyFootball (com.Miceli.Poly 4.5.3) economy unlocks.
//
// Scope for v1a (per next-game/polyfootball/PLAN.md):
//   - Load as a dylib via __mod_init_func
//   - Open Documents/pfplus.log
//   - Read Documents/pfplus.json (line-based key=value, one per line)
//   - Resolve il2cpp bridge, find PremiumCurrency class, log method_count
//     (acceptance: counts match catalog's 22)
//   - On a 10 Hz tick on a background thread:
//       * find a live PremiumCurrency instance via GC heap walk (cached)
//       * for each enabled flag, call its getter — if drift, invoke its
//         Unlock* setter. Zero code-page writes. Pure poll-and-invoke.
//
// Deferred to v1b/v1c/v1.5/v2+ per plan:
//   - set_Balance drift re-assertion, free money (CareerTeamBudget.Fits),
//     IAP CrossPlatformValidator hook, server-sync short-circuit,
//     Tier 2 dice/physics methodPointer swaps (PAC-gated),
//     in-game UIKit menu, team discriminator, speed scalar.
//
// Config file format (Documents/pfplus.json — misnomer, line-based):
//   # comments allowed
//   pro=1
//   agent=1
//   triple_tickets=1
//   cap_increase=1
//   log_each_fire=0
//   tick_hz=10
//
// File is reloaded at each tick when its mtime changes, so the user can
// toggle features live with the Files app.

#include "il2cpp_bridge.h"

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
// content — see CFRunLoop.c in Apple's open source. Our custom string had a
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
// never holds g_log_mtx across I/O — it protects only fd init.

static int g_log_fd = -1;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

static void pfp_resolve_doc_path(const char *fname, char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/var/mobile/Containers/Data/Application";
    snprintf(out, cap, "%s/Documents/%s", home, fname);
}

static int pfp_log_fd(void) {
    if (g_log_fd >= 0) return g_log_fd;
    pthread_mutex_lock(&g_log_mtx);
    if (g_log_fd < 0) {
        char path[1024];
        pfp_resolve_doc_path("pfplus.log", path, sizeof path);
        int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) g_log_fd = fd;
    }
    pthread_mutex_unlock(&g_log_mtx);
    return g_log_fd;
}

void pfp_log(const char *fmt, ...) {
    int fd = pfp_log_fd();
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

    // Single atomic write — no libc FILE lock, no stdio buffering. write()
    // to a plain file on iOS doesn't short-write; one retry handles the
    // rare EINTR.
    if (write(fd, line, total) < 0) {
        (void)write(fd, line, total);
    }
}

// -------- config --------

struct cfg {
    int pro;
    int agent;
    int triple_tickets;
    int cap_increase;
    int log_each_fire;
    int tick_hz;
    // Observability
    time_t mtime;
    int    loaded_ok;
};

static struct cfg g_cfg = {
    .pro = 1, .agent = 1, .triple_tickets = 1, .cap_increase = 1,
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
static int pfp_cfg_reload_if_changed(void) {
    char path[1024];
    pfp_resolve_doc_path("pfplus.json", path, sizeof path);
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
                    "# PFPlus v1a config — one key=value per line\n"
                    "# Edit in Files app or via SSH; reloaded automatically.\n"
                    "pro=1\n"
                    "agent=1\n"
                    "triple_tickets=1\n"
                    "cap_increase=1\n"
                    "log_each_fire=0\n"
                    "tick_hz=10\n";
                (void)write(fd, defaults, strlen(defaults));
                close(fd);
                pfp_log("cfg: wrote default config to %s", path);
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
        // trim
        char *e = k + strlen(k);
        while (e > k && (e[-1] == ' ' || e[-1] == '\t')) *--e = 0;
        char *ve = v + strlen(v);
        while (ve > v && (ve[-1] == '\n' || ve[-1] == '\r' || ve[-1] == ' ' || ve[-1] == '\t')) *--ve = 0;
        if      (!strcmp(k, "pro"))            next.pro = parse_bool_or_int(v, next.pro);
        else if (!strcmp(k, "agent"))          next.agent = parse_bool_or_int(v, next.agent);
        else if (!strcmp(k, "triple_tickets")) next.triple_tickets = parse_bool_or_int(v, next.triple_tickets);
        else if (!strcmp(k, "cap_increase"))   next.cap_increase = parse_bool_or_int(v, next.cap_increase);
        else if (!strcmp(k, "log_each_fire"))  next.log_each_fire = parse_bool_or_int(v, next.log_each_fire);
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
    pfp_log("cfg: reloaded (pro=%d agent=%d triple=%d cap=%d tick_hz=%d log=%d)",
            next.pro, next.agent, next.triple_tickets, next.cap_increase,
            next.tick_hz, next.log_each_fire);
    return 1;
}

// -------- hook table --------

struct hook {
    const char *key;       // config flag name
    const char *getter;    // returns bool — skip Unlock when already true
    const char *setter;    // the Unlock* method
    const MethodInfo *g_mi;
    const MethodInfo *s_mi;
    unsigned long fires;
    unsigned long last_tick_ms;
    int last_getter_state; // -1 unknown, 0 false, 1 true — for drift log
    int g_static;          // getter is static (self=NULL at invoke)
    int s_static;          // setter is static (self=NULL at invoke)
};

static struct hook g_hooks[] = {
    { "pro",            "get_HasPro",               "UnlockPro",              NULL, NULL, 0, 0, -1, 0, 0 },
    { "agent",          "get_HasAgent",             "UnlockAgent",            NULL, NULL, 0, 0, -1, 0, 0 },
    { "triple_tickets", "get_HasTripleTicketBoost", "UnlockTripleTicketBoost",NULL, NULL, 0, 0, -1, 0, 0 },
    { "cap_increase",   "get_HasCapIncrease",       "UnlockCapIncrease",      NULL, NULL, 0, 0, -1, 0, 0 },
};

// METHOD_ATTRIBUTE_STATIC = 0x0010 (mono/ECMA attribute table)
#define PFP_METHOD_STATIC 0x0010
static const int NUM_HOOKS = sizeof(g_hooks) / sizeof(g_hooks[0]);

static int cfg_flag_for(const char *key) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = 0;
    if      (!strcmp(key, "pro"))            v = g_cfg.pro;
    else if (!strcmp(key, "agent"))          v = g_cfg.agent;
    else if (!strcmp(key, "triple_tickets")) v = g_cfg.triple_tickets;
    else if (!strcmp(key, "cap_increase"))   v = g_cfg.cap_increase;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

// -------- PremiumCurrency resolution --------

static Il2CppClass *g_premium_class = NULL;
static void        *g_premium_instance = NULL;

// Find an instance of PremiumCurrency via heap walk. Cached after first
// success. Called on a worker thread, never during the init constructor.
// Heap walk is expensive (stop-the-world over the managed heap), so we
// throttle attempts to once every 2 seconds until an instance is found.
// The game instantiates PremiumCurrency when the main menu's save-slot
// view appears — can be many seconds post-launch.
static void *resolve_premium_instance(void) {
    if (g_premium_instance) return g_premium_instance;
    if (!g_premium_class) return NULL;
    static unsigned long last_walk_ms = 0;
    unsigned long t = now_ms();
    if (last_walk_ms && (t - last_walk_ms) < 2000UL) return NULL;
    last_walk_ms = t;
    void *found[8] = { 0 };
    int n = pfp_il2cpp_find_instances(g_premium_class, found, 8);
    if (n <= 0) return NULL;
    g_premium_instance = found[0];
    pfp_log("inst: PremiumCurrency live instance %p (heap-walk found %d)", found[0], n);
    return g_premium_instance;
}

static int resolve_premium_class_and_methods(void) {
    if (g_premium_class) return 1;
    // Image-name search first (fast); then fall back to no-image walk.
    Il2CppClass *k = pfp_il2cpp_find_class("Assembly-CSharp.dll", NULL, "PremiumCurrency");
    if (!k) k = pfp_il2cpp_find_class(NULL, NULL, "PremiumCurrency");
    if (!k) {
        pfp_log("resolve: PremiumCurrency class NOT FOUND");
        return 0;
    }
    g_premium_class = k;
    int mc = pfp_il2cpp_count_methods(k);
    pfp_log("resolve: PremiumCurrency class=%p method_count=%d (catalog expects 22)", k, mc);
    for (int i = 0; i < NUM_HOOKS; i++) {
        g_hooks[i].g_mi = pfp_il2cpp_find_method(k, g_hooks[i].getter, 0);
        g_hooks[i].s_mi = pfp_il2cpp_find_method(k, g_hooks[i].setter, 0);
        if (pfp_il2cpp_method_get_flags) {
            uint32_t iflags = 0;
            if (g_hooks[i].g_mi) {
                uint32_t f = pfp_il2cpp_method_get_flags(g_hooks[i].g_mi, &iflags);
                g_hooks[i].g_static = (f & PFP_METHOD_STATIC) ? 1 : 0;
            }
            if (g_hooks[i].s_mi) {
                uint32_t f = pfp_il2cpp_method_get_flags(g_hooks[i].s_mi, &iflags);
                g_hooks[i].s_static = (f & PFP_METHOD_STATIC) ? 1 : 0;
            }
        }
        pfp_log("resolve: %-24s getter=%p%s setter=%p%s",
                g_hooks[i].key,
                (void *)g_hooks[i].g_mi, g_hooks[i].g_static ? " [static]" : "",
                (void *)g_hooks[i].s_mi, g_hooks[i].s_static ? " [static]" : "");
    }

    // If every hook's setter is static, we don't need an instance — skip
    // heap-walk entirely. Log that as a one-liner so we know we took the
    // fast path.
    int all_static = 1;
    for (int i = 0; i < NUM_HOOKS; i++) {
        if (g_hooks[i].s_mi && !g_hooks[i].s_static) { all_static = 0; break; }
    }
    if (all_static) {
        pfp_log("resolve: all setters are STATIC — no instance needed, skipping heap walk");
    }
    return 1;
}

// -------- tick --------

static unsigned long now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (unsigned long)tv.tv_sec * 1000UL + (unsigned long)(tv.tv_usec / 1000);
}

static void tick_once(void) {
    pfp_cfg_reload_if_changed();

    if (!pfp_il2cpp_ready()) return;
    if (!resolve_premium_class_and_methods()) return;

    // Only fetch the instance if ANY enabled hook has a non-static method.
    // All-static case (common C# singleton pattern) skips the heap walk.
    int need_inst = 0;
    for (int i = 0; i < NUM_HOOKS; i++) {
        if (!cfg_flag_for(g_hooks[i].key)) continue;
        if (g_hooks[i].s_mi && !g_hooks[i].s_static) { need_inst = 1; break; }
        if (g_hooks[i].g_mi && !g_hooks[i].g_static) { need_inst = 1; break; }
    }
    void *inst = NULL;
    if (need_inst) {
        inst = resolve_premium_instance();
        if (!inst) {
            static unsigned long last_warn = 0;
            unsigned long t = now_ms();
            if (t - last_warn > 10000) {
                pfp_log("tick: no PremiumCurrency instance yet (menu probably not loaded)");
                last_warn = t;
            }
            return;
        }
    }

    int invoke_fail_this_tick = 0;
    for (int i = 0; i < NUM_HOOKS; i++) {
        if (!cfg_flag_for(g_hooks[i].key)) continue;
        if (!g_hooks[i].s_mi) continue;

        int should_set = 1;
        int prev_state = g_hooks[i].last_getter_state;
        if (g_hooks[i].g_mi) {
            void *g_self = g_hooks[i].g_static ? NULL : inst;
            int ok = 1;
            Il2CppObject *r = pfp_il2cpp_invoke0(g_hooks[i].g_mi, g_self, &ok);
            if (!ok) {
                pfp_log("tick: %s getter threw — skipping this tick", g_hooks[i].key);
                invoke_fail_this_tick++;
                continue;
            }
            int cur = pfp_unbox_bool(r);
            if (prev_state == 1 && cur == 0) {
                pfp_log("drift: %s server-overwrote (fires=%lu) — re-asserting",
                        g_hooks[i].key, g_hooks[i].fires);
            }
            g_hooks[i].last_getter_state = cur;
            should_set = !cur;
        } else {
            unsigned long t = now_ms();
            if (g_hooks[i].last_tick_ms && (t - g_hooks[i].last_tick_ms) < 60000UL) {
                should_set = 0;
            }
        }

        if (!should_set) continue;

        void *s_self = g_hooks[i].s_static ? NULL : inst;
        int ok = 1;
        pfp_il2cpp_invoke0(g_hooks[i].s_mi, s_self, &ok);
        if (!ok) {
            pfp_log("tick: %s %s threw", g_hooks[i].key, g_hooks[i].setter);
            invoke_fail_this_tick++;
            continue;
        }
        g_hooks[i].fires++;
        g_hooks[i].last_tick_ms = now_ms();
        if (g_cfg.log_each_fire) {
            pfp_log("fire: %s (%s%s) · fires=%lu", g_hooks[i].key,
                    g_hooks[i].setter, g_hooks[i].s_static ? " static" : "",
                    g_hooks[i].fires);
        }
    }

    // Staleness guard: only applies when we were using an instance.
    if (need_inst && invoke_fail_this_tick >= 2 && g_premium_instance) {
        pfp_log("inst: >=2 invoke failures — dropping cached instance %p, will re-walk",
                g_premium_instance);
        g_premium_instance = NULL;
    }
}

// Status dump — every 30s log the state so the log is useful without
// log_each_fire=1.
static void status_dump(void) {
    char line[512];
    int w = snprintf(line, sizeof line, "status:");
    for (int i = 0; i < NUM_HOOKS; i++) {
        int n = snprintf(line + w, sizeof(line) - w, " %s=%lu", g_hooks[i].key, g_hooks[i].fires);
        if (n < 0 || (size_t)n >= sizeof(line) - w) break;
        w += n;
    }
    pfp_log("%s", line);
}

// -------- main-runloop driver --------
//
// v1a and v1a.2 crashed at SIGSEGV 0x135 on a stack-pointer-relative load
// inside Unity's il2cpp runtime, from our pthread. Steve's diagnosis in
// debug/crashes/INDEX.md: on Unity 6000.3.9f1 even `il2cpp_domain_get` is
// unsafe on a non-GC-registered thread — the il2cpp exports rely on
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

    pfp_cfg_reload_if_changed();

    if (!pfp_il2cpp_ready()) {
        char err[256];
        int rc = pfp_il2cpp_init(err, sizeof err);
        if (rc != 0) {
            if ((g_init_warned++ % 30) == 0) {
                pfp_log("main: waiting for il2cpp (rc=%d, %s)", rc, err);
            }
            return;
        }
        pfp_log("main: il2cpp ready");
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
static void pfp_ctor(void) {
    pfp_log("boot: PFPlus v1a.5 up · target com.Miceli.Poly 4.5.3 · Unity 6 / metadata v39");
    pfp_log("boot: running on main runloop (Unity 6 GC-thread-attach requirement)");
    pfp_cfg_reload_if_changed();

    CFRunLoopRef rl = CFRunLoopGetMain();
    pfp_log("boot: CFRunLoopGetMain=%p kCFRunLoopCommonModes=%p kCFRunLoopDefaultMode=%p",
            (void *)rl, (void *)kCFRunLoopCommonModes, (void *)kCFRunLoopDefaultMode);
    if (!rl) {
        pfp_log("boot: CFRunLoopGetMain returned NULL — PFPlus disabled");
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
        pfp_log("boot: CFRunLoopTimerCreate failed — PFPlus disabled");
        return;
    }
    // Use the REAL kCFRunLoopCommonModes global. CoreFoundation's
    // CFRunLoopAddTimer special-cases this mode via POINTER equality, not
    // CFEqual (see Apple's CFRunLoop.c). v1a.3 used a runtime-created
    // content-equal CFString here, failed the pointer check, and the timer
    // was added to a never-serviced mode name — callback never fired.
    CFRunLoopAddTimer(rl, g_timer, kCFRunLoopCommonModes);
    pfp_log("boot: main-runloop timer armed in kCFRunLoopCommonModes (first fire +500ms, 100ms interval)");
}
