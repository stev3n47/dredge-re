import re
s = open('STPlus.m', encoding='utf-8').read()

# --- 1. hook struct: per-row image/class/method, vtable slot, dual orig ---
s = s.replace('''struct hook {
    const char *key;          // config flag name
    const char *class_name;   // C# class in PolytopiaAssembly.dll
    const char *method;       // method name
    int         argc;         // arg count; -1 = wildcard match
    void       *tramp;        // constant-return trampoline to install
    int         mp_unsafe;    // 1 = install blocked while mp_safe=1
    const MethodInfo *mi;
    void       *orig;         // saved slot[0] for live restore
    int         installed;
    int         blocked_logged;
    int         miss_logged;
    unsigned long fires;      // install count
};

static struct hook g_hooks[] = {
    { "tribes", "PurchaseManager", "IsTribeUnlocked", -1, (void *)stp_tramp_one_int, 0, NULL, NULL, 0, 0, 0, 0 },
    { "skins",  "PurchaseManager", "IsSkinUnlocked",  -1, (void *)stp_tramp_one_int, 0, NULL, NULL, 0, 0, 0, 0 },
    { "stars",  "PlayerState",     "get_Currency",     0, (void *)stp_tramp_huge_int, 1, NULL, NULL, 0, 0, 0, 0 },
};''','''// Each row is one (image, class, method) target. A cfg key may own several
// rows — e.g. "tribes" patches BOTH the base PurchaseManager and the live
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

static struct hook g_hooks[] = {
    { "tribes", "PolytopiaAssembly.dll", "PurchaseManager",               "IsTribeUnlocked", -1, (void *)stp_tramp_one_int, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0 },
    { "tribes", "PolytopiaAssembly.dll", "UnityPlatformPurchaseManager",  "IsTribeUnlocked", -1, (void *)stp_tramp_one_int, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0 },
    { "skins",  "PolytopiaAssembly.dll", "PurchaseManager",               "IsSkinUnlocked",  -1, (void *)stp_tramp_one_int, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0 },
    { "skins",  "PolytopiaAssembly.dll", "UnityPlatformPurchaseManager",  "IsSkinUnlocked",  -1, (void *)stp_tramp_one_int, 0, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0 },
    { "stars",  "GameLogicAssembly.dll", "PlayerState",                   "get_Currency",     0, (void *)stp_tramp_huge_int, 1, NULL, NULL, NULL, NULL, 0, 0, 0, 0, 0 },
};''')

# --- 2. resolve_class: honor per-row image (no wildcard for named images) ---
s = s.replace('''static Il2CppClass *resolve_class(const char *name) {
    static struct { const char *name; Il2CppClass *k; } cache[8];
    static int n = 0;
    for (int i = 0; i < n; i++) {
        if (!strcmp(cache[i].name, name)) return cache[i].k;
    }
    Il2CppClass *k = stp_il2cpp_find_class("PolytopiaAssembly.dll", NULL, name);
    if (!k) k = stp_il2cpp_find_class(NULL, NULL, name);''',
'''static Il2CppClass *resolve_class(const char *image, const char *name) {
    static struct { const char *name; Il2CppClass *k; } cache[8];
    static int n = 0;
    for (int i = 0; i < n; i++) {
        if (!strcmp(cache[i].name, name)) return cache[i].k;
    }
    // Exact image first (PlayerState lives in GameLogicAssembly.dll, NOT
    // PolytopiaAssembly — a wildcard scan could grab a same-named UI class
    // and hook the wrong get_Currency). Wildcard fallback only as a
    // last resort and only for the purchase classes (distinctive names).
    Il2CppClass *k = stp_il2cpp_find_class(image, NULL, name);
    if (!k && !strstr(name, "PlayerState"))
        k = stp_il2cpp_find_class(NULL, NULL, name);''')

