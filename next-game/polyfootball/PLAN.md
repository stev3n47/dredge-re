# PolyFootball (com.Miceli.Poly 4.5.3) — cheat plan

Target: `com.Miceli.Poly-4.5.3-eeveedecrypter.ipa` (decrypted Unity IL2CPP build).
Game code: `Assembly-CSharp.dll` inside `UnityFramework.framework` — 4,615 game
types (`catalog-types.txt`), Unity 6000.3.9f1 / global-metadata **v39**,
Photon Fusion multiplayer (code lives in `Fusion.Runtime.dll`, **not** in
`Assembly-CSharp.dll`), Unity IAP (`UnityEngine.Purchasing.*`, validator in
`Stores.dll`).

Device install channel: **TBD — user must confirm** (TrollStore vs AltStore /
SideStore vs dev-signed). Self-signed `.ipa` + `insert_dylib` only survives
launch under TrollStore or a developer provisioning profile. AltStore re-signs
and strips arbitrary dylibs unless we repack correctly.

## 0. What changed from v1 of this plan

The draft asserted that swapping `MethodInfo->methodPointer` sidesteps the
CODESIGNING kills PoGo/SPPlus fought. On arm64e iOS 17+ that is **not safe to
assume**: `methodPointer` is likely a PAC-signed function pointer (IL2CPP
builds against Unity 6 commonly sign C function pointers with `ptrauth_key_asia`
plus a per-call discriminator). A raw write of a trampoline pointer trips
`AUTIA` on the next branch. SPPlus's own bridge comment
(`next-game/spooferpro/il2cpp_bridge.c:687`) already says inline-style hooks
fail the hardened-runtime CS check; the plan's "swap is signed therefore fine"
claim is flipped. See §2 for the revised hook strategy.

The catalog method-index citations below are **cross-checked** against
`catalog-types.txt` (type-range contains the index) but are **not** all present
in `catalog-methods-targets.txt` (428 entries only — a subset dump). Names come
from the REA metadata-v39 decode. At boot the dylib resolves every target by
*name*, with the index as a hint only; a name/count mismatch flips the
feature to safe-off.

## 1. Delivery mechanism

`PFPlus.framework` — small ObjC/C dylib injected into the app binary via
`insert_dylib`, running from `__mod_init_func` **before `UnityMain`** so hooks
install before call sites cache. Reused wholesale from SPPlus:

- **`il2cpp_bridge.{c,h}`** — runtime API wrapper (opaque `il2cpp_*` entry points
  resolved from `LC_SYMTAB`). No struct offsets, no `offsetof` on
  `MethodInfo` / `Il2CppClass`. Metadata-version independent.
  `find_unity_image()` already matches `UnityFramework.framework/UnityFramework`
  by name — works unchanged for Poly.
- **`tools/dump_il2cpp_offsets.py`** — emits `il2cpp_offsets_poly_453.h` from
  Poly's UnityFramework `LC_SYMTAB`. Same WANTED list as PoGo covers everything
  we need. Run once per game update.
- **`.github/workflows/build-pfplus.yml`** — clone of `build-spooferpro-plus.yml`.
  Changes: source paths under `next-game/polyfootball/`, dylib install-name
  `@executable_path/Frameworks/PFPlus.framework/PFPlus`, **drop the PoGo
  symbol-IOC grep gate** (it fails on `foreach_heap` / `spp_il2cpp` which are
  anti-tamper IOCs specific to SpooferPro). Keep `strip -x` and self-sign.
- **`tools/inject_polyfootball.py`** — clone of `inject_spooferpro_plus.py`.
  Changes: `FW_NAME = 'PFPlus'`, `FW_ID = 'com.polyfootballplus'`, target IPA
  `com.Miceli.Poly-4.5.3-eeveedecrypter.ipa`, main exe name inside
  `Payload/*.app` (not `PokmonGO`).
- **Config + logs** — `Documents/pfplus.json` (feature toggles, read on boot
  and polled), `Documents/pfplus.log` (ring buffer). Both land in Files.app
  via `UIFileSharingEnabled`.

## 2. Hook strategy — layered, not one trick

### 2a. Primary (Tier 1 economy/unlocks): **poll-and-invoke** via `il2cpp_runtime_invoke`

Proven path from SPPlus. A 10 Hz tick on a dedicated thread calls setter
methods (`set_Balance`, `UnlockPro`, `UnlockAgent`, `UnlockCapIncrease`,
`UnlockTripleTicketBoost`) on the live `PremiumCurrency` instance whenever a
drift from the desired value is observed. Zero code-page writes. Zero PAC
exposure. Zero `MethodInfo` struct reads.

