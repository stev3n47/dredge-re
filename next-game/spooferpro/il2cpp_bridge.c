// il2cpp bridge implementation. See il2cpp_bridge.h for rationale.
//
// Lookup strategy:
//   1. Walk dyld's loaded image list for `UnityFramework.framework/UnityFramework`.
//   2. Use its `_dyld_get_image_vmaddr_slide(i)` as the ASLR slide.
//   3. For each il2cpp_* entry we need, compute
//        fn_ptr = (uint8_t *)header + slide + OFFSET
//      where OFFSET comes from the per-version header (il2cpp_offsets_*.h).
//   4. Expose the typed pointers so callers can use them like normal
//      functions.
//
// Class/method lookup caches results in a small hash-free list — the
// catalog is huge (tens of thousands) but we only look up a handful.

#include "il2cpp_bridge.h"
#include "il2cpp_offsets_pogo0743.h"

#include <mach-o/dyld.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

// --- typed pointers (defined once; declared extern in the header) --------
Il2CppDomain *(*spp_il2cpp_domain_get)(void);
const Il2CppAssembly **(*spp_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
const Il2CppImage   *(*spp_il2cpp_assembly_get_image)(const Il2CppAssembly *);
const char          *(*spp_il2cpp_image_get_name)(const Il2CppImage *);
Il2CppClass         *(*spp_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
size_t               (*spp_il2cpp_image_get_class_count)(const Il2CppImage *);
const char          *(*spp_il2cpp_class_get_name)(Il2CppClass *);
const char          *(*spp_il2cpp_class_get_namespace)(Il2CppClass *);
const MethodInfo    *(*spp_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
Il2CppObject        *(*spp_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
void                 (*spp_il2cpp_runtime_class_init)(Il2CppClass *);
void                 (*spp_il2cpp_thread_attach)(Il2CppDomain *);
void                *(*spp_il2cpp_thread_current)(void);
Il2CppObject        *(*spp_il2cpp_object_new)(Il2CppClass *);
Il2CppClass         *(*spp_il2cpp_object_get_class)(Il2CppObject *);
Il2CppString        *(*spp_il2cpp_string_new)(const char *);
Il2CppArray         *(*spp_il2cpp_array_new)(Il2CppClass *elem, uintptr_t len);
Il2CppClass         *(*spp_il2cpp_class_from_type)(Il2CppType *);
Il2CppType          *(*spp_il2cpp_class_get_type)(Il2CppClass *);
Il2CppObject        *(*spp_il2cpp_type_get_object)(const Il2CppType *);
uint32_t             (*spp_il2cpp_gchandle_new)(Il2CppObject *, int pinned);
const char          *(*spp_il2cpp_method_get_name)(const MethodInfo *);
uint32_t             (*spp_il2cpp_method_get_param_count)(const MethodInfo *);
const MethodInfo    *(*spp_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
void                *(*spp_il2cpp_class_get_fields)(Il2CppClass *, void **iter);
const char          *(*spp_il2cpp_field_get_name)(void *field);
void                 (*spp_il2cpp_field_static_get_value)(void *field, void *out);
void                 (*spp_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
void                 (*spp_il2cpp_gc_disable)(void);
void                 (*spp_il2cpp_gc_enable)(void);
int32_t              (*spp_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);

// --- state --------------------------------------------------------------
static int g_ready = 0;
static int g_allow_zenject = 0;   // Strategy C (crashes at launch) off by default
void spp_il2cpp_set_allow_zenject(int on) { g_allow_zenject = on ? 1 : 0; }

int spp_il2cpp_ready(void) { return g_ready; }

static int find_unity_image(const uint8_t **out_base, intptr_t *out_slide) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        // match tail of path to tolerate both @executable_path and @rpath layouts
        const char *needle = "UnityFramework.framework/UnityFramework";
        size_t ln = strlen(name), nn = strlen(needle);
        if (ln >= nn && strcmp(name + ln - nn, needle) == 0) {
            *out_base = (const uint8_t *)_dyld_get_image_header(i);
            *out_slide = _dyld_get_image_vmaddr_slide(i);
            return 1;
        }
    }
    return 0;
}

int spp_il2cpp_init(char *errbuf, size_t errbuflen) {
    if (g_ready) return 0;

    const uint8_t *base = NULL;
    intptr_t slide = 0;
    if (!find_unity_image(&base, &slide)) {
        // Try to load it — on PokmonGO.app the Unity framework is always
        // present at this path and dyld has already mapped it, but if the
        // caller runs us from a tool that didn't let the game boot, try
        // loading explicitly.
        (void)dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                     RTLD_NOW | RTLD_GLOBAL);
        if (!find_unity_image(&base, &slide)) {
            if (errbuf) snprintf(errbuf, errbuflen,
                                 "UnityFramework not loaded in this process");
            return -1;
        }
    }

    // Preferred base is 0; slide is the ASLR shift, which for a __TEXT
    // section at vma 0 equals the actual load address. Resolve each
    // function pointer as (slide + offset) — explicitly in uintptr_t so
    // we don't hit pointer-arith type gotchas.
#define RESOLVE(sym, off) do {                                 \
        spp_##sym = (typeof(spp_##sym))(uintptr_t)((intptr_t)(off) + slide); \
    } while (0)

    RESOLVE(il2cpp_domain_get,                 SPP_IL2CPP_DOMAIN_GET_OFF);
    RESOLVE(il2cpp_domain_get_assemblies,      SPP_IL2CPP_DOMAIN_GET_ASSEMBLIES_OFF);
    RESOLVE(il2cpp_assembly_get_image,         SPP_IL2CPP_ASSEMBLY_GET_IMAGE_OFF);
    RESOLVE(il2cpp_image_get_name,             SPP_IL2CPP_IMAGE_GET_NAME_OFF);
    RESOLVE(il2cpp_image_get_class,            SPP_IL2CPP_IMAGE_GET_CLASS_OFF);
    RESOLVE(il2cpp_image_get_class_count,      SPP_IL2CPP_IMAGE_GET_CLASS_COUNT_OFF);
    RESOLVE(il2cpp_class_get_name,             SPP_IL2CPP_CLASS_GET_NAME_OFF);
    RESOLVE(il2cpp_class_get_namespace,        SPP_IL2CPP_CLASS_GET_NAMESPACE_OFF);
    RESOLVE(il2cpp_class_get_method_from_name, SPP_IL2CPP_CLASS_GET_METHOD_FROM_NAME_OFF);
    RESOLVE(il2cpp_runtime_invoke,             SPP_IL2CPP_RUNTIME_INVOKE_OFF);
    RESOLVE(il2cpp_runtime_class_init,         SPP_IL2CPP_RUNTIME_CLASS_INIT_OFF);
    RESOLVE(il2cpp_thread_attach,              SPP_IL2CPP_THREAD_ATTACH_OFF);
    RESOLVE(il2cpp_thread_current,             SPP_IL2CPP_THREAD_CURRENT_OFF);
    RESOLVE(il2cpp_object_new,                 SPP_IL2CPP_OBJECT_NEW_OFF);
    RESOLVE(il2cpp_object_get_class,           SPP_IL2CPP_OBJECT_GET_CLASS_OFF);
    RESOLVE(il2cpp_string_new,                 SPP_IL2CPP_STRING_NEW_OFF);
    RESOLVE(il2cpp_array_new,                  SPP_IL2CPP_ARRAY_NEW_OFF);
    RESOLVE(il2cpp_class_from_type,            SPP_IL2CPP_CLASS_FROM_TYPE_OFF);
    RESOLVE(il2cpp_class_get_type,             SPP_IL2CPP_CLASS_GET_TYPE_OFF);
    RESOLVE(il2cpp_type_get_object,            SPP_IL2CPP_TYPE_GET_OBJECT_OFF);
    RESOLVE(il2cpp_gchandle_new,               SPP_IL2CPP_GCHANDLE_NEW_OFF);
    RESOLVE(il2cpp_method_get_name,            SPP_IL2CPP_METHOD_GET_NAME_OFF);
    RESOLVE(il2cpp_method_get_param_count,     SPP_IL2CPP_METHOD_GET_PARAM_COUNT_OFF);
    RESOLVE(il2cpp_class_get_methods,          SPP_IL2CPP_CLASS_GET_METHODS_OFF);
    RESOLVE(il2cpp_class_get_fields,           SPP_IL2CPP_CLASS_GET_FIELDS_OFF);
    RESOLVE(il2cpp_field_get_name,             SPP_IL2CPP_FIELD_GET_NAME_OFF);
    RESOLVE(il2cpp_field_static_get_value,     SPP_IL2CPP_FIELD_STATIC_GET_VALUE_OFF);
    RESOLVE(il2cpp_gc_foreach_heap,            SPP_IL2CPP_GC_FOREACH_HEAP_OFF);
    RESOLVE(il2cpp_gc_disable,                 SPP_IL2CPP_GC_DISABLE_OFF);
    RESOLVE(il2cpp_gc_enable,                  SPP_IL2CPP_GC_ENABLE_OFF);
    RESOLVE(il2cpp_class_is_assignable_from,   SPP_IL2CPP_CLASS_IS_ASSIGNABLE_FROM_OFF);
#undef RESOLVE

    // Attach this thread to the il2cpp runtime before we call anything —
    // il2cpp_* entry points invoke GC machinery that assumes the current
    // thread has been attached.
    Il2CppDomain *dom = spp_il2cpp_domain_get();
    if (!dom) {
        if (errbuf) snprintf(errbuf, errbuflen,
                             "il2cpp_domain_get returned NULL (runtime not initialized?)");
        return -2;
    }
    if (!spp_il2cpp_thread_current()) {
        spp_il2cpp_thread_attach(dom);
    }

    g_ready = 1;
    (void)base;
    return 0;
}

// Small cache keyed by (image_name, namespace, class). Hash-free linear
// scan; we expect < 20 lookups across the session.
#define CACHE_SZ 64
struct ccache_entry {
    const char *image;
    const char *ns;
    const char *cls;
    Il2CppClass *klass;
};
static struct ccache_entry g_class_cache[CACHE_SZ];
static int g_class_cache_n;

Il2CppClass *spp_il2cpp_find_class(const char *image_name, const char *ns, const char *cls) {
    if (!g_ready) return NULL;
    for (int i = 0; i < g_class_cache_n; i++) {
        struct ccache_entry *e = &g_class_cache[i];
        if ((e->image == image_name || (e->image && image_name && !strcmp(e->image, image_name))) &&
            (e->ns == ns || (e->ns && ns && !strcmp(e->ns, ns))) &&
            (e->cls == cls || (e->cls && cls && !strcmp(e->cls, cls)))) {
            return e->klass;
        }
    }

    Il2CppDomain *dom = spp_il2cpp_domain_get();
    size_t n_asm = 0;
    const Il2CppAssembly **asms = spp_il2cpp_domain_get_assemblies(dom, &n_asm);
    for (size_t ai = 0; ai < n_asm; ai++) {
        const Il2CppImage *img = spp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        if (image_name) {
            const char *in = spp_il2cpp_image_get_name(img);
            if (!in || strcmp(in, image_name) != 0) continue;
        }
        size_t nc = spp_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = spp_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kns = spp_il2cpp_class_get_namespace(k);
            const char *kcn = spp_il2cpp_class_get_name(k);
            if (!kcn) continue;
            if (ns && (!kns || strcmp(kns, ns) != 0)) continue;
            if (cls && strcmp(kcn, cls) != 0) continue;
            if (g_class_cache_n < CACHE_SZ) {
                struct ccache_entry *e = &g_class_cache[g_class_cache_n++];
                e->image = image_name; e->ns = ns; e->cls = cls; e->klass = k;
            }
            return k;
        }
    }
    return NULL;
}

const MethodInfo *spp_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc) {
    if (!g_ready || !klass || !name) return NULL;
    // ensure static ctor ran so vtable is complete
    spp_il2cpp_runtime_class_init(klass);
    return spp_il2cpp_class_get_method_from_name(klass, name, argc);
}

