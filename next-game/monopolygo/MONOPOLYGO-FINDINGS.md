# MONOPOLY GO — reverse engineering notes

Source IPA: `com.scopely.monopolygo-1.82.0-eeveedecrypter.ipa` (decrypted,
Scopely, bundle `MONOPOLYGO`). Unity IL2CPP, **Unity 6 / metadata v39**
— Il2CppDumper 6.7.46 fails (`not a supported version[39]`); used
`tools/bin/sm27-dumper/cli/Il2CppDumper-3.2.1-win-x64` (self-contained,
works, detects "6000.3.0b1+, variable-width index mode").

- Binary: `Payload/MONOPOLYGO.app/Frameworks/UnityFramework.framework/UnityFramework` (129.5 MB)
- Metadata: `Payload/MONOPOLYGO.app/Data/Managed/Metadata/global-metadata.dat` (32.8 MB)
- Extracted to `next-game/monopolygo/ipa/`; dump at `next-game/monopolygo/dump/`
  (dump.cs, script.json, stringliteral.json, il2cpp.h, DummyDll/)

⚠️ Integrity surface: `Frameworks/PlaygamiSwizzler.framework` +
`PlaygamiSwizzlerConfig.plist` (Scopely method-swizzler SDK) and
`withbuddies_integrity_ios.framework` ship in the app — expect
anti-tamper swizzles. `Datadog*` + `HelpshiftX` telemetry also present.

## Goal: "see the next roll"

### The roll pipeline (client-authoritative dice)

Rolls are generated **on the client**, then shipped to the server for
validation/execution:

- `RollClientActionV2` (dump.cs ~595399, TypeDefIndex 15433) —
  `[ProtoMember(2)] int[] RollResult` @ field `0x80`: the client computes
  the dice faces and *sends them*. Also carries `RollMultiplier`,
  `FeatureToggles`, `FriendCount`, `IsAutoRoll`, `TutorialKey/Step`.
- Executor: `RollCommonExecutor : CommonExecutor<RollClientActionV2, DefaultResult>`
  (TypeDefIndex 15419) — `ExecuteAsync` RVA **0x4CBE594**, MoveNext RVA
  **0x4CBF92C**. State machine shows: boardState → rollMultiplier →
  `RollResult <roll>` → `finalTileIndex` → `IsAcceptableTokenPosition(...)`
  gate (tutorial-time re-roll filter for banned tiles) → MoveSubResult.
- Dice math: `Roll.RollDice(Die[] dice, IRandom)` RVA **0x5292FAC**,
  `ProduceRollResultForDice` 0x5293050, `RollDie` 0x529314C → returns
  `RollResult{ int[] DiceResults; RollCombination BestCombination; bool Jackpot }`.
  `Die.Standard`/`StandardDice`/`ThreeDices` statics.
- Response echo: `RollSubResult` (TypeDefIndex 22822) `{ int[] Roll; int Multiplier }`,
  `RollActionResult.Dice`, `RollActionSubResult` (RollMultiplier +
  StartingMoney/Rolls/Shields/TileIndex analytics).

### The RNG — deterministic, server-synced

`PierPlay.Common.PseudoRandom : System.Random` is a **CMWC** generator
(fields `uint[] Q` @0x20, `uint c` @0x28, `uint i` @0x2C, `Stage` @0x30;
`SetSeed(long)`, `Cmwc()` at 0x2557134).

`BoardState` (TypeDefIndex 21570) carries the shared RNG state:
- `RandomStates : List<RandomState>` @ **0x30** (ProtoMember 6)
- `ScriptedRolls : List<int>` @ **0x60** (ProtoMember 17)

`RandomState` = `{ string Context; int State; long Seed; long Iteration }`.
`StatefulRandomFactory` maps context → `RandomStateDecorator` /
`CappedRandomStateDecorator` (IRandom wrappers; ctor overload
`(RandomState, Nullable<int> offset)` at 0x2559438 — built for lookahead).
Server validates: error codes **`RngIndexMismatch` (-72530)** and
**`PendingRollsMismatch` (-72521/-72541)**; plus
`RollIntegrityGameStateBasedTerm` anti-cheat terms (Time, RollMultiplier,
BoardPosition, DeviceId, LastAppOpen, CashRollBalance, RollBalance).

### Seams for "see next roll" (best → fallback)

