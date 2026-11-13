# PolyFootball on-device findings

## Build + target
- App: `com.Miceli.Poly 4.5.3`, Unity 6000.3.9f1, global-metadata v39.
- iOS 26.2 (23C55), iPhone18,2 (arm64e).
- UnityFramework loads at process map. Bridge resolves 22 il2cpp runtime
  entry points via dlsym with 0 misses — flat-namespace works, no offset
  table needed on this build.

## Tier 1 — confirmed working (v1a.5+)
- `PremiumCurrency` type 4130, method_count 22 matches catalog.
- `UnlockPro`, `UnlockAgent`, `UnlockTripleTicketBoost`, `UnlockCapIncrease`
  are **all static** (`METHOD_ATTRIBUTE_STATIC = 0x10`). No instance
  required. `il2cpp_runtime_invoke(method, self=NULL, args=NULL, &exc)` is
  sufficient.
- In-game shop screenshot confirmed `PRO OWNED`, `AGENT OWNED`, `3X BOOST`
  shows `PRO HAS 4X` (Pro grants 4× tickets, supersedes the standalone
  3× unlock), `$400M CAP` is bundled in Pro.
- `get_HasTripleTicketBoost` and `get_HasCapIncrease` returning `true`
  immediately after Pro unlock is correct game behaviour — Pro subsumes
  both. The `*_force` toggles are therefore unnecessary on this build.
- Main-runloop timer (`CFRunLoopGetMain` + real `kCFRunLoopCommonModes`
  global) fires reliably at 10 Hz. `-framework CoreFoundation` is required
  so the common-modes global resolves to the actual constant and
  `CFRunLoopAddTimer`'s pointer check (`modeName == kCFRunLoopCommonModes`)
  hits the common-modes special case.

## Tier 2 physics — ALL STATIC (v2.0-pre device run, 2026-11-13)

Every v2a diagnostic feature init'd clean and dumped its method inventory.
Every single Tier 2 physics method is `[static]`:

### Fumbles (`FootballFumbleRules` type 2424, 10 methods · `FootballFumbleSim` type 2427, 21 methods)
```
FootballFumbleRules.Chance            argc=1 [static]
FootballFumbleRules.ExpectedPerTackle argc=3 [static]
FootballFumbleRules.PunchTryChance    argc=1 [static]
FootballFumbleRules.Fumbles           argc=2 [static]
FootballFumbleSim.DriveChance         argc=4 [static]
FootballFumbleSim.DriveRoll           argc=5 [static]
FootballFumbleSim.PerTackle           argc=4 [static]
FootballFumbleSim.Fumbles             argc=2 [static]
```

### Injuries (7 classes, all resolved)
All methods static:
`FootballTackleInjuries.{Mark, IsMarked, StaysDown}`,
`InjuryCatalog.{Roll, AggravationChance}`,
`CareerInjuryRecovery.{RollPlayer, CopyInjury, RehabOffered, RecoveryRoom,
RehabOdds, RehabWorks, OnSeasonRollover}`,
`FranchiseInjuryCare.{RollLive, InRehab, RehabOdds, RehabBlocker,
ToggleRehab, AggravationChance}`,
`CareerInjuryDecision.{OnInjury, AggravationChance}`,
`FranchiseInjuryRules.Roll`.

### Tackle (`FootballCarrierMoveRules` + `FootballTackleStyle`)
All static. **Overloads exist**: `BreakChance` has argc-1 and argc-3
variants, `ShoveChance` has argc-3 and argc-4. `name_from_name` picks one
arbitrarily — v2.2 hook must handle both.

### Catch (`FootballCatchReach` + `FootballCatchStyle` + `CareerWrCatchRules`)
All static. `FootballCatchReach` has three `TrySolve*` variants (argc-8,
argc-9, argc-9) plus the C# local function
`<TrySolveOnce>g__Candidate|11_0 argc=4 [static]`.

### Throw (`ThrowController`, 196 methods)
**EXCEPTION: all methods are INSTANCE, not static.** `CalculateThrowVelocity`
`CalculateBallisticVelocity`, `CalculateBulletVelocity`,
`CorrectUnderthrowVelocity` — all no `[static]` tag. 0 live instances at
init time because no match was active. v2.1 adds periodic rewalk so we
catch the live instance when a career match starts.