# --- 3. vtable discovery + dual-slot install (insert before tick_once) ---
i = s.find('// -------- tick --------')
vt = '''// -------- vtable discovery --------
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

extern int mach_vm_read_overwrite(long task, long addr, long size,
                                  long data, long *outsz);
extern unsigned int mach_task_self(void);

static int safe_read(const void *addr, void *buf, unsigned long n) {
    long out = 0;
    return mach_vm_read_overwrite(mach_task_self(), (long)addr, (long)n,
                                  (long)buf, &out) == 0 && out == (long)n;
}

// Returns &vtable[i].methodPtr on success.
static void **find_vtable_slot(Il2CppClass *klass, const MethodInfo *mi) {
    void *kp[64];
    if (!safe_read(klass, kp, sizeof kp)) return NULL;
    for (int f = 0; f < 64; f++) {
        void *cand = kp[f];
        if (!cand) continue;
        for (int i = 0; i < 256; i++) {
            struct { void *methodPtr; const MethodInfo *method; } ent;
            if (!safe_read((char *)cand + i * sizeof ent, &ent, sizeof ent)) break;
            if (!ent.methodPtr && !ent.method) break;   // vtables end {NULL,NULL}
            if (((unsigned long)ent.method & 0x7) ||
                ((unsigned long)ent.methodPtr & 0x7)) break;  // not a ptr pair
            if (ent.method == mi) {
                return (void **)((char *)cand + i * sizeof ent);
            }
        }
    }
    return NULL;
}

'''
s = s[:i] + vt + s[i:]

# --- 4. rewrite tick_once to dual-slot install/restore ---
s = re.sub(r'static void tick_once\(void\) \{.*?\n\}',
'''static void tick_once(void) {
    stp_cfg_reload_if_changed();

    if (!stp_il2cpp_ready()) return;

    int mp_safe = stp_cfg_bool("mp_safe", 0);
    for (int i = 0; i < NUM_HOOKS; i++) {
        struct hook *h = &g_hooks[i];
        int want = stp_cfg_bool(h->key, 0);
        if (h->mp_unsafe && want && mp_safe) {
            if (!h->blocked_logged) {
                stp_log("%s: install blocked -- mp_safe=1 (match-sim hook)", h->key);
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
                    h->mi = stp_il2cpp_find_method(k, h->method, h->argc);
                    h->vslot = find_vtable_slot(k, h->mi);
                }
                if (!h->miss_logged) {
                    stp_log("resolve: %s -> %s.%s(argc=%d) mi=%p vslot=%p%s",
                            h->key, h->class_name, h->method, h->argc,
                            (void *)h->mi, (void *)h->vslot,
                            h->mi ? "" : " (will retry)");
                    h->miss_logged = 1;
                }
                if (h->mi) h->miss_logged = 0;
            }
            if (h->mi) {
                int ok = stp_pac_hook_install_save(h->mi, h->tramp,
                                                   &h->mi_orig, h->key);
                if (ok && h->vslot) {
                    h->v_orig = *h->vslot;
                    *h->vslot = h->tramp;
                    stp_log("vtable-swap: %s methodPtr %p -> tramp=%p",
                            h->key, h->v_orig, h->tramp);
                } else if (ok && !h->novtable_logged) {
                    stp_log("vtable: %s no vtable slot (non-virtual/direct-call) "
                            "-- methodPointer swap only, may not reach game callsites",
                            h->key);
                    h->novtable_logged = 1;
                }
                if (ok) { h->installed = 1; h->fires++; }
            }
        } else if (!want && h->installed) {
            if (h->vslot && h->v_orig) *h->vslot = h->v_orig;
            if (stp_pac_hook_restore(h->mi, h->mi_orig, h->key)) {
                h->installed = 0;
                h->mi_orig = h->v_orig = NULL;
            }
        }
    }

    // Registered features run after the unlock hooks.
    run_features_tick();

    // Install the in-game menu once UIKit's key window exists; idempotent.
    stp_menu_install();
}''', s, count=1, flags=re.S)

open('STPlus.m','w',encoding='utf-8').write(s)
print('vtable dual-slot design applied')