// --- Pokemon-bag probe ---------------------------------------------------
//
// IPokemonBag.ReleasePokemon lives in Assembly-CSharp.dll, in some
// namespace that varies by PoGo version. We try the most likely
// namespaces in order. Once we have the right one, the lookup is cached.
//
// To actually CALL the method we also need a live instance pointer. That
// comes from Zenject: ProjectContext._instance.Container.Resolve<IPokemonBag>().
// Resolving that chain requires the ProjectContext class + field offsets,
// which are per-version. Phase 3 of the il2cpp bridge is the probe +
// scaffold; the Zenject chain is phase 4 (next turn).
extern void ipalog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static const char *k_bag_namespaces[] = {
    // Known names across community dumps. The game has moved
    // pokemon bag code between namespaces across builds; listing every
    // one lets us survive a rename.
    "",
    "Niantic.Holoholo.Inventory.Pokemon",
    "Niantic.Holoholo.Inventory",
    "Niantic.Pogo.Inventory",
    NULL,
};
static const char *k_bag_classes[] = {
    "PokemonBagImpl",
    "PokemonBag",
    "IPokemonBag",
    NULL,
};

// --- typed invokers ------------------------------------------------------
Il2CppObject *spp_il2cpp_invoke_0(const MethodInfo *m, void *self) {
    if (!g_ready || !m) return NULL;
    Il2CppObject *exc = NULL;
    return spp_il2cpp_runtime_invoke(m, self, NULL, &exc);
}
Il2CppObject *spp_il2cpp_invoke_1(const MethodInfo *m, void *self, void *a0) {
    if (!g_ready || !m) return NULL;
    void *args[1] = { a0 };
    Il2CppObject *exc = NULL;
    return spp_il2cpp_runtime_invoke(m, self, args, &exc);
}
Il2CppObject *spp_il2cpp_invoke_2(const MethodInfo *m, void *self, void *a0, void *a1) {
    if (!g_ready || !m) return NULL;
    void *args[2] = { a0, a1 };
    Il2CppObject *exc = NULL;
    return spp_il2cpp_runtime_invoke(m, self, args, &exc);
}