1. **`BoardState.ScriptedRolls` (0x60)** — `List<int>` of upcoming roll
   *distances*, pushed by the server inside `ChangeSet.BoardChanges`
   (`BoardStateChanges.ScriptedRoll` ProtoMember 6, `ClearScriptedRolls`
   ProtoMember 7). Populated during board transitions / post-shield /
   tutorials; when non-empty this is literally the upcoming totals.
   `UpdateScriptedRollsSequence` (TypeDefIndex 13417) applies updates.
   `ScriptedRoll{Distance, ScriptedDouble}` config +
   `RollScriptingLogic.GetRollsFromDistance(s)` map distance → die faces.

2. **`RollClientActionV2.set_RollResult` (RVA 0x4CCA180)** — patch/hook
   point: read `int[]` the instant the client finalizes a roll, before
   the animation/network round-trip. This is the cheapest reliable
   "you're about to roll X+Y" display.

3. **RNG lookahead** — clone `BoardState.RandomStates`, feed the dice
   context into `PseudoRandom`/`RandomStateDecorator(state, offset)`,
   call `Roll.RollDice` locally → forecast N upcoming rolls. Needs the
   dice context string + confirming which decorator/path the real roll
   uses (disasm `RollCommonExecutor.ExecuteAsync` MoveNext @0x4CBF92C —
   not yet pulled).

### Cheat-flavored seams (control, not just see)

- `CheatAddExtraScriptedRolls` — static bool, backing field at
  dump.cs ~555406 (in `ValidateScriptedRollLogic`-adjacent class).
- `[DebugClientAction]` actions exist, e.g.
  `DebugPickBoardRaidPlayerClientAction` (tag 803) with
  `VisitorDiceOverrides`/`BoardOwnerDiceOverrides` — server may or may
  not accept debug actions on prod.
- `ScriptedRandom : PseudoRandom` — replays a scripted `List<double>`
  (test hook).
- `ScriptedRollsAllowed`/`ScriptedRollsAdded` counters (~555943/556028)
  imply server-side quota tracking on scripted-roll injection.
- `IsAcceptableTokenPosition(boardState, layout, tutorialState, int[])`
  RVA 0x4CBEBAC — client-side roll *rejection* filter; worth checking
  whether it re-rolls client-side (loop) since it would distort any
  naive RNG lookahead.

### Other notes

- Dice visuals are cosmetic: `RollReplayBundleManager` selects a
  pre-recorded physics replay per landing tile (MaxReplaysPerTile=25,
  JailIndex=40, NumIndices=41) and `DicePhysicsUtility.
  ApplyRotationsForExpectedOutcomes` forces final faces — the number is
  decided in code before the dice finish tumbling.
- `Roll.RollsToBeCharged`, `CalculateDoublesReward`, `GetBestRollCombination`,
  `GetJackpot` client-side mirror of server reward math.
- Old `RollClientAction` (tag 1) is `[Obsolete("use RollClientActionV2")]`.
- `PendingRolls` shows up on tile-mechanic sub-results
  (`HarvestTileOnLandSubResult`, `HarvestTileSubResult`) — pending-roll
  counts are validated server-side too.
- `RollFlowTelemetry(rollId, multiplier, startedAsAutoRoll)` phases —
  every roll is telemetry-tagged; `ClientActionsMetricsProvider` keeps
  last 201 actions (goes to Bugsnag/Datadog). A menu feature should avoid
  spamming rolls.

### Confirmed by disasm (Capstone, MoveNext @0x4CBF92C)

`RollCommonExecutor.<ExecuteAsync>d__3` fields (dump.cs ~594880):
`boardState`@0x38, `rollMultiplier`@0x40, `compA`@0x44, `compB`@0x48,
`roll`@0x50.

Exact roll flow, verified instruction-level:

1. `rollMultiplier = boardState.RollMultiplier` (interface slot 20);
   `compA = rollMultiplier * 0x53 (83)`,
   `compB = boardState.TokenPosition * 0x49 (73)` (interface slot 6).
2. If `IsNullOrEmpty(action.RollResult)` is false — i.e. **`RollResult`
   is already populated on the action** (field +0x80) — the executor
   SKIPS generation entirely and just computes
   `GetBestRollCombination`/`GetJackpot` over the supplied dice.
   **Force-dice seam: pre-set `action.RollResult` before dispatch and the
   client ships your chosen values.** Server integrity terms
   (`RollIntegrityGameStateBasedTerm`, `RngIndexMismatch`,
   `PendingRollsMismatch`) may still reject them — needs live test.
3. Otherwise:
   `random = BoardStateLogic.GetRandomWithOffset(boardState, "DICE_ROLL",
    (compA + compB + 0xD) % 211 + 1)`
   `roll   = Roll.RollDice(Die.StandardDice, random)` @0x4CC06C8.
   The `offset` arg only seeds a *new* RandomState
   (`new RandomState{Context, State=0, Seed=offset}`) when the context
   is missing — it is NOT an anti-prediction jitter for existing states.