Instance discovery reuses the SPPlus v38 Zenject-provider walk pattern
(`SpooferProPlus.m` / provider-dict → live bag), falling back to a bounded
heap enumeration filtered by `klass == PremiumCurrency`. Instance must be
cached post-menu-load, **not at boot** (Zenject lesson from SPPlus v36).

### 2b. Secondary (Tier 2 dice gates / physics): **`methodPointer` swap, behind a kill switch**

For `Chance`, `Roll`, `Fits`, `Cost`, `CalculateThrowVelocity`, etc., a polled
setter is wrong (there's no setter and the game reads the getter every frame
mid-play). These need a true hook. Approach:

1. **PAC probe at boot.** Read `methodPointer` of a known never-called
   target. Try to re-sign it with
   `ptrauth_sign_unauthenticated(p, ptrauth_key_asia, discriminator)` and
   write back. Call it once from our thread with a Mach exception port
   installed; if we catch `EXC_BAD_ACCESS` with `BRK 0xc470` the PAC case is
   live and all Tier 2 features flip to `disabled_pac_blocked`. If the probe
   survives, Tier 2 is enabled.
2. **Per-ABI trampolines.** Group targets by return type/calling convention
   and ship one trampoline per group (not one generic `uint64_t fn(void*)`):
   - `int32_t(void *self)` — `get_Balance`, `get_GameTicketMultiplier`, …
   - `bool(void *self)` — `get_HasPro`, `get_HasAgent`, `CanPlayThrough`, …
   - `bool(void *self, int32_t)` — `TrySpend`, …
   - `float(void *self, …)` — `Chance`, `ExpectedPerTackle`, `AggravationChance`, …
   - `void(void *self, Vector3 *sret, …)` — `CalculateThrowVelocity` (x8 sret)
   - `void(void *self, …)` — `Roll`, `Mark`, …
3. **Vtable patch for virtuals.** After swapping `methodPointer`, walk the
   class vtable and overwrite any slot whose `.method` matches the old
   `MethodInfo *`. Also walk derived classes (iterate the image's classes,
   check `parent`). `get_HasPro`, `get_HasAgent`, UI-bound getters are likely
   virtual.
4. **Generic methods.** The catalog index points at the generic *definition*;
   runtime calls use instantiated `MethodInfo`s. For any generic target,
   either hook the definition *and* iterate the generic-instance table (needs
   a v39-specific struct read — risky), or fall back to §2a (invoke-style
   write of the resulting state, if a setter exists).
5. **Do NOT swap `invoker_method`.** It's a type-erased thunk used by
   `il2cpp_runtime_invoke` / reflection / serializers. Breaking it corrupts
   save/load paths. Only `methodPointer`.
6. **Thread safety.** 8-byte aligned pointer writes are atomic on arm64.
   Install all swaps before `UnityMain`, serialized through a single install
   thread. No `mprotect` needed — `MethodInfo` lives in writable metadata
   pages, not in the text segment.

### 2c. Tertiary fallback: **state-diff setter sweep**

For any Tier 2 getter we can't safely swap (PAC blocked, virtual chain too
wide, generic instantiation exploded), find a mirror setter or back-store
field and write there on the same 10 Hz tick. Example: `FootballFumbleRules.Chance`
reads a configured float — if the config SO is in the bag, patch the SO once
and no hook is needed at all.

## 3. Feature → hook map (grouped by authority boundary)

### Tier 1 — Economy / unlocks (local-plus-server-mirrored)

`PremiumCurrency` is **type 4130** in `catalog-types.txt`, methods
m30470-m30491 (22 methods). Indices confirmed in-range:

| Feature | Hook | Mechanism |
|---|---|---|
| Unlimited Premium Tickets | `set_Balance` on drift (m30475 area); hook `TrySpend` m30481 → true in Tier 2 | §2a / §2b |
| Pro | `UnlockPro` m30473 once + poll `get_HasPro` m30470 drift | §2a / §2b |
| Triple ticket boost | `UnlockTripleTicketBoost` m30485 + `get_GameTicketMultiplier` m30471 → 3 | §2a / §2b |
| Agent | `UnlockAgent` m30487 + `get_HasAgent` m30488 → true | §2a / §2b |
| Save-cap increase | `UnlockCapIncrease` m30486 + `get_HasCapIncrease` m30490 / `get_GmSaveSlotLimit` m30472 | §2a / §2b |
| Career money / free spending | `CareerTeamBudget.Fits` m9422 → true, `.Cap` m9418/9419 → huge; `CareerSkillCosts.Cost` m9231 → 0, `.Spent` m9232 → 0 | §2b |

