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

// -------- forward decls --------

static unsigned long now_ms(void);

// -------- logging --------

static FILE *g_logf = NULL;
static pthread_mutex_t g_log_mtx = PTHREAD_MUTEX_INITIALIZER;

// Resolved via NSSearchPathForDirectoriesInDomains lookalike — but we
// avoid the ObjC runtime entirely here. The sandbox's Documents is at
// $HOME/Documents in every normal iOS process layout.
static void pfp_resolve_doc_path(const char *fname, char *out, size_t cap) {
    const char *home = getenv("HOME");
    if (!home || !*home) home = "/var/mobile/Containers/Data/Application";
    snprintf(out, cap, "%s/Documents/%s", home, fname);
}

void pfp_log(const char *fmt, ...) {
    pthread_mutex_lock(&g_log_mtx);
    if (!g_logf) {
        char path[1024];
        pfp_resolve_doc_path("pfplus.log", path, sizeof path);
        g_logf = fopen(path, "a");
        if (g_logf) setvbuf(g_logf, NULL, _IOLBF, 0);
    }
    if (g_logf) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        time_t t = tv.tv_sec;
        struct tm lt;
        localtime_r(&t, &lt);
        fprintf(g_logf, "[%02d:%02d:%02d.%03d] ",
                lt.tm_hour, lt.tm_min, lt.tm_sec, (int)(tv.tv_usec / 1000));
        va_list ap; va_start(ap, fmt);
        vfprintf(g_logf, fmt, ap);
        va_end(ap);
        fputc('\n', g_logf);
    }
    // Also to stderr so Console.app / Xcode see it during dev.
    va_list ap2; va_start(ap2, fmt);
    vfprintf(stderr, fmt, ap2);
    fputc('\n', stderr);
    va_end(ap2);
    pthread_mutex_unlock(&g_log_mtx);
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
        pthread_mutex_lock(&g_cfg_mtx);
        if (!g_cfg.loaded_ok) {
            FILE *f = fopen(path, "w");
            if (f) {
                fprintf(f,
                    "# PFPlus v1a config — one key=value per line\n"
                    "# Edit in Files app or via SSH; reloaded automatically.\n"
                    "pro=1\n"
                    "agent=1\n"
                    "triple_tickets=1\n"
                    "cap_increase=1\n"
                    "log_each_fire=0\n"
                    "tick_hz=10\n");
                fclose(f);
                pfp_log("cfg: wrote default config to %s", path);
            }
            g_cfg.loaded_ok = 1;
        }
        pthread_mutex_unlock(&g_cfg_mtx);
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
};

static struct hook g_hooks[] = {
    { "pro",            "get_HasPro",               "UnlockPro",              NULL, NULL, 0, 0 },
    { "agent",          "get_HasAgent",             "UnlockAgent",            NULL, NULL, 0, 0 },
    { "triple_tickets", "get_HasTripleTicketBoost", "UnlockTripleTicketBoost",NULL, NULL, 0, 0 },
    { "cap_increase",   "get_HasCapIncrease",       "UnlockCapIncrease",      NULL, NULL, 0, 0 },
};
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
        pfp_log("resolve: %-24s getter=%p setter=%p",
                g_hooks[i].key, (void *)g_hooks[i].g_mi, (void *)g_hooks[i].s_mi);
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

    void *inst = resolve_premium_instance();
    if (!inst) {
        static unsigned long last_warn = 0;
        unsigned long t = now_ms();
        if (t - last_warn > 10000) {
            pfp_log("tick: no PremiumCurrency instance yet (menu probably not loaded)");
            last_warn = t;
        }
        return;
    }

    for (int i = 0; i < NUM_HOOKS; i++) {
        if (!cfg_flag_for(g_hooks[i].key)) continue;
        if (!g_hooks[i].s_mi) continue;  // no setter — can't help

        // If a getter exists, call it; only Unlock on false. If no getter
        // (unlikely for Unlock* pattern), call setter each tick throttled
        // to once per 60s so we don't spam.
        int should_set = 1;
        if (g_hooks[i].g_mi) {
            int ok = 1;
            Il2CppObject *r = pfp_il2cpp_invoke0(g_hooks[i].g_mi, inst, &ok);
            if (!ok) {
                pfp_log("tick: %s getter threw — skipping this tick", g_hooks[i].key);
                continue;
            }
            int cur = pfp_unbox_bool(r);
            should_set = !cur;
        } else {
            unsigned long t = now_ms();
            if (g_hooks[i].last_tick_ms && (t - g_hooks[i].last_tick_ms) < 60000UL) {
                should_set = 0;
            }
        }

        if (!should_set) continue;

        int ok = 1;
        pfp_il2cpp_invoke0(g_hooks[i].s_mi, inst, &ok);
        if (!ok) {
            pfp_log("tick: %s %s threw", g_hooks[i].key, g_hooks[i].setter);
            continue;
        }
        g_hooks[i].fires++;
        g_hooks[i].last_tick_ms = now_ms();
        if (g_cfg.log_each_fire) {
            pfp_log("fire: %s (%s) · fires=%lu", g_hooks[i].key,
                    g_hooks[i].setter, g_hooks[i].fires);
        }
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

// -------- worker thread --------

static void *worker(void *unused) {
    (void)unused;
    pfp_log("worker: thread up");

    // Wait for IL2CPP to be mapped. UnityFramework is loaded very early
    // but il2cpp_init itself runs asynchronously — poll until domain is up.
    char err[256];
    int tries = 0;
    while (pfp_il2cpp_init(err, sizeof err) != 0) {
        if ((tries++ % 20) == 0) {
            pfp_log("worker: waiting for il2cpp (%s)", err);
        }
        usleep(500 * 1000);  // 0.5s
        if (tries > 240) {   // 2 min
            pfp_log("worker: giving up on il2cpp — exiting thread");
            return NULL;
        }
    }
    pfp_log("worker: il2cpp ready");

    unsigned long last_status = 0;
    for (;;) {
        pthread_mutex_lock(&g_cfg_mtx);
        int hz = g_cfg.tick_hz;
        pthread_mutex_unlock(&g_cfg_mtx);
        if (hz < 1) hz = 1;
        if (hz > 60) hz = 60;
        useconds_t period = (useconds_t)(1000000 / hz);

        tick_once();

        unsigned long t = now_ms();
        if (t - last_status > 30000) {
            status_dump();
            last_status = t;
        }

        usleep(period);
    }
    return NULL;
}

// -------- entry --------

__attribute__((constructor))
static void pfp_ctor(void) {
    pfp_log("boot: PFPlus v1a up · target com.Miceli.Poly 4.5.3 · Unity 6 / metadata v39");
    pfp_cfg_reload_if_changed();

    pthread_t th;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &attr, worker, NULL) != 0) {
        pfp_log("boot: pthread_create failed — PFPlus disabled");
    }
    pthread_attr_destroy(&attr);
}
