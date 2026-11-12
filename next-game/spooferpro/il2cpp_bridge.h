// SpooferProPlus il2cpp bridge — resolve UnityFramework's internal libil2cpp
// runtime entry points at load time and expose a tiny invocation surface.
//
// Why: the game's own C# methods (IPokemonBag.ReleasePokemon,
// FortSearch, etc.) sign their rpc2 envelopes with platform_request[5]
// (HasAbrLookup) + packed timing — our own NSURLSession-spliced requests
// can't reproduce that signature, so Niantic rejects them. The only
// reliable path is to call those C# methods via il2cpp_runtime_invoke so
// the game itself emits the request. iPoGo and SpooferPro both work this
// way; SpooferProPlus now does too.
//
// Preferred-base caveat: UnityFramework's sections have vma == file
// offset (preferred base 0), so the offsets emitted by
// tools/dump_il2cpp_offsets.py are also addresses relative to the image
// base. At runtime we add dyld's ASLR slide to each.

#ifndef SPP_IL2CPP_BRIDGE_H
#define SPP_IL2CPP_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque il2cpp handles — never dereferenced in our code, only passed back
// to the runtime.
typedef void Il2CppDomain;
typedef void Il2CppImage;
typedef void Il2CppAssembly;
typedef void Il2CppClass;
typedef void Il2CppObject;
typedef void Il2CppString;
typedef void Il2CppArray;
typedef void Il2CppType;
typedef void MethodInfo;

// One-shot init. Returns 0 on success, non-zero with details in `errbuf`
// (which can be NULL). Idempotent. Safe to call from a dispatch block.
int   spp_il2cpp_init(char *errbuf, size_t errbuflen);

// True once spp_il2cpp_init has succeeded.
int   spp_il2cpp_ready(void);

// --- the typed function pointers, only valid after spp_il2cpp_ready(). ---

