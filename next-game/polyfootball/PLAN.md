# PolyFootball (com.Miceli.Poly 4.5.3) — cheat plan

Target: `com.Miceli.Poly-4.5.3-eeveedecrypter.ipa` (decrypted Unity IL2CPP build)
Game code: `Assembly-CSharp.dll` inside `UnityFramework.framework` — 4,615 game types
(`catalog-types.txt`), Unity 6 (metadata v39, Unity 6000.3.9f1), Photon Fusion
multiplayer (`Fusion.*`, `Photon3Unity3D`), Unity IAP (`Unity.Purchasing.*`).

## Delivery mechanism (proven pattern from SpooferPro work)

`PFPlus.framework` — a small ObjC/C dylib injected into the app executable via
`insert_dylib`, running from `__mod_init_func`. Same architecture as SPPlus:

1. **Resolve** — `il2cpp_domain_get` -> assemblies -> `Assembly-CSharp` image ->
   `il2cpp_class_from_name` -> `il2cpp_class_get_method_from_name` gives
   `MethodInfo*`. All metadata walks = pure data reads, no managed dispatch.
2. **Hook** — swap `MethodInfo->methodPointer` (and `invoker_method`) to our C
   trampoline. Game call-sites then run our code through the normal signed call
   chain; we never need `il2cpp_runtime_invoke`, sidestepping the CODESIGNING
   page kills seen on PoGo. Trampolines live in our signed dylib.
3. **Config/UI** — JSON config file + in-game menu skeleton from SPPlus.
   Every cheat individually toggleable.

Method indices below are global-metadata indices (`catalog-methods-targets.txt`,
`catalog-types.txt` has every type's method_start/method_count for more).

## Feature -> hook map

### Tier 1 — Economy/unlocks (safe, all in one class)

`PremiumCurrency` (type 4129) is the single hub for nearly the whole paid list:

| Feature | Hook | Effect |
|---|---|---|
| Unlimited Premium Tickets | `get_Balance` (m30474) -> return big; `TrySpend` (m30481) -> return true w/o decrement | max balance, purchases free |
| Pro | `get_HasPro` (m30470) -> true (or call `UnlockPro` m30473 once) | Pro unlocked |
| Triple game tickets | `get_GameTicketMultiplier` (m30471) -> 3; `get_HasTripleTicketBoost` (m30483) -> true / `UnlockTripleTicketBoost` m30485 | 3x tickets |
| The agent | `get_HasAgent` (m30488) -> true / `UnlockAgent` m30487 | agent unlocked |
| Save cap | `get_HasCapIncrease` (m30490) -> true / `UnlockCapIncrease` m30486; `get_GmSaveSlotLimit` (m30472) -> big | save slots uncapped |
| Unlimited money & skill points | `CareerTeamBudget.Fits` (m9422) -> true, `.Cap` (m9418/9419) -> huge; `CareerSkillCosts.Cost` (m9231) -> 0, `.Spent` (m9232) -> 0 | everything affordable, free upgrades |

`TrySpend` alone gives "nothing you buy costs you any" even if get_Balance is
display-only. Skill-point balance also likely in `PlayerSaveData`/
`CareerPlayerDevelopment` (24 methods) — verify on device.

### Tier 2 — Dice-roll gates (single-value returns, low risk)

| Feature | Hook | Effect |
|---|---|---|
| No Fumbles (live) | `FootballFumbleRules.Chance` (m17791) / `ExpectedPerTackle` (m17792) -> 0; also `PunchTryChance` (m17793) | ball never pops loose on contact |
| No Fumbles (sim) | `FootballFumbleSim.DriveChance`/`DriveRoll`/`PerTackle` (m17801-17807) -> 0 | sim stats clean |
| No Injuries (live) | `FootballTackleInjuries.Mark`/`StaysDown` (m19618/m19622) -> neutralize; `InjuryCatalog.Roll` (m24445) -> none; `AggravationChance` (m24450) -> 0 | nobody gets hurt |
| No Injuries (sim/career) | `CareerInjuryRecovery`, `FranchiseInjuryCare`, `CareerInjuryDecision`, `CpuDriveInjury`, `FranchiseInjuryRules` rolls -> none | sim/career rosters stay healthy |
| Never Tackled | `FootballCarrierMoveRules.BreakChance`/`ShoveChance`/`AnkleBreakChance`/`SpinEscapeChance` (m16914-16921, m16871) -> 1.0 for OUR carrier only; or `FootballTackleStyle.Pick` (m20565) -> whiff vs our team | our side always breaks/wriggles free |
| Magnet Hands | `FootballCatchReach.TrySolve`/`Confidence`/`InFront` (m16986/16985/16982) -> always succeed for our team; `FootballCatchStyle.RollState`/`Rng` (m16998/17011); `CareerWrCatchRules` (11 methods at 11213) | our receivers catch anything near |
| Cannon Arm | `ThrowController.CalculateThrowVelocity` (m32724), `CalculateBallisticVelocity` (m32679), `CalculateBulletVelocity` (m32706) -> scale output ~1.75x; `CorrectUnderthrowVelocity` (m32670) | harder, further throws |
| Super Speed | carrier move-speed scalar — `FootballCarrierMoveRules`/`CarrierMoveControls` (15 at 7947)/`FootballJoystickLocomotion`/`FootballDefenseSpeeds` — speed getter TBD on device (likely a multiplier like `get_PocketMoveSpeedMultiplierForCurrentCareerArchetype` m32647 pattern) | ~1.9x run/turn |

### Remaining unknowns to resolve on-device

- **Exact "our team vs theirs" discriminator** for Never Tackled / Magnet Hands:
  each hook must check the carrier/receiver's team flag (IsDefender / team id
  on the object) so the cheat only helps us — needs one runtime inspect pass.
