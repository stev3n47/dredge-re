# Bulldozer Master findings

## Build + target
- App: `io.supercent.bulldozermasters` 11.7.0 (build 31), main exe `BulldozerMaster` (88 KB stub).
- Unity **2022.3.76f1**, global-metadata **v31** (12.9 MB), UnityFramework 136 MB arm64.
- Built against iOS 26.2 SDK, min iOS 15.0. Decrypted IPA (eeveedecrypter) — LC cryptid already stripped.
- Ad stack: AppLovin MAX mediation + AdMob/InMobi/Meta/Moloco/Mintegral/Yandex/AppMetrica,
  Firebase (Crashlytics, Analytics, Installations), UniWebView, Unity.Purchasing (IAP),
  Facebook SDK, ByteBrew, GameAnalytics, AppsFlyer, Adjust, Tapjoy, Offerwall.
- UnityFramework uses **dyld chained fixups** — REA cannot decode it
  (`unsupported-pointer-encoding`), same wall as previous targets;
  `tools/macho_chained_fixups.py` + Il2CppDumper RVAs are the way.

## Pipeline state
- `bin/Payload/BulldozerMaster.app` — full extraction.
- `extracted/UnityFramework`, `extracted/global-metadata.dat`.
- `dump/` — Il2CppDumper net7 build run under `DOTNET_ROLL_FORWARD=LatestMajor`
  (host only has .NET 8/10; net7 runtime missing). CodeRegistration 0x6ff3888,
  MetadataRegistration 0x710d670 found automatically. dump.cs has full RVA==VA==fileoff.
- `catalog/` — `il2cpp_v39_catalog.py` output: 105 images, 13,953 types, 101,836 methods.
  **Tool fixes made for v31** (kept generic):
  - `valid_name` regex: first char now also accepts `<` and `.` (compiler-generated
    `<Foo>d__N`, `<>c`, `.ctor` were failing the 90% stride probe).
  - v31 `Il2CppTypeDefinition` = 88 B, `Il2CppMethodDefinition` = 36 B,
    `Il2CppImageDefinition` = 40 B — detected.
  - v31 typedef rows are **not token-sorted**: `methodStart` (col9) is monotonic only
    in token order, not row order. Fixed fallback: `methodStart` i32 @+36,
    `method_count` u16 @+64; method flags u16 @+28, parameterCount u16 @+34.
  - Game assembly = image 0 `Assembly-CSharp.dll`, types 0..3323.

## Architecture
- **Two currency layers.** `BulldozerMaster.Currency.CurrencyManager` (game money,
  `ECurrency.Money` only — single-currency game) and Supercent SDK `User`
  (Coin/RoundCoin/BigCoin/Stage/Level — analytics+leaderboard identity layer, all static).
- Supercent LaunchOps SDK namespaces: `Supercent.LaunchOps.Ads` (AdsHelper),
  `Supercent.Loader`, `ScPerformance`. Ads go through static helpers — clean seams.
- Management-sim loop: mine ore → smelt → sell → upgrade. Systems: MineStage,
  LostMine (event mines), WorldMap/Continents, Workers (hiring), Vehicles,
  Equipment/HandTools, MegaHarvester (fuel), RvBoost (rewarded-video boosts),
  PiggyBank, InAppShop, LiveOps, HR upgrades, research timers, onboarding chain.
- `ECurrencyObtain`/`ECurrencySpend` enums are empty-ish (Unknown/SellOrePiece) —
  free-form spend types; nothing to spoof there.

## Tier 1 — static seams (il2cpp_runtime_invoke / direct patch, no instance needed)