**Authority boundary.** `MultiplayerProfileSaveManager` (26 methods) +
`MultiplayerProfileEnvelope` + `MultiplayerProfileSaveData` + a `HttpResult`
type in the catalog = this is a serialize-local → POST-to-backend → server-
canonical-apply pattern. Expect the server to overwrite `HasPro` / `HasAgent`
/ balances on next sync or cold start. Two options:

- **Accept rollback** and re-apply on each session boot (poll-and-invoke
  handles this automatically).
- **Hook the sync**: `MultiplayerProfileSaveManager.Apply*` or equivalent →
  short-circuit the server-canonical write-back so our local flags stand.
  Decide after a device-side probe of the manager's methods.

### Tier 1.5 — IAP receipt validator (prerequisite for durable Pro)

`UnityEngine.Purchasing.CrossPlatformValidator` lives in `Stores.dll` (not in
`Assembly-CSharp.dll`, not catalogued yet). Without touching it, flipping
`UnlockPro` locally will get re-locked next time the Apple receipt is
validated at launch. **Action**: resolve `Stores.dll` image at boot, find
`CrossPlatformValidator.Validate` / `AppleValidator.Validate`, hook to return
success. Add before v1 ships, or Tier 1 is a one-session trick.

### Tier 2 — Dice-roll gates (single-player safe; **multiplayer-gated off**)

All `Chance` / `Roll` / `Break*` / `Catch*` / throw-velocity hooks. Indices
spot-checked against `catalog-types.txt` type ranges:

| Feature | Hook | Notes |
|---|---|---|
| No Fumbles (live) | `FootballFumbleRules.Chance` m17791, `ExpectedPerTackle` m17792, `PunchTryChance` m17793 → 0 (type 2424) | float return |
| No Fumbles (sim) | `FootballFumbleSim.DriveChance` / `DriveRoll` / `PerTackle` m17801-m17807 → 0 (type 2427) | |
| No Injuries (live) | `FootballTackleInjuries.Mark` m19618, `StaysDown` m19622 → neutralize; `InjuryCatalog.Roll` m24445 → none; `AggravationChance` m24450 → 0 | names confirmed in `catalog-methods-targets.txt:12,17` |
| No Injuries (sim/career) | `CareerInjuryRecovery`, `FranchiseInjuryCare`, `CareerInjuryDecision`, `CpuDriveInjury`, `FranchiseInjuryRules` rolls → none | |
| Never Tackled | `FootballCarrierMoveRules.BreakChance`/`ShoveChance`/`AnkleBreakChance`/`SpinEscapeChance` m16914-m16921, m16871 → 1.0 for our carrier only; or `FootballTackleStyle.Pick` m20565 → whiff vs our team | **needs team discriminator** (§5) |
| Magnet Hands | `FootballCatchReach.TrySolve`/`Confidence`/`InFront` m16986/m16985/m16982 → always succeed for our team; `FootballCatchStyle.RollState`/`Rng` m16998/m17011; `CareerWrCatchRules` (11 at m11213) | **needs team discriminator** |
| Cannon Arm | `ThrowController.CalculateThrowVelocity` m32724, `CalculateBallisticVelocity` m32679, `CalculateBulletVelocity` m32706, `CorrectUnderthrowVelocity` m32670 → scale output ~1.75x (names confirmed `catalog-methods-targets.txt:225,248,257,284,302`) | Vector3 sret ABI — special trampoline |
| Super Speed | locomotion speed scalar — `FootballCarrierMoveRules`, `CarrierMoveControls` (15 at m7947), `FootballJoystickLocomotion`, `FootballDefenseSpeeds`; `GetPocketMoveSpeedMultiplierForCurrentCareerArchetype` m32647 as reference pattern (plain method, **not** a `get_*` auto-property — naming in draft was misleading) | exact field TBD on device |

