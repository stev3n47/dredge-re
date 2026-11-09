# dredge-re

Reverse engineering + custom cheat-menu injection for four Unity IL2CPP iOS
titles. Each mod replaces an iOSGods-style injection chain with our own
dylib so we own the UI, the toggles and the patch surface — no iOSGods
runtime (Jailpatch / iGameGod) ships in the final IPA, except where that
runtime is load-bearing and has to be stubbed rather than removed.

## Games

| Dir | Game | Findings | Injector | Menu dylib |
|---|---|---|---|---|
| `menu/` | DREDGE 1.5.19 | [FINDINGS.md](FINDINGS.md) | [tools/inject_menu.py](tools/inject_menu.py) | [menu/DREMenu.mm](menu/DREMenu.mm) |
| `next-game/sm27/` | SM27 | [next-game/sm27/SM27-FINDINGS.md](next-game/sm27/SM27-FINDINGS.md) | [tools/inject_sm27.py](tools/inject_sm27.py) | [next-game/sm27/SMMenu.mm](next-game/sm27/SMMenu.mm) |
| `next-game/` | CarX Drift Racing 3 1.18.1 | [next-game/CARX-FINDINGS.md](next-game/CARX-FINDINGS.md) | [tools/inject_carx.py](tools/inject_carx.py) | [next-game/CXMenu.mm](next-game/CXMenu.mm) |
| `next-game/pogo/` | iPoGo (Pokemon Go v0.435.1) | [next-game/pogo/POGO-FINDINGS.md](next-game/pogo/POGO-FINDINGS.md) | [next-game/pogo/inject_ipauto.py](next-game/pogo/inject_ipauto.py) | [next-game/pogo/IPAuto.m](next-game/pogo/IPAuto.m) |

See also: [AUDIT.md](AUDIT.md) — the running whole-project findings doc.

## Layout

```
menu/           DREDGE menu source
next-game/      CarX source + sibling game dirs
  pogo/           iPoGo / IPAuto
  sm27/           SM27
tools/          Injectors (one per game) + dupe_ipa.py
build/          Compiled menu dylibs (CI artifact landing zone)
.github/        One build-*.yml workflow per menu
```

## Build

Menu dylibs compile on macos-latest CI (`.github/workflows/build-*.yml`):
real iPhoneOS SDK + self-signed codesign. Local cross-build on Linux is
documented in [next-game/pogo/POGO-FINDINGS.md](next-game/pogo/POGO-FINDINGS.md)
(theos SDK + zig cc for IPAuto). Download the CI artifact to `build/` and
run the matching injector.

## Inject

Each injector takes `<input.ipa> <menu dylib> <out.ipa>` plus
per-game flags. Examples:

```sh
python tools/inject_menu.py   DREDGE.ipa          build/DREMenu.dylib  out.ipa
python tools/inject_sm27.py   SM27.ipa            build/SMMenu.dylib   out.ipa
python tools/inject_carx.py   CarX.ipa            build/CXMenu.dylib   out.ipa  igg
python next-game/pogo/inject_ipauto.py \
                              ipogo-4.6.1.ipa     build/IPAuto.dylib   out.ipa
```

`inject_carx.py` has modes: `keep` (keep all iOSGods payloads — v5 working
baseline), `igg` (stub iGameGod only — current shipped v6+), `carx`
(stub libcarx only), or omit for excise-both (crashes at launch — see
findings for why libcarx is load-bearing).

## Signing + install

All IPAs are built static-patch-only (no runtime Jailpatch) so they can be
signed and sideloaded with any mainstream signer (Signulous, TrollStore,
AltStore + the usual provisioning). The injectors preserve the zip layout
the signers expect; see `tools/dupe_ipa.py` to re-target a bundle id when
installing alongside the original.

## Approach

Rather than keeping iOSGods' encrypted Jailpatch records, each game's mod
is reimplemented as static byte patches into the stock `UnityFramework`:
VA == file offset, stubs live in segment-tail padding, flags in `__DATA`
zero-fill. See each game's FINDINGS doc for the specific seams and the
mistakes ruled out on the way to the current approach.

## Note

These are personal-use research mods of games the authors own. Don't ship
the output IPAs.