### Money — `BulldozerMaster.Currency.CurrencyManager` (type 1848, 64 m)
All `fl=0x96` public static, RVA==fileoff:
- `GetAmount(ECurrency)` @ 0x3A9E510 — read
- `SetAmount(ECurrency, int)` @ 0x3A9E670 — direct set
- `Obtain(ECurrency, int added, ECurrencyObtain)` @ 0x3A9E97C (+FX variants 0x3A9ED5C…0x3AA0308)
- `CheckSpendable(ECurrency, int cost)` @ 0x3AA0694 → patch `return true` = spend anything
- `Spend(ECurrency, int, ECurrencySpend)` @ 0x3AA082C → no-op = free purchases
- `TrySpend(...)` @ 0x3AA0BB8 → patch `return true` (+ skip decrement)
- `DEV_ShowMeTheMoreMoney()` @ 0x3AA1738 — built-in money cheat
- `DEV_ResetAmount()` @ 0x3AA1B64
- Instance mirror: `CurrencyInst` (1843) `SetAmount/Increase/Decrease` — the store record.

### SDK user — `User` (type 2626) — ALL STATIC
- `Coin`/`RoundCoin`/`BigCoin` get/set — SDK-layer coin
- `Stage`, `CurStage`, `Level` get/set — progression
- `SetSkinUnlockedAll()` @ 0x3C19D1C — unlock every skin
- `NoAds` get @ 0x3C0523C / set @ 0x3C19F34 — master no-ads flag
- `IsOnOpenAppAds` get/set — app-open ad gate
- `IsBannedUser` / `IsMultiBannedUser` — ban status (see Anti-cheat)
- `AdImpressionCount`, `RvImpressionCount`, `PurchaseCount` — ad/purchase telemetry

### Ads — `Supercent.LaunchOps.Ads.AdsHelper`
- `Interstitial.HasNoAds` get @ 0x3B6ECA4 / set @ 0x3B6ED14 — patch get→true or set(true) at boot
- `Interstitial.IsAdReady`, `Show(placement, Action)` @ 0x3B6EE0C,
  `ShowWithProb` @ 0x3B6F4F4 — no-op kills interstitials
- `Paused` (pause ads): `IsEnabled` set, `IsAdLocked`, `Interval`
- `RewardedVideo.Show(ERewardedPlacement, Action<bool>)` @ 0x3B70FE4 —
  **the free-RV seam**: patch to invoke `doneCallback(true)` immediately;
  covers every placement: player_speed/damage/cargomax tiles, money_rv, gear_rv,
  furnace_boost, selling_boost, trolley, bridge1/2, mining_auto, collecting_auto,
  fuel_add, offline_reward, time_boost_upgrade…
- `RewardedVideo.IsAdReady` @ 0x3B70F74 → force true (UI shows button always)
- `User.NoAds` is the persistence layer; `Interstitial.HasNoAds` the runtime gate.
  Both should be set. `is_purchased_no_ads` save key + product `noadspack`
  (EProductName 17, `bulldozermasters.non.usd.noadspack_4.99`).

### Upgrades — `StatUpgradeManager` (type 386, 31 m, instance singleton)
- `IsMaxLevel`, `Upgrade`, `PayPrice`, `CheatSetStatLevel` (dev cheat),
  `IsResearchStarted/Complete`, `SkipResearchTimeByRV`, `GetRemainingResearchTime`,
  `HasResearchTime` — research-timer skip + free upgrade seams.
- `HRUpgradeManager` (1729), `LostMineUpgradeManager` (1639) — same pattern.
- `StageManager` (408): `CheatSetCurrentStageID`, `GetRecommendedID`, `StartStageClearFlow`.
- `MineManager` (1151, instance): `MoveToStageLevelByCheat`, `MoveToStageByCheat`,
  `CompleteStage`, `AddPurchasedVehicles`, `AddPurchasedWorkers` — dev cheats in-shipping.

### IAP — `InAppShopManager` (type 1714, 26 m)
- `TryPurchase`, `PurchaseProcess`, `PurchaseCompleted`, `IsPurchased`,
  `IsValidProduct`, `IsShopAvailable` — classic free-IAP seams.
- `Unity.Purchasing` DLLs present; receipt path = `AppleReceiptParser` etc.
  (same as polyfootball §Tier 1.5).

## Tier 2 — instance hooks
- `FuelTank` (1191): `get_RemainingOil`/`set_RemainingOil`, `ConsumeOil`,
  `SetOilToMax`, `get_IsOilEmpty` — infinite vehicle fuel via ConsumeOil→no-op
  or IsOilEmpty→false.