**Multiplayer gate (mandatory).** Catalog shows a *deterministic* MP model:
`MultiplayerPlayMirrorCodec`, `MultiplayerPlayMirrorDriver`,
`MultiplayerPlayMirrorTimeline`, `OnlinePlayClock`,
`MultiplayerMatchPlayerSnapshot`, `MultiplayerMatchStatLine`,
`MultiplayerResultsSummary`. This is snapshot-and-replay, not Fusion-free-sim.
Local physics overrides change nothing the opponent sees; the authoritative
mirror snaps our view, Cannon Arm desync-snaps visibly, and outlier stats get
uploaded. **Every Tier 2 hook short-circuits to no-op when a match is
active**, keyed on `MultiplayerLobbyStateNetwork` / `MultiplayerMatchRuntimeContext`
state. Also neutralize `MultiplayerVersionRules` to avoid version-gate kick
if a serializer-adjacent hook misbehaves.

### Tier 2.5 — High-leverage targets not in draft v1

Flagged by catalog audit; verify on-device before enabling:

- **XP boost / free progression** — `CareerXpBoost` (12 methods at m11224),
  `CareerXpProgression` (7 at m11236). Direct player-dev gate.
- **Contract / salary** — `CareerContractNegotiation` (40 at m2753),
  `CareerNegotiationSheet` (33 at m6865), `CareerContractExtension` (10 at
  m2711), `CareerContractIncentives` (18 at m2721), `SalaryRules` (3 at
  m31560), `FranchiseContractRules` (20 at m21189). `CareerTeamBudget.Fits`
  alone does not cover contract offers or cap holds.
- **Scouting reveal** — `FranchiseScoutingService` (11 at m23601),
  `ProspectScoutReport`. "See hidden ratings" cheat.
- **Draft** — `CareerRookieDraftBoard` (1 at m8906). Single method; possibly
  reveal/reroll.

### Tier 3 — Stats scrubber (if physics cheats ever run in a session that uploads)

Hook `MultiplayerResultsSummary` / `MultiplayerMatchStatLine` getters or
serialize path to cap outliers before upload. Opt-in; defense in depth.

## 4. Remaining on-device unknowns

- **Team discriminator** for Never Tackled / Magnet Hands: carrier/receiver
  team flag (likely `IsDefender` or `TeamId`). One runtime inspect pass; the
  hook must branch so the cheat only helps us.
- **Run-speed scalar** location on the athlete/carrier object: field dump via
  `il2cpp_class_get_fields` on `FootballCarrierMoveRules` / sibling classes.
- **Career cash balance field**: `PlayerSaveData` / `CareerSaveData` money
  field — `Fits`/`Cost` hooks cover most spends, but on-screen display may
  still show the real value. Low priority if §2a drives balances.
- **Stores.dll** image — confirm it's loaded and resolvable as a separate
  `Il2CppImage` (not merged into `Assembly-CSharp`).
- **`Fusion.Runtime.dll`** — catalog contains zero `Fusion.*` /
  `NetworkBehaviour` / `[Networked]` entries. For any claim about Fusion
  prediction/rollback behavior, resolve that image first and dump its types.
  The `MultiplayerLobbyStateNetwork` wrapper (648 methods) is where
  `[Networked]` setters and `Rpc_*` methods live and is the real auth-write
  surface.
- **Full-metadata grep for anti-tamper**: `catalog-methods-targets.txt` is a
  428-entry subset; a full dump should be grep'd for `Receipt` / `Verify` /
  `Validate` / `Signature` / `Hash` / `Checksum` / `AntiCheat` / `Tamper`
  before any ship.

## 5. Rollout — phased with acceptance criteria

The draft's v1→v3 ladder presumed load, resolve, and hook all work on first
try. SPPlus v28→v39 (11 builds) says otherwise. Insert the groundwork phases
SPPlus should have had:

- **v0 — Load check.** Inject, `__mod_init_func` writes `"PFPlus up"` to
  `Documents/pfplus.log`, zero IL2CPP calls. **Accept**: game boots, log
  present, no re-sign crash. Captures the AltStore-vs-TrollStore question
  early.
- **v0.5 — Anti-tamper recon.** Enumerate `_dyld_image_count()`, grep names
  and nearby strings for `SpooferPro` / `Tamper` / `Integrity`, log Unity base
  address + a few opcode slices, exit. **Accept**: report filed in
  `POLYFOOTBALL-FINDINGS.md`; no hostile dylib or BRK gate detected.
- **v0.7 — Bridge resolve.** `il2cpp_domain_get` → `Assembly-CSharp` image →
  `PremiumCurrency` class; log `method_count`; assert matches catalog's
  method range (22). **Accept**: counts match; mismatch flips safe-mode and
  logs the delta.
- **v0.9 — Read-only probe.** Find the live `PremiumCurrency` instance
  post-menu (not at boot — Zenject lesson); call `get_Balance` via its own
  `methodPointer` (read, no write) through `il2cpp_runtime_invoke`; log the
  value. No swaps yet. **Accept**: real menu balance appears in log.