Il2CppObject *spp_il2cpp_static_field_object(Il2CppClass *klass, const char *field_name) {
    if (!g_ready || !klass || !field_name) return NULL;
    spp_il2cpp_runtime_class_init(klass);
    void *iter = NULL;
    for (;;) {
        void *f = spp_il2cpp_class_get_fields(klass, &iter);
        if (!f) break;
        const char *n = spp_il2cpp_field_get_name(f);
        if (n && strcmp(n, field_name) == 0) {
            Il2CppObject *out = NULL;
            spp_il2cpp_field_static_get_value(f, &out);
            return out;
        }
    }
    return NULL;
}

void spp_il2cpp_dump_class_members(Il2CppClass *klass, int limit) {
    if (!g_ready || !klass) return;
    spp_il2cpp_runtime_class_init(klass);
    ipalog("[SP+] il2cpp class %s.%s members:",
           spp_il2cpp_class_get_namespace(klass) ?: "",
           spp_il2cpp_class_get_name(klass) ?: "?");
    void *iter = NULL;
    int n = 0;
    for (; n < limit; n++) {
        const MethodInfo *m = spp_il2cpp_class_get_methods(klass, &iter);
        if (!m) break;
        const char *name = spp_il2cpp_method_get_name(m);
        uint32_t argc = spp_il2cpp_method_get_param_count(m);
        ipalog("[SP+]   method %s / argc=%u", name ?: "?", argc);
    }
    iter = NULL;
    int fn = 0;
    for (; fn < limit; fn++) {
        void *f = spp_il2cpp_class_get_fields(klass, &iter);
        if (!f) break;
        ipalog("[SP+]   field  %s", spp_il2cpp_field_get_name(f) ?: "?");
    }
    ipalog("[SP+]   (%d methods, %d fields shown)", n, fn);
}

