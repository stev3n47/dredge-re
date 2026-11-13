# Polytopia (Super Tribes) 2.18.0 — PTPlus feature plan

Source IPA: `com.felixrum.supertribes-2.18.0-eeveedecrypter.ipa`
Bundle: `Payload/Polytopia.app`, executable `Polytopia` (88KB stub), engine in
`Frameworks/UnityFramework.framework/UnityFramework`.
Unity IL2CPP, **global-metadata v39** (same as PolyFootball — REA + methodPointer
swap pattern proven there transfer directly).
Metadata: `Data/Managed/Metadata/global-metadata.dat` sha256
`e86462f23abbcffae6cfed31572d87a0c6d875460ce46fc50782a22b0598279c`
17,280 types / 117,030 methods / 74,393 fields / 25,655 literals / 148 images.

Extras vs PolyFootball: `EOSSDK.framework` (Epic Online Services), Firebase
(App/Messaging/Analytics), `Microsoft.AspNetCore.SignalR.*` (live multiplayer),
Unity.Purchasing (+Stores +Security) IAP.

## Image map

| image | types | role |
|---|---|---|
| PolytopiaAssembly.dll | 0–1912 | UI, purchase layer, startup, skin visuals, debug ctrls |
| GameLogicAssembly.dll | 10568–11000 | match sim — actions, GameState, PlayerState, map gen |
| PolytopiaBackendBase.dll | 11198–11846 | backend/lobby/SignalR multiplayer surface |
| Unity.Purchasing*.dll | 13954+/14315+/16141+ | Unity IAP framework |
| DebugOverlay.dll | 16420+ | 16 types — debug UI |

## Purchase architecture (PolytopiaAssembly)

```
PurchaseManager (t741, ms3645, 43m)         — the gate everyone calls
  get_PlatformPurchaseManager  m3646        — impl selector
  SetupPlatformPurchaseManager m3650
  GetUnlockedTribes m3652 / GetUnlockedSkins m3653
  IsTribeUnlocked m3658 / IsSkinUnlocked m3659   ← THE unlock checks
  GetUnlockedDifficulties m3645
  PurchaseProduct m3666 / RestorePurchases m3669
  GetPreunlockedTribes m3670 / IsAnythingBought m3671

IPlatformPurchaseManager (t734, iface)      — IsProductUnlocked m3602 et al
  EverythingUnlockedPlatformPurchaseManager (t733, ms3586, 12m)
      — dev build impl; IsProductUnlocked m3590 presumably always true
  SteamPlatformPurchaseManager (t743)
  UnityPlatformPurchaseManager (t746, real IAP)

PurchaseCache (t736, ms3610, 27m)           — persisted unlock list
  GetUnlockedTribes m3610 / GetUnlockedSkins m3631
  TryUpdateServerUnlockedTribes m3611 / Skins m3632   ← server can overwrite
  TryUpdateIAPUnlockedTribes m3612 / Skins m3633
  WriteUnlockedTribes m3616 / WriteUnlockedSkins m3617
  GetChecksum1-4 m3620-23, VerifyChecksum m3630       ← anti-tamper checksums
```

## Game-sim architecture (GameLogicAssembly)

```
GameState (t10782, ms80584, 80m) — match root; get_PlayerStates m80602,
    get_Map m80600, get_CurrentPlayer m80616, get_CurrentTurn m80590
PlayerState (t10790, ms80742, 26m)
    get_Currency m80753 / set_Currency m80754   ← STAR BALANCE (instance!)
    get_AutoPlay m80748 — human-vs-AI discriminator field
UnitState (t10793, ms80771)
    CanAttack m80780 / CanMove m80781 / IsFreezable m80782 /
    IsInvisible m80783-84 / GetFullCost m80791
PlayerExtensions (t10848, ms81220, 30m) — static, self=PlayerState arg0
    HasTech m81234 / HasTribeAbility m81235
    CountCities m81226 / GetScore m81243/46 / GetDefenceBonus m81232
ActionUtils (t10591, ms78762, 61m) — the sim library
    LearnTech m78765 / TrainUnit m78770 / LevelUpCity m78798
    TryRevealAllCapitals m78810 / ExploreTile m78785
IncreaseCurrencyAction (t10643, ms79396) — the earn path
MapGenerator (t10825, 68m) / MapGeneratorPreNaval (10835, 42m)
CityReward m10735 / CityRewardData m10736
```

