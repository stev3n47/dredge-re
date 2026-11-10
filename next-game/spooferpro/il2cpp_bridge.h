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
extern uint32_t             (*spp_il2cpp_gchandle_new)(Il2CppObject *, int pinned);

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

// Diagnostic — look up IPokemonBag / PokemonBagImpl + ReleasePokemon and
// log what we found. Does NOT invoke anything (no `this` instance yet).
// Returns 0 if class+method resolved successfully, -N otherwise.
int               spp_il2cpp_probe_release_pokemon(void);

// EXPERIMENTAL — try to release a pokemon via il2cpp. Currently returns
// -1 "instance not resolved" until the Zenject chain is implemented;
// kept so SpooferProPlus can switch to it via release_mode="il2cpp" once
// the resolution is done, without touching callers.
int               spp_il2cpp_release_pokemon(uint64_t uid);

#ifdef __cplusplus
}
#endif

#endif  // SPP_IL2CPP_BRIDGE_H
