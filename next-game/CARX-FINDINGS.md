# CarX Drift Racing 3 — reverse engineering notes

Source IPA: iOSGods mod, game v1.18.1 (`CarXDriftRacing3`, Unity IL2CPP,
UnityFramework 128MB, il2cpp metadata version 31).

Shipped: `carx-1.18.1-menu-v6` — real `libcarx.dylib` kept (its runtime
patches are LOAD-BEARING — see v5/v6 discovery below), iGameGod replaced
with a neutral stub, `CXMenu.framework` injected. v1–v4 all removed or
stubbed libcarx and crash at launch.

## The load-bearing discovery (v5)

`v5` = stock IPA + our additions, removing NOTHING → **launches, menu
works**. So the crash was never our injection machinery — it was removal.
`libcarx.dylib`'s `__mod_init_func` (7 entries) applies Jailpatch runtime
hooks *before* UF's own initializers run (bottom-up JIT order). Its
strings show boot-critical work, not just cheats:

- `Hooked GenerateFreeRideEncryptionSign @ 0x26FE11C` — request signing
- `install NSURLSession hook`, `hook hit[dataTask]` — network interception
- `iGameGod XXSideloadFix keychain access-group hook` — sideload shims
- `finish achievements patched` — the actual cheats

With libcarx absent/stubbed, UF's 769 initializers run on **unpatched**
code → one tail-calls into a function that resolves to null → `pc=0` in
`forEachInitializer`. (Pointer math: `__init_offsets` targets are
base+offset, never 0 — so the fault is inside a callee, consistent with a
tail-call to a function the Jailpatch hooks were meant to provide/fix.)

`iGameGod.framework` (22MB, Swift) is the separate auth/login-wall
component. libcarx has **zero** LC links and **zero** symbol imports from
it → the two are independent. v6 stubs iGameGod only.

## Earlier wrong theories (all ruled out)

- Cave in live `__const` (v1) — real cause of the FIRST crash, fixed in v2
- Defunct weak-image upward-links walk (v2/v3) — plausible but v4's
  complete dep-graph still crashed identically; disproven
- Malformed init tables / binds to deleted libs / LC_ROUTINES /
  thread_starts / cryptid — all verified clean (LIEF + manual parse)

## Architecture (same pattern as DREDGE)

- `tools/inject_carx.py` — injector. Modes: excise-both (broken), `keep`
  (all stock + additions = working v5), path stub-both, `igg` (stub
  iGameGod only — v6), `carx` (stub libcarx only). Bakes the resource-seam
  patch into UnityFramework, embeds `CXMenu.framework`, repackages.
- `next-game/CXMenu.mm` — menu dylib (same design system as DREMenu: floating
  dot, material panel, spring/haptic feedback). Writes flag bytes only.
- Flag page: `__DATA` segment-tail padding at **0x7B47000** — `__common`
  ends 0x7B44F40, segment maps to 0x7B48000; file-backed data ends
  0x771C000 so the tail is mapped zero-fill (writable, unreferenced).
- Code cave: `__TEXT` segment-tail padding at **0x69974D0** — ~0xB30 bytes
  before vend 0x6998000, zero branch/pointer xrefs.

⚠️ **Cave-selection lesson (v1 launch crash):** zero runs INSIDE live
sections are real data, not padding. The v1 cave (0x6150690) sat in
`__TEXT.__const` — its "zeros" were live const data; overwriting them made
dyld's initializer walk call a null pointer (CODESIGNING "Invalid Page",
pc=0 in `forEachInitializer`). `__data`/`__bss`/`__common` interior runs
have the same problem (0x7658720 was inside `__data`; 0x771A000 is
`__swift_hooks`). Only SEGMENT-TAIL padding — after the last section but
inside the mapped segment — is provably dead. Also note unsectioned code
can exist between the last declared section and the nonzero tail
(0x6994010–0x69974C3 holds real ARM64 code with no owning section).

