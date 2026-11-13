// STPlus IL2CPP bridge — resolve UnityFramework's internal libil2cpp
// runtime entry points and expose a small invocation surface.
//
// Reused wholesale from SPPlus structurally (no struct offset reads, only
// opaque runtime calls) and renamed stp_*. Resolution strategy:
//   1. Try dlsym on the UnityFramework image handle (works whenever the
//      game ships a normal export trie — most Unity 6 builds do).
//   2. Fall back to an optional offset header (il2cpp_offsets_supertribes_2180.h)
//      produced by tools/dump_il2cpp_offsets.py. If neither resolves a
//      given symbol, the typed pointer stays NULL and callers check.
//
// This design means the dylib builds and runs without a pre-generated
// offset header — missing entry points surface at runtime, not build time.

#ifndef STP_IL2CPP_BRIDGE_H
#define STP_IL2CPP_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void Il2CppDomain;
typedef void Il2CppImage;
typedef void Il2CppAssembly;
typedef void Il2CppClass;
typedef void Il2CppObject;
typedef void Il2CppString;
typedef void Il2CppType;
typedef void MethodInfo;

int  stp_il2cpp_init(char *errbuf, size_t errbuflen);
int  stp_il2cpp_ready(void);

// Each is NULL until init resolved it. Callers must check before invoking.
extern Il2CppDomain *(*stp_il2cpp_domain_get)(void);
extern const Il2CppAssembly **(*stp_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
extern const Il2CppImage   *(*stp_il2cpp_assembly_get_image)(const Il2CppAssembly *);
extern const char          *(*stp_il2cpp_image_get_name)(const Il2CppImage *);
extern Il2CppClass         *(*stp_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
extern size_t               (*stp_il2cpp_image_get_class_count)(const Il2CppImage *);
extern const char          *(*stp_il2cpp_class_get_name)(Il2CppClass *);
extern const char          *(*stp_il2cpp_class_get_namespace)(Il2CppClass *);
extern const MethodInfo    *(*stp_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
extern Il2CppObject        *(*stp_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
extern void                 (*stp_il2cpp_runtime_class_init)(Il2CppClass *);
extern void                 (*stp_il2cpp_thread_attach)(Il2CppDomain *);
extern void                *(*stp_il2cpp_thread_current)(void);
extern Il2CppClass         *(*stp_il2cpp_object_get_class)(Il2CppObject *);
extern void                 (*stp_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
extern void                 (*stp_il2cpp_gc_disable)(void);
extern void                 (*stp_il2cpp_gc_enable)(void);
extern int32_t              (*stp_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);
extern const MethodInfo    *(*stp_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
extern const char          *(*stp_il2cpp_method_get_name)(const MethodInfo *);
// il2cpp_method_get_flags(method, &iflags) returns the method attribute
// bits and writes the IL2CPP impl flags to iflags. Static bit is 0x10
// (METHOD_ATTRIBUTE_STATIC in the mono/ECMA attribute table).
extern uint32_t             (*stp_il2cpp_method_get_flags)(const MethodInfo *, uint32_t *iflags);
extern uint32_t             (*stp_il2cpp_method_get_param_count)(const MethodInfo *);

// High-level helpers.
Il2CppClass      *stp_il2cpp_find_class(const char *image_name, const char *ns, const char *cls);
const MethodInfo *stp_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc);

// Count visible methods on the class, for the v0.7 metadata-match
// assertion (we cross-check this against catalog-types.txt).
int               stp_il2cpp_count_methods(Il2CppClass *klass);

// Walk the managed heap once; for each live object whose class equals
// (or is assignable to) `klass`, append its pointer to `out[]` up to
// `cap`. Returns the count written. Bracketed by gc_disable/enable so the
// walk is safe. Not re-entrant.
int               stp_il2cpp_find_instances(Il2CppClass *klass, void **out, int cap);

// Invoke `method` with 0/1 args. `self` may be NULL for statics. Returns
// the boxed result; caller unboxes if needed. On any resolver miss returns
// NULL and sets *out_ok = 0 if non-NULL.
Il2CppObject     *stp_il2cpp_invoke0(const MethodInfo *m, void *self, int *out_ok);
Il2CppObject     *stp_il2cpp_invoke1(const MethodInfo *m, void *self, void *a0, int *out_ok);

// Unbox a boxed primitive: boxed objects are a 16-byte header followed by
// the value. These helpers return 0 on NULL input.
int32_t           stp_unbox_i32(Il2CppObject *boxed);
int64_t           stp_unbox_i64(Il2CppObject *boxed);
int               stp_unbox_bool(Il2CppObject *boxed);
float             stp_unbox_f32(Il2CppObject *boxed);

#ifdef __cplusplus
}
#endif

#endif  // STP_IL2CPP_BRIDGE_H