## Feature candidates (evidence-ranked)

### T1 — content unlocks (the IAP money content)
1. **All Tribes** — hook `PurchaseManager.IsTribeUnlocked` → true.
   One swap covers tribe picker, match setup, bot tribes. The game sells
   tribes individually — this is the main paid content.
2. **All Skins** — hook `IsSkinUnlocked` → true. Tribe skins are also IAP.
3. **All Difficulties** — `GetUnlockedDifficulties` returns a collection —
   needs a look at the return type; defer if it's not a simple bool/int.
4. Alternative: swap `get_PlatformPurchaseManager` to fabricate a
   `EverythingUnlockedPlatformPurchaseManager` instance — more moving parts,
   same effect. Prefer (1)+(2).
5. Watch: `TryUpdateServerUnlocked*` — server may re-write the cache on
   profile sync. Hooks on Is*Unlocked are evaluated at call time so server
   writes don't matter unless the game caches the verdict. `PurchaseCache`
   checksums only guard the persisted file — we don't touch it.

### T2 — in-match cheats (single-player first; MP-unsafe ones gated)
6. **Unlimited Stars** — `PlayerState.get_Currency` → return 999,999.
   Instance method on every player INCLUDING AI. Needs a self-check
   trampoline: cache the human PlayerState* (heap-walk once, filter
   `get_AutoPlay()==false` or `get_Id()==local`), return huge only when
   x0==human, else jmp original. Second option: hook
   `IncreaseCurrencyAction.Execute` to multiply the gain — still affects
   whoever earns, but AI earning is rarer. Cleanest: the self-check tramp.
7. **Free/All Tech** — `PlayerExtensions.HasTech` → true makes UI show all
   techs owned, but real tech *effects* live elsewhere (abilities are
   checked via HasTribeAbility/HasAbility per effect). Treat as
   unlock-the-tree visual unless device test shows effects follow.
   `ActionUtils.LearnTech` is the real grant — could invoke per-tech.
8. **Units always act** — `UnitState.CanAttack`/`CanMove` → true.
   Also instance-per-unit — same self/owner problem as stars; AI units get
   it too unless we check owner. Defer until self-check tramp exists.
9. **Defence bonus** — `GetDefenceBonus` → big number. Same owner problem.

### T3 — map/fog
10. **Reveal map** — `ActionUtils.TryRevealAllCapitals` exists (invoke it?),
    `ExploreTile`/`ExploreFromTile` reveal per-tile. Full-map reveal =
    iterate map tiles calling the explore path, or hook the fog-side
    visibility getter (find `Tile.IsExplored`/`IsVisible` getter on device).
    Medium effort.

### Diagnostic extras
11. `DebugCommands` (t370) is only modifier-key plumbing — the real cheat
    layer, if any, keys off `IsDebugModifierDown`+taps at runtime. Not a
    feature target by itself.
12. EOS/SignalR multiplayer: `PolytopiaBackendBase` lobby classes — MP
    desync/ban risk is real; ALL T2/T3 hooks get an mp_safe gate and we
    default to OFF for MP until SP evidence shows turn validation is lax.

## Build notes

- Same pipeline as PFPlus: `STPlus.dylib` + `LC_LOAD_DYLIB` into the stub
  `Polytopia` exec + `Frameworks/STPlus.framework`. Injector can fork
  `tools/inject_polyfootball.py` (it already auto-discovers bundle+exe).
- il2cpp bridge + main-runloop tick + pac_swap + UIKit menu all transfer —
  PFPlus v2.5.x is the reference architecture; rebrand + retarget.
- `mp_safe` flag must gate T2/T3 — Polytopia multiplayer is real-time via
  SignalR with server-side replay; desync is detectable.
