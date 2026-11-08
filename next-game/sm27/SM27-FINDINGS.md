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
