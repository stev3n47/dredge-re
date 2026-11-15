// pac_swap.c — generalized methodPointer swap + inline code patch
// (see pac_swap.h).

#include "pac_swap.h"
#include "features.h"
#include <string.h>
#include <dlfcn.h>

// mach_vm.h / OSCacheControl.h are macOS-only or unreliable in the iOS
// SDK — declare the entry points with primitive types instead
// (mach_port_t=u32, mach_vm_address_t=u64, mach_msg_type_number_t=u32).
// Same workaround PDPlus uses for mach_vm_read_overwrite.
extern unsigned int mach_task_self(void);
extern int mach_vm_write(unsigned int task, unsigned long long addr,
                         unsigned long long data, unsigned int cnt);
extern void sys_icache_invalidate(void *start, unsigned long len);

int bd_pac_hook_install_save(const MethodInfo *mi, void *trampoline,
                               void **out_original, const char *tag) {
    if (!mi || !trampoline) {
        bd_log("pac-swap: %s invalid args (mi=%p trampoline=%p)",
                tag ? tag : "?", (const void *)mi, trampoline);
        return 0;
    }
    void **slot = (void **)mi;     // slot[0] = methodPointer (offset 0)
    void *orig = slot[0];
    if (out_original) *out_original = orig;
    slot[0] = trampoline;
    bd_log("pac-swap: %s installed · MethodInfo=%p orig=%p -> trampoline=%p",
            tag ? tag : "?", (const void *)mi, orig, trampoline);
    return 1;
}

int bd_pac_hook_install(const MethodInfo *mi, void *trampoline, const char *tag) {
    return bd_pac_hook_install_save(mi, trampoline, NULL, tag);
}

// Shared trampolines. Declared `(void)` so the compiler doesn't touch
// the stack. `no_sanitize("address")` just in case a future ASan build
// probes the frame.
__attribute__((no_sanitize("address")))
float bd_tramp_zero_float(void) { return 0.0f; }

__attribute__((no_sanitize("address")))
float bd_tramp_one_float(void) { return 1.0f; }

__attribute__((no_sanitize("address")))
int64_t bd_tramp_zero_int(void) { return 0; }

__attribute__((no_sanitize("address")))
int64_t bd_tramp_one_int(void) { return 1; }

__attribute__((no_sanitize("address")))
int64_t bd_tramp_huge_int(void) { return 999999999LL; }

__attribute__((no_sanitize("address")))
float bd_tramp_two_float(void) { return 2.0f; }

// ---------------- v1.1 inline code patching ------------------------------
//
// slot[0] of MethodInfo is methodPointer — the runtime VA of the
// generated function entry inside UnityFramework __TEXT. Patching those
// bytes intercepts EVERY call path (direct call, vtable dispatch,
// runtime_invoke, delegates) because they all execute the same code.
//
// Writes go through mach_vm_write: the kernel mediates the copy and
// does not require the user page to be writable (this is the same
// mechanism debuggers use to plant breakpoints in RX text). If the
// kernel refuses (KERN_PROTECTION_FAILURE / KERN_INVALID_ADDRESS) we
// report failure and callers fall back to the methodPointer swap.

static void *mi_code_addr(const MethodInfo *mi) {
    if (!mi) return NULL;
    void * const *slot = (void * const *)mi;
    void *p = slot[0];
    if (!p || ((uintptr_t)p & 3u)) return NULL;
    // Sanity: must resolve to a loaded image — for our targets that's
    // always UnityFramework. dladdr is cheap and catches layout drift
    // (e.g. slot[0] not being methodPointer on this metadata version).
    Dl_info di;
    if (!dladdr(p, &di) || !di.dli_fname ||
        !strstr(di.dli_fname, "UnityFramework")) {
        bd_log("inline: methodPointer %p does not resolve into "
               "UnityFramework (dladdr fname=%s) — refusing patch",
               p, (di.dli_fname ? di.dli_fname : "?"));
        return NULL;
    }
    return p;
}

static int bd_text_write(void *addr, const void *data, size_t len) {
    int kr = mach_vm_write(mach_task_self(),
                           (unsigned long long)(uintptr_t)addr,
                           (unsigned long long)(uintptr_t)data,
                           (unsigned int)len);
    if (kr != 0) {
        bd_log("inline: mach_vm_write @%p len=%zu failed kr=%d",
               addr, len, kr);
        return 0;
    }
    sys_icache_invalidate(addr, len);
    return 1;
}