extern Il2CppDomain *(*spp_il2cpp_domain_get)(void);
extern const Il2CppAssembly **(*spp_il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
extern const Il2CppImage   *(*spp_il2cpp_assembly_get_image)(const Il2CppAssembly *);
extern const char          *(*spp_il2cpp_image_get_name)(const Il2CppImage *);
extern Il2CppClass         *(*spp_il2cpp_image_get_class)(const Il2CppImage *, size_t idx);
extern size_t               (*spp_il2cpp_image_get_class_count)(const Il2CppImage *);
extern const char          *(*spp_il2cpp_class_get_name)(Il2CppClass *);
extern const char          *(*spp_il2cpp_class_get_namespace)(Il2CppClass *);
extern const MethodInfo    *(*spp_il2cpp_class_get_method_from_name)(Il2CppClass *, const char *name, int argc);
extern Il2CppObject        *(*spp_il2cpp_runtime_invoke)(const MethodInfo *, void *self, void **args, Il2CppObject **exc);
extern void                 (*spp_il2cpp_runtime_class_init)(Il2CppClass *);
extern void                 (*spp_il2cpp_thread_attach)(Il2CppDomain *);
extern void                *(*spp_il2cpp_thread_current)(void);
extern Il2CppObject        *(*spp_il2cpp_object_new)(Il2CppClass *);
extern Il2CppClass         *(*spp_il2cpp_object_get_class)(Il2CppObject *);
extern Il2CppString        *(*spp_il2cpp_string_new)(const char *);
extern Il2CppArray         *(*spp_il2cpp_array_new)(Il2CppClass *elem, uintptr_t len);
extern Il2CppClass         *(*spp_il2cpp_class_from_type)(Il2CppType *);
extern Il2CppType          *(*spp_il2cpp_class_get_type)(Il2CppClass *);
extern Il2CppObject        *(*spp_il2cpp_type_get_object)(const Il2CppType *);
extern uint32_t             (*spp_il2cpp_gchandle_new)(Il2CppObject *, int pinned);

// Introspection — Phase 4 additions
extern const char          *(*spp_il2cpp_method_get_name)(const MethodInfo *);
extern uint32_t             (*spp_il2cpp_method_get_param_count)(const MethodInfo *);
extern const MethodInfo    *(*spp_il2cpp_class_get_methods)(Il2CppClass *, void **iter);
extern void                *(*spp_il2cpp_class_get_fields)(Il2CppClass *, void **iter);
extern const char          *(*spp_il2cpp_field_get_name)(void *field);
extern void                 (*spp_il2cpp_field_static_get_value)(void *field, void *out);

// v26 — GC heap walk, for finding a live instance without Zenject Resolve
// (which crashes on this build) or code-patching (code-signing risk).
// il2cpp_gc_foreach_heap invokes `func(obj, user)` for every live managed
// object; it stops the GC world for the duration, so the callback must not
// allocate or block. gc_disable/enable bracket the walk defensively.
extern void                 (*spp_il2cpp_gc_foreach_heap)(void (*func)(void *obj, void *user), void *user);
extern void                 (*spp_il2cpp_gc_disable)(void);
extern void                 (*spp_il2cpp_gc_enable)(void);
extern int32_t              (*spp_il2cpp_class_is_assignable_from)(Il2CppClass *to, Il2CppClass *from);

// Zenject Strategy C crashes during launch and is OFF by default. The host
// can opt in (post-login only) via config if a future build needs it.
void              spp_il2cpp_set_allow_zenject(int on);

// High-level helpers (cached by name so the walk cost is paid once).
//
// `image_name` is the assembly's file name e.g. "Assembly-CSharp.dll" or
// "mscorlib.dll".  Pass NULL to search across every loaded image, which is
// slow but survives image renames.
Il2CppClass      *spp_il2cpp_find_class(const char *image_name, const char *ns, const char *cls);
const MethodInfo *spp_il2cpp_find_method(Il2CppClass *klass, const char *name, int argc);

// Convenience: list every (image, namespace, class, class-count) once to
// the log — helpful to find the right class name on a new PoGo build.
// Only runs the first time it's called.
void              spp_il2cpp_log_classes_once(void);

// Static-field read helper. Returns the field's object value (or NULL on
// failure). `out` optionally receives the field pointer for subsequent
// reads/writes.
Il2CppObject     *spp_il2cpp_static_field_object(Il2CppClass *klass,
                                                 const char *field_name);

// Typed-arity invokers. Wrap il2cpp_runtime_invoke with the right args[]
// array. `self` is NULL for static methods. Returns the boxed result or
// NULL (caller unboxes if needed).
Il2CppObject     *spp_il2cpp_invoke_0(const MethodInfo *m, void *self);
Il2CppObject     *spp_il2cpp_invoke_1(const MethodInfo *m, void *self, void *a0);
Il2CppObject     *spp_il2cpp_invoke_2(const MethodInfo *m, void *self, void *a0, void *a1);

// Diagnostic: dump the first `limit` methods and fields of a class to the
// log. Use to discover the right member name on a new PoGo build when a
// resolver step fails.
void              spp_il2cpp_dump_class_members(Il2CppClass *klass, int limit);

// Try to resolve a live IPokemonBag instance via four strategies (see
// implementation). Caches the result. Returns NULL if none worked and
// logs which strategies failed at which step.
Il2CppObject     *spp_il2cpp_get_pokemon_bag(void);

// Probe step — resolves the class+method+instance and logs everything it
// finds. Returns 0 if a callable (klass, method, bag_instance) triple
// landed; non-zero otherwise.
int               spp_il2cpp_probe_release_pokemon(void);

// Invoke IPokemonBag.ReleasePokemon via il2cpp. Returns 0 on success,
// non-zero if any resolution step failed (logged).
int               spp_il2cpp_release_pokemon(uint64_t uid);

// Feature-time bag inspection: find the live bag via the GC heap walk and
// dump its enumeration API + a sample collection object's class, so the
// per-keep-rule clean can be wired against this build's real method names.
// Returns 0 if a live bag was found. Call when the user taps Clean Bag Now
// (post-login) — never at launch. `enum_probe` (host: cfg_i("bag_enum_probe"))
// gates the phase-2 enumeration probe that runs managed invokes
// (get_Count / get_AllPokemon); 0 = metadata-only.
int               spp_il2cpp_bag_inspect(int enum_probe);

// Crash-safe Zenject chain probe (v37): reaches the DiContainer via pure data
// reads (ProjectContext._instance -> _container) and dumps its field layout +
// the provider-dictionary/ProviderInfo/BindingId metadata, so the provider
// walk that yields the live bag can be written from real offsets. Executes NO
// generic-dispatch invoke, so it cannot trip the CODESIGNING page that killed
// v36. Logs how far it reached.
void              spp_il2cpp_zenject_probe(void);

#ifdef __cplusplus
}
#endif

#endif  // SPP_IL2CPP_BRIDGE_H