⚠️ **Weak-load lesson (v2 launch crash — same signature, different cause):**
`LC_LOAD_WEAK_DYLIB` of a *missing* file leaves a defunct image in the
dependency graph. The crash was `pc=0` in `MachOAnalyzer::forEachInitializer`
under `dyld4::APIs::dlopen_from` → `runInitializersBottomUpPlusUpwardLinks`:
the exe loads UnityFramework at runtime via `-[NSBundle loadAndReturnError:]`
→ `_CFBundleDlfcnLoadFramework`; when dyld runs the JIT image's initializers
it also walks *upward links* (the dlopener's dep graph), reaches the
weak-missing iGameGod loader, and calls a null initializer. Exhaustively
ruled out first: all init sections valid (UF `__init_offsets` 769/769 sane,
AppLovin/CXMenu `__mod_init_func` valid), zero binds/undefs referencing the
deleted dylibs (LIEF, 39,553 entries), no LC_ROUTINES/thread_starts,
cryptid=0, byte-diff surgical. The fix is `remove_load`: excise the command,
slide the rest down. Only safe because both iOSGods LCs are the LAST dylib
LC in their binary (exe ordinal 23/23, UF ordinal 77/77 — appended at the
end by the mod tool) — removing an earlier LC would renumber ordinals and
corrupt existing binds. DREDGE never hit this because it was built on a
stock decrypted IPA with no injected loads to strip.

## Flag layout (uf_base + 0x7B47000)

| Off | Type | Meaning |
|-----|------|---------|
| +0  | u8   | Cash Boost enable |
| +1  | u8   | Free Purchases enable |
| +4  | i32  | Boost multiplier (menu-written, default 10000) |

## The resource seam — one stub covers everything

`Dr3PlayerResources` fields: `+0x10 Soft` (cash), `+0x14 Hard` (premium),
`+0x18 Fans`, `+0x1C Fuel`.

`Dr3PlayerResourcesUtils.AddResource(dict, name, balance, out*, factor)`
@ **0x283D590**: every resource grant and spend flows through the
multiply-accumulate:

```
0x283D65C  ldr  w8, [sp,#0xc]      ; w8 = delta (dict value)
0x283D660  madd w23, w8, w22, w23  ; w23 = delta*factor + balance
0x283D664  str  w23, [x21]         ; *out = new balance
0x283D670  ...  dict[name] = w23   ; dict updated in-place too
```

factor (`w22`) is `+1` on earns, `-1` on spends (`cneg` from the `add` bool
in `AddResources` @0x283D4A4 — called by `RewardsResultDelta..ctor`
@0x286828C, the race-end reward pipeline).

Stub at 0x69974D0 (site `b` at 0x283D660):

- flag+0 && factor>0 → `madd w23, w8, w10, w23` with w10 = i32 from flag+4
  → earns pay `delta × mult`.
- flag+1 && factor<0 → skip the madd entirely → `w23` keeps `balance`
  → store writes back the unchanged balance → spends are free.
- All other cases replay the original `madd w23, w8, w22, w23`.

Both toggles, both currencies, fuel, fans — one instruction site.

## iOSGods payload (for reference)

`libcarx.dylib` (Swift Jailpatch — `SwiftHooks`, `MemoryPatcher`,
`CydiaSubstrate` refs) loaded by UnityFramework via
`LC_LOAD_DYLIB @executable_path/Frameworks/libcarx.dylib` @fileoff 0x2af8.
`iGameGod.framework` loaded by the exe via `LC_LOAD_DYLIB
@rpath/iGameGod.framework/iGameGod` @fileoff 0xeb8. v3 excises both
commands outright (files already dropped).

## Dump notes

Il2CppDumper (il2cppdumper7) works with `DOTNET_ROLL_FORWARD=LatestMajor`
on .NET 8/10; it throws only at the final `Console.ReadKey` — outputs are
still valid. CarX dump outputs live in `next-game/` (48MB dump.cs); the
dumper writes `dump.cs` into its own tool dir — move results per-game so
DREDGE's dump isn't clobbered (restored to `tools/dredge-dump/`).

## Server caveat

`Dr3.Server` assemblies exist (`Dr3PlayerResources` is likely server-synced,
`Dr3PlayerBanned` exists). Patches modify the *client* balance write — if
the server authoritative-checks currency, effects may be cosmetic or
corrected on sync. Untestable from here; on-device check: earn once with
Boost on, restart, see if the balance persists.
