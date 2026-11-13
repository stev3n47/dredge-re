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
    // v1a Tier 1 unlocks (static invoke)
    int pro;
    int agent;
    int triple_tickets;
    int cap_increase;
    // *_force: skip the getter check, re-invoke the setter every second.
    int pro_force;
    int agent_force;
    int triple_tickets_force;
    int cap_increase_force;
    // v1b–v2 features. Default-on except the diagnostic probes which are
    // default-on but perform read-only logging only — they cost one heap
    // walk + metadata enumeration per init, nothing per tick thereafter.
    int money;              // v1b
    int skills;             // v1b
    int iap;                // v1.5
    int sync;               // v1e
    int skills_force;       // v1b: opt-in to fire reset-shaped methods
    int fumbles;            // v2a diagnostic
    int injuries;           // v2a diagnostic
    int tackle;             // v2a diagnostic
    int catch_hands;        // v2a diagnostic  (config key = "catch")
    int throw_cannon;       // v2a diagnostic  (config key = "throw")
    int speed;              // v2a diagnostic
    int pac;                // v2.2: PAC probe feature on/off (default on for phase 1)
    int pac_probe;          // v2.2: 0=phase 1 only (safe), 1=phase 2 swap (opt-in)
    int fumbles_force;      // v2.2.1: install fumble-chance hooks (static methods -> 0)
    int injuries_force;     // v2.2.1: AggravationChance/StaysDown hooks
    int tackle_force;       // v2.2.1: BreakChance/ShoveChance/SpinEscape/AnkleBreak -> 1
    int catch_force;        // v2.2.1: Confidence -> 1.0, v2.4.1: + InFront -> true
    int iap_force;          // v2.2.1: reserved for v2.2.2 AppleReceiptParser hook
    int cap_force;          // v2.5: CareerTeamBudget.Cap -> 999,999,999
    int throw_force;        // v2.5: ThrowController.get_PassIsBullet -> true (cannon arm)
    int accuracy_force;     // v2.5: ThrowController.get_ThrowSpreadOnTheRun -> 0
    int mp_safe;            // v2.5.1: 1 = block physics/offense hook installs (safe for MP)
    int tickets_force;      // v2.5.2: TicketWallet.TrySpend/TrySpendCareer -> true (free tickets)
    int speed_force;        // v2.6: AnimatorSpeed + PocketMoveSpeedMultiplier -> 2.0 (super speed)
    // Housekeeping
    int log_each_fire;
    int tick_hz;
    time_t mtime;
    int    loaded_ok;
};

