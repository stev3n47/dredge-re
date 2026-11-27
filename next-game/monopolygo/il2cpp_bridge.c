// MGOPlus IL2CPP bridge implementation — see il2cpp_bridge.h for rationale.
//
// Resolves il2cpp_* entry points by (1) dlsym on the UnityFramework image
// handle and (2) optional offset-header fallback. v1 ships without the
// offset header since Monopoly GO 1.82.0 exports all 242 il2cpp_* symbols
// normally; the header can be generated with tools/dump_il2cpp_offsets.py
// if a later build strips them.

#include "il2cpp_bridge.h"

#include <mach-o/dyld.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

// Optional: if the header exists, use its offsets as a fallback when
// dlsym misses. Guard it so the dylib builds with or without the file.
#if __has_include("il2cpp_offsets_mgo_182.h")
#include "il2cpp_offsets_mgo_182.h"
#define MGO_HAVE_OFFSETS 1
#else
#define MGO_HAVE_OFFSETS 0
#endif

extern void mgo_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

// --- typed pointers (defined once; declared extern in the header) --------
Il2CppDomain *(*mgo_il2cpp_domain_get)(void);
const Il2CppAssembly **(*mgo_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
const Il2CppImage   *(*mgo_il2cpp_assembly_get_image)(const Il2CppAssembly *);
const char          *(*mgo_il2cpp_image_get_name)(const Il2CppImage *);
Il2CppClass         *(*mgo_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
size_t               (*mgo_il2cpp_image_get_class_count)(const Il2CppImage *);
const char          *(*mgo_il2cpp_class_get_name)(Il2CppClass *);
const char          *(*mgo_il2cpp_class_get_namespace)(Il2CppClass *);
const MethodInfo    *(*mgo_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
Il2CppObject        *(*mgo_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
void                 (*mgo_il2cpp_runtime_class_init)(Il2CppClass *);
void                 (*mgo_il2cpp_thread_attach)(Il2CppDomain *);
void                *(*mgo_il2cpp_thread_current)(void);
Il2CppClass         *(*mgo_il2cpp_object_get_class)(Il2CppObject *);
void                 (*mgo_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
void                 (*mgo_il2cpp_gc_disable)(void);
void                 (*mgo_il2cpp_gc_enable)(void);
int32_t              (*mgo_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);
const MethodInfo    *(*mgo_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
const char          *(*mgo_il2cpp_method_get_name)(const MethodInfo *);
uint32_t             (*mgo_il2cpp_method_get_flags)(const MethodInfo *, uint32_t *iflags);
uint32_t             (*mgo_il2cpp_method_get_param_count)(const MethodInfo *);

static int g_ready = 0;

int mgo_il2cpp_ready(void) { return g_ready; }

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

int mgo_il2cpp_init(char *errbuf, size_t errbuflen) {
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
    mgo_log("bridge: UnityFramework at %p (slide=0x%lx)", (void *)base, (long)slide);

    int resolved = 0, missing = 0;
#define TRY(sym) do {                                       \
        void *p = resolve_dlsym(path, #sym);                \
        if (!p) { missing++; mgo_log("bridge: miss %s", #sym); } \
        else   { resolved++; }                              \
        mgo_##sym = (typeof(mgo_##sym))p;                   \
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
    (void)MGO_HAVE_OFFSETS;  // reserved for an offset-header fallback (unused in v1)

    mgo_log("bridge: resolved %d symbols (%d missing)", resolved, missing);

    if (!mgo_il2cpp_domain_get) {
        if (errbuf) snprintf(errbuf, errbuflen,
                             "il2cpp_domain_get unresolved — bridge unusable");
        return -2;
    }

    // Pre-call instrumentation (PFPlus v1a.2 lesson): on Unity 6000.x even
    // domain_get is unsafe on a non-GC-registered thread. All calls here
    // run inside a CFRunLoopTimer on the main runloop, so this is benign
    // instrumentation — but keep the log lines in case a caller strays.
    mgo_log("bridge: calling domain_get @ %p ...", (void *)mgo_il2cpp_domain_get);
    Il2CppDomain *dom = mgo_il2cpp_domain_get();
    mgo_log("bridge: domain_get returned %p", dom);
    if (!dom) {
        if (errbuf) snprintf(errbuf, errbuflen,
                             "il2cpp_domain_get returned NULL (runtime not initialized yet?)");
        return -3;
    }

    if (mgo_il2cpp_thread_current) {
        mgo_log("bridge: calling thread_current @ %p ...", (void *)mgo_il2cpp_thread_current);
        void *cur = mgo_il2cpp_thread_current();
        mgo_log("bridge: thread_current returned %p", cur);
        if (!cur && mgo_il2cpp_thread_attach) {
            mgo_log("bridge: calling thread_attach(%p) @ %p ...", dom, (void *)mgo_il2cpp_thread_attach);
            mgo_il2cpp_thread_attach(dom);
            mgo_log("bridge: thread_attach returned");
        }
    }

    g_ready = 1;
    mgo_log("bridge: init complete");
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

Il2CppClass *mgo_il2cpp_find_class(const char *image_name, const char *ns, const char *cls) {
    if (!g_ready) return NULL;
    for (int i = 0; i < g_class_cache_n; i++) {
        struct ccache *e = &g_class_cache[i];
        if ((e->image == image_name || (e->image && image_name && !strcmp(e->image, image_name))) &&
            (e->ns == ns || (e->ns && ns && !strcmp(e->ns, ns))) &&
            (e->cls == cls || (e->cls && cls && !strcmp(e->cls, cls)))) {
            return e->klass;
        }
    }

    Il2CppDomain *dom = mgo_il2cpp_domain_get();
    if (!dom) return NULL;
    size_t n_asm = 0;
    const Il2CppAssembly **asms = mgo_il2cpp_domain_get_assemblies(dom, &n_asm);
    for (size_t ai = 0; ai < n_asm; ai++) {
        const Il2CppImage *img = mgo_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        if (image_name) {
            const char *in = mgo_il2cpp_image_get_name(img);
            if (!in || strcmp(in, image_name) != 0) continue;
        }
        size_t nc = mgo_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < nc; ci++) {
            Il2CppClass *k = mgo_il2cpp_image_get_class(img, ci);
            if (!k) continue;
            const char *kns = mgo_il2cpp_class_get_namespace(k);
            const char *kcn = mgo_il2cpp_class_get_name(k);
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

const MethodInfo *mgo_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc) {
    if (!g_ready || !klass || !name) return NULL;
    if (mgo_il2cpp_runtime_class_init) mgo_il2cpp_runtime_class_init(klass);
    return mgo_il2cpp_class_get_method_from_name(klass, name, argc);
}

int mgo_il2cpp_count_methods(Il2CppClass *klass) {
    if (!g_ready || !klass || !mgo_il2cpp_class_get_methods) return -1;
    void *iter = NULL;
    int n = 0;
    while (mgo_il2cpp_class_get_methods(klass, &iter)) n++;
    return n;
}

// --- instance discovery via heap walk ------------------------------------
//
// SAFETY (SPPlus v33+ / PFPlus v1a crash, debug/crashes/pfplus-v1a-*.ips):
// inside the stop-the-world callback ONLY read obj->klass (one field load)
// and do POINTER-EQUALITY compares against a class pointer pre-resolved
// from image metadata. gc_foreach_heap surfaces non-managed allocations
// whose klass field is garbage — any il2cpp call through it walks into
// bad memory. No is_assignable_from, no class_get_name, no gc_disable
// wrap (gc_foreach_heap manages its own stop-the-world).
//
// CALLBACK CONTRACT (Unity 6 / Monopoly GO 1.82.0):
// il2cpp_gc_foreach_heap on this build passes a pointer to an ITERATOR
// RECORD, not the Il2CppObject itself. The record's first word is the
// real object pointer, the second is its size in bytes. Verified
// empirically via mgo_il2cpp_probe_object_layout: 256 sampled `obj`
// callback args were all the same stack address (0x16d... — iOS main-
// thread stack), while *(obj) walked the heap pages (deltas between
// successive *(obj) values matched *(obj+8) sizes exactly).
// Dereference once at the top of every callback to get the real object.

static inline void *mgo_heap_iter_to_obj(void *iter) {
    if (!iter) return NULL;
    void *obj = *(void **)iter;
    // Range guard: real managed objects live in the iOS heap range. If
    // the dereferenced value is outside that, something about the
    // iterator layout is different for this record — skip it rather
    // than crash.
    uintptr_t u = (uintptr_t)obj;
    if (u < 0x100000000UL || u >= 0x8000000000UL) return NULL;
    return obj;
}

struct walk_ctx {
    Il2CppClass *target;  // pre-resolved from image metadata — always safe
    void **out;
    int cap;
    int n;
    long scanned;
};

static void walk_cb(void *iter, void *user) {
    struct walk_ctx *c = (struct walk_ctx *)user;
    c->scanned++;
    void *obj = mgo_heap_iter_to_obj(iter);
    if (!obj || c->n >= c->cap) return;
    Il2CppClass *k = mgo_il2cpp_object_get_class(obj);  // obj->klass; cheap
    if (!k) return;
    // Pointer-equality only. No calls through k.
    if (k == c->target) {
        c->out[c->n++] = obj;
    }
}

int mgo_il2cpp_find_instances(Il2CppClass *klass, void **out, int cap) {
    if (!g_ready || !klass || !out || cap <= 0) return 0;
    if (!mgo_il2cpp_gc_foreach_heap || !mgo_il2cpp_object_get_class) return 0;
    struct walk_ctx c = { klass, out, cap, 0, 0 };
    mgo_il2cpp_gc_foreach_heap(walk_cb, &c);
    mgo_log("heap: walk scanned %ld objects, matched %d of class %p", c.scanned, c.n, (void *)klass);
    return c.n;
}

// Multi-target variant: match against ANY of n_targets pre-resolved classes.
// Still only pointer-equality inside the callback — targets[] is a small
// array of klass pointers the caller already resolved from image metadata,
// so the safety rules above still hold.
struct walk_ctx_multi {
    Il2CppClass **targets;
    int n_targets;
    void **out;
    int cap;
    int n;
    long scanned;
};

static void walk_cb_multi(void *iter, void *user) {
    struct walk_ctx_multi *c = (struct walk_ctx_multi *)user;
    c->scanned++;
    void *obj = mgo_heap_iter_to_obj(iter);
    if (!obj || c->n >= c->cap) return;
    Il2CppClass *k = mgo_il2cpp_object_get_class(obj);
    if (!k) return;
    for (int i = 0; i < c->n_targets; i++) {
        if (k == c->targets[i]) {
            c->out[c->n++] = obj;
            return;
        }
    }
}

int mgo_il2cpp_find_instances_any(Il2CppClass **targets, int n_targets,
                                  void **out, int cap) {
    if (!g_ready || !targets || n_targets <= 0 || !out || cap <= 0) return 0;
    if (!mgo_il2cpp_gc_foreach_heap || !mgo_il2cpp_object_get_class) return 0;
    struct walk_ctx_multi c = { targets, n_targets, out, cap, 0, 0 };
    mgo_il2cpp_gc_foreach_heap(walk_cb_multi, &c);
    mgo_log("heap: walk scanned %ld objects, matched %d against %d class(es)",
            c.scanned, c.n, n_targets);
    return c.n;
}

// --- known-klass set + heap histogram ------------------------------------
//
// To interpret klass pointers collected during gc_foreach_heap safely, we
// need to distinguish real Il2CppClass* values (from image metadata) from
// garbage that the walker surfaces for non-managed allocations. Build a
// sorted array of every klass pointer we can enumerate at init, then
// binary-search it before calling any il2cpp_class_* API on a heap klass.

static Il2CppClass **g_all_klasses = NULL;
static int           g_n_all_klasses = 0;

static int cmp_klass_ptr(const void *a, const void *b) {
    Il2CppClass *ka = *(Il2CppClass * const *)a;
    Il2CppClass *kb = *(Il2CppClass * const *)b;
    if (ka < kb) return -1;
    if (ka > kb) return 1;
    return 0;
}

int mgo_il2cpp_build_klass_set(void) {
    if (!g_ready) return -1;
    if (g_all_klasses) return g_n_all_klasses;

    Il2CppDomain *dom = mgo_il2cpp_domain_get();
    if (!dom || !mgo_il2cpp_domain_get_assemblies) return -1;
    size_t n_asm = 0;
    const Il2CppAssembly **asms = mgo_il2cpp_domain_get_assemblies(dom, &n_asm);
    if (!asms) return -1;

    size_t total = 0;
    for (size_t ai = 0; ai < n_asm; ai++) {
        const Il2CppImage *img = mgo_il2cpp_assembly_get_image(asms[ai]);
        if (img) total += mgo_il2cpp_image_get_class_count(img);
    }
    if (total == 0) return 0;

    g_all_klasses = (Il2CppClass **)calloc(total, sizeof(Il2CppClass *));
    if (!g_all_klasses) return -1;

    for (size_t ai = 0; ai < n_asm; ai++) {
        const Il2CppImage *img = mgo_il2cpp_assembly_get_image(asms[ai]);
        if (!img) continue;
        size_t ncl = mgo_il2cpp_image_get_class_count(img);
        for (size_t ci = 0; ci < ncl; ci++) {
            Il2CppClass *k = mgo_il2cpp_image_get_class(img, ci);
            if (k) g_all_klasses[g_n_all_klasses++] = k;
        }
    }
    qsort(g_all_klasses, g_n_all_klasses, sizeof(Il2CppClass *), cmp_klass_ptr);
    mgo_log("bridge: known-klass set: %d classes across %zu assemblies",
            g_n_all_klasses, n_asm);
    return g_n_all_klasses;
}

int mgo_il2cpp_is_known_klass(Il2CppClass *k) {
    if (!g_all_klasses || !k) return 0;
    int lo = 0, hi = g_n_all_klasses - 1;
    while (lo <= hi) {
        int mid = (lo + hi) >> 1;
        Il2CppClass *m = g_all_klasses[mid];
        if (m == k) return 1;
        if (m < k) lo = mid + 1;
        else       hi = mid - 1;
    }
    return 0;
}

// Heap histogram: walk once, bucket klass pointers, log each class whose
// namespace starts with `ns_prefix` (NULL = all) and its live count.
// Static 1 MiB staging buffer; overflow is fine — unique classes still
// get seen even if some object entries are dropped.

#define MGO_HIST_CAP (1 << 17)   /* 131072 object slots */
static Il2CppClass *g_hist_buf[MGO_HIST_CAP];

struct hist_ctx {
    int n;
    int overflow;
    long scanned;
};

static void hist_walk_cb(void *iter, void *user) {
    struct hist_ctx *c = (struct hist_ctx *)user;
    c->scanned++;
    void *obj = mgo_heap_iter_to_obj(iter);
    if (!obj) return;
    Il2CppClass *k = mgo_il2cpp_object_get_class(obj);
    if (!k) return;
    if (c->n < MGO_HIST_CAP) g_hist_buf[c->n++] = k;
    else c->overflow++;
}

// Per-unique-class row collected after the walk's RLE pass.
struct hist_row {
    Il2CppClass *k;
    int count;
};

static int cmp_hist_row_desc(const void *a, const void *b) {
    const struct hist_row *ra = (const struct hist_row *)a;
    const struct hist_row *rb = (const struct hist_row *)b;
    if (ra->count != rb->count) return rb->count - ra->count;
    return 0;
}

void mgo_il2cpp_heap_histogram(const char *ns_prefix, int top_n) {
    if (!g_ready || !mgo_il2cpp_gc_foreach_heap || !mgo_il2cpp_object_get_class) return;
    if (!g_all_klasses) {
        mgo_log("heap: histogram skipped — known-klass set not built");
        return;
    }
    struct hist_ctx c = { 0, 0, 0 };
    mgo_il2cpp_gc_foreach_heap(hist_walk_cb, &c);

    qsort(g_hist_buf, c.n, sizeof(Il2CppClass *), cmp_klass_ptr);

    // RLE pass -> rows (unique klass pointers + counts).
    static struct hist_row rows[MGO_HIST_CAP];
    int n_rows = 0;
    long known_obj_count = 0;
    int n_known_rows = 0;
    for (int i = 0; i < c.n; ) {
        Il2CppClass *k = g_hist_buf[i];
        int cnt = 1;
        while (i + cnt < c.n && g_hist_buf[i + cnt] == k) cnt++;
        if (n_rows < MGO_HIST_CAP) {
            rows[n_rows].k = k;
            rows[n_rows].count = cnt;
            n_rows++;
            if (mgo_il2cpp_is_known_klass(k)) {
                n_known_rows++;
                known_obj_count += cnt;
            }
        }
        i += cnt;
    }

    mgo_log("heap: histogram scanned %ld objects (overflow=%d, prefix=%s)",
            c.scanned, c.overflow, ns_prefix ? ns_prefix : "*");
    mgo_log("heap: %d unique klass ptrs, %d known (metadata), %ld objects on known klasses",
            n_rows, n_known_rows, known_obj_count);

    qsort(rows, n_rows, sizeof(rows[0]), cmp_hist_row_desc);

    // Top-N by object count across ALL known classes (no namespace filter).
    if (top_n > 0) {
        int printed = 0;
        for (int i = 0; i < n_rows && printed < top_n; i++) {
            Il2CppClass *k = rows[i].k;
            if (!mgo_il2cpp_is_known_klass(k)) continue;
            const char *kn  = mgo_il2cpp_class_get_name(k);
            const char *kns = mgo_il2cpp_class_get_namespace(k);
            if (!kn) continue;
            mgo_log("heap: top[%d] %d x %s.%s (klass %p)",
                    printed, rows[i].count, kns ? kns : "", kn, (void *)k);
            printed++;
        }
    }

    // Explicit prefix pass (even if no entries match, you see the search ran).
    if (ns_prefix) {
        size_t pref_len = strlen(ns_prefix);
        int printed = 0;
        for (int i = 0; i < n_rows; i++) {
            Il2CppClass *k = rows[i].k;
            if (!mgo_il2cpp_is_known_klass(k)) continue;
            const char *kn  = mgo_il2cpp_class_get_name(k);
            const char *kns = mgo_il2cpp_class_get_namespace(k);
            if (!kn || !kns) continue;
            if (strncmp(kns, ns_prefix, pref_len) != 0) continue;
            mgo_log("heap: %s %d x %s.%s (klass %p)",
                    ns_prefix, rows[i].count, kns, kn, (void *)k);
            printed++;
        }
        mgo_log("heap: %d class(es) matched prefix '%s'", printed, ns_prefix);
    }
}

// --- object layout probe --------------------------------------------------
//
// Previous diagnostic build: histogram reported "76390 unique klass ptrs,
// 0 known". Every object yields a unique "klass" value and NONE are in
// image metadata — that cannot be real Il2CppObject.klass reads. Probe
// the raw layout: sample first PROBE_CAP objects' first 4 pointer-sized
// words, then tally how many objects have a known-klass value at each
// offset. The capture happens INSIDE the stop-the-world callback (safe),
// and we also record what mgo_il2cpp_object_get_class returns for each
// object so we can tell whether the function pointer is misbehaving vs.
// the layout being shifted.

#define PROBE_CAP 256
static int        g_probe_n = 0;
static void      *g_probe_addr[PROBE_CAP];
static uintptr_t  g_probe_w[PROBE_CAP][4];        // first 4 words at iter addr
static uintptr_t  g_probe_oget[PROBE_CAP];        // what il2cpp_object_get_class returns
static uintptr_t  g_probe_deref_w[PROBE_CAP][4];  // first 4 words at *(iter+0) (real obj, if hypothesis holds)
static uintptr_t  g_probe_deref_oget[PROBE_CAP];  // il2cpp_object_get_class(*iter)
static int        g_probe_deref_valid[PROBE_CAP]; // 1 if *(iter+0) looked like a heap address

static void probe_walk_cb(void *iter, void *user) {
    (void)user;
    if (!iter || g_probe_n >= PROBE_CAP) return;
    uintptr_t *o = (uintptr_t *)iter;
    g_probe_addr[g_probe_n] = iter;
    // Read first 4 words at iter. Captures the full iterator record if the
    // Unity 6 hypothesis is correct, or the raw object header otherwise.
    g_probe_w[g_probe_n][0] = o[0];
    g_probe_w[g_probe_n][1] = o[1];
    g_probe_w[g_probe_n][2] = o[2];
    g_probe_w[g_probe_n][3] = o[3];
    g_probe_oget[g_probe_n] = (uintptr_t)(mgo_il2cpp_object_get_class
                                          ? mgo_il2cpp_object_get_class(iter)
                                          : NULL);

    // Hypothesis: iter is a pointer to an iterator record whose first word
    // is the real object pointer. Dereference once and probe the real
    // object's first 4 words — the first should be a known klass if the
    // hypothesis holds.
    uintptr_t cand = o[0];
    if (cand >= 0x100000000UL && cand < 0x8000000000UL) {
        uintptr_t *r = (uintptr_t *)cand;
        g_probe_deref_w[g_probe_n][0] = r[0];
        g_probe_deref_w[g_probe_n][1] = r[1];
        g_probe_deref_w[g_probe_n][2] = r[2];
        g_probe_deref_w[g_probe_n][3] = r[3];
        g_probe_deref_oget[g_probe_n] =
            (uintptr_t)(mgo_il2cpp_object_get_class
                        ? mgo_il2cpp_object_get_class((void *)cand)
                        : NULL);
        g_probe_deref_valid[g_probe_n] = 1;
    } else {
        g_probe_deref_valid[g_probe_n] = 0;
    }
    g_probe_n++;
}

void mgo_il2cpp_probe_object_layout(void) {
    if (!g_ready || !mgo_il2cpp_gc_foreach_heap) return;
    if (!g_all_klasses) {
        mgo_log("probe: skipped - known-klass set not built");
        return;
    }
    g_probe_n = 0;
    mgo_il2cpp_gc_foreach_heap(probe_walk_cb, NULL);
    mgo_log("probe: collected %d objects (cap %d)", g_probe_n, PROBE_CAP);

    // Tally known-klass hits at offsets 0, +8, +16, +24; plus offset-0
    // with low-bit tags stripped (some IL2CPP builds pack bits there);
    // plus what il2cpp_object_get_class() returned.
    int hit_w[4] = {0};
    int hit_untag = 0;
    int hit_oget = 0;
    int oget_eq_w0 = 0;
    for (int i = 0; i < g_probe_n; i++) {
        for (int j = 0; j < 4; j++) {
            if (mgo_il2cpp_is_known_klass((Il2CppClass *)g_probe_w[i][j]))
                hit_w[j]++;
        }
        uintptr_t untag = g_probe_w[i][0] & ~(uintptr_t)0x7;
        if (mgo_il2cpp_is_known_klass((Il2CppClass *)untag)) hit_untag++;
        if (mgo_il2cpp_is_known_klass((Il2CppClass *)g_probe_oget[i])) hit_oget++;
        if (g_probe_oget[i] == g_probe_w[i][0]) oget_eq_w0++;
    }
    for (int j = 0; j < 4; j++) {
        mgo_log("probe: iter+%2d: %d/%d objects have a known-klass value",
                j * 8, hit_w[j], g_probe_n);
    }
    mgo_log("probe: iter+ 0 untagged (&~0x7): %d/%d", hit_untag, g_probe_n);
    mgo_log("probe: il2cpp_object_get_class(iter): %d/%d known; equals *iter in %d/%d",
            hit_oget, g_probe_n, oget_eq_w0, g_probe_n);

    // Hypothesis check: iter is a pointer to {obj, size, ...}. Deref once
    // and probe offsets from the real obj.
    int hit_dw[4] = {0};
    int hit_doget = 0;
    int n_deref = 0;
    for (int i = 0; i < g_probe_n; i++) {
        if (!g_probe_deref_valid[i]) continue;
        n_deref++;
        for (int j = 0; j < 4; j++) {
            if (mgo_il2cpp_is_known_klass((Il2CppClass *)g_probe_deref_w[i][j]))
                hit_dw[j]++;
        }
        if (mgo_il2cpp_is_known_klass((Il2CppClass *)g_probe_deref_oget[i])) hit_doget++;
    }
    for (int j = 0; j < 4; j++) {
        mgo_log("probe: *iter then +%2d: %d/%d objects have a known-klass value",
                j * 8, hit_dw[j], n_deref);
    }
    mgo_log("probe: il2cpp_object_get_class(*iter): %d/%d known (deref-valid: %d/%d)",
            hit_doget, n_deref, n_deref, g_probe_n);

    // Raw dump of the first 5 samples for eyeball analysis.
    int dump = g_probe_n < 5 ? g_probe_n : 5;
    for (int i = 0; i < dump; i++) {
        mgo_log("probe: iter[%d]@%p  w0=0x%lx w1=0x%lx w2=0x%lx w3=0x%lx  oget=0x%lx",
                i, g_probe_addr[i],
                (unsigned long)g_probe_w[i][0],
                (unsigned long)g_probe_w[i][1],
                (unsigned long)g_probe_w[i][2],
                (unsigned long)g_probe_w[i][3],
                (unsigned long)g_probe_oget[i]);
        if (g_probe_deref_valid[i]) {
            mgo_log("probe:  *iter[%d]@0x%lx dw0=0x%lx dw1=0x%lx dw2=0x%lx dw3=0x%lx  doget=0x%lx",
                    i, (unsigned long)g_probe_w[i][0],
                    (unsigned long)g_probe_deref_w[i][0],
                    (unsigned long)g_probe_deref_w[i][1],
                    (unsigned long)g_probe_deref_w[i][2],
                    (unsigned long)g_probe_deref_w[i][3],
                    (unsigned long)g_probe_deref_oget[i]);
        }
    }
}

// --- typed invokes --------------------------------------------------------

Il2CppObject *mgo_il2cpp_invoke0(const MethodInfo *m, void *self, int *out_ok) {
    if (!g_ready || !m || !mgo_il2cpp_runtime_invoke) {
        if (out_ok) *out_ok = 0;
        return NULL;
    }
    Il2CppObject *exc = NULL;
    Il2CppObject *r = mgo_il2cpp_runtime_invoke(m, self, NULL, &exc);
    if (out_ok) *out_ok = (exc == NULL);
    return r;
}

Il2CppObject *mgo_il2cpp_invoke1(const MethodInfo *m, void *self, void *a0, int *out_ok) {
    if (!g_ready || !m || !mgo_il2cpp_runtime_invoke) {
        if (out_ok) *out_ok = 0;
        return NULL;
    }
    void *args[1] = { a0 };
    Il2CppObject *exc = NULL;
    Il2CppObject *r = mgo_il2cpp_runtime_invoke(m, self, args, &exc);
    if (out_ok) *out_ok = (exc == NULL);
    return r;
}

// Boxed primitive layout on IL2CPP: { void *klass; void *monitor; <value>; ... }
// so the value starts 16 bytes into the object on 64-bit builds.
int32_t mgo_unbox_i32(Il2CppObject *b) { return b ? *(int32_t *)((char *)b + 16) : 0; }
int64_t mgo_unbox_i64(Il2CppObject *b) { return b ? *(int64_t *)((char *)b + 16) : 0; }
int     mgo_unbox_bool(Il2CppObject *b) { return b ? (int)*(uint8_t *)((char *)b + 16) : 0; }
float   mgo_unbox_f32(Il2CppObject *b) { return b ? *(float *)((char *)b + 16) : 0.0f; }