- **Run-speed scalar**: the locomotion speed value lives on the carrier/athlete
  object; find via fields dump or a `get_*Speed*` method at runtime.
- **Career cash balance field**: `PlayerSaveData`/`CareerSaveData` money field —
  patch `Fits`/`Cost` covers most spends; display value may need the field write.
- **VIP scope in multiplayer**: Fusion-shared sim means local hooks affect the
  local simulation. Stats/unlocks server-verified paths may desync or be
  ignored remotely; live-game physics cheats affect our own simulation inputs.

## Build/test loop (Claude remote-friendly)

- Same pipeline as SPPlus: edit `next-game/polyfootball/PFPlus.m` +
  `il2cpp_bridge.c` (reuse PoGo bridge — image/type/method resolution is
  game-agnostic), CI workflow `build-pfplus.yml` builds `PFPlus.dylib`, I inject
  into IPA (`tools/inject_polyfootball.py` — adapt inject_spooferpro_plus.py)
  and push to a GitHub release for device install.
- Commits on `claude/*` branches -> I merge/release as before; crashes go to
  `debug/crashes/polyfootball-*.ips`, logs `pfplus.log`.
- Catalogs on disk for grep: `catalog-types.txt` (4,615 types w/ method ranges),
  `catalog-methods-targets.txt` (428 target methods so far). More slices via
  REA `inspect_il2cpp_metadata` views (metadata v39 decoded, no registration
  structs needed for names; native RVAs come from runtime, not static — the
  Mach-O uses chained fixups which REA/dumpers don't decode, but our own
  `tools/macho_chained_fixups.py` now decodes all 219k rebases if static
  addresses are ever needed).

## Suggested rollout

1. **v1**: PremiumCurrency hooks only (all unlocks + tickets) — one class, zero
   gameplay risk, instantly verifiable on the menu screen.
2. **v2**: dice gates — fumbles, injuries, tackle-break, catch-reach, throw
   velocity, speed scalar (all `return-constant` style).
3. **v3**: refinement — team discriminators, values tuning, career money field,
   MP behavior notes.