// --- resolve IPokemonBag ---------------------------------------------------
//
// Four strategies, tried in order. Each step is logged so a failure on a
// new PoGo build shows exactly where we stopped.
//
// A. PokemonBagImpl has a static field "Instance" or "_instance"
//    (singleton pattern). Fastest when it's there.
// B. PokemonBagImpl has a static property "Instance" (`get_Instance`).
// C. Zenject: ProjectContext._instance.Container.Resolve(typeof(IPokemonBag))
//    — the canonical path per POGO-FINDINGS.
// D. GameManager.Instance.PokemonBag — some Niantic builds expose this.
static Il2CppObject *g_cached_bag;

// Dump every class whose name contains `substr` across all images — our
// class-name guesses keep missing because Niantic renames both assemblies
// (holo-game.dll, not Assembly-CSharp.dll) and classes between builds.
static void dump_matching_classes(const char *substr) {
    if (!g_ready || !substr) return;
    Il2CppDomain *dom = spp_il2cpp_domain_get();
    size_t n_asm = 0;
    const Il2CppAssembly **asms = spp_il2cpp_domain_get_assemblies(dom, &n_asm);
    int shown = 0;
    for (size_t ai = 0; ai < n_asm && shown < 40; ai++) {
        const Il2CppImage *img = spp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        const char *in = spp_il2cpp_image_get_name(img);
        size_t nc = spp_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc && shown < 40; ci++) {
            Il2CppClass *k = spp_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kcn = spp_il2cpp_class_get_name(k);
            if (kcn && strstr(kcn, substr)) {
                ipalog("[SP+]   match %s :: %s.%s",
                       in ?: "?", spp_il2cpp_class_get_namespace(k) ?: "", kcn);
                shown++;
            }
        }
    }
    ipalog("[SP+]   (%d classes match '%s')", shown, substr);
}

