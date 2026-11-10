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
uint32_t             (*spp_il2cpp_gchandle_new)(Il2CppObject *, int pinned);

// --- state --------------------------------------------------------------
static int g_ready = 0;

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
    RESOLVE(il2cpp_gchandle_new,               SPP_IL2CPP_GCHANDLE_NEW_OFF);
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

int spp_il2cpp_probe_release_pokemon(void) {
    if (!g_ready) return -10;
    Il2CppClass *klass = NULL;
    const char *found_ns = NULL, *found_cls = NULL;
    for (int i = 0; !klass && k_bag_namespaces[i]; i++) {
        for (int j = 0; !klass && k_bag_classes[j]; j++) {
            klass = spp_il2cpp_find_class("Assembly-CSharp.dll",
                                          k_bag_namespaces[i][0] ? k_bag_namespaces[i] : NULL,
                                          k_bag_classes[j]);
            if (klass) { found_ns = k_bag_namespaces[i]; found_cls = k_bag_classes[j]; }
        }
    }
    if (!klass) {
        ipalog("[SP+] il2cpp probe: no PokemonBag class found across known names");
        return -1;
    }
    ipalog("[SP+] il2cpp probe: found class %s.%s", found_ns, found_cls);

    const MethodInfo *m = spp_il2cpp_find_method(klass, "ReleasePokemon", 1);
    if (!m) {
        ipalog("[SP+] il2cpp probe: class resolved but ReleasePokemon(1) not found");
        return -2;
    }
    ipalog("[SP+] il2cpp probe: ReleasePokemon(PokemonProto) resolved — Phase 4 will "
           "wire the Zenject chain + call it");
    return 0;
}

int spp_il2cpp_release_pokemon(uint64_t uid) {
    // Scaffold — real implementation lands in Phase 4 once the Zenject
    // chain (ProjectContext._instance.Container.Resolve<IPokemonBag>())
    // is modelled for PoGo 0.743. Logging the uid here keeps the call
    // site honest about what we WOULD release.
    extern void ipalog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
    if (!g_ready) {
        ipalog("[SP+] il2cpp release skipped (bridge not ready): uid=%llu", (unsigned long long)uid);
        return -10;
    }
    ipalog("[SP+] il2cpp release uid=%llu — Zenject instance resolution not "
           "implemented yet (Phase 4); use release_mode=rpc2 or wait", (unsigned long long)uid);
    return -1;
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
