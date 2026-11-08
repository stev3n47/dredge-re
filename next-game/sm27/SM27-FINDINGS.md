# Soccer Manager 2027 — clean-slate mod (no iOSGods IPA available)

Base: `_Soccer Manager 2027-v4.1.8_AppAssassin.ipa` (clean decrypted) +
`_patched` variant carrying `asignpatch.dylib` (AppAssassin's generic
sideload fix layer: AsignDyldPatch/CloudKit/Subscription/Purchase hooks).
Unity IL2CPP, UnityFramework 148MB, metadata v39 (Unity 6000.x — needed
AndnixSH Il2CppDumper 3.2.1; classic 6.7.46 caps at v31).

## The trick: iOSGods features are the game's OWN ad-reward calls

Every iOSGods button maps 1:1 onto `AdRewardsManager` methods — the same
functions the game invokes after a watched rewarded-ad. Calling them
directly IS the cheat; no patching needed.

Resolution chain (all plain C calls, `this`/info arg may be NULL):
- `AdMobRewardsController.get_Instance()` @ `0x29FE794` → controller
- `controller->adRewardsManager` field @ `+0x48` → AdRewardsManager
- `mgr->playerId` field @ `+0x20` — write target player ID before
  player-scoped rewards (iOSGods resolves last-viewed/boost-screen/squad
  fallback; we resolve via squad picker instead)

| Feature | Method | VA |
|---|---|---|
| Cash Injection | `GiveCashReward` | `0x2A02D40` |
| Team Fitness | `GiveTeamFitnessReward` | `0x2A02A84` |
| Chemistry Reward | `GiveChemistryBoostReward` | `0x2A027B4` |
| Heal Reward | `GiveHealBoostReward` | `0x2A025A4` |
| Fitness Boost | `GiveFitnessBoostReward` | `0x2A023EC` |
| Morale Boost | `GiveMoraleBoostReward` | `0x2A02234` |
| Training Reward | `GiveTrainingReward` | `0x2A02EF4` |
| Facility Reduce | `GiveFacilityUpgradeReduceReward` | `0x2A02088` |
| Stadium Reduce | `GiveStadiumUpgradeReduceReward` | `0x2A030F0` |
| Suspension Boost | `GiveSuspensionBoostReward` | `0x2A026C4` |
| Pre-match Boost | `GivePreMatchPlayerBoostReward` | `0x2A01EEC` |
| Scout Report | `GiveScoutReportReward` | `0x2A02CD8` |
| Profile Scout Rpt | `GiveProfileScoutReportReward` | `0x2A02C70` |

## Squad access (Max-All + player picker)

- `GetCurrentUserClubID()` @ `0x27F7150` → `short` club id (verified in dump)
- `PlayerSquad.GetPlayers(clubId)` @ `0x2D035F0` → PlayerSquad (verified)
- `squad->players` List<PlayerData> @ `+0x18`; List layout: `_items`@0x10
  (Il2CppArray: len@+0x18, items@+0x20), `_size`@+0x18
- `PlayerData : PlayerStaticData : PersonData` — `PersonData.Id`@+0x10,
  `Forename`/`Surname` Il2CppStrings (len@+0x10, UTF16@+0x14)
- Per-player sets: `PlayerData.SetFitness(int)` @ `0x2888C78`,
  `ApplyMoraleBoost(int amount=1, PlayerStatusInfo)` @ `0x28896D4`,
  `ApplyTeamChemistryIncrease(float perc, PlayerData)` @ `0x27D8C44`
  (static — pass playerData arg)

## Cash

`ManagedClub.get_CurrentUserClub()` @ `0x2804410` → `IncreaseBalance
(source, double)` @ `0x282D5FC` — direct write alternative to
GiveCashReward if the latter proves cosmetic/capped.

## Build plan

- `next-game/sm27/SMMenu.mm` — CXMenu chrome (dot/panel/toast) +
  managed-call engine; buttons invoke the VAs via UnityFramework base
- `tools/inject_sm27.py` — inject `SMMenu.framework` LC into the SM27
  exe; clean IPA as base (asignpatch stays optional if sideload issues)
- No LCs to strip, no Unity patch — pure additive injection

## CustomerDataController (Wealth section — v2)

`CustomerDataController` (TypeDefIndex 1760) is the account wallet:
GoldBalance / BoostsBalance / CashTokenBalance / TraitsBalance / XP +
`SpecialEditionStatus` (enhanced/ultimate=V IAP flags).

**Instance resolution** — Unity 6 il2cpp keeps class statics behind the
runtime class object:

    cls      = *(uf + 0x84906F0)          // Il2CppClass* for CDC
    statics  = *(cls + 0xb8)              // static_fields
    cdc      = *(statics + 0x48)          // Instance (dump offset 0x48)
    holder   = *(cdc + 0x20)              // CustomerDataHolder
    data     = *(holder + 0x10)           // CustomerData

Verified against `Awake` (`str x19,[x8,#0x48]` = `Instance = this`) and
`AddCredits` (reads `statics+0x8` = OnCreditBalanceChanged delegate —
dump offset 0x8 — and invokes it via `+0x18` method ptr).

**CustomerData field map** (from getter/setter disasm):

| Field | Offset | Access |
|---|---|---|
| Gold (credits) | `+0xb8` int | `AddCredits(int)` @ `0x2A18808` adds + fires event |
| Boosts | `+0x108` int | `SetCurUserBoostAmount(int)` @ `0x2A188A4` sets |
| CashTokens | `+0x48` int | `SetCashTokenAmount(int)` @ `0x2A18938` sets |
| TraitPoints | `+0xd4` int | `SetManagerTraitPointsAmount(int)` @ `0x2A189CC` sets |
| XP | `+0xe0` → `+0x64` int | direct write (no setter found) |
| Editions | `+0x10` → `+0x10`/`+0x11` bytes | direct write |

`data+0x10` = `SpecialEditionStatus` object: `IsEnhancedEditionUser`@+0x10,
`IsUltimateEditionUser`@+0x11. `IsVIPUser()` @ `0x2A15528` tail-calls
`IsUltimateEditionUser` — VIP == ultimate flag in this build.
`SetCreditAmount(int,string)` @ `0x2A18540` also exists (set+source).

Refresh trick: `AddCredits(cdc, 0)` fires `OnCreditBalanceChanged` —
used after direct writes so the UI redraws.

## Caveats

- These write the *local* CustomerData snapshot. Persistence depends on
  the game's save/sync path (`SaveUserManagerProfile` /
  `FetchLatestCustomerData` may overwrite). Verify on-device.
- VIP/edition flags are local entitlements — no StoreKit receipt is
  generated; server-gated features may still check purchases.
