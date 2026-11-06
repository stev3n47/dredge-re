# DREDGE iOS Mod IPA — Reverse Engineering Findings

Source: `DREDGE-1.0.12-mod.ipa` (iOSGods mod, 611 MB, SHA-256 `ac887395…`)
Game: DREDGE, bundle `com.blacksaltgames.dredge`, App Store version 1.5.19 (build 246), min iOS 16.0.

## Architecture

Unity IL2CPP title — all managed C# compiled to arm64 native code. No managed DLLs shipped.

| File | Size | Role |
|---|---|---|
| `DREDGE` | 88 KB | Stub launcher (had added `LC_LOAD_DYLIB` → iGameGod) |
| `Frameworks/UnityFramework.framework/UnityFramework` | 71 MB | Unity engine + IL2CPP game code (had added `LC_LOAD_DYLIB` → libDREDGE) |
| `Frameworks/libDREDGE.dylib` | 5.7 MB | iOSGods **Jailpatch** runtime (removed) |
| `Frameworks/iGameGod.framework/iGameGod` | 22 MB | iGameGod cheat-menu framework (removed) |
| `Data/Managed/Metadata/global-metadata.dat` | 13.7 MB | IL2CPP metadata v31, unencrypted |

### Injection chain (stock mod)
`DREDGE` loads `iGameGod` → menu/UI. `UnityFramework` loads `libDREDGE.dylib` → Jailpatch engine applies runtime patches into `UnityFramework` code.

### Jailpatch (iOSGods proprietary)
`libDREDGE.dylib` contains MSHookFunction/MSHookMemory/MemoryPatcher/FishHook/`CodeSwap.CodePatchObjc`/ObjcSelectorHook/HardwareBreakpointHookController + CydiaSubstrate references. Patch records live in a ~14 KB XOR-encrypted blob in `__DATA` at file offset `0x50ce88` (header `1c000000 01040000`, ciphertext to `~0x5106xx`). Records are decrypted at runtime; keys not recovered (not needed — see below).

## REA notes
REA inventoried the IPA fine (evidence `ev_bd72ca87…`) but **cannot decompile Mach-O on Windows**: Ghidra P0 = PE only on win32, Hopper = macOS only, IDA/Kuna unconfigured. Used `llvm-objdump` (Swift toolchain) + Il2CppDumper v6.7.46 (net7 build, `DOTNET_ROLL_FORWARD=LatestMajor`) instead. Dump output in `tools/il2cppdumper7/` (dump.cs, script.json, DummyDll).

## Approach taken
Rather than decrypting Jailpatch records, the mod's features were reimplemented as **static byte patches** in `UnityFramework` (VA == file offset). Zero iOSGods code remains.

## Root-cause: why removing libDREDGE crashed (v4/v5)

Diffing the mod `UnityFramework` against a **decrypted stock IPA** (build 246, `global-metadata.dat` SHA identical) revealed ~6,000 static modifications by iOSGods — far more than the two injected `LC_LOAD_DYLIB` commands:

- `__objc_stubs` (≈`0x36ac2e8–0x36b5a00`): stock entries are 32-byte `objc_msgSend` stubs (`adrp/ldr selref + adrp/ldr _objc_msgSend; br` + `brk` padding to 0x20). iOSGods **repurposed the `brk` padding** to embed a second stub type:
  ```
  mov  x16, #lo16
  movk x16, #hi16, lsl #16
  b    tail
  tail: add x16, x16, x30   ; x30 = caller return addr
        ldr x16, [x16]
        br   x16
  ```
  The immediate is baked per-stub so that `[return_addr + imm]` resolves to one shared slot: **`0x46DF528`** in `__DATA` zerofill (near `_globalOptions`). All ~250 rewritten callsites funnel to this single dispatch pointer.
- iOSGods rewrote ~250 call sites across `__text` to `bl` these injected stubs, plus code appended in the `__text` tail slack (`0x3e46d40+`, zeros in stock).
- The dispatch slot has **no chained-fixup binding and no static writer** — it is populated at runtime by **`libDREDGE.dylib`'s initializer**, which dyld runs before `UnityFramework`'s initializers (bottom-up dependency order).
- Deleting libDREDGE leaves the slot = 0 → first dispatch call `br 0` → `EXC_BAD_ACCESS KERN_INVALID_ADDRESS at 0x0`, `x16=0`, inside `UnityFramework` initializer #439 (`0xA709AC` → `0xA60D5C` → `0xA60E74` → `bl 0x36B3054`). Confirmed by crash log `DREDGE-2026-11-06-144208.ips` under TrollStore.

