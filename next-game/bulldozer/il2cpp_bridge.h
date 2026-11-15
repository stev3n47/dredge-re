// BDPlus IL2CPP bridge — resolve UnityFramework's internal libil2cpp
// runtime entry points and expose a small invocation surface.
//
// Reused wholesale from SPPlus structurally (no struct offset reads, only
// opaque runtime calls) and renamed bd_*. Resolution strategy:
//   1. Try dlsym on the UnityFramework image handle (works whenever the
//      game ships a normal export trie — most Unity 6 builds do).
//   2. Fall back to an optional offset header (il2cpp_offsets_bulldozer.h)
//      produced by tools/dump_il2cpp_offsets.py. If neither resolves a
//      given symbol, the typed pointer stays NULL and callers check.
//
// This design means the dylib builds and runs without a pre-generated
// offset header — missing entry points surface at runtime, not build time.

#ifndef BD_IL2CPP_BRIDGE_H
#define BD_IL2CPP_BRIDGE_H

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

int  bd_il2cpp_init(char *errbuf, size_t errbuflen);
int  bd_il2cpp_ready(void);

// Each is NULL until init resolved it. Callers must check before invoking.
extern Il2CppDomain *(*bd_il2cpp_domain_get)(void);
extern const Il2CppAssembly **(*bd_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
extern const Il2CppImage   *(*bd_il2cpp_assembly_get_image)(const Il2CppAssembly *);
extern const char          *(*bd_il2cpp_image_get_name)(const Il2CppImage *);
extern Il2CppClass         *(*bd_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
extern size_t               (*bd_il2cpp_image_get_class_count)(const Il2CppImage *);
extern const char          *(*bd_il2cpp_class_get_name)(Il2CppClass *);
extern const char          *(*bd_il2cpp_class_get_namespace)(Il2CppClass *);
extern const MethodInfo    *(*bd_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
extern Il2CppObject        *(*bd_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
extern void                 (*bd_il2cpp_runtime_class_init)(Il2CppClass *);
extern void                 (*bd_il2cpp_thread_attach)(Il2CppDomain *);
extern void                *(*bd_il2cpp_thread_current)(void);
extern Il2CppClass         *(*bd_il2cpp_object_get_class)(Il2CppObject *);
extern void                 (*bd_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
extern void                 (*bd_il2cpp_gc_disable)(void);
extern void                 (*bd_il2cpp_gc_enable)(void);
extern int32_t              (*bd_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);
extern const MethodInfo    *(*bd_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
extern const char          *(*bd_il2cpp_method_get_name)(const MethodInfo *);
// il2cpp_method_get_flags(method, &iflags) returns the method attribute
// bits and writes the IL2CPP impl flags to iflags. Static bit is 0x10
// (METHOD_ATTRIBUTE_STATIC in the mono/ECMA attribute table).
extern uint32_t             (*bd_il2cpp_method_get_flags)(const MethodInfo *, uint32_t *iflags);
extern uint32_t             (*bd_il2cpp_method_get_param_count)(const MethodInfo *);
// v1.2 — singleton instance discovery without the (broken on this build)
// gc_foreach_heap klass compare. class_get_parent walks to the inflated
// SingletonBase<T>/SingletonBehaviourBase<T> which declares the static
// `_instance` field; field_static_get_value reads it.
extern Il2CppClass         *(*bd_il2cpp_class_get_parent)(Il2CppClass *);
extern const void          *(*bd_il2cpp_class_get_field_from_name)(Il2CppClass *, const char *name);
extern void                 (*bd_il2cpp_field_static_get_value)(const void *field, void *value);

// High-level helpers.
Il2CppClass      *bd_il2cpp_find_class(const char *image_name, const char *ns, const char *cls);
const MethodInfo *bd_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc);

// Count visible methods on the class, for the v0.7 metadata-match
// assertion (we cross-check this against catalog-types.txt).
int               bd_il2cpp_count_methods(Il2CppClass *klass);

// Walk the managed heap once; for each live object whose class equals
// (or is assignable to) `klass`, append its pointer to `out[]` up to
// `cap`. Returns the count written. Bracketed by gc_disable/enable so the
// walk is safe. Not re-entrant.
int               bd_il2cpp_find_instances(Il2CppClass *klass, void **out, int cap);

// v1.2 — resolve the live singleton instance for classes deriving from
// SingletonBase<T>/SingletonBehaviourBase<T>: walk the parent chain,
// find the static `_instance` field on the inflated generic parent, and
// read it via il2cpp_field_static_get_value. Returns NULL when the
// class isn't a singleton, the instance isn't spawned yet, or any
// resolver is missing. Call on the main runloop only.
void             *bd_singleton_instance(Il2CppClass *klass);

// Invoke `method` with 0/1 args. `self` may be NULL for statics. Returns
// the boxed result; caller unboxes if needed. On any resolver miss returns
// NULL and sets *out_ok = 0 if non-NULL.
Il2CppObject     *bd_il2cpp_invoke0(const MethodInfo *m, void *self, int *out_ok);
Il2CppObject     *bd_il2cpp_invoke1(const MethodInfo *m, void *self, void *a0, int *out_ok);
// Generic N-arg invoke. `args` is an array of pointers to argument values
// (one pointer per parameter, in declaration order). Pass NULL/0 for none.
Il2CppObject     *bd_il2cpp_invoke(const MethodInfo *m, void *self, void **args, int *out_ok);

// Unbox a boxed primitive: boxed objects are a 16-byte header followed by
// the value. These helpers return 0 on NULL input.
int32_t           bd_unbox_i32(Il2CppObject *boxed);
int64_t           bd_unbox_i64(Il2CppObject *boxed);
int               bd_unbox_bool(Il2CppObject *boxed);
float             bd_unbox_f32(Il2CppObject *boxed);

#ifdef __cplusplus
}
#endif

#endif  // BD_IL2CPP_BRIDGE_H