static struct cfg g_cfg = {
    .pro = 1, .agent = 1, .triple_tickets = 1, .cap_increase = 1,
    .pro_force = 0, .agent_force = 0, .triple_tickets_force = 0, .cap_increase_force = 0,
    .money = 1, .skills = 1, .skills_force = 0, .iap = 1, .sync = 1,
    .fumbles = 1, .injuries = 1, .tackle = 1, .catch_hands = 1,
    .throw_cannon = 1, .speed = 1,
    .pac = 1, .pac_probe = 0,  // phase 1 always; phase 2 opt-in
    .fumbles_force = 0, .injuries_force = 0, .tackle_force = 0, .catch_force = 0, .iap_force = 0,
    .cap_force = 0, .throw_force = 0, .accuracy_force = 0, .mp_safe = 0, .tickets_force = 0,
    .speed_force = 0,
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
                    "# Set <feature>_force=1 to re-invoke the setter every tick\n"
                    "# even when the getter says the state is already unlocked.\n"
                    "# Useful if a getter returns true for reasons other than ownership.\n"
                    "pro_force=0\n"
                    "agent_force=0\n"
                    "triple_tickets_force=0\n"
                    "cap_increase_force=0\n"
                    "# v1b–v2 features (set to 0 to disable)\n"
                    "money=1\n"
                    "skills=1\n"
                    "# skills_force=1 fires reset-shaped methods on\n"
                    "# CareerSkillCosts — potentially destructive, opt-in.\n"
                    "skills_force=0\n"
                    "iap=1\n"
                    "sync=1\n"
                    "fumbles=1\n"
                    "injuries=1\n"
                    "tackle=1\n"
                    "catch=1\n"
                    "throw=1\n"
                    "speed=1\n"
                    "# v2.2 PAC probe. pac=1 runs phase 1 (read-only, zero risk) every boot.\n"
                    "# pac_probe=1 opts into phase 2 (actual methodPointer swap test).\n"
                    "# Phase 2 may crash the process once; read the device log + .ips.\n"
                    "pac=1\n"
                    "pac_probe=0\n"
                    "# v2.2.1 methodPointer swap hooks (opt-in, requires PAC success).\n"
                    "# fumbles_force=1 → fumble chances → 0 (no fumbles)\n"
                    "# injuries_force=1 → aggravation chance → 0, StaysDown → false\n"
                    "# tackle_force=1 → BreakChance/ShoveChance/SpinEscape → 1.0 (unstoppable carrier)\n"
                    "# catch_force=1 → FootballCatchReach.Confidence → 1.0 (magnet hands)\n"
                    "# iap_force=1 reserved for v2.2.2 AppleReceiptParser hook (not yet active).\n"
                    "fumbles_force=0\n"
                    "injuries_force=0\n"
                    "tackle_force=0\n"
                    "catch_force=0\n"
                    "iap_force=0\n"
                    "# v2.5 methodPointer swap hooks (opt-in).\n"
                    "# cap_force=1 → CareerTeamBudget.Cap → 999,999,999 (infinite save-cap)\n"
                    "# throw_force=1 → ThrowController.get_PassIsBullet → true (cannon arm)\n"
                    "# accuracy_force=1 → get_ThrowSpreadOnTheRun → 0 (perfect run-throws)\n"
                    "cap_force=0\n"
                    "throw_force=0\n"
                    "accuracy_force=0\n"
                    "# v2.5.1 — set mp_safe=1 to block install of physics/offense\n"
                    "# hooks (tackle/fumbles/injuries/catch/throw/accuracy).\n"
                    "# Flip ON before joining multiplayer to avoid desync/bans.\n"
                    "mp_safe=0\n"
                    "# v2.5.2 — tickets_force=1 hooks TicketWallet.TrySpend* -> true\n"
                    "# so every ticket transaction succeeds without deducting.\n"
                    "# Buy skill points infinitely, buy anything else that costs tickets.\n"
                    "tickets_force=0\n"
                    "# v2.6 — speed_force=1 hooks AnimatorSpeed + PocketMoveSpeedMultiplier\n"
                    "# to 2.0, roughly doubling the player's movement and the QB's\n"
                    "# scrambling speed. MP-unsafe — gated by mp_safe.\n"
                    "speed_force=0\n"
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
        if      (!strcmp(k, "pro"))                   next.pro = parse_bool_or_int(v, next.pro);
        else if (!strcmp(k, "agent"))                 next.agent = parse_bool_or_int(v, next.agent);
        else if (!strcmp(k, "triple_tickets"))        next.triple_tickets = parse_bool_or_int(v, next.triple_tickets);
        else if (!strcmp(k, "cap_increase"))          next.cap_increase = parse_bool_or_int(v, next.cap_increase);
        else if (!strcmp(k, "pro_force"))             next.pro_force = parse_bool_or_int(v, next.pro_force);
        else if (!strcmp(k, "agent_force"))           next.agent_force = parse_bool_or_int(v, next.agent_force);
        else if (!strcmp(k, "triple_tickets_force")) next.triple_tickets_force = parse_bool_or_int(v, next.triple_tickets_force);
        else if (!strcmp(k, "cap_increase_force"))   next.cap_increase_force = parse_bool_or_int(v, next.cap_increase_force);
        else if (!strcmp(k, "money"))                 next.money = parse_bool_or_int(v, next.money);
        else if (!strcmp(k, "skills"))                next.skills = parse_bool_or_int(v, next.skills);
        else if (!strcmp(k, "skills_force"))          next.skills_force = parse_bool_or_int(v, next.skills_force);
        else if (!strcmp(k, "iap"))                   next.iap = parse_bool_or_int(v, next.iap);
        else if (!strcmp(k, "sync"))                  next.sync = parse_bool_or_int(v, next.sync);
        else if (!strcmp(k, "fumbles"))               next.fumbles = parse_bool_or_int(v, next.fumbles);
        else if (!strcmp(k, "injuries"))              next.injuries = parse_bool_or_int(v, next.injuries);
        else if (!strcmp(k, "tackle"))                next.tackle = parse_bool_or_int(v, next.tackle);
        else if (!strcmp(k, "catch"))                 next.catch_hands = parse_bool_or_int(v, next.catch_hands);
        else if (!strcmp(k, "throw"))                 next.throw_cannon = parse_bool_or_int(v, next.throw_cannon);
        else if (!strcmp(k, "speed"))                 next.speed = parse_bool_or_int(v, next.speed);
        else if (!strcmp(k, "pac"))                   next.pac = parse_bool_or_int(v, next.pac);
        else if (!strcmp(k, "pac_probe"))             next.pac_probe = parse_bool_or_int(v, next.pac_probe);
        else if (!strcmp(k, "fumbles_force"))         next.fumbles_force = parse_bool_or_int(v, next.fumbles_force);
        else if (!strcmp(k, "injuries_force"))        next.injuries_force = parse_bool_or_int(v, next.injuries_force);
        else if (!strcmp(k, "tackle_force"))          next.tackle_force = parse_bool_or_int(v, next.tackle_force);
        else if (!strcmp(k, "catch_force"))           next.catch_force = parse_bool_or_int(v, next.catch_force);
        else if (!strcmp(k, "iap_force"))             next.iap_force = parse_bool_or_int(v, next.iap_force);
        else if (!strcmp(k, "cap_force"))             next.cap_force = parse_bool_or_int(v, next.cap_force);
        else if (!strcmp(k, "throw_force"))           next.throw_force = parse_bool_or_int(v, next.throw_force);
        else if (!strcmp(k, "accuracy_force"))        next.accuracy_force = parse_bool_or_int(v, next.accuracy_force);
        else if (!strcmp(k, "mp_safe"))               next.mp_safe = parse_bool_or_int(v, next.mp_safe);
        else if (!strcmp(k, "tickets_force"))         next.tickets_force = parse_bool_or_int(v, next.tickets_force);
        else if (!strcmp(k, "speed_force"))           next.speed_force = parse_bool_or_int(v, next.speed_force);
        else if (!strcmp(k, "log_each_fire"))         next.log_each_fire = parse_bool_or_int(v, next.log_each_fire);
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
    pfp_log("cfg: reloaded (pro=%d/f%d agent=%d/f%d triple=%d/f%d cap=%d/f%d tick_hz=%d log=%d)",
            next.pro, next.pro_force,
            next.agent, next.agent_force,
            next.triple_tickets, next.triple_tickets_force,
            next.cap_increase, next.cap_increase_force,
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

static int cfg_force_for(const char *key) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = 0;
    if      (!strcmp(key, "pro"))            v = g_cfg.pro_force;
    else if (!strcmp(key, "agent"))          v = g_cfg.agent_force;
    else if (!strcmp(key, "triple_tickets")) v = g_cfg.triple_tickets_force;
    else if (!strcmp(key, "cap_increase"))   v = g_cfg.cap_increase_force;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

// Public helpers for feature modules (features.h). Linear-dispatch on the
// known keys registered above. defval returned when the key is unknown
// (should never happen in practice — all features' keys are compile-time).
int pfp_cfg_bool(const char *key, int defval) {
    pthread_mutex_lock(&g_cfg_mtx);
    int v = defval;
    if      (!strcmp(key, "pro"))            v = g_cfg.pro;
    else if (!strcmp(key, "agent"))          v = g_cfg.agent;
    else if (!strcmp(key, "triple_tickets")) v = g_cfg.triple_tickets;
    else if (!strcmp(key, "cap_increase"))   v = g_cfg.cap_increase;
    else if (!strcmp(key, "money"))          v = g_cfg.money;
    else if (!strcmp(key, "skills"))         v = g_cfg.skills;
    else if (!strcmp(key, "skills_force"))   v = g_cfg.skills_force;
    else if (!strcmp(key, "iap"))            v = g_cfg.iap;
    else if (!strcmp(key, "sync"))           v = g_cfg.sync;
    else if (!strcmp(key, "fumbles"))        v = g_cfg.fumbles;
    else if (!strcmp(key, "injuries"))       v = g_cfg.injuries;
    else if (!strcmp(key, "tackle"))         v = g_cfg.tackle;
    else if (!strcmp(key, "catch"))          v = g_cfg.catch_hands;
    else if (!strcmp(key, "throw"))          v = g_cfg.throw_cannon;
    else if (!strcmp(key, "speed"))          v = g_cfg.speed;
    else if (!strcmp(key, "pac"))            v = g_cfg.pac;
    else if (!strcmp(key, "pac_probe"))      v = g_cfg.pac_probe;
    else if (!strcmp(key, "fumbles_force"))  v = g_cfg.fumbles_force;
    else if (!strcmp(key, "injuries_force")) v = g_cfg.injuries_force;
    else if (!strcmp(key, "tackle_force"))   v = g_cfg.tackle_force;
    else if (!strcmp(key, "catch_force"))    v = g_cfg.catch_force;
    else if (!strcmp(key, "iap_force"))      v = g_cfg.iap_force;
    else if (!strcmp(key, "cap_force"))      v = g_cfg.cap_force;
    else if (!strcmp(key, "throw_force"))    v = g_cfg.throw_force;
    else if (!strcmp(key, "accuracy_force")) v = g_cfg.accuracy_force;
    else if (!strcmp(key, "mp_safe"))        v = g_cfg.mp_safe;
    else if (!strcmp(key, "tickets_force"))  v = g_cfg.tickets_force;
    else if (!strcmp(key, "speed_force"))    v = g_cfg.speed_force;
    pthread_mutex_unlock(&g_cfg_mtx);
    return v;
}

int pfp_cfg_int(const char *key, int defval) {
    // Future: expose tick_hz etc. For now, same as bool.
    return pfp_cfg_bool(key, defval);
}

// v2.5.1 — write the full in-memory g_cfg back to Documents/pfplus.json
// atomically (write to .tmp, rename over the original). Called from
// pfp_cfg_set_bool so menu toggles survive a cold restart. Must be
// called WITH g_cfg_mtx held so the snapshot is consistent.
static void pfp_cfg_save_locked(void) {
    char path[1024];
    pfp_resolve_doc_path("pfplus.json", path, sizeof path);
    char tmp[1024];
    int tn = snprintf(tmp, sizeof tmp, "%s.tmp", path);
    if (tn <= 0 || tn >= (int)sizeof tmp) return;

    FILE *f = fopen(tmp, "w");
    if (!f) return;

    // Keep the same layout/comments as the first-run default so edits in
    // the Files app still read naturally. Order matches the struct for
    // easy mental diff when debugging.
    fprintf(f,
        "# PFPlus config — one key=value per line\n"
        "# Written by the in-game menu. Hand-edits are preserved across\n"
        "# restarts; the next menu toggle will re-serialize the file.\n");
    fprintf(f, "pro=%d\n",                   g_cfg.pro);
    fprintf(f, "agent=%d\n",                 g_cfg.agent);
    fprintf(f, "triple_tickets=%d\n",        g_cfg.triple_tickets);
    fprintf(f, "cap_increase=%d\n",          g_cfg.cap_increase);
    fprintf(f, "pro_force=%d\n",             g_cfg.pro_force);
    fprintf(f, "agent_force=%d\n",           g_cfg.agent_force);
    fprintf(f, "triple_tickets_force=%d\n",  g_cfg.triple_tickets_force);
    fprintf(f, "cap_increase_force=%d\n",    g_cfg.cap_increase_force);
    fprintf(f, "money=%d\n",                 g_cfg.money);
    fprintf(f, "skills=%d\n",                g_cfg.skills);
    fprintf(f, "skills_force=%d\n",          g_cfg.skills_force);
    fprintf(f, "iap=%d\n",                   g_cfg.iap);
    fprintf(f, "sync=%d\n",                  g_cfg.sync);
    fprintf(f, "fumbles=%d\n",               g_cfg.fumbles);
    fprintf(f, "injuries=%d\n",              g_cfg.injuries);
    fprintf(f, "tackle=%d\n",                g_cfg.tackle);
    fprintf(f, "catch=%d\n",                 g_cfg.catch_hands);
    fprintf(f, "throw=%d\n",                 g_cfg.throw_cannon);
    fprintf(f, "speed=%d\n",                 g_cfg.speed);
    fprintf(f, "pac=%d\n",                   g_cfg.pac);
    fprintf(f, "pac_probe=%d\n",             g_cfg.pac_probe);
    fprintf(f, "fumbles_force=%d\n",         g_cfg.fumbles_force);
    fprintf(f, "injuries_force=%d\n",        g_cfg.injuries_force);
    fprintf(f, "tackle_force=%d\n",          g_cfg.tackle_force);
    fprintf(f, "catch_force=%d\n",           g_cfg.catch_force);
    fprintf(f, "iap_force=%d\n",             g_cfg.iap_force);
    fprintf(f, "cap_force=%d\n",             g_cfg.cap_force);
    fprintf(f, "throw_force=%d\n",           g_cfg.throw_force);
    fprintf(f, "accuracy_force=%d\n",        g_cfg.accuracy_force);
    fprintf(f, "mp_safe=%d\n",               g_cfg.mp_safe);
    fprintf(f, "tickets_force=%d\n",         g_cfg.tickets_force);
    fprintf(f, "speed_force=%d\n",           g_cfg.speed_force);
    fprintf(f, "log_each_fire=%d\n",         g_cfg.log_each_fire);
    fprintf(f, "tick_hz=%d\n",               g_cfg.tick_hz);
    fflush(f);
    fclose(f);

    if (rename(tmp, path) == 0) {
        // Update mtime so the next pfp_cfg_reload_if_changed() sees the
        // file we just wrote and doesn't replay it back on top of us.
        struct stat st;
        if (stat(path, &st) == 0) g_cfg.mtime = st.st_mtime;
    } else {
        unlink(tmp);
    }
}

// v2.3 — in-memory config write path used by the UIKit menu so toggles
// take effect immediately without an mtime-based file reload. Uses the
// same string→field dispatch as pfp_cfg_bool, mutating g_cfg under the
// mutex. v2.5.1 — also persists to disk via pfp_cfg_save_locked so
// toggles survive a cold restart.
void pfp_cfg_set_bool(const char *key, int value) {
    int v = value ? 1 : 0;
    pthread_mutex_lock(&g_cfg_mtx);
    if      (!strcmp(key, "pro"))            g_cfg.pro = v;
    else if (!strcmp(key, "agent"))          g_cfg.agent = v;
    else if (!strcmp(key, "triple_tickets")) g_cfg.triple_tickets = v;
    else if (!strcmp(key, "cap_increase"))   g_cfg.cap_increase = v;
    else if (!strcmp(key, "money"))          g_cfg.money = v;
    else if (!strcmp(key, "skills"))         g_cfg.skills = v;
    else if (!strcmp(key, "skills_force"))   g_cfg.skills_force = v;
    else if (!strcmp(key, "iap"))            g_cfg.iap = v;
    else if (!strcmp(key, "sync"))           g_cfg.sync = v;
    else if (!strcmp(key, "fumbles"))        g_cfg.fumbles = v;
    else if (!strcmp(key, "injuries"))       g_cfg.injuries = v;
    else if (!strcmp(key, "tackle"))         g_cfg.tackle = v;
    else if (!strcmp(key, "catch"))          g_cfg.catch_hands = v;
    else if (!strcmp(key, "throw"))          g_cfg.throw_cannon = v;
    else if (!strcmp(key, "speed"))          g_cfg.speed = v;
    else if (!strcmp(key, "pac"))            g_cfg.pac = v;
    else if (!strcmp(key, "pac_probe"))      g_cfg.pac_probe = v;
    else if (!strcmp(key, "fumbles_force"))  g_cfg.fumbles_force = v;
    else if (!strcmp(key, "injuries_force")) g_cfg.injuries_force = v;
    else if (!strcmp(key, "tackle_force"))   g_cfg.tackle_force = v;
    else if (!strcmp(key, "catch_force"))    g_cfg.catch_force = v;
    else if (!strcmp(key, "iap_force"))      g_cfg.iap_force = v;
    else if (!strcmp(key, "cap_force"))      g_cfg.cap_force = v;
    else if (!strcmp(key, "throw_force"))    g_cfg.throw_force = v;
    else if (!strcmp(key, "accuracy_force")) g_cfg.accuracy_force = v;
    else if (!strcmp(key, "mp_safe"))        g_cfg.mp_safe = v;
    else if (!strcmp(key, "tickets_force"))  g_cfg.tickets_force = v;
    else if (!strcmp(key, "speed_force"))    g_cfg.speed_force = v;
    // v2.5.1 — persist every change so cold restart gets the same state.
    pfp_cfg_save_locked();
    pthread_mutex_unlock(&g_cfg_mtx);
}

// ---------------- Diagnostic helpers (features.h) -------------------------

// Enumerate every class in Assembly-CSharp whose name contains any of the
// `substrs`. Returns count written to out_classes.
int pfp_find_classes_by_name(const char **substrs, int substr_count,
                             Il2CppClass **out_classes, int cap) {
    if (!pfp_il2cpp_ready() || !substrs || substr_count <= 0) return 0;
    int n = 0;
    Il2CppDomain *dom = pfp_il2cpp_domain_get();
    if (!dom) return 0;
    size_t na = 0;
    const Il2CppAssembly **asms = pfp_il2cpp_domain_get_assemblies(dom, &na);
    for (size_t ai = 0; ai < na; ai++) {
        const Il2CppImage *img = pfp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        const char *in = pfp_il2cpp_image_get_name(img);
        if (!in || strcmp(in, "Assembly-CSharp.dll") != 0) continue;
        size_t nc = pfp_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = pfp_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kn = pfp_il2cpp_class_get_name(k);
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
    Il2CppClass *k = pfp_il2cpp_object_get_class(obj);
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

int pfp_diag_log_live_instances(const char *prefix,
                                Il2CppClass * const *target_classes,
                                int target_count) {
    if (!pfp_il2cpp_ready() || !target_classes || target_count <= 0) return 0;
    if (!pfp_il2cpp_gc_foreach_heap || !pfp_il2cpp_object_get_class) return 0;
    struct diag_walk w = { target_classes, target_count, {0}, {0}, 0, 0 };
    pfp_il2cpp_gc_foreach_heap(diag_walk_cb, &w);
    pfp_log("%s: heap walk scanned %ld objects, %d live instance(s) of %d target class(es)",
            prefix, w.scanned, w.n, target_count);
    // Post-walk: safe to resolve class names on target_classes (pre-resolved
    // from image metadata, not from the heap).
    for (int i = 0; i < w.n; i++) {
        const char *nm = pfp_il2cpp_class_get_name(w.hits_klass[i]);
        pfp_log("%s:   live %s @ %p", prefix, nm ? nm : "?", w.hits_obj[i]);
    }
    return w.n;
}

void pfp_diag_log_methods(const char *prefix, Il2CppClass *klass,
                          const char **name_substrs, int substr_count) {
    if (!pfp_il2cpp_ready() || !klass || !pfp_il2cpp_class_get_methods) return;
    const char *kn = pfp_il2cpp_class_get_name(klass);
    void *iter = NULL;
    int logged = 0;
    const MethodInfo *m;
    while ((m = pfp_il2cpp_class_get_methods(klass, &iter)) != NULL) {
        const char *mn = pfp_il2cpp_method_get_name(m);
        if (!mn) continue;
        if (substr_count > 0 && name_substrs) {
            int match = 0;
            for (int i = 0; i < substr_count; i++) {
                if (name_substrs[i] && strstr(mn, name_substrs[i])) { match = 1; break; }
            }
            if (!match) continue;
        }
        uint32_t iflags = 0;
        uint32_t f = pfp_il2cpp_method_get_flags ? pfp_il2cpp_method_get_flags(m, &iflags) : 0;
        int is_static = (f & 0x10) ? 1 : 0;
        int argc = pfp_il2cpp_method_get_param_count ? (int)pfp_il2cpp_method_get_param_count(m) : -1;
        pfp_log("%s: method %s.%s argc=%d%s", prefix, kn ? kn : "?", mn, argc,
                is_static ? " [static]" : "");
        if (++logged >= 32) { pfp_log("%s: (methods truncated at 32)", prefix); break; }
    }
}

// ---------------- Periodic rewalk registry (v2.1) -------------------------
//
// Features whose init-time heap walk turned up 0 live instances (common
// for match-only objects like ThrowController) register their target
// class here. Every ~60s we do ONE heap walk against the combined set
// and log any first-time hits per feature prefix.

#define PFP_MAX_REWALK_TARGETS 64
struct pfp_rewalk_entry {
    const char *prefix;
    Il2CppClass *klass;
    int done;
};
static struct pfp_rewalk_entry g_rewalk[PFP_MAX_REWALK_TARGETS];
static int g_rewalk_count = 0;
static unsigned long g_last_rewalk_ms = 0;

void pfp_register_rewalk(const char *prefix, Il2CppClass *klass) {
    if (!prefix || !klass) return;
    if (g_rewalk_count >= PFP_MAX_REWALK_TARGETS) {
        pfp_log("rewalk: registry full at %d — dropping %s target",
                PFP_MAX_REWALK_TARGETS, prefix);
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

#define PFP_KLASS_SAMPLE_CAP 16
struct pfp_rewalk_ctx {
    void *found_obj[PFP_MAX_REWALK_TARGETS];
    Il2CppClass *found_klass[PFP_MAX_REWALK_TARGETS];
    int n_found;
    long scanned;
    // v2.1.1 klass-sampling diagnostic (SPPlus v35 pattern):
    // collect distinct obj->klass pointers seen during the walk so we can
    // verify gc_foreach_heap is handing us real metadata-comparable klass
    // pointers. If NONE of these match our resolved metadata class pointers
    // we know gc_foreach_heap is useless for instance discovery on this
    // build and v2.2 needs a different path (Zenject-provider walk, etc).
    Il2CppClass *sampled_klass[PFP_KLASS_SAMPLE_CAP];
    int n_sampled;
    int do_sample;
};

static void pfp_rewalk_cb(void *obj, void *user) {
    struct pfp_rewalk_ctx *c = (struct pfp_rewalk_ctx *)user;
    c->scanned++;
    if (!obj) return;
    Il2CppClass *k = pfp_il2cpp_object_get_class(obj);
    if (!k) return;

    // Pointer-equality check against the whitelist (SPPlus v33 rule).
    for (int i = 0; i < g_rewalk_count; i++) {
        if (g_rewalk[i].done) continue;
        if (g_rewalk[i].klass == k) {
            if (c->n_found < PFP_MAX_REWALK_TARGETS) {
                // Dedup within this walk — one hit per class is enough.
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

    // Diagnostic klass sampling — collect first N distinct klass pointers
    // that did NOT match the whitelist. One probe only (first rewalk).
    if (c->do_sample && c->n_sampled < PFP_KLASS_SAMPLE_CAP) {
        for (int j = 0; j < c->n_sampled; j++) {
            if (c->sampled_klass[j] == k) return;
        }
        c->sampled_klass[c->n_sampled++] = k;
    }
}

static void pfp_periodic_rewalk(void) {
    if (g_rewalk_count == 0) return;
    if (!pfp_il2cpp_ready() || !pfp_il2cpp_gc_foreach_heap ||
        !pfp_il2cpp_object_get_class) return;

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
    struct pfp_rewalk_ctx ctx = { {0}, {0}, 0, 0, {0}, 0, !sample_done };
    pfp_il2cpp_gc_foreach_heap(pfp_rewalk_cb, &ctx);

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
        pfp_log("rewalk-sample: %d distinct klass ptrs sampled; "
                "metadata range of our %d resolved targets: [0x%lx..0x%lx]",
                ctx.n_sampled, g_rewalk_count, (long)lo, (long)hi);
        int in_range = 0;
        for (int i = 0; i < ctx.n_sampled; i++) {
            uintptr_t p = (uintptr_t)ctx.sampled_klass[i];
            int ok = (p >= safe_lo && p <= safe_hi);
            // v2.5.1 — do NOT call class_get_name on a heap-derived klass
            // pointer, per the SPPlus v33 rule. Even gated by a ±64MB
            // metadata window, a bogus pointer from a non-managed alloc
            // can pass and trap inside type->name deref. The pointer
            // alone + the in-range flag is enough diagnostic signal.
            pfp_log("rewalk-sample: [%2d] klass=%p %s",
                    i, (void *)ctx.sampled_klass[i],
                    ok ? "IN-RANGE" : "OUT-OF-RANGE");
            if (ok) in_range++;
        }
        if (in_range == 0) {
            pfp_log("rewalk-sample: ZERO in-range klass pointers — "
                    "gc_foreach_heap matches SPPlus v35 pattern (walked objs "
                    "don't carry real metadata klass ptrs). "
                    "Instance discovery needs a different path (v2.2).");
        } else {
            pfp_log("rewalk-sample: %d/%d klass pointers in metadata range — "
                    "heap walk is usable; target classes just aren't live yet",
                    in_range, ctx.n_sampled);
        }
    }

    if (ctx.n_found == 0) {
        pfp_log("rewalk: scanned %ld objects, %d class(es) still unfound",
                ctx.scanned, pending);
        return;
    }
    // Post-walk, log hits and mark done.
    for (int i = 0; i < ctx.n_found; i++) {
        for (int j = 0; j < g_rewalk_count; j++) {
            if (g_rewalk[j].klass == ctx.found_klass[i] && !g_rewalk[j].done) {
                const char *kn = pfp_il2cpp_class_get_name(g_rewalk[j].klass);
                pfp_log("%s: rewalk found live %s @ %p (scanned=%ld)",
                        g_rewalk[j].prefix, kn ? kn : "?", ctx.found_obj[i],
                        ctx.scanned);
                g_rewalk[j].done = 1;
            }
        }
    }
}

// ---------------- Feature registry ----------------------------------------

static PfpFeature *g_feature_registry[] = {
    &pfp_feature_money,
    &pfp_feature_skills,
    &pfp_feature_iap,
    &pfp_feature_sync,
    &pfp_feature_fumbles,
    &pfp_feature_injuries,
    &pfp_feature_tackle,
    &pfp_feature_catch,
    &pfp_feature_throw,
    &pfp_feature_speed,
    &pfp_feature_pac,
    &pfp_feature_tickets,
};
static const int NUM_FEATURES = sizeof(g_feature_registry) / sizeof(g_feature_registry[0]);

static void run_features_tick(void) {
    for (int i = 0; i < NUM_FEATURES; i++) {
        PfpFeature *f = g_feature_registry[i];
        if (!f || f->init_failed) continue;
        if (!pfp_cfg_bool(f->key, 1)) continue;
        if (!f->initialised) {
            if (!f->init) { f->init_failed = 1; continue; }
            int rc = f->init();
            if (rc != 0) {
                pfp_log("feature: %s init failed (rc=%d) — disabled for session", f->key, rc);
                f->init_failed = 1;
                continue;
            }
            f->initialised = 1;
            pfp_log("feature: %s init ok", f->key);
        }
        if (f->tick) {
            int did = f->tick();
            if (did > 0) {
                f->fires++;
                f->last_tick_ms = now_ms();
            }
        }
        // Per-feature rewalk callback (optional; currently unused — the
        // global pfp_periodic_rewalk below handles all registered classes).
        if (f->rewalk) {
            unsigned long t = now_ms();
            if (!f->last_rewalk_ms || (t - f->last_rewalk_ms) >= 60000UL) {
                f->rewalk();
                f->last_rewalk_ms = t;
            }
        }
    }
    // v2.1: global periodic rewalk across all registered classes.
    pfp_periodic_rewalk();
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

        int force = cfg_force_for(g_hooks[i].key);
        int should_set = 1;
        int prev_state = g_hooks[i].last_getter_state;

        // Always consult the getter (even in force mode) so we still log
        // drift and know the game's view of state. Force mode just means
        // "invoke setter anyway, throttled to 1Hz".
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
            if (!force) should_set = !cur;
        } else {
            unsigned long t = now_ms();
            unsigned long throttle = force ? 1000UL : 60000UL;
            if (g_hooks[i].last_tick_ms && (t - g_hooks[i].last_tick_ms) < throttle) {
                should_set = 0;
            }
        }

        // In force mode, throttle setter to once per second so we don't
        // 10 Hz spam for no diagnostic value.
        if (force && g_hooks[i].last_tick_ms &&
            (now_ms() - g_hooks[i].last_tick_ms) < 1000UL) {
            should_set = 0;
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

    // Run registered v1b–v2 features after Tier 1 unlocks.
    run_features_tick();

    // v2.3 — install the in-game menu once UIKit's key window exists.
    // pfp_menu_install() is idempotent + returns early if the host
    // window isn't available yet, so we can call it every tick cheaply
    // until the install succeeds.
    pfp_menu_install();
}

// Status dump — every 30s log the state so the log is useful without
// log_each_fire=1. Format: `<key>=<fires>/<last_getter_state>` where
// last_getter_state is T (true), F (false), or ? (never observed).
static void status_dump(void) {
    char line[1024];
    int w = snprintf(line, sizeof line, "status:");
    for (int i = 0; i < NUM_HOOKS; i++) {
        char g = (g_hooks[i].last_getter_state == 1) ? 'T' :
                 (g_hooks[i].last_getter_state == 0) ? 'F' : '?';
        int n = snprintf(line + w, sizeof(line) - w, " %s=%lu/%c",
                         g_hooks[i].key, g_hooks[i].fires, g);
        if (n < 0 || (size_t)n >= sizeof(line) - w) break;
        w += n;
    }
    for (int i = 0; i < NUM_FEATURES; i++) {
        PfpFeature *f = g_feature_registry[i];
        if (!f) continue;
        const char *tag = f->init_failed ? "x" : (f->initialised ? "i" : "-");
        int n = snprintf(line + w, sizeof(line) - w, " %s=%lu%s",
                         f->key, f->fires, tag);
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
    pfp_log("boot: PFPlus v2.8 up · target com.Miceli.Poly 4.5.3 · Unity 6 / metadata v39");
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