- `MegaHarvesterActor` (1360, 40 m) — harvester automation.
- `RVPayPlatform` (1431) — pay-by-RV platforms; `OnPayFinished` completes.
- `MineBlockBreakRewardManager` (1181), `MiningComboManager` (1169) — yield multipliers.
- `StackingInventory` (1216, 29 m) — carry capacity.
- `WorkerHiringManager` (349): `get_IsUnlocked`, `SetUnlocked`, `TryPurchaseWorker`,
  `GetHirePriceWithMultiplier` — hire-price + unlock seams.
- `LostMineGameSessionManager` (1671, 54 m) — event-mine session.

## Anti-cheat notes
- `AdsHelper.Interstitial.IsOnSkippedCheat` / `RewardedVideo.IsOnSkippedCheat`
  backed by persisted keys `ah_is_sk` / `ah_rv_sk` — Supercent tracks ad-skip
  cheating. A free-RV hook should either avoid setting these or suppress the write;
  flag likely feeds analytics segmentation, maybe server ban review.
- `User.IsBannedUser` / `IsMultiBannedUser` — there IS a ban concept; force-false
  is cheap insurance.
- Firebase Crashlytics + Analytics + GameAnalytics + AppsFlyer + Adjust + ByteBrew
  all bundled — heavy telemetry. No server-visible economy calls seen in
  CurrencyManager (local JSON save `currency` / `inst_dict`), so money cheats
  are client-side only. `SaveDataManager` (525) drives save files.
- No jailbreak/Frida/tamper-detection symbols spotted in the game namespace so far;
  SDK may have silent checks — revisit if dylib gets killed at load.

## Proposed menu set (pick to scope v1)
1. Money: +1M button (Obtain) and/or Always-Spendable (CheckSpendable→true, TrySpend→true).
2. No Ads: `User.NoAds=true` + `AdsHelper.Interstitial.HasNoAds` forced + Paused.IsEnabled=false.
3. Free RV rewards: `RewardedVideo.Show`→auto-doneCallback(true) (suppress IsOnSkippedCheat write).
4. Unlock All Skins: `User.SetSkinUnlockedAll`.
5. Infinite Fuel: FuelTank ConsumeOil no-op / IsOilEmpty→false.
6. Stage skip: `MineManager.MoveToStageByCheat` / `CompleteStage` (needs instance).
7. Research instant: `StatUpgradeManager.SkipResearchTimeByRV`-free / `CheatSetStatLevel`.
8. Free IAP (later tier): `InAppShopManager.PurchaseProcess` spoof or receipt stub.

## Next
- Choose feature scope → write `BDMenu`/`bd_features.c` + `il2cpp_bridge` (copy
  polyfootball skeleton — flat-namespace dlsym bridge, no offset table needed
  pending device check), CI workflow `build-bulldozer.yml`, `tools/inject_bulldozer.py`
  (clone inject_polyfootball.py).
- Verify on device: which bridges resolve, whether `IsOnSkippedCheat` fires.

## v1.0 implementation (BDPlus) — built, awaiting device test

Scope chosen by user: everything (standard pack + fuel + stage/research/IAP).

Files (polyfootball skeleton cloned, pfp_→bd_):
- `BDPlus.m` — log/config/feature-registry/rewalk/main-runloop driver (PFPlus infra
  minus the PremiumCurrency hook table; all features are self-contained modules).
- `il2cpp_bridge.{c,h}` — dlsym resolution of il2cpp_* exports on UnityFramework +
  `bd_il2cpp_invoke` N-arg helper added.
- `pac_swap.{c,h}` — MethodInfo methodPointer swap + shared trampolines.
- `bdplus_menu.m` — UIKit overlay (9 toggles + 4 footer actions: +10M, Complete
  Stage, Kill All, Dump Log).
- `feature_money.c` — `money_mod` sentinel key; drip +1M/5s via
  `CurrencyManager.Obtain_WithoutFX(Money=1, n, 0)`; `money_grant` action +10M.