**Conclusion:** in the iOSGods build, `libDREDGE.dylib` is load-bearing — its init fills the BSS dispatch table. It cannot simply be deleted; a standalone build must either keep libDREDGE, replicate its table fill, or (chosen) start from a clean stock binary.

## v7: standalone build from decrypted stock IPA

`com.blacksaltgames.dredge_1.5.19_decrypted.ipa` (user-supplied, dumped on jailbroken iPad): identical build 246, `global-metadata.dat` identical → all method RVAs transfer. Stock `UnityFramework` has real code at all the spots iOSGods rewrote — including the true `GetHasEntitlement` prologue at `0x13E358C` (`sub sp,#0xC0; stp x22,x21`, where the mod had an iOSGods branch patch). The same three static patches applied at identical RVAs. No dylib removal needed — stock never had the iOSGods load commands.

## Applied patches (in v1.0.12-clean / -v2 releases)

| Effect | Method (IL2CPP) | RVA | Bytes |
|---|---|---|---|
| Full game unlocked | `TrialModeManager.get_IsInTrialMode` | `0x12948BC` | `mov w0,#0; ret` |
| All DLC entitled (DLC1+DLC2) | `EntitlementManager.GetHasEntitlement` | `0x13E358C` | `mov w0,#1; ret` |
| Sell value 4x | `MarketDestination.get_SellValueModifier` | `0x13C07E4` | `movz w0,#0x4080,lsl#16; ret` (returns `0x40800000` = 4.0f in s0) |

Also removed: `LC_LOAD_DYLIB` for iGameGod (in `DREDGE`) and libDREDGE (in `UnityFramework`), deleted `iGameGod.framework/`, `libDREDGE.dylib`, `_CodeSignature/` dirs, and stripped `LC_CODE_SIGNATURE` from all 4 Mach-O binaries (v2) so re-signing works. No binds/lazy-binds referenced the removed dylibs.

## Additional patch candidates found (dump.cs RVAs)

Always-on candidates (single-function bool/float patches):

| Effect | Method | RVA | Patch |
|---|---|---|---|
| Godmode | `get_IsGodModeEnabled` | `0x125E7EC` | `mov w0,#1; ret` |
| Immune to equipment damage | `get_IsImmuneModeEnabled` | `0x125E7FC` | `mov w0,#1; ret` |
| Damage immune (alt) | `get_DamageImmune` | `0x134B698` | `mov w0,#1; ret` |
| Never lose sanity | `GetPlayerSanity` → `0.0f` | `0x135BFE4` | float const |
| Max catch rate | `get_CatchRate` | `0x134BEAC` | float const |
| Faster boat | `GetMaxSpeed` | `0x14A3AF8` | float const |
| No ability cooldowns | `CheckAbilityCooldown` | `0x1295D74` | `ret` |
| Free research | `get_ResearchPointsRequired` | `0x134C5B8` | `mov w0,#0; ret` |
| No item/net wear | `GetMissingDurabilityAmount` | `0x127B134` | float const |
| No sanity-gated spawns | `GetCanSpawnBySanity` → `false` | `0x1462AF0` | `mov w0,#0; ret` |

Needs a runtime hook / custom menu to trigger (not cleanly always-on):
`SetGodMode 0x1260734`, `SetImmuneMode 0x1260878`, `SetSanity 0x126AFE0`, `SetMaxSpeed 0x1346464`, `SetPlayerBaseMoveSpeed 0x1263894`, `SetPlayerBaseTurnSpeed 0x12638D4`, `ToggleIcebreaker 0x126077C`, `TeleportPlayerToHarvestSpot 0x1466E98`, `DebugAddItem 0x1362AFC`, `DebugAddItemInventory 0x1362A80`, `DebugAddItemNet 0x1363D2C`, `DebugAddAllCabinItems 0x1362D34`, `DebugUnlockAbility 0x297164?` (see dump.cs line 297164), `RepairAllItemDurability 0x1403EA0`, `RepairToFullDurability 0x127B214`, `SetAllDLC 0x13851D8`, `SetNoDLC 0x13849BC`, `SetGameAsPurchased 0x1294C2C`, `GrantEntitlementBypass 0x13F393C`, `AddItemById 0x1408090`.

Terminal/debug commands shipped in the game: godmode, icebreaker, immune-to-equipment-damage, player move/turn speed, sanity, achievements, TIR/TPR/world phase, sale mode, time set, cloud/wave/wind params.

## Custom menu — `DREMenu.dylib` (v8+)

Architecture: small ObjC dylib injected into the stock `DREDGE` executable via
added `LC_LOAD_DYLIB` — same mechanism iOSGods uses, but our own code and zero
dependencies on their frameworks.

