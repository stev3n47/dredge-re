# CarX Drift Racing 3 — reverse engineering notes

Source IPA: iOSGods mod, game v1.18.1 (`CarXDriftRacing3`, Unity IL2CPP,
UnityFramework 128MB, il2cpp metadata version 31).

Shipped: `carx-1.18.1-menu-v1` — iOSGods payload stripped (libcarx.dylib +
iGameGod.framework removed, load commands weakened to LC_LOAD_WEAK_DYLIB so
dyld skips the now-absent files), independent `CXMenu.framework` injected.

## Architecture (same pattern as DREDGE)

- `tools/inject_carx.py` — injector: weakens iOSGods LCs, bakes patches into
  UnityFramework, embeds `CXMenu.framework`, repackages.
- `next-game/CXMenu.mm` — menu dylib (same design system as DREMenu: floating
  dot, material panel, spring/haptic feedback). Writes flag bytes only.
- Flag page: UnityFramework `__data` dead run at **0x7658720** (0x1540 bytes
  of file-backed zeros, zero pointer xrefs — NOT 0x771A000, that's
  `__swift_hooks` and live).
- Code cave: `__TEXT` zero run at **0x6150690** (0x2130 bytes).

## Flag layout (uf_base + 0x7658720)

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

Stub at 0x6150690 (site `b` at 0x283D660):

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
@rpath/iGameGod.framework/iGameGod` @fileoff 0xeb8. Both commands rewritten
to weak loads + files dropped — silent removal under re-signing.

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
