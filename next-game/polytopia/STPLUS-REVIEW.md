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

### 1. Make effectiveness observable (DONE in this branch — verify on device)
`pac_swap.c` now has counting trampolines and `STPlus.m`'s `status:` line prints
`intercepts: true=<n>`. On the next device run, drive a tribe picker and watch the
counter. If it stays **0** during gameplay, that's hard confirmation the
`methodPointer` path is inert and you must move to a real interception (below).
`feature_diag.c` now also dumps the method inventories of `GameManager`,
`ClientBase` and `GameState` (filtered to the navigation accessors) so you have the
exact symbol names needed for step 3 after one launch.

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

### 3. Stars → invoke `set_Currency` on the local player (device-test required)
Drop the `get_Currency` hook entirely (removed in this branch) and instead, each
tick while `stars=1` and `mp_safe` allows, write the human's balance directly:

- Resolve the live `GameState` via the `GameManager`/`ClientBase` singleton. The
  method names come from the step‑1 diag dump; PLAN.md already has the GameLogic
  side: `GameState.get_CurrentPlayer` (m80616) / `get_PlayerStates` (m80602),
  `PlayerState.get_AutoPlay` (m80748, human = false), `set_Currency` (m80754).
- Filter to the local human (`get_AutoPlay()==false`, or match `get_Id`/`AccountId`
  to the local client) so AI is untouched — this is the "self-check" PLAN.md §T2.6
  wants, done on the data side instead of in a trampoline.
- Call `set_Currency(huge)` via `runtime_invoke` (int32 arg: pass `&value`). This is
  the **proven** path (the v2.2 probe confirmed `runtime_invoke` routes through our
  swap), it changes the real stored balance, and it needs no code patching.
- Keep it under the `mp_safe` gate — it mutates match-sim state.

Build it as `feature_stars.c` (CI already globs `feature_*.c`). Follow
`feature_money.c`'s discipline: resolve everything, log arity/static bits, invoke
only with verified signatures, never guess.

### 4. Cleanup (DONE in this branch)
Removed the two dead `UnityPlatformPurchaseManager.Is*Unlocked` rows. If you want a
belt-and-suspenders unlock, re-add them as `IsProductUnlocked` on both
`UnityPlatformPurchaseManager` and `EverythingUnlockedPlatformPurchaseManager` — but
that's still a `methodPointer` swap and won't fire on direct calls until step 2 lands.

## Decisions for Steven

- OK to pursue the inline detour (step 2), given it needs an on-device RWX probe and
  the project has hit `codesign-invalid-page` before? Or prefer the data-side 2b route?
- For stars, confirm the `GameManager → GameState` entry accessor from the step‑1 diag
  dump before I/Devin wire `feature_stars.c`.