- **v0.95 — PAC probe (§2b step 1).** Writes back the same pointer to a
  never-called method, calls it, catches `BRK 0xc470` in a Mach exception
  handler. Flips the dylib feature matrix. **Accept**: log says
  `pac_mode=blocked` or `pac_mode=ok` before v1a runs.
- **v1a — One Tier 1 hook, poll-style.** Only `set_Balance` on drift, via
  §2a. JSON toggle. Counter in menu. **Accept**: 100 in-game purchases, log
  shows balance restored each tick, no crash over 10-minute session.
- **v1b — Pro / HasPro.** Add `UnlockPro` + poll `get_HasPro`. **Accept**:
  menu reflects Pro state.
- **v1c — Remaining PremiumCurrency.** Full Tier 1 via §2a.
- **v1d — IAP validator** (Tier 1.5). Hook `CrossPlatformValidator.Validate`.
  **Accept**: cold start retains Pro.
- **v1e — Server-sync hook decision.** Based on
  `MultiplayerProfileSaveManager` device probe: either hook its apply path or
  accept rollback + auto-re-apply.
- **v2a — Tools groundwork before physics.** `tools/regen_catalog.py` (names
  the exact REA invocation — current `tools/pf_extract_methods.py` /
  `pf_keywords.py` have hardcoded Windows paths and are not reproducible),
  save-slot backup on first new-version boot, menu "safe mode" toggle (reads
  a crash-marker file written pre-hook, deleted after first tick).
- **v2b+ — Dice gates**, one hook per release behind its own toggle, each
  with fire counter + last-value sample in the menu. **Accept per feature**:
  toggle-off restores vanilla in-session; no crash over 30-min career sim;
  multiplayer-active gate verified against an online exhibition match.
- **v3 — Team discriminator, run-speed scalar, Tier 2.5 (XP / contracts /
  scouting / draft), MP-behavior notes, Tier 3 stats scrubber.**

## 6. Observability & safety rails

- **Per-hook counters.** `static struct { uint64_t fires; uint64_t last_in;
  uint64_t last_out; uint32_t last_err; }` per target. Menu pane dumps them
  live. Two hours of silent debugging in SPPlus (v23) was fixed in 20 lines
  of counter.
- **JSON kill switch.** `pfplus.json` read on boot *before*
  `il2cpp_class_from_name`, and polled on the 10 Hz tick for runtime toggle.
  Per-feature off means the hook is reverted to the saved original
  `methodPointer` (keep the originals in a table).
- **Crash-marker file.** Written before first hook install, deleted after
  first successful tick. On boot, if present → safe mode (no hooks, menu
  still loads).
- **Save backup.** Before first hook on a new game version, copy the career
  save aside. Covered in v2a.
- **Device logs.** `pfplus.log` ring buffer in `Documents/` — pull via
  Files.app. SPPlus crash-collection path
  (`debug/crashes/polyfootball-*.ips`) reused.

## 7. Static-addresses note (demoted)

`tools/macho_chained_fixups.py` decodes all 219k rebases if static addresses
are ever wanted (e.g. pre-ASLR disassembly). `MethodInfo *` holds the runtime
function pointer already resolved, so **static addresses are not needed for
the hook**. Left here as a one-line pointer; previous plan over-emphasized it.

## 8. Files touched / to add

- `next-game/polyfootball/PFPlus.m` (new) — cloned from `SpooferProPlus.m`.
- `next-game/polyfootball/il2cpp_bridge.c` / `.h` — copied from
  `next-game/spooferpro/` unchanged.
- `next-game/polyfootball/il2cpp_offsets_poly_453.h` — generated via
  `tools/dump_il2cpp_offsets.py` on Poly's UnityFramework.
- `.github/workflows/build-pfplus.yml` — cloned from
  `build-spooferpro-plus.yml`; symbol-IOC grep gate dropped.
- `tools/inject_polyfootball.py` — cloned from `inject_spooferpro_plus.py`
  with new `FW_NAME`, `FW_ID`, IPA, exe name.
- `tools/regen_catalog.py` — new; wraps the REA invocation that produced
  `catalog-types.txt` / `catalog-methods-targets.txt` so updates are
  reproducible.
- `next-game/polyfootball/POLYFOOTBALL-FINDINGS.md` — new; v0.5 recon report,
  on-device unknowns, per-version offset deltas.