- `feature_spend.c` — `spend_free`: methodPointer swap
  `CheckSpendable`/`TrySpend` → `bd_tramp_one_int` (free purchases, balance untouched).
- `feature_profile.c` — poll-and-set sweep: `User.NoAds`→T,
  `Interstitial.HasNoAds`→T, `Interstitial/User.IsOnOpenAppAds`→F,
  both `IsOnSkippedCheat`→F, `Paused.IsEnabled`→F (private setter, invoke ignores
  accessibility); `unlock_skins` → `SetSkinUnlockedAll` ~30s; `sdk_progress`
  opt-in Stage/Level=100, Coin=999999999 (server-sync risk).
- `feature_rv.c` — `free_rv`: methodPointer swap on
  `RewardedVideo.Show(2)` + `ShowWithExt(3)`; trampolines invoke the
  `Action<bool>` delegate's `Invoke(true)` via runtime_invoke (delegate Invoke
  MethodInfo cached per klass). All 15 RV placements grant free; skipped-cheat
  flag never written since `_ShowRewardedVideo` is bypassed.
- `feature_fuel.c` — `infinite_fuel`: FuelTank methods are VIRTUAL → chose
  poll-and-invoke `SetOilToMax()` on every live instance ~5s (heap walk, cap 8)
  instead of methodPointer swap (vtable snapshots at class-init may bypass swap).
- `feature_stage.c` — `stage` sentinel + `stage_complete` action key: heap-walk
  MineManager → `CompleteStage()` once. MoveToStageLevelByCheat(int)/
  MoveToStageByCheat(int,int,Action) resolved+logged for v1.1.
- `feature_research.c` — `research_force`: methodPointer swap
  `StatUpgradeManager.IsResearchComplete` → true (non-virtual, sealed class).
  `GetRemainingResearchTime` returns TimeSpan (struct) — NOT hooked; UI countdown
  may still animate while the completion gate is open.
- `feature_iap.c` — `free_iap`: methodPointer swap on InAppShopManager
  `IsPurchased`/`IsValidProduct`/`IsProductAvailable`/`IsPurchaseLimitAvailable`
  → true, `GetRemainingPurchaseCount` → 999999999. TryPurchase/PurchaseProcess
  left alone (StoreKit receipts stay honest). Caveat: consumable packs may show
  "owned" and hide buy buttons.
- `tools/inject_bulldozer.py` — clone of inject_polyfootball.py (FW_NAME=BDPlus,
  FW_ID=com.bulldozerplus, auto-discovers .app bundle).
- `.github/workflows/build-bdplus.yml` — clone of build-pfplus.yml
  (macOS clang, self-signed cert, rolling `bdplus-latest` release).

Config: `Documents/bdplus.json` line-based key=value; menu writes through
`bd_cfg_set_bool`. Action keys (`money_grant`, `stage_complete`) are consumed
by feature ticks (set→invoke→reset).

## v1.1 hook mechanism — inline code patching added