- **Injection:** `tools/inject_menu.py` writes a new `LC_LOAD_DYLIB`
  (`@executable_path/Frameworks/DREMenu.dylib`) into the DREDGE header pad
  (~14 KB free after `sizeofcmds`), drops the dylib into `Frameworks/`, repackages.
- **Build:** `menu/DREMenu.m` compiled on macOS GitHub Actions
  (`.github/workflows/build-menu.yml`) — Windows can't produce arm64 iOS Mach-O.
- **UI:** constructor thread waits for `UnityFramework` + `Terminal.Shell` to
  exist, then creates an always-visible floating mini `UIWindow` (draggable,
  `UIWindowLevelAlert+3`). Tap → cheat panel (`UIWindowLevelAlert+2`).
- **Command dispatch:** the game ships a full `CommandTerminal` console —
  `Terminal.Shell` is a static `CommandShell` singleton. The dylib calls
  `get_Shell()` (`0x1216E70`) → `RunCommand(string)` (`0x1214D50`), creating
  managed strings via exported `il2cpp_string_new`. Every registered command
  becomes a button: godmode, sanity, speed, teleport, add items, unlocks, DLC.
- **Command list:** enumerated at runtime from `Terminal.Shell.Commands`
  (`get_Commands` `0x1215CD0`) — a `Dictionary<string,CommandInfo>` walked
  natively. `CommandInfo` is a 24-byte **value struct** (proc@0, max_args@8,
  min_args@0xC, help@0x10) stored **inline** in the entry, so each
  `Entry{hash@0,next@4,key@8,value@16}` is **40 bytes**, entries array at
  obj+0x18 (candidate offsets 0x18/0x20/0x10 tried), Il2CppString utf16 chars
  at +0x14. The menu reads name + min/max arg counts + help per command —
  no-arg commands run on tap, arg commands get an alert prompt.
- **Runtime toggles:** byte patches applied/restored on demand at the known
  RVAs (mprotect RWX + `sys_icache_invalidate`). Float-returning methods patch
  via `ldr s0,[pc,#8]; ret; .float` literal-pool — **not** `mov w0` (wrong
  register file) and **not** `b +8` (branches into mid-function → crash).

| Toggle | RVA | Patch |
|---|---|---|
| God Mode | `0x125E7EC` | `mov w0,#1; ret` |
| Immune (equip dmg) | `0x125E7FC` | `mov w0,#1; ret` |
| Free Research | `0x134C5B8` | `mov w0,#0; ret` |
| Catch Rate 5.0 | `0x134BEAC` | `ldr s0 / ret / .float 5.0` |
| Sell 4x | `0x13C07E4` | `ldr s0 / ret / .float 4.0` |

Dropped after audit (unverified or wrong semantics):
- `GetPlayerSanity`→0 (`0x135BFE4`): 0 = *insane*, drives dialogue/AI — not
  "sanity never decreases".
- `CheckAbilityCooldown` (`0x1295D74`): UI-layer check; doesn't touch real
  cooldown enforcement.
- `GetMissingDurabilityAmount` (`0x127B134`): repair-side calculation, not
  proven "no durability loss".
- `GetMaxSpeed` (`0x14A3AF8`): misattributed — disassembly shows a float
  interpolation function, not boat speed. Forcing 20.0 could corrupt state.

> Static patches applied at build time (v10): `get_IsInTrialMode`→false
> (`0x12948BC`) and `GetHasEntitlement`→true (`0x13E358C`). SellValueModifier is
> runtime-toggle only — its earlier static patch returned via `w0` which is the
> wrong register file for a `float` method (must write `s0`).

## Not included
- "All cabin items" — `DebugAddAllCabinItems` is a debug command; reachable via
  the menu's command list instead of an always-on patch.

