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

## Not included
- Cheat **menu** — iGameGod removed; unlocks are always-on. A custom menu needs a small loader dylib (no iGameGod required).
- "All cabin items" — `DebugAddAllCabinItems` is a debug command, no clean always-on patch; would need a call-site hook.

## Releases
- `v1.0.12` — original iOSGods mod IPA (reference)
- `v1.0.12-clean` — first clean build (failed Singulous sign due to stale LC_CODE_SIGNATURE)
- `v1.0.12-clean-v2` — clean build with stripped code signatures; sign with Singulous/Sideloadly/AltStore

## Install / saves
Same bundle ID → installs over the existing modded app; save files in app Documents survive (don't uninstall first or you lose them).
