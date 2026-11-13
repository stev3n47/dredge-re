# STPlus v1.0.1 — hook review & fix plan (for Devin)

Review of the first device run (`stplus.log`, 2026‑11‑13) against the source in
`next-game/polytopia/`. Steven's report: **stars isn't working, and the tribes/skins
unlocks are unverified.** This confirms that and tells you what to do.

## TL;DR

All three features are installed but **none of them actually intercept the game's
own calls.** They share one root cause, plus stars has a second, independent bug.
The fix is to stop swapping `MethodInfo.methodPointer` for methods the game calls
directly, and instead either (a) detour the function prologue, or (b) drive the
game's own setters/data via `il2cpp_runtime_invoke` (the one path we've proven
works on this build).

## Evidence

From `stplus.log`, every hook logs the same line right after install:

```
vtable: <feat> no vtable slot (non-virtual/direct-call) -- methodPointer swap only, may not reach game callsites
```

- `resolve:` shows `vslot=0x0` for tribes, skins **and** stars → `find_vtable_slot()`
  (`STPlus.m:809`) found no vtable entry for any of them, so only
  `MethodInfo.methodPointer` (slot[0]) was swapped (`pac_swap.c:13`).
- The two `UnityPlatformPurchaseManager.IsTribeUnlocked/IsSkinUnlocked` rows never
  resolve (`mi=0x0 ... (will retry)`) — that's the permanent `tribes=? skins=?` in
  every `status:` line. That class has **no such methods**; its interface method is
  `IsProductUnlocked` (catalog: `UnityPlatformPurchaseManager` idx 746, mc 32).
- Note: `diag=0i` in the status line is **not** an intercept count — it's the `diag`
  *feature's* tick counter (`diag_tick` always returns 0). There is currently **no**
  counter that proves whether a trampoline ever fired. (This branch adds one.)

## Root cause

In IL2CPP on this build, non‑virtual instance calls compile to direct `bl`
to the method's generated code. The call site never reads
`MethodInfo.methodPointer`; that field is used by `il2cpp_runtime_invoke`,
delegates, and reflection. `pac_swap.h` itself documents that v2.2 only *proved
the swap routes a `runtime_invoke` call* — not a direct call. So:

- `methodPointer` swap → reaches `runtime_invoke`/delegate callers only.
- vtable `methodPtr` swap → would reach `callvirt`, but `find_vtable_slot` returns
  NULL here (these aren't dispatched through `PurchaseManager`'s vtable — the
  polymorphic type is the `IPlatformPurchaseManager` impl, not `PurchaseManager`).
- direct `bl` → reached by **neither**. This is how the game calls
  `IsTribeUnlocked`, `IsSkinUnlocked` and `get_Currency`.

Result: the swaps install cleanly and do nothing to real gameplay.

## Per-feature status

| Feature | Target | Resolves? | Fires on game calls? | Also wrong because |
|---|---|---|---|---|
| tribes | `PurchaseManager.IsTribeUnlocked` | yes | **no** (direct call) | 2nd row targets a non-existent method |
| skins | `PurchaseManager.IsSkinUnlocked` | yes | **no** (direct call) | 2nd row targets a non-existent method |
| stars | `PlayerState.get_Currency` | yes | **no** (direct call) | getter, instance-wide (**AI too**), and hooking a *getter* never changes the stored balance |

Stars is doubly broken: even if the swap reached callers, `get_Currency` is read for
**every** `PlayerState` including AI (PLAN.md already flags this as the "AI too"
problem), and pinning a getter's return doesn't change what the spend path
writes back. PLAN.md §T2.6 already prescribes the right shape — this just hasn't
been built.

## Fix plan (prioritized)

### 1. Make effectiveness observable (DONE — CONFIRMED on device)
`pac_swap.c` has counting trampolines and `STPlus.m`'s `status:` line prints
`intercepts: true=<n>`. **The 14:55 device run (v1.0.2) settled it: `intercepts:
true=0` for the entire ~19‑minute session** (through menu use and gameplay). The
`methodPointer` swap is inert — tribes/skins must move to a real interception
(step 2). `feature_diag.c` also dumped the navigation accessors; the useful ones
turned out to be static:

