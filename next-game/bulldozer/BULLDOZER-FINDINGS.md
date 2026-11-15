# Bulldozer Masters — BDPlus findings (first device run)

Target: `io.supercent.bulldozermasters` 11.7.0 · Unity 2022.3.76f1 · IL2CPP
metadata v31. Mod: **BDPlus v1.1**. Source: derived from `bdplus.log`
(11:10–11:25 session); BDPlus source is not in this repo yet — addresses and
status below are from the log, verify against the mod when it lands here.

## TL;DR — same split as STPlus/SPPlus/PFPlus

**Two features work. Six are installed but almost certainly dead**, for the two
root causes we've now hit on every target:

- Features that **invoke the game's own setters** (money, profile) work.
- Features that **hook a check** fail, because the inline detour can't write
  code pages (`mach_vm_write … kr=1`) and falls back to the methodPointer swap
  that STPlus proved inert on direct call sites.
- Features that **need a live instance** (fuel, stage) fail, because the heap
  walk finds zero in-range objects (`gc_foreach_heap` is dead on this build).

The winning pattern is the one the money/profile features and the SM27 writeup
already use: **call the game's own grant/set methods directly; don't patch, and
don't rely on the heap walk.**

## What works

| Feature | Mechanism | Evidence |
|---|---|---|
| **money** | Invokes `CurrencyManager.Obtain_WithoutFX(Money, +1,000,000)` on a ~5s drip + `+10,000,000` on menu grant | `money: Obtain_WithoutFX(Money,+1000000) ok (drip)` throughout; `money_mod` counter climbs 0→178 |
| **profile** (no_ads, skins, sdk boost) | Invokes `User` setters directly — `SetSkinUnlockedAll`, `NoAds`/`IsOnOpenAppAds` re-assert, and (when `sdk_progress=1`) Stage/Level/Coin | `profile: SetSkinUnlockedAll invoked` every ~2s; `User.NoAds re-asserted (was 0)`; `profile` counter climbs 1→418; `sdk_progress boost applied (Stage=100 Level=100 Coin=999999999)` |

Both work because they never hook and never walk the heap — they call setters on
a singleton/static (`CurrencyManager`, `User`). This is the template for fixing
the rest.

## What's broken — root cause 1: inline write fails, fallback is inert

Every inline hook attempt fails identically and falls back:

```
inline: spend.CheckSpendable @0x10ef18694 patching 8B …
inline: mach_vm_write @0x10ef18694 len=8 failed kr=1
inline: spend.CheckSpendable failed — falling back to methodPointer swap
pac-swap: spend.CheckSpendable installed · orig=0x10ef18694 -> trampoline=0x102c61064
```

`kr=1` = `KERN_INVALID_ADDRESS` — the process can't write its own `__TEXT`
(same wall STPlus hit as `v20-codesign-invalid-page`). So these land only as
methodPointer swaps, and STPlus's device run proved that swap **never fires on
the game's direct `bl` call sites** (`intercepts: true=0` all session). BDPlus
has no intercept counter, so the log can't confirm firing either way — but the
mechanism is identical, so treat all of these as **not taking effect**:

| Feature | Hooked method(s) | orig code addr |
|---|---|---|
| spend_free | `CheckSpendable`, `TrySpend` | `0x10ef18694`, `0x10ef18bb8` |
| free_rv | `RewardedVideo.Show`, `ShowWithExt` | `0x10efe8fe4`, `0x10efe94e8` |
| research_force | `StatUpgradeManager.IsResearchComplete` | `0x10f191d64` |
| free_iap | `InAppShopManager.IsPurchased` / `IsValidProduct` / `IsProductAvailable` / `IsPurchaseLimitAvailable` / `GetRemainingPurchaseCount` | `0x10eeb2ac8` … `0x10eeb3638` |

(`spend_free` is moot anyway while money drips infinitely, but the other three
are real gaps: rewarded-video auto-grant, instant research, and free IAP are
probably all not happening.)

## What's broken — root cause 2: instance discovery is dead

```
rewalk-sample: 16 distinct klass ptrs sampled; … ZERO in-range klass pointers
  — gc_foreach_heap matches the SPPlus/PFPlus failure pattern; instance
    features will rely on action-time walks only.
```

The heap walk never matches a live instance of either target class, so:

| Feature | Needs instance of | Session result |
|---|---|---|
| **infinite_fuel** | `FuelTank` (class `0x124373210`, `SetOilToMax=0x128d00ff8`) | `infinite_fuel=0i` the entire session; every tick `fuel: walk N — no live FuelTank instances yet` |
| **stage** complete | `MineManager` (class `0x124227820`, `CompleteStage=0x123d59320`) | `stage=0i`; on each menu tap `stage: CompleteStage requested but no live MineManager instance` |

The "action-time walk" fallback doesn't rescue it — the walk at tap time still
matched 0. These features need a **singleton/static path to the live instance**,
not a heap scan.

## Fix plan (priority order)

1. **Convert hook-based features to invoke-based** wherever the game exposes a
   setter/grant — the money/profile/SM27 pattern. Likely wins:
   - *research_force* → invoke the "complete/grant research" setter on
     `StatUpgradeManager` instead of hooking `IsResearchComplete`.
   - *free_rv* → invoke the reward-granted callback directly (the method the
     game calls after a watched ad) rather than hooking `Show`.
   - *free_iap* → if `InAppShopManager` has a "mark owned/grant product" setter,
     call it; otherwise this one genuinely needs a working detour (step 3).
2. **Resolve the live instance via a singleton, not the heap**, for fuel + stage.
   Find a static accessor or singleton field that yields the live `MineManager`
   / `FuelTank` (the way STPlus stars uses `GameManager.get_LocalPlayer`, and
   SM27 uses `…Controller.get_Instance()` + a field offset), then invoke
   `SetOilToMax` / `CompleteStage` on it. Add a diag dump of `MineManager` /
   `FuelTank` / any `GameManager`-like singleton's statics to get the accessor.
3. **Only if a feature has no setter** (likely `free_iap`'s check path): land a
   real inline detour by solving the `mach_vm_write kr=1` write — `mach_vm_protect`
   with `VM_PROT_COPY` to force a private writable copy, write, restore `R-X`,
   `sys_icache_invalidate` — gated behind a one-page RWX probe so a refused page
   can't crash the game (same approach + caveat as the STPlus detour).
4. **Add an intercept counter** to the methodPointer trampolines (STPlus v1.0.2
   did this) so "installed" vs "actually firing" is visible, instead of inferring
   it. Right now `spend_free=1i` etc. only means "installed."

## To confirm against source

- Point me at the BDPlus repo/branch (it's not in `dredge-re`) and I'll verify
  these addresses against the code and wire steps 1–2, exactly as done for
  STPlus stars.
- Whether the methodPointer-swap features are truly inert here needs either the
  intercept counter (step 4) or an in-game check (does a locked IAP actually
  read as owned? does research actually complete?).