static Il2CppClass *find_bag_class(const char **out_ns, const char **out_cls) {
    static const char *k_images[] = { "holo-game.dll", NULL, "Assembly-CSharp.dll" };
    for (int im = 0; im < 3; im++) {
        for (int i = 0; k_bag_namespaces[i]; i++) {
            for (int j = 0; k_bag_classes[j]; j++) {
                Il2CppClass *k = spp_il2cpp_find_class(
                    k_images[im],
                    k_bag_namespaces[i][0] ? k_bag_namespaces[i] : NULL,
                    k_bag_classes[j]);
                if (k) {
                    if (out_ns)  *out_ns  = k_bag_namespaces[i];
                    if (out_cls) *out_cls = k_bag_classes[j];
                    return k;
                }
            }
        }
    }
    ipalog("[SP+] bag-resolve: no exact name — dumping *Bag* classes:");
    dump_matching_classes("Bag");
    return NULL;
}

// Strategy E — GC heap walk. Enumerate every live managed object and keep
// the first whose class is (assignable to) the bag class. This is the only
// instance-discovery path that touches neither Zenject (DiContainer.Resolve
// hits a code-signature-invalid page on this build, SIGKILL) nor the game's
// native code pages (inline hooks would fail the hardened-runtime CS check).
// The callback runs with the GC world stopped — it must not allocate.
struct bag_search { Il2CppClass *target; Il2CppObject *found; long scanned; };

static void bag_heap_cb(void *obj, void *user) {
    struct bag_search *s = (struct bag_search *)user;
    s->scanned++;
    if (s->found || !obj) return;
    Il2CppClass *k = spp_il2cpp_object_get_class((Il2CppObject *)obj);
    if (!k) return;
    if (k == s->target ||
        (spp_il2cpp_class_is_assignable_from &&
         spp_il2cpp_class_is_assignable_from(s->target, k))) {
        s->found = (Il2CppObject *)obj;
    }
}

static Il2CppObject *heap_walk_find(Il2CppClass *target) {
    if (!spp_il2cpp_gc_foreach_heap || !target) return NULL;
    // Attach this thread to the runtime — the walk and any later invoke run
    // on our background completion-handler queue, not a managed thread.
    if (spp_il2cpp_thread_attach && spp_il2cpp_domain_get)
        spp_il2cpp_thread_attach(spp_il2cpp_domain_get());
    struct bag_search s = { target, NULL, 0 };
    if (spp_il2cpp_gc_disable) spp_il2cpp_gc_disable();
    spp_il2cpp_gc_foreach_heap(bag_heap_cb, &s);
    if (spp_il2cpp_gc_enable) spp_il2cpp_gc_enable();
    ipalog("[SP+] bag-resolve: heap walk scanned %ld objects, %s",
           s.scanned, s.found ? "FOUND bag" : "no match");
    return s.found;
}