```
GameManager.get_LocalPlayer  argc=0 [static]   -> local human PlayerState
GameManager.get_GameState    argc=0 [static]
GameState.GetFirstHumanPlayer argc=0           (fallback)
PlayerState.set_Currency     argc=1            (the write path)
```

### 2. Tribes / skins → inline prologue detour (device-test required)
These are constant-return hooks ("always unlocked"), so you don't need to call the
original — the simplest correct fix is an **in-place prologue patch**: overwrite the
first two instructions of the target function (its code address is the pre-swap
`slot[0]`, already captured as `mi_orig`) with:

```
mov  w0, #1        ; 0x52800020
ret                ; 0xd65f03c0
```

**Blocker to clear first:** the repo already crashed on code-page writes —
`debug/crashes/v20-codesign-invalid-page.ips`. Before relying on this, add a
one-page RWX probe: pick a scratch/own page, `mach_vm_protect(..., VM_PROT_READ|
VM_PROT_WRITE|VM_PROT_COPY)`, write, restore `READ|EXECUTE`, `sys_icache_invalidate`,
and confirm no CS fault. Only enable the detour if the probe passes on the actual
signed/injected build. CI builds `-arch arm64` (build-stplus.yml:47) while the device
is arm64e — confirm which slice executes, because PAC/codesign enforcement differs.
If `__TEXT` writes are refused on the shipping signature, fall back to step 2b.

**2b (no code patching):** flip the data the check reads. `PurchaseManager`
delegates to `get_PlatformPurchaseManager().IsProductUnlocked(id)` and/or
`PurchaseCache` (idx 736). The dev-build impl `EverythingUnlockedPlatformPurchaseManager`
(idx 733) exists — its `IsProductUnlocked` is presumably always true. Two options:
populate the cached unlocked set via `runtime_invoke` of the `PurchaseCache`
`TryUpdateIAPUnlockedTribes/Skins` grant path, or make `get_PlatformPurchaseManager`
return the everything-unlocked impl. Watch `PurchaseCache.VerifyChecksum`/`GetChecksum1‑4`
(anti-tamper) — they guard the *persisted* file; an in-memory set used at call time
should be fine, but verify.

### 3. Stars → invoke `set_Currency` on the local player (DONE — verify on device)
Implemented in `feature_stars.c`. The old `get_Currency` hook is gone. Each
throttled (~2 Hz) tick while `stars=1` and `mp_safe=0`:

```
PlayerState* lp = GameManager.get_LocalPlayer();   // static, argc 0
if (lp && lp->klass == PlayerState)                // SPPlus v33 pointer check
    PlayerState.set_Currency(lp, 999999);          // instance, argc 1, via runtime_invoke
```

`get_LocalPlayer` returns the human's `PlayerState`, so **AI is never touched** —
no self-check trampoline needed. It uses only `runtime_invoke` (the proven path),
writes the real stored balance, needs no code patching, and logs a one-shot
set/readback so the next device log confirms the write. Still `mp_safe`-gated.

**Verify on device:** start a match with `stars=1`, confirm the log shows
`stars: set local player currency to 999999 (readback=999999)` and that the
in-game star count reflects it. If `get_LocalPlayer` returns a non-`PlayerState`
type, the log will say so and skip — fall back to `GameState.GetFirstHumanPlayer`.

### 4. Cleanup (DONE in this branch)
Removed the two dead `UnityPlatformPurchaseManager.Is*Unlocked` rows. If you want a
belt-and-suspenders unlock, re-add them as `IsProductUnlocked` on both
`UnityPlatformPurchaseManager` and `EverythingUnlockedPlatformPurchaseManager` — but
that's still a `methodPointer` swap and won't fire on direct calls until step 2 lands.

## Status

- **stars** — implemented (`feature_stars.c`), pending device verification.
- **tribes/skins** — still need step 2; `intercepts: true=0` confirms the current
  `methodPointer` swap does nothing.

## Decisions for Steven

- OK to pursue the inline detour (step 2) for tribes/skins, given it needs an
  on-device RWX probe and the project has hit `codesign-invalid-page` before? Or
  prefer the data-side 2b route (invoke the `PurchaseCache` grant path)?
- If stars' device log shows `get_LocalPlayer` returning a non-`PlayerState`, say so
  and I'll switch it to `GameState.GetFirstHumanPlayer`.