// arm64 encodings used below:
//   mov  w0, #1            = 0x52800020
//   movz w0, #imm16        = 0x52800000 | (imm16 << 5)
//   movk w0, #imm16,lsl16  = 0x72A00000 | (imm16 << 5)
//   ret                    = 0xD65F03C0
//   adrp x16, page         = 0x90000000 | immlo<<29 | immhi<<5 | 16
//   add  x16, x16, #lo12   = 0x91000000 | (lo12 << 10) | (16 << 5) | 16
//   br   x16               = 0xD61F0200
//   nop                    = 0xD503201F

static int inline_patch_bytes(const MethodInfo *mi, const uint32_t *code,
                              size_t nbytes, const char *tag) {
    void *addr = mi_code_addr(mi);
    if (!addr) {
        bd_log("inline: %s — no usable methodPointer, patch skipped", tag);
        return 0;
    }
    uint32_t orig[4] = {0};
    memcpy(orig, addr, (nbytes < 16 ? nbytes : 16));
    bd_log("inline: %s @%p patching %zuB (was %08x %08x %08x %08x)",
           tag, addr, nbytes, orig[0], orig[1], orig[2], orig[3]);
    if (!bd_text_write(addr, code, nbytes)) return 0;
    bd_log("inline: %s patched — all call paths now hit our code", tag);
    return 1;
}

int bd_hook_bool_true(const MethodInfo *mi, const char *tag) {
    static const uint32_t code[2] = { 0x52800020u, 0xD65F03C0u };
    if (inline_patch_bytes(mi, code, 8, tag)) return 1;
    bd_log("inline: %s failed — falling back to methodPointer swap", tag);
    return bd_pac_hook_install(mi, (void *)bd_tramp_one_int, tag);
}

int bd_hook_int_imm(const MethodInfo *mi, uint32_t imm, const char *tag) {
    uint32_t code[3];
    size_t n = 2;
    code[0] = 0x52800000u | ((imm & 0xFFFFu) << 5);          // movz w0,#lo16
    if (imm > 0xFFFFu) {
        code[1] = 0x72A00000u | (((imm >> 16) & 0xFFFFu) << 5); // movk w0,#hi16,lsl#16
        code[2] = 0xD65F03C0u;                              // ret
        n = 3;
    } else {
        code[1] = 0xD65F03C0u;                              // ret
    }
    if (inline_patch_bytes(mi, code, n * 4u, tag)) return 1;
    bd_log("inline: %s failed — falling back to methodPointer swap", tag);
    void *tramp = (imm == 1) ? (void *)bd_tramp_one_int
                 : (imm == 999999999u) ? (void *)bd_tramp_huge_int
                 : (imm == 0) ? (void *)bd_tramp_zero_int : NULL;
    if (!tramp) {
        bd_log("inline: %s — no fallback trampoline for imm=%u", tag, imm);
        return 0;
    }
    return bd_pac_hook_install(mi, tramp, tag);
}

int bd_hook_branch(const MethodInfo *mi, void *target, const char *tag) {
    void *addr = mi_code_addr(mi);
    if (!addr || !target) {
        bd_log("inline: %s — bad args (addr=%p target=%p)", tag, addr, target);
        return 0;
    }
    int64_t pdiff = (int64_t)((uintptr_t)target & ~(uintptr_t)0xFFF)
                  - (int64_t)((uintptr_t)addr   & ~(uintptr_t)0xFFF);
    int64_t imm = pdiff >> 12;                    // adrp page delta, 4KB units
    if (imm < -(1LL << 20) || imm >= (1LL << 20)) {
        bd_log("inline: %s — target %p out of adrp range from %p",
               tag, target, addr);
        return 0;
    }
    uint32_t lo12 = (uint32_t)((uintptr_t)target & 0xFFFu);
    uint32_t code[4];
    code[0] = 0x90000000u
            | (uint32_t)(((imm & 3LL) << 29)
                       | (((imm >> 2) & 0x7FFFFLL) << 5)
                       | 16u);                     // adrp x16, target@PAGE
    code[1] = 0x91000000u | (lo12 << 10) | (16u << 5) | 16u; // add x16,x16,#lo12
    code[2] = 0xD61F0200u;                          // br x16
    code[3] = 0xD503201Fu;                          // nop (pad)
    if (inline_patch_bytes(mi, code, 16, tag)) return 1;
    bd_log("inline: %s failed — falling back to methodPointer swap", tag);
    return bd_pac_hook_install(mi, target, tag);
}