Il2CppObject *spp_il2cpp_get_pokemon_bag(void) {
    if (!g_ready) return NULL;
    if (g_cached_bag) return g_cached_bag;

    const char *ns = NULL, *cls = NULL;
    Il2CppClass *bag_class = find_bag_class(&ns, &cls);
    if (!bag_class) {
        ipalog("[SP+] bag-resolve: PokemonBag class not in known namespaces");
        return NULL;
    }
    ipalog("[SP+] bag-resolve: class %s.%s", ns, cls);

    // Strategy E — GC heap walk (primary; no Zenject, no code-patching).
    {
        Il2CppObject *inst = heap_walk_find(bag_class);
        if (inst) {
            ipalog("[SP+] bag-resolve: heap walk hit");
            g_cached_bag = inst;
            return inst;
        }
    }

    // Strategy A — static Instance / _instance field
    {
        static const char *k_instance_names[] = {
            "Instance", "_instance", "s_Instance", "s_instance", NULL };
        for (int i = 0; k_instance_names[i]; i++) {
            Il2CppObject *inst = spp_il2cpp_static_field_object(bag_class,
                                                                k_instance_names[i]);
            if (inst) {
                ipalog("[SP+] bag-resolve: static field %s on %s hit",
                       k_instance_names[i], cls);
                g_cached_bag = inst;
                return inst;
            }
        }
    }
    ipalog("[SP+] bag-resolve: no static Instance/_instance field");

    // Strategy B — static property get_Instance
    const MethodInfo *get_inst = spp_il2cpp_find_method(bag_class, "get_Instance", 0);
    if (get_inst) {
        Il2CppObject *inst = spp_il2cpp_invoke_0(get_inst, NULL);
        if (inst) {
            ipalog("[SP+] bag-resolve: get_Instance() on %s hit", cls);
            g_cached_bag = inst;
            return inst;
        }
        ipalog("[SP+] bag-resolve: get_Instance() returned null");
    } else {
        ipalog("[SP+] bag-resolve: no get_Instance method");
    }

    // Strategy C — Zenject ProjectContext._instance.Container.Resolve(type).
    // KNOWN CRASHER: on pogo-0.743 this reaches a code-signature-invalid page
    // and the kernel SIGKILLs us (v20). Off unless the host explicitly opts in
    // via spp_il2cpp_set_allow_zenject(1). Kept for older builds / future use.
    if (g_allow_zenject) {
        Il2CppClass *pc_class = spp_il2cpp_find_class("Assembly-CSharp.dll",
                                                       "Zenject", "ProjectContext");
        if (!pc_class) {
            pc_class = spp_il2cpp_find_class(NULL, "Zenject", "ProjectContext");
        }
        if (pc_class) {
            Il2CppObject *pc = spp_il2cpp_static_field_object(pc_class, "_instance");
            if (!pc) pc = spp_il2cpp_static_field_object(pc_class, "s_Instance");
            if (!pc) {
                const MethodInfo *gi = spp_il2cpp_find_method(pc_class, "get_Instance", 0);
                if (gi) pc = spp_il2cpp_invoke_0(gi, NULL);
            }
            if (pc) {
                const MethodInfo *get_container = spp_il2cpp_find_method(
                    spp_il2cpp_object_get_class(pc), "get_Container", 0);
                Il2CppObject *container = get_container
                    ? spp_il2cpp_invoke_0(get_container, pc) : NULL;
                if (container) {
                    // Resolve(Type)
                    Il2CppClass *container_class = spp_il2cpp_object_get_class(container);
                    const MethodInfo *resolve = spp_il2cpp_find_method(container_class,
                                                                        "Resolve", 1);
                    if (resolve) {
                        Il2CppType *bag_type = spp_il2cpp_class_get_type(bag_class);
                        Il2CppObject *type_obj = spp_il2cpp_type_get_object
                            ? spp_il2cpp_type_get_object(bag_type) : NULL;
                        if (type_obj) {
                            Il2CppObject *inst = spp_il2cpp_invoke_1(resolve, container,
                                                                     type_obj);
                            if (inst) {
                                ipalog("[SP+] bag-resolve: Zenject Resolve() hit");
                                g_cached_bag = inst;
                                return inst;
                            }
                        }
                        ipalog("[SP+] bag-resolve: Resolve(Type) returned null");
                    } else {
                        ipalog("[SP+] bag-resolve: DiContainer.Resolve(1) missing");
                    }
                } else {
                    ipalog("[SP+] bag-resolve: ProjectContext.Container unreachable");
                }
            } else {
                ipalog("[SP+] bag-resolve: ProjectContext._instance null");
            }
        } else {
            ipalog("[SP+] bag-resolve: Zenject.ProjectContext class not found");
        }
    } else {
        ipalog("[SP+] bag-resolve: Zenject Resolve skipped (disabled; "
               "known CODESIGNING crash on 0.743)");
    }

    // Strategy D — GameManager.Instance.PokemonBag
    Il2CppClass *gm = spp_il2cpp_find_class("holo-game.dll", NULL, "GameManager");
    if (!gm) gm = spp_il2cpp_find_class(NULL, NULL, "GameManager");
    if (gm) {
        Il2CppObject *g = spp_il2cpp_static_field_object(gm, "Instance");
        if (!g) {
            const MethodInfo *gi = spp_il2cpp_find_method(gm, "get_Instance", 0);
            if (gi) g = spp_il2cpp_invoke_0(gi, NULL);
        }
        if (g) {
            static const char *k_bag_accessors[] = {
                "get_PokemonBag", "get_Bag", "get_IPokemonBag", NULL };
            for (int i = 0; k_bag_accessors[i]; i++) {
                const MethodInfo *gp = spp_il2cpp_find_method(
                    spp_il2cpp_object_get_class(g), k_bag_accessors[i], 0);
                if (!gp) continue;
                Il2CppObject *bag = spp_il2cpp_invoke_0(gp, g);
                if (bag) {
                    ipalog("[SP+] bag-resolve: GameManager.%s() hit", k_bag_accessors[i]);
                    g_cached_bag = bag;
                    return bag;
                }
            }
            ipalog("[SP+] bag-resolve: GameManager has no PokemonBag accessor");
        }
    } else {
        ipalog("[SP+] bag-resolve: GameManager class not found");
    }

    // All strategies failed — dump the class members to give the user
    // something to grep in sppro_plus.log.
    static int dumped;
    if (!dumped) {
        dumped = 1;
        spp_il2cpp_dump_class_members(bag_class, 32);
    }
    return NULL;
}