4. `GetRandomWithOffset` (0x5455AD0) recognizes three contexts with
   cached statics — `"DICE_ROLL"` (str cell 0x71F75B0), `"ESCAPE_JAIL"`
   (0x71F9520), `"CHANCE_CARDS"` (0x71F1DF8) — then delegates to
   `GetRandom(state, ctx)` (0x5455874) →
   `new StatefulRandomFactory(state.RandomStates)
     .GetCappedRandomForContext(ctx)` (0x2559D7C) →
   `CappedRandomStateDecorator(RandomState, STATE_CAP)` wrapping
   `PseudoRandom` (CMWC: `Q[256]`/c/i/Stage, `SetSeed(long)` 0x255769C).
   `RandomState` layout: Context@0x10, State@0x18, Seed@0x20,
   Iteration@0x28. `CappedRandomStateDecorator._state`@0x18 /
   `_random`@0x20 / `_stateCap`@0x10.
5. Roll is consumed downstream by `RollActionSubResult`,
   `RollRewardCalculator.HandleDiceRoll`,
   `LuckyRollsLogic.HandleLuckyRollsDiceRoll`, `MoveHandler.HandleMove`.

### "See next roll" — concrete recipe (easiest first)

- **A. Hook `Roll.RollDice` (0x5292FAC)** — every roll passes through;
  log `RollResult.DiceResults`. Zero state juggling; shows the roll at
  generation time (before animation/server ack).
- **B. Peek ahead:** find `RandomState` in `boardState.RandomStates`
  (field 0x30) with `Context == "DICE_ROLL"`, clone all 4 fields into a
  fresh `RandomState`, wrap in `CappedRandomStateDecorator(clone,
  STATE_CAP)` (ctor 0x2558658; STATE_CAP is the factory static at
  StatefulRandomFactory+0x0 — read it at runtime) or plain
  `RandomStateDecorator(clone)` (ctor 0x2559354), then call
  `Roll.RollDice(Die.StandardDice, cloneRandom)` repeatedly → future
  rolls without touching the real Iteration counter. Verify against an
  actual roll — the game may draw extra Next()s per roll (2 dice + maybe
  combination draws).
- **C. `BoardState.ScriptedRolls` (0x60)** — when the server has queued
  forced distances (transitions/tutorials/post-shield), this list IS the
  upcoming rolls. Cheap add-on: display alongside the predicted values.
- `ESCAPE_JAIL` and `CHANCE_CARDS` contexts predict jail dice and
  next chance cards the same way (CHANCE_CARDS also has the synced
  `NextChanceCards` list @0x50).

### Open questions / next steps

- Live-test whether server accepts a client-supplied `RollResult`
  (decides "force roll" vs "see roll" only).
- Find who constructs `RollClientActionV2` (roll button → dispatch) —
  `OnRollButtonPressed` impl around dump.cs ~295563; a menu "set dice"
  feature would hook there or the action factory.
- PlaygamiSwizzler: check what it swizzles before assuming dylib method
  hooks are clean.

## Verified RNG math (instruction-level, 1.82.0)

All constants below were re-confirmed against `UnityFramework` disasm.
Corrects the earlier `Q[256]` note — the CMWC state is **Q[16]**.

- `PseudoRandom..ctor(long)` 0x25575E0: allocs `uint[16]` → `Q`;
  `c=0`, `i=0`, `Stage=0` (zeroed object), then `SetSeed`.
- `SetSeed` 0x255769C: xorshift32 chain `w ^= w<<13; w ^= w>>17; w ^= w<<5`
  fills `Q[0..14]` starting from `w = (u32)seed`;
  **`Q[15] = (u32)(seed>>32) ^ (u32)seed`**; `Stage=0`. `seed==0` → ArgumentException.
- `Cmwc()` 0x2557134: `i=(i+1)&15; t = (u64)Q[i]*0x1D0AF6E + c;
  c = t>>32; x = c + (u32)t; if (c > x) { c++; x++; }
  Q[i] = 0xFFFFFFFE - x; return Q[i]`.