Critical correction to the v1.0 design: `MethodInfo.methodPointer` swap only
intercepts paths that consult MethodInfo — `il2cpp_runtime_invoke`,
reflection, and delegates created after the swap. IL2CPP compiles ordinary
`call`/`callvirt` sites to direct function calls / vtable slots that never
read `MethodInfo->methodPointer` (vtable `VirtualInvokeData.methodPtr` is
populated at class-init, so post-init swaps don't propagate either). PFPlus's
PAC probe only proved the `runtime_invoke` path — game call sites were never
verified.

`pac_swap.c` v1.1 therefore adds `bd_hook_bool_true` / `bd_hook_int_imm` /
`bd_hook_branch`, which patch the generated code AT the methodPointer
address (slot[0] = runtime VA of the function entry in UnityFramework
__TEXT):

- bool/int getters → `mov w0,#1; ret` or `movz/movk w0,#imm; ret` (8–12B)
- `RewardedVideo.Show`/`ShowWithExt` → `adrp x16; add x16; br x16; nop`
  (16B absolute branch to our grant callback; original not preserved)

Writes go through `mach_vm_write` (kernel-mediated, the debugger
breakpoint mechanism — does not require user-writable text). `dladdr`
verifies slot[0] resolves inside `UnityFramework` before patching.
`sys_icache_invalidate` after each write. On any failure the helpers fall
back to the methodPointer swap, so runtime_invoke/delegate paths are still
covered.

Features converted: spend_free (CheckSpendable/TrySpend), free_iap
(IsPurchased/IsValidProduct/IsProductAvailable/IsPurchaseLimitAvailable/
GetRemainingPurchaseCount=999999999), research_force (IsResearchComplete),
free_rv (Show/ShowWithExt → auto-grant callback).

Open risks for device test:
1. Whether `mach_vm_write` can write UnityFramework __TEXT on the target
   iOS version — if KERN_PROTECTION_FAILURE, all four features degrade to
   methodPointer-swap-only coverage (runtime_invoke paths; most game call
   sites unaffected) and the log will say so per-hook.
2. slot[0]=methodPointer layout on metadata v31 — `dladdr` check + logged
   original bytes make a wrong-offset mistake loud, not silent.
3. PAC signing on arm64e — Unity 2022.3 may or may not sign methodPointer;
   PFPlus v2.2 probe pattern (write-back-same-pointer + exception port) is the
   escalation path if swaps BRK.
4. `bd_find_class_verified` handles nested-type naming (`AdsHelper.Interstitial`
   vs `Interstitial` vs `AdsHelper/Interstitial`) via last-segment match +
   signature-method verification — log will show which resolved.
5. `IsOnSkippedCheat`/`IsBannedUser` server-side effects unknown — telemetry
   flags are re-asserted false client-side; ban review is server-side.

## v1.2 — first on-device log analysis + fixes

Log (bdplus.log, 1031 lines) showed:
- Bridge resolved 22/22 symbols; every class/method resolved with exact
  catalog method counts (CurrencyManager 64, MineManager 70,
  StatUpgradeManager 31, InAppShopManager 26, FuelTank 17).
- methodPointer = image_base + dump.cs RVA confirmed (e.g. Show @
  base+0x3B70FE4).
- ALL inline patches failed: mach_vm_write -> KERN_INVALID_ADDRESS (kr=1)
  on every target. Text pages are not writable via mach_vm_write.
- methodPointer swaps installed fine (MethodInfo pages writable) but only
  reach runtime_invoke/reflection/delegate paths — spend/rv/iap/research
  hooks were therefore inert for normal game call sites.
- Money Obtain "ok" but user saw no balance change — GetAmount/SetAmount
  diagnostics + DEV_ShowMeTheMoreMoney fallback added to find out.
- gc_foreach_heap klass pointers (0x10446xxxx region) never match image
  metadata classes (0x124-0x128xxxxxx) — same failure PFPlus/SPPlus saw.
  Instance features moved to SingletonBase._instance static field reads.

v1.2 changes:
- pac_swap: vm_protect fallback — flip __TEXT page RW, memcpy, restore RX.
  UnityFramework is an app-bundle framework (not PPL-protected platform
  code) so this should succeed where mach_vm_write failed. New helpers
  bd_hook_bool_false (mov w0,#0;ret) and bd_hook_ret_only (ret).
- il2cpp_bridge: +il2cpp_class_get_parent / class_get_field_from_name /
  field_static_get_value; bd_singleton_instance() walks the parent chain
  to the inflated SingletonBase<T>/SingletonBehaviourBase<T> and reads
  the static _instance field.
- feature_money: GetAmount logged around every op; `money` toggle adds a
  ~10s SetAmount(Money, 2e9) pin (infinite money, spend checks pass
  naturally); grant = GetAmount->SetAmount(+10M), DEV fallback.
- feature_fuel: rewritten — code-patches FuelTank.get_IsOilEmpty->false
  and ConsumeOil->ret (covers ALL instances, no discovery needed);
  SetOilToMax poll kept as backup.
- feature_stage: CompleteStage via bd_singleton_instance(MineManager),
  heap walk kept as fallback.
- spend/rv/iap/research: unchanged code — they now get real text patches
  via the vm_protect path; methodPointer swap remains the fallback.