int spp_il2cpp_probe_release_pokemon(void) {
    if (!g_ready) return -10;
    const char *ns = NULL, *cls = NULL;
    Il2CppClass *klass = find_bag_class(&ns, &cls);
    if (!klass) {
        ipalog("[SP+] il2cpp probe: no PokemonBag class across known names");
        return -1;
    }
    ipalog("[SP+] il2cpp probe: class %s.%s", ns, cls);

    const MethodInfo *m = spp_il2cpp_find_method(klass, "ReleasePokemon", 1);
    if (!m) {
        ipalog("[SP+] il2cpp probe: ReleasePokemon(1) missing — dumping methods");
        spp_il2cpp_dump_class_members(klass, 32);
        return -2;
    }
    ipalog("[SP+] il2cpp probe: ReleasePokemon(PokemonProto) resolved");

    // Instance resolution is DEFERRED to first feature use. Eager
    // DiContainer.Resolve() during launch runs managed code inside an
    // initializing Zenject container — on this build that call chain
    // reaches a code-signature-invalid page and the kernel kills us.
    // The bag can't exist pre-login anyway, so nothing is lost. The bag is
    // now found at feature time via the GC heap walk (Strategy E).
    ipalog("[SP+] il2cpp probe: bag instance deferred (heap walk at feature use)");
    return 0;
}

// Feature-time bag inspection. Finds the live bag via the heap walk, then
// dumps its methods/fields and (if we can reach one) a sample pokemon's
// members — so we can wire enumeration + per-pokemon field reads for the
// keep-rule clean. The bag's collection API (GetPokemon / get_Pokemon /
// indexer / count) is renamed per build, so we learn it from this dump
// rather than hard-coding guesses. Returns 0 if the bag was found.
//
// Also attempts the common enumeration accessors directly; if one returns
// an object, logs its class so the next build can iterate it. This is the
// bridge between "we can find + release one pokemon" and "we can clean the
// whole bag by keep-rules".
int spp_il2cpp_bag_inspect(void) {
    if (!g_ready) { ipalog("[SP+] bag-inspect: bridge not ready"); return -10; }
    const char *ns = NULL, *cls = NULL;
    Il2CppClass *bag_class = find_bag_class(&ns, &cls);
    if (!bag_class) { ipalog("[SP+] bag-inspect: no bag class"); return -1; }

    Il2CppObject *bag = spp_il2cpp_get_pokemon_bag();
    if (!bag) { ipalog("[SP+] bag-inspect: heap walk found no live bag "
                       "(log in and open your pokemon storage first)"); return -2; }
    ipalog("[SP+] bag-inspect: live bag @ %p — dumping its API", (void *)bag);
    spp_il2cpp_dump_class_members(bag_class, 60);

    // Try common enumeration accessors so we can see the collection type.
    static const char *k_enum_getters[] = {
        "GetPokemon", "get_Pokemon", "GetAllPokemon", "get_AllPokemon",
        "GetPokemonList", "get_PokemonList", "GetPokedex", "get_Count",
        "GetCount", "get_Pokemons", "GetPokemons", NULL };
    for (int i = 0; k_enum_getters[i]; i++) {
        const MethodInfo *g = spp_il2cpp_find_method(bag_class, k_enum_getters[i], 0);
        if (!g) continue;
        Il2CppObject *r = spp_il2cpp_invoke_0(g, bag);
        if (r) {
            Il2CppClass *rc = spp_il2cpp_object_get_class(r);
            ipalog("[SP+] bag-inspect: %s() -> %s.%s @ %p",
                   k_enum_getters[i],
                   rc ? (spp_il2cpp_class_get_namespace(rc) ?: "") : "",
                   rc ? (spp_il2cpp_class_get_name(rc) ?: "?") : "null-class",
                   (void *)r);
        } else {
            ipalog("[SP+] bag-inspect: %s() -> null/empty", k_enum_getters[i]);
        }
    }
    return 0;
}

