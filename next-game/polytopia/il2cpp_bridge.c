// STPlus IL2CPP bridge implementation — see il2cpp_bridge.h for rationale.
//
// Resolves il2cpp_* entry points by (1) dlsym on the UnityFramework image
// handle and (2) optional offset-header fallback. v1a ships without the
// offset header since most Unity 6 builds export normally; the header can
// be generated with tools/dump_il2cpp_offsets.py once we have the UIPA
// extracted and dlsym proves insufficient.

#include "il2cpp_bridge.h"

#include <mach-o/dyld.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

// Optional: if the header exists, use its offsets as a fallback when
// dlsym misses. Guard it so the dylib builds with or without the file.
#if __has_include("il2cpp_offsets_supertribes_2180.h")
#include "il2cpp_offsets_supertribes_2180.h"
#define STP_HAVE_OFFSETS 1
#else
#define STP_HAVE_OFFSETS 0
#endif

extern void stp_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// --- typed pointers (defined once; declared extern in the header) --------
Il2CppDomain *(*stp_il2cpp_domain_get)(void);
const Il2CppAssembly **(*stp_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
const Il2CppImage   *(*stp_il2cpp_assembly_get_image)(const Il2CppAssembly *);
const char          *(*stp_il2cpp_image_get_name)(const Il2CppImage *);
Il2CppClass         *(*stp_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
size_t               (*stp_il2cpp_image_get_class_count)(const Il2CppImage *);
const char          *(*stp_il2cpp_class_get_name)(Il2CppClass *);
const char          *(*stp_il2cpp_class_get_namespace)(Il2CppClass *);
const MethodInfo    *(*stp_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
Il2CppObject        *(*stp_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
void                 (*stp_il2cpp_runtime_class_init)(Il2CppClass *);
void                 (*stp_il2cpp_thread_attach)(Il2CppDomain *);
void                *(*stp_il2cpp_thread_current)(void);
Il2CppClass         *(*stp_il2cpp_object_get_class)(Il2CppObject *);
void                 (*stp_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
void                 (*stp_il2cpp_gc_disable)(void);
void                 (*stp_il2cpp_gc_enable)(void);
int32_t              (*stp_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);
const MethodInfo    *(*stp_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
const char          *(*stp_il2cpp_method_get_name)(const MethodInfo *);
uint32_t             (*stp_il2cpp_method_get_flags)(const MethodInfo *, uint32_t *iflags);
uint32_t             (*stp_il2cpp_method_get_param_count)(const MethodInfo *);

static int g_ready = 0;

int stp_il2cpp_ready(void) { return g_ready; }

static int find_unity_image(const uint8_t **out_base, intptr_t *out_slide,
                            uint32_t *out_index) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const char *needle = "UnityFramework.framework/UnityFramework";
        size_t ln = strlen(name), nn = strlen(needle);
        if (ln >= nn && strcmp(name + ln - nn, needle) == 0) {
            *out_base  = (const uint8_t *)_dyld_get_image_header(i);
            *out_slide = _dyld_get_image_vmaddr_slide(i);
            if (out_index) *out_index = i;
            return 1;
        }
    }
    return 0;
}

// Resolve a symbol by name using dlopen/dlsym on UnityFramework's path.
// Returns NULL if unresolved; caller falls back to offset-header lookup.
static void *resolve_dlsym(const char *path, const char *name) {
    void *h = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    if (!h) return NULL;
    void *sym = dlsym(h, name);
    // Don't dlclose; the image is still live in the process.
    return sym;
}

int stp_il2cpp_init(char *errbuf, size_t errbuflen) {
    if (g_ready) return 0;

    const uint8_t *base = NULL;
    intptr_t slide = 0;
    uint32_t idx = 0;
    if (!find_unity_image(&base, &slide, &idx)) {
        (void)dlopen("@executable_path/Frameworks/UnityFramework.framework/UnityFramework",
                     RTLD_NOW | RTLD_GLOBAL);
        if (!find_unity_image(&base, &slide, &idx)) {
            if (errbuf) snprintf(errbuf, errbuflen,
                                 "UnityFramework not mapped in this process");
            return -1;
        }
    }

    const char *path = _dyld_get_image_name(idx);
    stp_log("bridge: UnityFramework at %p (slide=0x%lx)", (void *)base, (long)slide);

    int resolved = 0, missing = 0;
#define TRY(sym) do {                                       \
        void *p = resolve_dlsym(path, #sym);                \
        if (!p) { missing++; stp_log("bridge: miss %s", #sym); } \
        else   { resolved++; }                              \
        stp_##sym = (typeof(stp_##sym))p;                   \
    } while (0)

    TRY(il2cpp_domain_get);
    TRY(il2cpp_domain_get_assemblies);
    TRY(il2cpp_assembly_get_image);
    TRY(il2cpp_image_get_name);
    TRY(il2cpp_image_get_class);
    TRY(il2cpp_image_get_class_count);
    TRY(il2cpp_class_get_name);
    TRY(il2cpp_class_get_namespace);
    TRY(il2cpp_class_get_method_from_name);
    TRY(il2cpp_runtime_invoke);
    TRY(il2cpp_runtime_class_init);
    TRY(il2cpp_thread_attach);
    TRY(il2cpp_thread_current);
    TRY(il2cpp_object_get_class);
    TRY(il2cpp_gc_foreach_heap);
    TRY(il2cpp_gc_disable);
    TRY(il2cpp_gc_enable);
    TRY(il2cpp_class_is_assignable_from);
    TRY(il2cpp_class_get_methods);
    TRY(il2cpp_method_get_name);
    TRY(il2cpp_method_get_flags);
    TRY(il2cpp_method_get_param_count);
#undef TRY
    (void)STP_HAVE_OFFSETS;  // reserved for an offset-header fallback (unused in v1a)

    stp_log("bridge: resolved %d symbols (%d missing)", resolved, missing);

    if (!stp_il2cpp_domain_get) {
        if (errbuf) snprintf(errbuf, errbuflen,
                             "il2cpp_domain_get unresolved — bridge unusable");
        return -2;
    }

    // Pre-call instrumentation. v1a.2 crash had NO log between "resolved 20
    // symbols" and the SIGSEGV — Steve's diagnosis was SP-relative deref
    // inside the first export call, likely domain_get on an un-GC-attached
    // pthread. These per-call log lines pin the exact crash site next time.
    stp_log("bridge: calling domain_get @ %p ...", (void *)stp_il2cpp_domain_get);
    Il2CppDomain *dom = stp_il2cpp_domain_get();
    stp_log("bridge: domain_get returned %p", dom);
    if (!dom) {
        if (errbuf) snprintf(errbuf, errbuflen,
                             "il2cpp_domain_get returned NULL (runtime not initialized yet?)");
        return -3;
    }

    if (stp_il2cpp_thread_current) {
        stp_log("bridge: calling thread_current @ %p ...", (void *)stp_il2cpp_thread_current);
        void *cur = stp_il2cpp_thread_current();
        stp_log("bridge: thread_current returned %p", cur);
        if (!cur && stp_il2cpp_thread_attach) {
            stp_log("bridge: calling thread_attach(%p) @ %p ...", dom, (void *)stp_il2cpp_thread_attach);
            stp_il2cpp_thread_attach(dom);
            stp_log("bridge: thread_attach returned");
        }
    }

    g_ready = 1;
    stp_log("bridge: init complete");
    return 0;
}

// --- class/method lookup -------------------------------------------------

#define CACHE_SZ 128
struct ccache {
    const char *image;
    const char *ns;
    const char *cls;
    Il2CppClass *klass;
};
static struct ccache g_class_cache[CACHE_SZ];
static int g_class_cache_n = 0;

Il2CppClass *stp_il2cpp_find_class(const char *image_name, const char *ns, const char *cls) {
    if (!g_ready) return NULL;
    for (int i = 0; i < g_class_cache_n; i++) {
        struct ccache *e = &g_class_cache[i];
        if ((e->image == image_name || (e->image && image_name && !strcmp(e->image, image_name))) &&
            (e->ns == ns || (e->ns && ns && !strcmp(e->ns, ns))) &&
            (e->cls == cls || (e->cls && cls && !strcmp(e->cls, cls)))) {
            return e->klass;
        }
    }

    Il2CppDomain *dom = stp_il2cpp_domain_get();
    if (!dom) return NULL;
    size_t n_asm = 0;
    const Il2CppAssembly **asms = stp_il2cpp_domain_get_assemblies(dom, &n_asm);
    for (size_t ai = 0; ai < n_asm; ai++) {
        const Il2CppImage *img = stp_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        if (image_name) {
            const char *in = stp_il2cpp_image_get_name(img);
            if (!in || strcmp(in, image_name) != 0) continue;
        }
        size_t nc = stp_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = stp_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kns = stp_il2cpp_class_get_namespace(k);
            const char *kcn = stp_il2cpp_class_get_name(k);
            if (!kcn) continue;
            if (ns && (!kns || strcmp(kns, ns) != 0)) continue;
            if (cls && strcmp(kcn, cls) != 0) continue;
            if (g_class_cache_n < CACHE_SZ) {
                struct ccache *e = &g_class_cache[g_class_cache_n++];
                e->image = image_name; e->ns = ns; e->cls = cls; e->klass = k;
            }
            return k;
        }
    }
    return NULL;
}

const MethodInfo *stp_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc) {
    if (!g_ready || !klass || !name) return NULL;
    if (stp_il2cpp_runtime_class_init) stp_il2cpp_runtime_class_init(klass);
    return stp_il2cpp_class_get_method_from_name(klass, name, argc);
}

int stp_il2cpp_count_methods(Il2CppClass *klass) {
    if (!g_ready || !klass || !stp_il2cpp_class_get_methods) return -1;
    void *iter = NULL;
    int n = 0;
    while (stp_il2cpp_class_get_methods(klass, &iter)) n++;
    return n;
}

// --- instance discovery via heap walk ------------------------------------
//
// SAFETY: v1a shipped a walk_cb that called is_assignable_from on class
// pointers derived from the heap walk. That SIGSEGV'd at offset 0x135
// deep inside the il2cpp type-hierarchy traversal (crash sig in
// debug/crashes/stplus-v1a-PolyFootball-2026-11-12-175228.ips). Same
// bug class as SPPlus v32: gc_foreach_heap surfaces some non-managed
// allocations whose klass field is garbage, and any il2cpp runtime call
// through a garbage class pointer walks into bad memory.
//
// Fix (SPPlus v33 pattern, see spooferpro/il2cpp_bridge.c:685): inside
// the stop-the-world callback ONLY read obj->klass (one field load) and
// do POINTER-EQUALITY compares against the caller's pre-resolved valid
// class pointer. No is_assignable_from, no class_get_name, no gc_disable
// wrap (gc_foreach_heap manages its own stop-the-world — nesting
// disables was likely harmless but is unneeded and SPPlus doesn't).

struct walk_ctx {
    Il2CppClass *target;  // pre-resolved from image metadata — always safe
    void **out;
    int cap;
    int n;
    long scanned;
};

static void walk_cb(void *obj, void *user) {
    struct walk_ctx *c = (struct walk_ctx *)user;
    c->scanned++;
    if (!obj || c->n >= c->cap) return;
    Il2CppClass *k = stp_il2cpp_object_get_class(obj);  // obj->klass; cheap
    if (!k) return;
    // Pointer-equality only. No calls through k (is_assignable_from,
    // class_get_name, etc.) because k may be a garbage pointer for
    // non-managed-object heap allocations.
    if (k == c->target) {
        c->out[c->n++] = obj;
    }
}

int stp_il2cpp_find_instances(Il2CppClass *klass, void **out, int cap) {
    if (!g_ready || !klass || !out || cap <= 0) return 0;
    if (!stp_il2cpp_gc_foreach_heap || !stp_il2cpp_object_get_class) return 0;
    struct walk_ctx c = { klass, out, cap, 0, 0 };
    // No gc_disable wrap — gc_foreach_heap handles its own stop-the-world.
    stp_il2cpp_gc_foreach_heap(walk_cb, &c);
    stp_log("heap: walk scanned %ld objects, matched %d of class %p", c.scanned, c.n, (void *)klass);
    return c.n;
}

// --- typed invokes --------------------------------------------------------

Il2CppObject *stp_il2cpp_invoke0(const MethodInfo *m, void *self, int *out_ok) {
    if (!g_ready || !m || !stp_il2cpp_runtime_invoke) {
        if (out_ok) *out_ok = 0;
        return NULL;
    }
    Il2CppObject *exc = NULL;
    Il2CppObject *r = stp_il2cpp_runtime_invoke(m, self, NULL, &exc);
    if (out_ok) *out_ok = (exc == NULL);
    return r;
}

Il2CppObject *stp_il2cpp_invoke1(const MethodInfo *m, void *self, void *a0, int *out_ok) {
    if (!g_ready || !m || !stp_il2cpp_runtime_invoke) {
        if (out_ok) *out_ok = 0;
        return NULL;
    }
    void *args[1] = { a0 };
    Il2CppObject *exc = NULL;
    Il2CppObject *r = stp_il2cpp_runtime_invoke(m, self, args, &exc);
    if (out_ok) *out_ok = (exc == NULL);
    return r;
}

// Boxed primitive layout on IL2CPP: { void *klass; void *monitor; <value>; ... }
// so the value starts 16 bytes into the object on 64-bit builds.
int32_t stp_unbox_i32(Il2CppObject *b) { return b ? *(int32_t *)((char *)b + 16) : 0; }
int64_t stp_unbox_i64(Il2CppObject *b) { return b ? *(int64_t *)((char *)b + 16) : 0; }
int     stp_unbox_bool(Il2CppObject *b) { return b ? (int)*(uint8_t *)((char *)b + 16) : 0; }
float   stp_unbox_f32(Il2CppObject *b) { return b ? *(float *)((char *)b + 16) : 0.0f; }