## Releases
- `v1.0.12` — original iOSGods mod IPA (reference)
- `v1.0.12-clean`/`v2`/`v3` — early clean builds (signing/packaging issues)
- `v1.0.12-clean-v4`/`v5` — surgical-zip builds; install but crash at launch (null dispatch slot, see root-cause)
- `v1.0.12-clean-v6` — keeps `libDREDGE.dylib` + load command, drops iGameGod only; diagnostic build
- `v1.5.19-standalone-v7` — **stock decrypted IPA + 3 static patches only; zero iOSGods code**
- `v1.5.19-menu-v8` — v7 + `DREMenu.dylib` injected; floating menu + all game commands + runtime toggles
- `v1.5.19-menu-v8c` — adds bundled save (`dredge-save0.bin`), a restore button in the menu, and `UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace` so Documents is browsable in Files.app / Finder
- `v1.5.19-menu-v9` — fixes two UI bugs reported on iPad: (1) windows must be attached to a `UIWindowScene` to render on iOS 13+ (v8 bubble was invisible); (2) `UIGestureRecognizer` targets are weak refs, so the tap host must be retained in a static var — v8 bubble rendered but did nothing on tap. Same contents as v8c otherwise.
- `v1.5.19-menu-v9b` — v9 + ad-hoc-signed `DREMenu.dylib` (re-signers only recurse into binaries that already carry `LC_CODE_SIGNATURE`; unsigned dylib → Singulous signed OK but iOS install refused).
- `v1.5.19-menu-v10` — **current build.** Four-agent audit applied: float toggles used `b +8` into mid-function (guaranteed crash) → correct `ldr s0/ret/.float`; dropped buggy static `get_SellValueModifier` patch (returned via `w0`, float methods return in `s0` — Sell is runtime-toggle only); `mprotect` checked + RX restored; dictionary enum hardened to 40-byte stride (CommandInfo is an inline value struct); il2cpp calls on main thread; ObjC++ try/catch around managed calls; **zip repack preserves exec bits** (explicit 0755 on all Mach-O) — the likely Singulous install blocker alongside device-UDID provisioning; stale `_CodeSignature`/`embedded.mobileprovision` stripped; dylib ad-hoc signed. Toggle list trimmed to the 5 verified patches (see table). No-arg commands run on tap; arg commands show min/max prompt.

## Multi-agent audit — remaining findings (not yet implemented)

UX audit surfaced these, prioritized:

**Critical UX**
- Panel fixed `(30,80,340,420)` overflows landscape iPhone height (~390–430 pt) — clamp to screen.
- `run_cmd` fails silently; `toast:` is a blocking alert hardcoded to title "Save" even for patch failures — need a real transient toast.
- Destructive commands (`Die`, `DepleteHarvestSpots`, save overwrite) are one-tap, no confirmation.

**Important**
- Dot: default position sits in the left-thumb steering zone and overlaps the panel (alert+3 vs alert+2); add edge-snap on pan-end, idle alpha fade, move default to right edge.
- Toggle buttons lose the `✓` state suffix when the panel rebuilds on reopen.
- Toggle states not persisted across relaunch (NSUserDefaults + re-apply in poll_ready).
- `CommandInfo.help` (entry+32) is available but unread — surface as long-press help / arg-prompt message.

**Nice-to-have**
- Long-press dot → collapse to edge tab (proper hide, replaces accidental 8-pt sliver).
- Search/filter for the ~25+ command list.
- Move Toggles section above the long command scroll; 34→40 pt buttons, 10→11–12 pt font.

## Signulous install failure (iPhone) — diagnosis in progress

Device ruled out: iOSGods IPA installs on the same iPhone 17 Pro Max / iOS 26.2 via Signulous, UDID registered, old app deleted. So the IPA is at fault. v10 fixed exec bits + ad-hoc dylib + stale signatures; still fails. Working theory: Signulous's signer may only enumerate `.framework` bundles (or binaries with real cert signatures — iGameGod's blob is 287 KB with certs, ours is a 1 KB ad-hoc stub) → a bare ad-hoc `.dylib` keeps an invalid signature → iOS nested-code integrity check fails.

- `v1.5.19-base-v10` — control build: base-v10 packaging with NO dylib/menu. Installs ⇒ dylib confirmed as blocker.
- `v1.5.19-menu-v10f` — v10 with `DREMenu` packaged as `Frameworks/DREMenu.framework/DREMenu` (+Info.plist), mimicking iGameGod's layout. **Tested: still "Unable to install" via Signulous on iPhone.**
- `v1.5.19-menu-v10g` — signing-shape match attempt: keeps stock `_CodeSignature/CodeResources` dirs (mod IPA ships them — ours previously stripped them); `LC_LOAD_DYLIB` inserted *before* `LC_CODE_SIGNATURE`; `DREMenu` signed with a real self-signed CMS cert (~1.7 KB blob) instead of ad-hoc stub; `-Wl,-no_fixup_chains` for legacy signer compat. Verified locally: real CMS superblob, no chained fixups, correct command order.
- `v1.5.19-stock-repack` — pure control: decrypted stock IPA through our zip pipeline with **zero content changes** (211 entries, identical bytes). If even this fails on the iPhone, our zip writer is guilty, not the dylib/patches.

## Install / saves
Same bundle ID → installs over the existing modded app; save files in app Documents survive (don't uninstall first or you lose them).