int spp_il2cpp_release_pokemon(uint64_t uid) {
    if (!g_ready) {
        ipalog("[SP+] il2cpp release skipped (bridge not ready): uid=%llu",
               (unsigned long long)uid);
        return -10;
    }
    const char *ns = NULL, *cls = NULL;
    Il2CppClass *bag_class = find_bag_class(&ns, &cls);
    if (!bag_class) { ipalog("[SP+] release: no bag class"); return -1; }
    const MethodInfo *release = spp_il2cpp_find_method(bag_class, "ReleasePokemon", 1);
    if (!release) { ipalog("[SP+] release: no ReleasePokemon(1) method"); return -2; }

    Il2CppObject *bag = spp_il2cpp_get_pokemon_bag();
    if (!bag) { ipalog("[SP+] release: no live IPokemonBag instance"); return -3; }

    // Build a minimal PokemonProto with just PokemonId set. The game's
    // ReleasePokemon reads the id field server-side; the rest is ignored.
    Il2CppClass *proto_class = spp_il2cpp_find_class("Assembly-CSharp.dll",
                                                     NULL, "PokemonProto");
    if (!proto_class) proto_class = spp_il2cpp_find_class(NULL, NULL, "PokemonProto");
    if (!proto_class) { ipalog("[SP+] release: no PokemonProto class"); return -4; }
    Il2CppObject *proto = spp_il2cpp_object_new(proto_class);
    if (!proto) { ipalog("[SP+] release: PokemonProto allocation failed"); return -5; }

    const MethodInfo *set_id = spp_il2cpp_find_method(proto_class, "set_PokemonId", 1);
    if (!set_id) {
        // Fall back to field-direct write — need field offset which we
        // don't have without a dump. Log and bail.
        ipalog("[SP+] release: set_PokemonId not found (dumping proto members)");
        spp_il2cpp_dump_class_members(proto_class, 16);
        return -6;
    }
    // Pokemon ids are ulong (64-bit). il2cpp passes value types by pointer.
    uint64_t pid = uid;
    spp_il2cpp_invoke_1(set_id, proto, &pid);

    (void)spp_il2cpp_invoke_1(release, bag, proto);
    ipalog("[SP+] il2cpp ReleasePokemon posted uid=%llu", (unsigned long long)uid);
    return 0;
}

static int g_logged_catalog;
void spp_il2cpp_log_classes_once(void) {
    if (!g_ready || g_logged_catalog) return;
    g_logged_catalog = 1;
    // Diagnostic: dump the catalog of (image, namespace, class) once so
    // callers can find the right names on a new PoGo build. Written
    // through ipalog via extern linkage with the host dylib.
    extern void ipalog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
    Il2CppDomain *dom = spp_il2cpp_domain_get();
    size_t n_asm = 0;
    const Il2CppAssembly **asms = spp_il2cpp_domain_get_assemblies(dom, &n_asm);
    ipalog("[SP+] il2cpp catalog: %zu assemblies", n_asm);
    for (size_t ai = 0; ai < n_asm && ai < 32; ai++) {
        const Il2CppImage *img = spp_il2cpp_assembly_get_image(asms[ai]);
        const char *in = img ? spp_il2cpp_image_get_name(img) : "?";
        size_t nc = img ? spp_il2cpp_image_get_class_count(img) : 0;
        ipalog("[SP+]   image %s: %zu classes", in, nc);
    }
}