- `Next(min,max)` 0x25573A4: `min + trunc(u/2^32 * (max-min))`
  (ucvtf d0,w8,#0x20 → double multiply → fcvtzs). Max-exclusive.
- `CappedRandomStateDecorator.ctor` 0x2558658(state,cap,offset):
  **`_random = new PseudoRandom(state.Seed ^ state.Iteration ^ offset)`**,
  then burns `state.State` calls of `_random.Next()` (vtable slot @0x188).
- `CappedRSD.Next(min,max)` 0x2558AB4: when `cap>=1 && state.State >= cap`
  → `State=0; Iteration++; _random = new PseudoRandom(Seed ^ Iteration)`
  (**no offset on reseed**), then draws; `STATE_CAP = 2000` (SRF.cctor).
- `RandomStateDecorator` write-back: `state.State = _random.Stage` after
  every draw — `State` = total draws consumed this iteration.
- `Die..cctor` 0x5292960: `Die.Standard = new Die(int[6]{1..6})`;
  `StandardDice = Die[2]` (2d6), `ThreeDices = Die[3]`. `FaceValues` @0x10.
- `RollDice` call site in `MoveNext` (0x4CC06C8) passes
  `Die.StandardDice` (statics slot +0x8) — the standard roll is 2d6, one
  CMWC step per die (`RollDie` → `rng.Next(0, FaceValues.Length)`).
- Roll offset (MoveNext): **`offset = (RollMultiplier*83 + TokenPosition*73 + 13) % 211 + 1`**
  (`RollMultiplier` @0x68, `TokenPosition` @0x20 on BoardState).
- `action.RollResult` non-empty → `GetBestRollCombination` path,
  generation skipped entirely (pre-filled server rolls bypass prediction;
  `ScriptedRolls` covers the queued-distances case).

## Runtime access (chosen: zero-hook heap walk)

UnityFramework **exports the full il2cpp_* API** (242 symbols incl.
`il2cpp_domain_get`, `il2cpp_image_get_class(_count)`,
`il2cpp_gc_foreach_heap`, `il2cpp_class_get_static_field_data`,
`il2cpp_runtime_invoke`). So instead of resolving DI statics:

1. `dlsym` the exports (same bridge as PFPlus).
2. `il2cpp_image_get_class*` → `Tophat.Common.Board.State.BoardState`.
3. `il2cpp_gc_foreach_heap` → live `BoardState` instance (pointer-equal
   `obj->klass` match inside the stop-the-world callback; pick the
   candidate whose `RandomStates` actually parses a `DICE_ROLL` entry).
4. Read fields directly: `RandomStates`@0x30 → find `Context=="DICE_ROLL"`
   → `State`@0x18 / `Seed`@0x20 / `Iteration`@0x28; `TokenPosition`@0x20,
   `RollMultiplier`@0x68, `ScriptedRolls`@0x60.
5. Re-run the math above in C → next N rolls. **No hooks, no code-page
   writes, no managed invokes** — PlaygamiSwizzler's swizzle surface is
   irrelevant to a pure reader.

## MGOPlus v1 — implementation (this workspace convention)

- `next-game/monopolygo/MGOPlus.m` — ctor + CFRunLoopTimer @10 Hz on the
  main runloop (Unity 6 GC-attach requirement), `Documents/mgoplus.json`
  cfg (`dice=1`, `peek=3`, `log_rolls=1`, `tick_hz=10`), write(2) logger.
- `il2cpp_bridge.{h,c}` — dlsym resolver + `find_class`/`find_instances`
  helpers (PFPlus-derived, `mgo_` prefix).
- `feature_dice.c` — BoardState discovery (2s-throttled heap walk, klass
  pointer liveness check, bad-instance skip), the CMWC port +
  `predict_rolls()` replaying ctor-burn + cap-reseed exactly.
- `mgoplus_menu.m` — floating orb (predicted sum, amber on doubles) +
  thick-material panel (die faces ⚀–⚅, upcoming rolls, mono RNG info
  line, scripted list, master switch, "Log state" dump). UIKit via
  objc_msgSend only. Refreshes only on change.
- `tools/inject_monopolygo.py` — `LC_LOAD_DYLIB` + framework drop +
  file-sharing plist flags (verified against the real IPA: MONOPOLYGO
  stub exe has header pad).
- `.github/workflows/build-mgoplus.yml` — macos-latest clang dylib +
  self-signed codesign + `mgoplus-latest` rolling release.

### On-device validation plan

`log_rolls=1` writes `next=a+b=s | mult pos st it off` whenever the
prediction changes. Procedure: note the logged `next`, roll in-game,
compare. If wrong, likely causes: extra DICE_ROLL draws between/around
die pulls (burn count drift — logged `st` will still be right, adjust
draws-per-roll), a pre-filled `action.RollResult` (scripted path), or
TokenPosition/RollMultiplier read mid-animation (self-corrects on land).
`draw N/2000` in the panel tracks the cap-reseed boundary.