### Speed
`CarrierMoveControls`, `FootballJoystickLocomotion`, `FootballDefenseSpeeds`
all resolved. Only `FootballJoystickLocomotion.AnimatorSpeed argc=5
[static]` matched the speed-substring filter. Pattern scan found exactly
one `PocketMoveSpeedMultiplierForCurrentCareerArchetype` — it lives on
`ThrowController`, consistent with catalog m32647.

## Tier 1.5 — IAP infrastructure present

`Unity.Purchasing.*` DLLs are loaded on this build:
- `Unity.Purchasing.Stores.dll` (283 classes)
- `Unity.Purchasing.dll` (398 classes)
- `Unity.Purchasing.PaymentProviderService.dll` (122)
- `Unity.Purchasing.LiveContentAdapterService.dll` (68)
- `Unity.Purchasing.WebshopService.dll` (72)
- `Unity.Purchasing.Security.dll` (22)
- `Unity.Purchasing.Utilities.dll` (26)
- `Unity.Purchasing.Apple.dll` (2)
- `Unity.Purchasing.SecurityCore.dll` (4)
- `Unity.Purchasing.AppleMacosStub.dll` (2)

Candidate hook targets for durable Pro across cold-start receipt
revalidation:
- `UnityEngine.Purchasing.Security.AppleReceiptParser` — **12 methods**
  in `Unity.Purchasing.Security.dll`. The parser is the clear hook point.
- `UnityEngine.Purchasing.UseCases.AppReceiptUseCase` (2 methods) +
  `AppleRefreshAppReceiptUseCase` (1 method).
- `UnityEngine.Purchasing.Security.AppleReceipt` (7 methods) +
  `AppleInAppPurchaseReceipt` (21 methods).
- Cart validators: `AppleAppStoreCartValidator`, `AggregateCartValidator`,
  `StoreCartValidator`, `NonNullCartValidator`, etc. These sit between
  the parser and the UseCase and might be a cleaner hook surface.

v1.5.1 scope: resolve `AppleReceiptParser`, enumerate its 12 methods with
flags/argc, pick the static method whose name looks like `Parse` or
`Validate` and hook it. If the hook target is instance, promote the
rewalk entry to catch the live instance on first IAP flow.

## v1e — Sync infrastructure present

`MultiplayerProfileSaveManager` (26 methods, matches catalog),
`MultiplayerProfileEnvelope`, `MultiplayerProfileSaveData`, and
`HttpResult` all resolved. Method dump showed:

```
MultiplayerProfileSaveManager.SaveProfile      argc=0         (instance)
MultiplayerProfileSaveManager.LoadProfile      argc=0         (instance)
MultiplayerProfileSaveManager.SerializeProfile argc=1 [static]
```

(v2.0 critic-fix pass dumps the envelope + savedata too — missing in
v2.0-pre on-device run; v2.1 of that is on the rolling release.)

`SerializeProfile(static, argc=1)` is the clearest hook target. Static
methods can be methodPointer-swapped to a trampoline that writes a
"clean" serialization (omitting our locally-flipped Pro bit) before
upload, so the server never sees a mismatch to overwrite. 0 live
instances at init time — not surprising, sync manager spawns at first MP
login. v2.1 adds periodic rewalk.

## v2.1 scope (this build)
- Periodic rewalk registry: every ~60s re-walk the heap against every
  feature-registered target that hasn't been found yet. Catches
  match-time-spawned instances (ThrowController, FumbleRules asset,
  sync manager on first MP login, etc.).
- `feature_money.c` corrected to reflect reality: no setter exists,
  `Cap` is a static getter, forcing the cap requires methodPointer
  swap deferred to v2.2.
- No new action hooks — v1.5.1 (IAP) and v1e.1 (sync) both need
  methodPointer swap on static methods. Deferred to v2.2 PAC probe.

## Known blockers for v2.2+
- PAC probe infrastructure: write-back-same-pointer, invoke, catch
  `BRK 0xc470` via Mach exception port. Required for any methodPointer
  swap on arm64e iOS 17+.
- Metadata-v39 `MethodInfo` struct offsets: needed to read/write
  `methodPointer` safely. Current bridge uses only opaque runtime API —
  no struct offset reads. Will need a dedicated offset-dump step before
  PAC probe.
- ThrowController velocity methods are **instance**, not static — the
  v2.2 hook pattern there is different (per-instance vtable overwrite
  or per-tick GetTargetVelocity invoke with modified args).
