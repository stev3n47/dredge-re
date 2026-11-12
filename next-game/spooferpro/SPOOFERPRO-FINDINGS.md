# SpooferPro 0.435.1 — Pro/Elite entitlement unlock

Base: `SpooferPro-0.435.1-0.743.ipa` (Pokémon GO 0.743, SpooferPro
build 0.435.1). Mod ships in `Payload/PokmonGO.app/Frameworks/libSpooferPro.dylib`
(30,295,600 bytes, arm64 Mach-O).

The stock dylib is a tiered-subscription client for the SpooferPro add-on
(Free / Pro / Elite). Every gated feature calls a pair:

```
bl  <central_compare>     ; derive user's tier level
bl  <gate_fn>             ; bool check against required tier
```

All reads also flow through a LEVEL getter that returns the raw tier int.

## Patch set across shipped releases (verified by cmp diff)

| VA | Kind | Stock | v1 | v2 | v3 | v4 (proposed) |
|---|---|---|:-:|:-:|:-:|:-:|
| `0x7d9ae0` | Tier wrapper 1 (prologue) | *unknown* | ✅ | ✅ | ✅ | ✅ |
| `0x7d9bec` | Tier wrapper 2 (prologue) | *unknown* | ✅ | ✅ | ✅ | ✅ |
| `0x7d9edc` | Tier wrapper 3 (prologue) | *unknown* | ✅ | ✅ | ✅ | ✅ |
| `0x7da154` | Tier wrapper 4 (prologue) | *unknown* | ✅ | ✅ | ✅ | ✅ |
| `0x7da430` | Fifth gate (13 BL callers) — entry | `a9ba6ffc` | — | `mov w0,#1;ret` | — | `mov w0,#1;ret` |
| `0xbcf70` | LEVEL getter — **entry** | `d10203ff` | — | `mov x0,#0xff;ret` | `mov x0,#4;ret` | — |
| `0xbdbc8` | LEVEL getter — **epilogue** (`mov x0, x21`) | `aa1503e0` | — | — | — | `mov x0,#0xff` |

**v2 and v3 both crash at launch.** Both overwrite the function entry at
`0xbcf70` with `mov x0, #<const>; ret`. The crash is NOT about the returned
value (v2 tried 0xFF, v3 tried 4 — same crash) — it's because the stock
function has **required side effects** that get skipped:

- Saves x19–x28 (ten callee-saved registers — unusually large working set).
- Reads globals at `0x1a1a040 / 44 / 48`.
- Computes `x20 = 0x1bac75c` (an address in `__DATA.__thread_bss`, a TLS
  slot).
- Conditionally performs an atomic op on that TLS slot (opcode
  `88dffe9f` at `0xbcff4`).

That looks like a **lazy initialization** path. Downstream code that reads
the TLS slot or related globals expects them to have been populated by the
first LEVEL getter call. Trashing the entry means they're never populated.

### Correct fix (v4): patch the RETURN VALUE, not the entry

The function is a single large basic block ending at a single `ret` at
**`0xbdbe8`**. Its epilogue:

```
0xbdbc8  aa1503e0   mov x0, x21               ; <-- return value is x21
0xbdbcc  a9477bfd   ldp x29,x30, [sp,#112]
0xbdbd0  a9464ff4   ldp x20,x19, [sp,#96]
0xbdbd4  a94557f6   ldp x22,x21, [sp,#80]
0xbdbd8  a9445ff8   ldp x24,x23, [sp,#64]
0xbdbdc  a94367fa   ldp x26,x25, [sp,#48]
0xbdbe0  a9426ffc   ldp x28,x27, [sp,#32]
0xbdbe4  910203ff   add sp, sp, #0x80
0xbdbe8  d65f03c0   ret
```

Replace **4 bytes** at `0xbdbc8` — `mov x0, x21` → `mov x0, #0xff`
(`d2801fe0`). The function runs in full, every side effect preserved, and
the return value is overridden. v4 as computed: SHA-256
`7143ec165c806dfaa258f66109bef1e97a1309a85ae97c350345c8c1406a7a6a`
(fifth gate stays stock since v3 already reverted it, out of caution).

**Central compare — still unidentified.** The structurally obvious candidate
is `0x7cff64`: every one of the 13 fifth-gate call sites does
`bl 0x7cff64; bl 0x7da430` back-to-back, and it has 131 total BL callers
(highest in the cluster). But its first two words in all three shipped
builds are a real prologue (`stp x28, x27, [sp,#-0x60]!` /
`stp x26, x25, [sp,#0x10]`), i.e. NOT a trivial-return patch. Without a
true pre-mod reference we can't diff it; the four "tier wrappers" at
`0x7d9ae0..0x7da154` may include the central-compare slot the release
notes mention, or it may be another function we haven't located.

**Central compare — unidentified address.** The release notes mention "the
central compare" as patched in v1. The structurally obvious candidate is
`0x7cff64`: every one of the 13 fifth-gate call sites does
`bl 0x7cff64; bl 0x7da430` back-to-back, and it has 131 total BL callers
(highest in the cluster). But its first two words in v2 are a real prologue
(`stp x28, x27, [sp,#-0x60]!` / `stp x26, x25, [sp,#0x10]`), i.e. NOT a
trivial-return patch. Either (a) the "central compare" is a mid-function
value override we haven't located, or (b) it's one of the tier wrappers and
the release wording is loose. Flagged for the next revision. Without a stock
(pre-mod) copy of libSpooferPro.dylib we can't diff it.

## Evidence

Binary SHA-256 pins (for `tools/inject_spooferpro.py` verification):

- v1 (pre-fifth-gate, pre-LEVEL, working):
  `6014374be941440e61fd889db8ad49555004542a20195df00536d418cfcaa7b8`
- v2 (fifth gate + LEVEL entry → `0xff`, CRASHES):
  `be3e5ec019c766d725729904f4aced920b201a9f72aed1573b5dd813b2f0e8df`
- v3 (fifth gate reverted, LEVEL entry → `4`, CRASHES):
  `658578b2633ba3625b691c523e097a5591ae38a2d9023e6df8c220138c510247`
- v4 proposed (fifth gate stock, LEVEL epilogue-override `0xbdbc8` → `0xff`):
  `7143ec165c806dfaa258f66109bef1e97a1309a85ae97c350345c8c1406a7a6a`

Reproduce each of them from the v1 IPA with the injector:

```sh
# v2 shipped:
python tools/inject_spooferpro.py v1.ipa out.ipa --no-level-override --level-getter-entry
# v3 shipped:
python tools/inject_spooferpro.py v1.ipa out.ipa --no-fifth-gate --no-level-override --level-getter-entry --level-entry-value 4
# v4 proposed (default, with --no-fifth-gate to match):
python tools/inject_spooferpro.py v1.ipa out.ipa --no-fifth-gate
```

Diff: `cmp -l v1 v2` returns exactly **16 bytes** of divergence, grouped at
offsets `0xbcf70..0xbcf77` and `0x7da430..0x7da437`. File offset equals
virtual address throughout (every `__TEXT.*` section has `vma == foff`), so
the addresses are usable as both.

Related strings:

- `__cstring 0x01513d04`: "This feature is exclusive to Pro and Elite
  members. Free users can use it only once per hour." — the gated paywall
  copy. No direct ADRP xref found (likely referenced via `__cfstring`
  constant pool at `0x179a368` or an `__objc_selrefs` dispatch).
- `__objc_classname 0x016100e9`: `m7b0kltierv88d9uurjwk` — SpooferPro's own
  obfuscated tier class; `tier` is the only readable substring.

BL xrefs (v2, counted by raw 26-bit BL immediates in `__text`):

- `0x7d9ae0` tier wrapper 1: 1 caller
- `0x7d9bec` tier wrapper 2: 39 callers
- `0x7d9edc` tier wrapper 3: 48 callers
- `0x7da154` tier wrapper 4: 5 callers
- `0x7da430` fifth gate: 13 callers *(matches release notes)*
- `0xbcf70`  LEVEL getter: 2 direct callers at `0xbbb3c` and `0xbddb4`

Both LEVEL getter callers load `x0 = x19` before the call (`aa1303e0`), so
the getter takes a feature-id argument and returns its level — the v2 patch
forces every feature to report level 255, which the downstream
`level >= required` compare in the derivation function satisfies for any
tier.

## Server-side caveat

SpooferPro features that hit Niantic (routes, GPX, snipe, nearby) are
server-proxied through SpooferPro's own backend, which validates the
account's real subscription status. Client patches unlock the UI but
server-proxied features may remain gated. The v2 release notes already
call this out.

## On-device status: v4 launches but Pro/Elite rows stay grayed

v4 as built (fifth gate stock, LEVEL epilogue override at `0xbdbc8` →
`0xff`) launches cleanly, but Pro/Elite menu rows remain disabled.

### What static analysis showed (2026-11-09)

The "LEVEL getter" label from the release notes appears to be wrong:

- `0xbcf70` has only 2 direct BL callers.
- Caller 1 at `0xbbb3c` is inside the function at `0xbb7a4`, which
  `__objc_const @ 0x181d2a8` identifies as **`.cxx_destruct`** — a C++
  destructor, not an entitlement check.
- Caller 2 at `0xbddb4` is inside `0xbdce8`, which only one BL caller
  (`0x7da5f0`) invokes, and uses the return in `csel x20, x0, x20, lt`
  — a `min(x0, x20)` bounds computation, not a gate check.

So `0xbcf70` isn't what grayed menu rows read. v4's epilogue-override
there is harmless but also useless for the grayed-row problem.

The four tier wrappers and the fifth gate are called via BL with the
pattern `cbz w0, <fail>` or `cmp w0, #1; b.ne <fail>` — they are real
gate functions, and all return 1 (Pro) as expected. Features that call
them directly DO get through. Pro/Elite rows that stay grayed are
therefore reading tier state via a *different* code path.

Likely paths, all behind indirect dispatch:

- Swift witness-table dispatch on the obfuscated tier class
  `m7b0kltierv88d9uurjwk` (ObjC class @ `0x1a006b8`, class_ro_t @
  `0x193fc30`). Its ObjC side has **zero methods, ivars, properties**
  (`baseMethods = 0`, `ivars = 0`, `baseProperties = 0`, `instSize = 8`,
  `flags = 0x80`): the whole class is Swift-internal. None of its state
  is reachable through ObjC runtime walks.
- A stored tier value in `__bss` or `__thread_bss` written at runtime.
  The TLS slot at `0x1bac75c` that we saw the "getter" touch is one
  candidate; the others are heap ivars on the tier class, unknowable
  from a static image.
- Server-driven: a receipt-check response that sets the tier at startup.

`0x7cff64` ("central compare" candidate) has 131 BL callers, but a
mechanical pass of the 3 insns after each BL shows **129 of them ignore
the return** (no cmp/cbz/mov consumes `w0`/`x0`). It's a side-effect /
telemetry helper, not a gate. The two that DO use the return
(`0x50e36c`, `0x9689e4`) are exposed in the injector as
`--pregate-override` for an experiment.

### Next moves to try

| Move | Flag | Risk |
|---|---|---|
| Try the pre-gate return override anyway (2 of 131 callers use it) | `--pregate-override` | low — only one `ldr x0,[x8]` becomes `mov x0,#1` |
| Vary the LEVEL epilogue value (maybe tier is an enum, not a magnitude) | `--level-value 1`, `--level-value 2`, `--level-value 3` | low |
| On-device dynamic diagnosis — recommended | — | needs device |

### For dynamic diagnosis (recommended path)

The static graph can't tell us which function reads the tier at UI
render time. The quickest way to find it on-device:

- Install the v4 build and open the menu with Pro/Elite rows visible.
- Attach `debugserver`/LLDB to the running `PokmonGO` process (TrollStore
  jailed users: Frida with CoreTrust bypass, or use an unsigned
  `debugserver` via `ldid` on a jailbroken device).
- `image list libSpooferPro` to find the slide; break on `0x7cff64`,
  `0xbcf70`, each of the 4 tier wrappers, and `0x7da430`. Tap a grayed
  row — see which (if any) are hit at the moment of render vs. tap.
- If none are hit at render time, break on common UI setters —
  `-[UITableViewCell setAlpha:]`, `-[UIView setUserInteractionEnabled:]`,
  `-[UIControl setEnabled:]` — filter to the row's cell and walk the
  backtrace back into `libSpooferPro`.
- The function at the top of that backtrace is the real tier getter.
  Overwrite its epilogue (or mid-function value load) the same way we
  fixed `0xbdbc8`.

### Also worth investigating

1. Receipt-validation bypass for server-proxied SpooferPro features.
   Likely lives in the same dylib's auth/JWT flow — look for
   `NSURLSession` + `SwiftProtobuf` + `Downstream_SubscriptionResponse`
   handlers. The class `Downstream_SubscriptionResponse` is in the ObjC
   class list and its methods are enumerable.
2. The paywall string's 5 xref sites (`0x2fe1d0`, `0x3cccac`, `0x4ade84`,
   `0x6a9634`, `0x986e08`) all sit in functions with **0 BL callers** —
   they're reached only through indirect dispatch, same as the tier
   readers. Any patch to their enclosing functions would be
   diagnostic-only.

## Bag cleaner — exposed as plain ObjC (audited 2026-11-10)

After 20+ builds fighting `_GetN2Api` poison / Zenject Resolve crashes /
anti-tamper for SPPlus to do il2cpp invocations itself, the audit of
`libSpooferPro.dylib` revealed the bag cleaner is already a plain ObjC
class — no il2cpp needed on our side, we just call its selectors.

Full method surface:

```
Class: gu5nyo3pkexjug7to2       (obfuscated name; class_t @ 0x1a012c0,
                                 classref slot @ 0x19ad6a0)
Methods @ 0x194c948 (method_list, 9 entries):
  imp @ 0x7695c8  init
  imp @ 0x7698b0  PerformPokemonCleanupTask:completion:
  imp @ 0x76e728  TransferPokemon:
  imp @ 0x76fa2c  releasePokemon:
  imp @ 0x770f34  PerformPokemonCleanupManually
  imp @ 0x77379c  isCleaning
  imp @ 0x7737a4  setIsCleaning:
  imp @ 0x7737ac  isManualCleaning
  imp @ 0x7737b4  setIsManualCleaning:
```

Class-method accessor: **`+[gu5nyo3pkexjug7to2 sharedCleaner]`** (selref
@0x199ede0 → selname `sharedCleaner` @0x15e5bda). The singleton is
created during SpooferPro's own init, so by the time our `SP+` sheet is
usable it's already live — our call retrieves it, does not create it.

Related selectors clustered in __objc_selrefs @0x199edc0..0x199edf8:

```
[0x199edc0] = 'pokemonProtoCpp'
[0x199edc8] = 'fb8cxluyr7o855q:'          (obfuscated — likely a per-mon filter query)
[0x199edd0] = 'setPokemon:'
[0x199edd8] = 'showCellActions:'
[0x199ede0] = 'sharedCleaner'              ← accessor
[0x199ede8] = 'releasePokemon:'            ← per-pokemon release
[0x199edf0] = 'favouriteMon:'              ← favorite marker
[0x199edf8] = 'cwd9iyfz8wl9eqjf:9o217u:'   (obfuscated — likely a bulk filter)
```

`PerformPokemonCleanupManually` has exactly ONE BL caller across the
whole binary (at 0xa4a934, inside the Pro-gated UI button handler).
Calling the selector from outside that call site bypasses the gate —
no license check is between `sharedCleaner` and the method, only in
the UI button-enable logic.

Three-line unlock from inside SP+:

```objc
Class cls = objc_getClass("gu5nyo3pkexjug7to2");
id cleaner = [cls sharedCleaner];
[cleaner PerformPokemonCleanupManually];
```

### FOLLOW-UP 2026-11-10 — the ObjC bypass runs but DOES NOTHING

v23 shipped with the three-line bypass wired to SP+'s "Clean Bag Now"
button. On-device log `debug/crashes/v23-sppro_plus.log`:

```
236  [SP+] SpooferPro cleaner: invoking PerformPokemonCleanupManually on 0x152dd3260
237  [SP+] SpooferPro cleaner: dispatch returned (async cleanup is in flight)
...
256  [SP+] SpooferPro cleaner: invoking PerformPokemonCleanupManually on 0x152dd3260
257  [SP+] SpooferPro cleaner: dispatch returned (async cleanup is in flight)
...
269  [SP+] SpooferPro cleaner: invoking PerformPokemonCleanupManually on 0x152dd3260
270  [SP+] SpooferPro cleaner: dispatch returned (async cleanup is in flight)
```

Three button presses across ~4 minutes, same singleton pointer each
time, every dispatch returned cleanly — **and neither the pokemon bag
nor the item bag changed**. The call is a silent no-op.

Earlier reading of "the implementation at 0x770f34 loads from the
invoke-table pointer `*(0x16447C8)`" was wrong. `0x16447C8` is inside
`__got` and is just `___stack_chk_guard` — the stack cookie, not an
invoke table. The real dispatch pattern uses encrypted state words
loaded from `hooksengine_ek::g_hooker_lib` (SpooferPro's VM data
block). See the new section below.

Likewise: there is NO separate ObjC item-bag cleaner class worth
wiring — the `gu5nyo3pkexjug7to2` class exposes only pokemon methods
(`TransferPokemon:`, `releasePokemon:`), and its surrounding selref
cluster at `__objc_selrefs 0x199edc0..0x199edf8` is all
pokemon-themed. Item-bag cleanup in SpooferPro's Pro UI is driven
separately (probably through the same VM dispatcher, different
magic constants).

The three-line unlock remains valid shorthand — the gate is NOT in
the UI button-enable logic alone — but it isn't sufficient.

## License-tied VM dispatcher (Option A to re-enable the ObjC cleaner)

**What goes wrong.** Both `-PerformPokemonCleanupManually @ 0x770f34`
and `-PerformPokemonCleanupTask:completion: @ 0x7698b0` begin with
an obfuscated dispatcher that reads encrypted 32-bit words from
`hooksengine_ek::g_hooker_lib` (located at `0x1b17000 + 0x5210` in
libSpooferPro v4-strip; symbol name
`__ZN14hooksengine_ek12g_hooker_libE+0x5210`), XOR-decodes them against
hard-coded constants, and dispatches to the real cleaner only if the
decoded result equals a magic value. On a free-tier license, the
block is populated with values that don't decode to the magic → the
dispatcher takes a no-op branch (or spins on an atomic at 0x1bb8050
until a never-flipped state word changes).

**Prologue of `-[gu5nyo3pkexjug7to2 PerformPokemonCleanupTask:completion:]`:**

```asm
adrp x8, 0x1b17000         ; hooksengine_ek::g_hooker_lib base
ldr  w8, [x8, #0x930]      ; encrypted state flag
mov  w9, #0x5d79
movk w9, #0xc19, lsl #16   ; XOR key = 0x0c195d79
eor  w8, w8, w9
adrp x9, 0x1b17000
ldr  w9, [x9, #0x934]      ; encrypted divisor
mov  w10, #0x957d
movk w10, #0x8c98, lsl #16 ; XOR key = 0x8c98957d
eor  w9, w9, w10
udiv w8, w8, w9
mov  w9, #0xa1f5
movk w9, #0xcc90, lsl #16  ; add  0xcc90a1f5
add  w8, w8, w9
mov  w9, #0x57a9
movk w9, #0xaef6, lsl #16  ; and  0xaef657a9
and  w8, w8, w9
mov  w9, #0xc472
movk w9, #0xc991, lsl #16  ; cmp  0xc991c472  ← target magic
adrp x16, 0x1bb8000
add  x16, x16, #0x50       ; spin lock word @ 0x1bb8050
cmp  w8, w9
b.eq 0x76995c              ; MATCH → proceed to real cleanup
ldar w8, [x16]             ; else: spin on atomic state
mov  w9, #0xa95d
movk w9, #0x6b4d, lsl #16  ; spin threshold = 0x6b4da95d
mov  w10, #0xdefd
movk w10, #0x6ed7, lsl #16 ; spin ceiling   = 0x6ed7defd
cmp  w10, w9
b.hs 0x769964
ldar wzr, [x16]
b    0x769940              ; back to top of spin
```

The decoded expression that must hold for the cleaner to run:

```
((((g_hooker_lib[0x930] ^ 0x0c195d79)
   / (g_hooker_lib[0x934] ^ 0x8c98957d))
  + 0xcc90a1f5) & 0xaef657a9) == 0xc991c472
```

**Patch options (ordered by effort / robustness):**

1. **Flip the branch at 0x7698f8 (approx) from `b.eq` to `b` (always).**
   Smallest change: NOP-or-rewrite the gate so the method always
   proceeds to the cleanup body. Requires inject_spooferpro.py to
   emit a 4-byte instruction overwrite at the branch site in
   `libSpooferPro.dylib`. Risk: downstream code paths inside the
   cleanup body may themselves re-check `g_hooker_lib` state and
   bail. A full audit of every `adrp x?, 0x1b17000` in the method
   body is needed before assuming one branch flip is sufficient.
   Exact file offset: __text VMA 0x4000 → file offset = VMA − 0x4000
   = (branch site) − 0x4000.

2. **Populate `g_hooker_lib[0x930]` and [0x934] with Pro-decode
   values at runtime.** From the formula above, any pair
   `(A, B)` where `((((A^0x0c195d79) / (B^0x8c98957d)) +
   0xcc90a1f5) & 0xaef657a9) == 0xc991c472` works. Simplest choice:
   set `A^0x0c195d79 = B^0x8c98957d`, so the division yields 1,
   then `(1 + 0xcc90a1f5) & 0xaef657a9` must equal `0xc991c472`.
   0xcc90a1f6 & 0xaef657a9 = 0x8c9001a0. Does not match 0xc991c472,
   so the division ≠ 1. Solve algebraically or brute-force in a
   script (~2^32 keyspace per unknown, but constrained enough to
   search in minutes with the right ordering). Risk: this is only
   the FIRST gate — later ones use different offsets (0x940, …) and
   likely different magic constants. Each needs its own solve.

3. **Discover the Pro-tier values from a signed-response capture.**
   SpooferPro's license response from `static.spooferpro.com` at
   session start populates these slots. A MITM proxy capture of
   that response on a Pro-licensed device would give us the full
   block to memcpy at init time. We don't have a Pro license for
   capture, and the response is likely signed so synthesis won't
   validate client-side. Needs an inside-out solve of SpooferPro's
   own license decoder.

**Why we picked Option B (our own rpc2 path) over A instead.** Even
assuming we solve all N gates, SpooferPro's cleanup body ends up
calling the game's own `IPokemonBag.ReleasePokemon` via SpooferPro's
il2cpp invoke — which is precisely the path v11..v22 crashed trying
to reach, because our `DiContainer.Resolve` chain hit a non-code-signed
anonymous page. If we re-enable the ObjC dispatcher we still run into
the same il2cpp instance-resolve crash class; we've just moved the
gate upstream. Option B bypasses the entire problem by reading
inventory off the rpc2 wire (via our already-flowing hook on
UnityWebRequestDelegate) and sending `METHOD_RELEASE_POKEMON=112`
envelopes signed by the game's own auth from `gTemplate`.

If someone later wants to pick up Option A: the branch offset to
flip in `-PerformPokemonCleanupTask:completion:` is roughly at
file offset `0x7698f8 - 0x4000 + <__text file offset>`. Verify the
target jump destination on each build — the obfuscator may re-shuffle
offsets per release.

## libSpooferPro anti-tamper (crashes the app when SPPlus is injected)

**Symptom:** game crashes on launch when a build with
`SPPlus.framework/SPPlus` injected via LC_LOAD_DYLIB is installed.
libSpooferPro.dylib still launches on its own; only the combo crashes.

**Evidence:** libSpooferPro imports from dyld:

```
_dyld_register_func_for_add_image
_dyld_register_func_for_remove_image
_dyld_get_image_header / _get_image_name / _image_count
_sysctl / _sysctlbyname
```

and ships the literal string `/Library/MobileSubstrate/DynamicLibraries/SpooferPro.dylib`
— it knows what it is and watches for foreign dylibs. The add-image
callback runs on every `LC_LOAD_DYLIB` resolution, so when SPPlus
loads it fires with SPPlus's path and almost certainly aborts.

Found via stub trace (PoGo 0.743 build):

- Stub for `__dyld_register_func_for_add_image` at `0xea54f4`.
- Five BL callers (= five callback registrations):
  `0x606bc4, 0x606c84, 0x00c50e50, 0x00c510ac, 0x00c54e3c`.
- Three of them pass identifiable callback entry points via `adrp+add`:
  `0x6055ac, 0x00c51478, 0x00c55028`. The other two compute the
  callback pointer indirectly (`mov x0, x21` from earlier register
  setup; `bl` helper).

**Fix in `tools/inject_spooferpro.py`** (defaults on when SPPlus is
also being injected): defense-in-depth —

- NOP each of the 5 registration BLs so no callback is ever handed
  to dyld.
- Also force the 3 identifiable callback entry points to `ret` so
  if we missed an indirect registration, the callback is a no-op.

Toggle via `--strip-antitamper` / `--no-strip-antitamper`. When
present the SpooferPro-v4-spplus IPA produced from v1 has SHA-256
`b5f49d6dd386d7f6ffa988cf0396ec748202b4ad746a10b516ea9f4d58f5ade6`.

If the launch crash persists after this patch, the sync image enum
at init (7 BL callers of `_dyld_image_count`, 7 of
`_dyld_get_image_header`) is the next thing to disarm.

## SpooferProPlus — add-our-own-on-top approach

Static patching can't reach the obfuscated Swift tier dispatch; dynamic
analysis is the only way to pin down the tier read path. So instead of
continuing to fight the mod's own UI, we inject our own feature dylib
alongside — the same strategy IPAuto uses for iPoGo.

### Files

- `next-game/spooferpro/SpooferProPlus.m` — feature-parity fork of
  `next-game/pogo/IPAuto.m`, renamed to avoid any symbol collision.
  Includes: NSURLSession class-cluster swizzle (with per-class original
  IMPs), protobuf rpc2 parser, release-on-catch, bag-cleaner, keep rules
  (shiny/100IV/favorite/buddy/lucky/legendary/IV%/species), log rotation
  at 1 MB, floating "SP+" button with alert-sheet toggles.
- `tools/inject_spooferpro_plus.py` — ships the dylib as
  `Payload/PokmonGO.app/Frameworks/SPPlus.framework/SPPlus`, adds
  `LC_LOAD_DYLIB` on the stub, strips the stub's now-stale
  `LC_CODE_SIGNATURE`, enables `UIFileSharingEnabled` so
  `Documents/sppro_plus.{json,log}` are visible in Files.app. Verifies
  the input really is a SpooferPro IPA (looks for
  `Frameworks/libSpooferPro.dylib`).
- `.github/workflows/build-spooferpro-plus.yml` — builds SPPlus on
  `macos-latest` with a self-signed cert (NOT ad-hoc — Signulous-style
  re-signers enumerate nested binaries by their CMS blob) and a
  re-sign + verify pass that mirrors the IPAuto workflow.

### Usage

```sh
# From the shipped SpooferPro-v1 IPA, which is the known-working build:
python tools/inject_spooferpro.py       SpooferPro-v1.ipa  patched.ipa     # optional: fifth-gate + LEVEL-safe
python tools/inject_spooferpro_plus.py  patched.ipa  SPPlus  final.ipa     # adds SP+ feature dylib
# flash final.ipa with TrollStore / Signulous / AltStore
```

### Why IPAuto never worked right — audited 2026-11-09

Pulled iPoGo 4.6.1's `Frameworks/Sentry.framework/Sentry` (16.8 MB, iPoGo's
actual payload) and cross-referenced against SpooferPro's own
`libSpooferPro.dylib`. **Both mods invoke il2cpp directly — neither splices
rpc2.** This is the architectural reason our IPAuto-derived rpc2 approach
is unreliable.

Evidence from iPoGo Sentry (strings on the dylib):

```
il2cpp_init                       il2cpp_class_get_name
il2cpp_domain_get                 il2cpp_class_get_namespace
il2cpp_domain_get_assemblies      il2cpp_class_get_method_from_name
il2cpp_assembly_get_image         il2cpp_class_get_field_from_name
il2cpp_image_get_class            il2cpp_field_static_get_value
il2cpp_image_get_class_count      il2cpp_runtime_invoke
il2cpp_runtime_class_init         il2cpp_object_new
il2cpp_thread_attach              il2cpp_object_get_class
il2cpp_thread_current             il2cpp_string_new
il2cpp_thread_detach              il2cpp_string_chars
il2cpp_type_get_name              il2cpp_string_length
il2cpp_type_get_object            il2cpp_array_new
il2cpp_class_from_type            il2cpp_gchandle_new
il2cpp_class_get_type             il2cpp_method_get_param
```

SpooferPro has a full **ObjC bridge** that exposes il2cpp invoke by name:

```
InvokeBoolFunction:withObject:args:
InvokeIntFunction:withObject:args:
InvokeLatLngFunction:withObject:args:
InvokeRetFunction:withObject:args:
InvokeRetFunctionWithImageName:nameSpace:className:functionName:args:
InvokeRetFunctionWithImageNameStatic:nameSpace:className:functionName:args:
InvokeRetFunctionWithMethodInfo:methodInfo:args:
InvokeUInt64Function:withObject:args:
```

And method constants for every action it automates:

```
MethodReleasePokemon        MethodUseItemCapture
MethodFortSearch            MethodUseItemEncounter   (berry feed)
MethodUseItemFlee           MethodUseItemBattleBoost
MethodUseItemBulkHeal       MethodUseItemEggIncubator
MethodUseItemLuckyFriendApplicator  MethodUseItemMoveReroll
MethodUseItemPotion         MethodUseItemRareCandy
MethodUseItemRevive         (…)
```

**Neither mod's payload contains a protobuf parser** or any splicing logic.
They call `IPokemonBag.ReleasePokemon(PokemonProto)` on the game's own C#
instance; the game assembles and signs the rpc2 envelope itself, which
sails past Niantic's anti-cheat signature checks (platform_requests[5]
HasAbrLookup + packed timing signatures).

### What this means for us

Our SpooferProPlus port of IPAuto's rpc2 splicer is **architecturally the
wrong tool for the job**. Even after the safety hardening in the previous
commit (parse-looks-broken fail-safe, dry_run, bag_clean_max), a live
batched RELEASE_POKEMON=112 from our own `NSURLSession` has a very
different envelope shape from one the game emits, and Niantic is likely
to reject or shadow-ban on that signal. That matches the "IPAuto never
worked correctly" report.

### What UnityFramework's export table says

UnityFramework ships with a **24-byte empty export trie** — it exports
nothing. iPoGo and SpooferPro resolve every `il2cpp_*` call via **hardcoded
file offsets** into UnityFramework, pinned per PokémonGO version
(POGO-FINDINGS already recorded this: "resolved via per-build hardcoded
offsets (hence version pin 'v0.435.1')"). iPoGo is pinned to PoGo 0.435.1,
SpooferPro to 0.743. The two IPAs cannot share an offset table.

Building an il2cpp bridge for SpooferProPlus (PoGo 0.743) requires:

1. A full il2cpp dump of this UnityFramework (191 MB) with
   Il2CppInspectorRedux — classic Il2CppDumper 6.7.46 caps at metadata v31,
   this build is metadata v39.
2. From the dump, extract offsets of ~14 `il2cpp_*` runtime entry points
   inside UnityFramework.
3. In the dylib: dlopen UnityFramework, resolve each entry point by
   image-base + offset, cache in a per-version table.
4. Implement `invoke_il2cpp(image, namespace, class_name, method_name, args[])`
   — walk assemblies/classes/methods via the entry points, cache the
   `MethodInfo *` by name, call `il2cpp_runtime_invoke`.
5. For release-on-catch specifically: resolve `IPokemonBag` via the
   `ProjectContext._instance.Container` Zenject chain (POGO-FINDINGS has
   the field offsets from the iPoGo dump but they're pinned to 0.435.1).

That's one or two sessions of work on its own.

### Safety discipline (critical — IPAuto's heritage of "never worked right")

Every automation feature in this dylib reads PokemonProto fields whose
numbers are **inferred, not read from a .proto for this build**. If any
of them is wrong (e.g. `shiny` lives in a different nested field on
v0.743 than it did on v0.241), the parse returns all zeros and
`should_keep` would say "release" for genuine keepers. The cost of a
silent wrong answer is a wiped bag.

Three concentric safety rails, from outside in:

1. **`dry_run: true` by default.** Every release — single or batched —
   is logged with full context and *nothing is posted to Niantic*.
   The on-screen sheet shows `DRY-RUN` in large text and the toggle
   is the first row. You must deliberately flip it to go live.
2. **`bag_clean_max: 50` (% of bag) per-batch safety abort.** If the
   keep-rule evaluator decides to release more than 50% of the bag in
   one HOLO_INVENTORY response, the batch is aborted with a loud log.
   Set `bag_clean_max` higher (up to 100) only after on-device
   verification.
3. **`parse_looks_broken()` fail-safe in `should_keep()`.** When a mon
   has `species <= 0 || species > 1500`, OR every scalar we extract
   is at its memset-zero default (atk=def=sta=0 AND no flags set AND
   egg=0), the mon is assumed to be a parse miss and kept
   unconditionally. This catches the common case where ASSUMED proto
   field numbers are off by one or two.

### Features working today (ported from IPAuto with safety hardening)

- `release_on_catch` — on CATCH_POKEMON=103 response status=SUCCESS,
  splice RELEASE_POKEMON=112 for the captured uid, with keep-rules
  evaluated against the mon's data from the next HOLO_INVENTORY delta.
  Default **off**. Each release goes through `should_keep` which has
  the parse-looks-broken fail-safe, and then through `release_pokemon`
  which respects `dry_run`. On the catch response itself, if uid is
  unset but status=SUCCESS, the raw blob is logged as hex so the user
  can eyeball the correct field.
- `bag_full_clean` — on HOLO_INVENTORY=4 with mon count >= threshold,
  batch-release non-keepers in ONE spliced request. Safety abort fires
  if the batch exceeds `bag_clean_max` percent of the bag. Default
  **off**.
- Manual "Clean Bag Now" action in the sheet (gCleanOnce) — same
  safety rails as the automatic path.
- **Keep-rule evaluator (`should_keep`)**, ordered:
    1. `parse_looks_broken()` → keep (unconditional fail-safe).
    2. egg → keep (never releases eggs).
    3. `keep_species` match → keep.
    4. `drop_species` match → release. (Was broken in IPAuto: IV%
       check short-circuited, and a mon in `drop_species` with IV ≥
       `iv_pct_min` was NEVER dropped. Fixed by reordering.)
    5. favorite/buddy/lucky/shiny/hundo/legendary flags → keep (each
       gated by its `keep_*` toggle).
    6. IV% ≥ `iv_pct_min` → keep. (Formula now uses rounded-to-nearest:
       `(sum*100 + 22) / 45` so 40/45 reads as 89% matching the
       in-game display, not the truncated 88% of the IPAuto port.)
    7. Fallthrough → release.
- Rotated log at `Documents/sppro_plus.log(.1)` capped at 1 MB.
- `encounter_log` — on ENCOUNTER=102 / DISK_ENCOUNTER=145, log the
  wild Pokémon's species, IV, shiny flag.
- **`requests_field`** config override: Niantic's RequestEnvelope has
  used field 4 for `repeated Request requests` since v0.117+. The
  old auto-detector picked wrong when the first observed envelope
  only carried low-id methods. Now hardcoded to 4 with a config
  override — the first envelope's top-level field layout is logged
  once so a mismatch is obvious.
- `auto_catch` (new) — on ENCOUNTER=102 (or DISK_ENCOUNTER=145), splice
  CATCH_POKEMON=103 with a configurable pokeball (field 2: 1=Poké /
  2=Great / 3=Ultra / 4=Master), reticle=1.95 (excellent), spin=1.0
  (curveball), hit_pokemon=true. encounter_id (fixed64 field 1) and
  spawn_point_id (string field 4) are scanned from the response via a
  conservative field walk (`parse_encounter_ids`): fixed64 at depth
  ≤2 and a 12..64-char hex string. Delay is `auto_catch_delay_ms` ms
  (default 1200) via `dispatch_after` to avoid instant-throw
  fingerprinting. Composes with `release_on_catch` — a successful
  auto-catch feeds the uid into the next HOLO_INVENTORY keep-rule
  evaluator, so you can auto-catch + auto-release-if-not-keeper in one
  flow.

### Features scaffolded, awaiting on-device config

- `block_non_shiny` / `block_non_hundo` / `block_non_shundo` — toggles
  live in the sheet AND the ENCOUNTER=102 handler already parses the
  wild Pokemon and evaluates the criteria. **Blocking requires a valid
  `flee_method_id` in `sppro_plus.json`** — the method id for
  "RUN_FROM_ENCOUNTER" varies by Pokémon GO version and isn't in our
  known-ids table for v0.743. Steps to enable:
    1. Install the app with the encounter blocker toggles OFF but
       `encounter_log=true`.
    2. In Pokémon GO, attempt to flee a wild encounter manually with the
       standard Run button.
    3. Open `Documents/sppro_plus.log` from Files.app. The first rpc2
       round-trip after the flee will log the method id used.
    4. Set `"flee_method_id": <id>` in `sppro_plus.json` and flip the
       block toggles on.

### Features to add next

Two tracks now. Pick one; the first is tiny, the second is a project.

**Low-stakes rpc2 observers (won't post anything):**

| Feature | Approach | Complexity |
|---|---|---|
| CATCH-response logger | Log full CatchPokemonOutProto blob hex on every status=SUCCESS so uid field (ASSUMED 3) can be verified | low |
| Nearby-shiny alert | GET_MAP_OBJECTS=106 scan + `UNUserNotificationCenter` local notification | medium |
| Journal of everything caught | SQLite in Documents, UI tab | medium-high |
| Teleport to coordinates (with cooldown) | Swizzle `CLLocationManager startUpdatingLocation` to feed our own coords | medium |

**il2cpp bridge — phases 1–3 landed, phase 4 is the Zenject chain**

Mirrors iPoGo's and SpooferPro's design. Progress:

- **Phase 1 ✅** `tools/dump_il2cpp_offsets.py` parses UnityFramework's
  `LC_SYMTAB` directly (llvm-nm hangs on 191 MB) and emits a C header.
  29 of the il2cpp_* glue entry points were found for PoGo 0.743; they
  cluster in a tight 0x20b92c..0x20c854 VMA range (libil2cpp runtime).
  Header: `next-game/spooferpro/il2cpp_offsets_pogo0743.h`.

  UnityFramework exports a 24-byte empty trie, so `dlsym` can't find
  these symbols — but they're still present in the classic symbol
  table. The dumper walks `nlist_64` entries once at build time.

- **Phase 2 ✅** `next-game/spooferpro/il2cpp_bridge.{h,c}` dlopens
  UnityFramework, locates its mach_header via `_dyld_image_name`,
  reads the ASLR slide via `_dyld_get_image_vmaddr_slide`, and
  materialises typed function pointers for every il2cpp_* glue we
  need. One-shot init on a 2-second dispatch_after from
  `spplus_init` so UnityFramework has time to boot.

  Exposes `spp_il2cpp_find_class` (walks every assembly's class list,
  caches hits) and `spp_il2cpp_find_method` (calls
  `il2cpp_class_get_method_from_name` with implicit
  `il2cpp_runtime_class_init`). Both have result caches so the
  linear-scan cost is paid once per name.

- **Phase 3 ✅ (scaffold)** `spp_il2cpp_probe_release_pokemon()` walks
  likely namespaces for Pokémon GO's bag class — currently
  `Niantic.Holoholo.Inventory.Pokemon.PokemonBagImpl` plus fallbacks
  for `PokemonBag` / `IPokemonBag` — and logs whether
  `ReleasePokemon(1)` resolves. Runs at init so the user can verify
  class/method naming on their build in `sppro_plus.log` before
  trusting the path.

  `release_mode` config now dispatches between `rpc2` (default,
  current fragile path), `il2cpp` (try il2cpp, fall back to rpc2 on
  failure), and `il2cpp_only` (never fall back). The sheet header
  also shows `il2cpp READY` / `off` based on
  `spp_il2cpp_ready()`.

- **Phase 4 ✅ (needs on-device verification).** Full invocation path
  landed. The resolver walks four strategies, logging each step so
  class-name mismatches on a new build surface in `sppro_plus.log`
  instead of silently failing:

    A. `PokemonBagImpl.Instance / _instance / s_Instance` static field
    B. `PokemonBagImpl.get_Instance()` static property
    C. Zenject: `ProjectContext._instance` →
       `get_Container()` → `Resolve(typeof(IPokemonBag))` — no
       field-offset knowledge needed; we use the property getter and
       the non-generic `Resolve(Type)` overload.
    D. `GameManager.Instance` → `get_PokemonBag()` /`get_Bag()` /
       `get_IPokemonBag()`

  If every strategy misses, the resolver dumps the first 32 methods +
  fields of `PokemonBagImpl` to the log (via a new
  `spp_il2cpp_dump_class_members` diagnostic) so the user can tell us
  the right accessor name without more guesswork.

  The actual release call:
  1. Resolve `PokemonProto` class via `spp_il2cpp_find_class`.
  2. `il2cpp_object_new(pokemonProtoClass)`.
  3. Set the `PokemonId` field via `set_PokemonId(ulong)` property
     setter (safer than field-offset writes; falls back to dumping
     class members on miss).
  4. `il2cpp_runtime_invoke(releaseMethod, bagInstance, {proto})`.

  Also added: `il2cpp_method_get_name`, `_param_count`,
  `class_get_methods`, `class_get_fields`, `field_get_name`,
  `field_static_get_value`, `type_get_object` — all 40 entry points
  in the generated offset header now.

  The release path is wired through `release_mode="il2cpp"` in
  `sppro_plus.json`. Default stays `"rpc2"` so a broken resolver
  can't hurt an existing user; opt-in once the log confirms the
  probe resolves a `(class, method, instance)` triple.

Next: once on-device logs show which strategy wins and whether
`set_PokemonId` exists under that exact name, tighten the resolver
(cache the first-successful path) and wire the rest of the
automation (bag-clean, auto-catch, berry-feed, auto-spin) onto the
same bridge. Each becomes ~10 lines (same as iPoGo's
MethodReleasePokemon / MethodFortSearch / MethodUseItemEncounter /
MethodUseItemFlee bindings).

Once Phase 4 lands, bag-clean, auto-catch, berry-feeding, auto-spin
and bulk-evolve all become 5-line functions that just resolve+invoke
the matching method (`MethodReleasePokemon`, `MethodUseItemEncounter`,
`MethodFortSearch`, etc — same names SpooferPro uses).

## rpc2 template capture — gotchas and preconditions (v25)

v24 on-device test (`debug/crashes/.../v24-sppro_plus.log`) showed the
manual bag-clean splice succeeded — three HOLO_INV requests went out,
three 100-byte responses came back — but nothing happened to the bag.
Root-cause audit found the captured envelope template was a pre-login
handshake / heartbeat envelope, NOT a logged-in `RequestEnvelope`.

### Symptom pattern

```
475  [SP+] rpc2 envelope layout: f0×1 f2×1
477  [SP+] methods: f0×1 f2×1          ← uninitialized stack memory (v24 bug)
...
545  [SP+] manual bag clean: splicing HOLO_INV seq=10
546  [SP+] spliced response 100B — dispatching to handle_response
```

Two red flags:

1. **`f0×1 f2×1` layout.** A real `RequestEnvelope` on pogo-0.743 has
   fields 1 (status/sequence), 3 (lat), 4 (lon), 6 (requests[]),
   10+ (platform_request/auth). A `f0×1 f2×1` envelope is either
   something before login or a response to an auth token refresh.
   Field 0 is invalid proto — our `pb_field` parser surfaces it when
   the first byte is `0x02` (length-delimited field with field number
   0, i.e. garbage-shaped data) or when the data is not protobuf.

2. **100-byte response.** A real `HOLO_INVENTORY` response is tens of
   KB (even for a thin bag — the auth/status/returns envelope alone
   is a few hundred bytes). 100 bytes is a server-side error tombstone.

### What v25 fixes

- `template_quality()` gate — reject a candidate template unless:
  - size ≥ 500 bytes
  - at least one submessage with a 1..1000 varint as its first inner
    field (looks like a method id)
  Preserves the biggest known-good template across the session;
  thinner envelopes don't overwrite.

- Auto-detect the `requests` field number. If the first method-id-
  carrying submessage lives at field 4 (historical default), use 4.
  Otherwise use whichever field number holds the first candidate
  submessage. User can still override via `requests_field` in
  `sppro_plus.json`.

- `hex_dump()` first 64 bytes of each captured template so a wrong
  capture is obvious in the log.

- Bug fix: the `[SP+] methods:` line was reading uninitialized stack
  memory when `nM==0`, producing the confusing mirror of the layout
  log. Now only emits when methods were actually extracted, and
  initializes the buffer.

- Response-side diagnostic: if the response has zero field-100
  returns, log that explicitly with the response size and first
  32 bytes — much clearer than a silent "dispatching" message.

- Dashboard row: the main pane now shows `rpc2: captured (NNNN B,
  requests at field 4)` or `rpc2: not captured yet — move around
  the map or open the bag in-game`. Status at a glance.

### Preconditions for a successful Clean Bag Now

Before tapping:

1. Sign in through the normal PoGo flow.
2. Reach the map (sees your avatar).
3. Walk/move for a few seconds, or open the in-game pokemon storage
   screen, so the game sends a real `GET_HOLOHOLO_INVENTORY=4` or
   `GET_MAP_OBJECTS=106` request.
4. Check the SP+ sheet status: it must read `rpc2: captured (...)`.
5. Only then does Clean Bag Now have a valid envelope to splice.

### Why we can't shortcut this

The template carries the game session auth tokens, encoded
sequence/time offsets, and the per-session platform_request chain
Niantic's anti-cheat validates. Without those, any envelope we POST
is rejected server-side as unauthenticated — even if we solve every
other schema puzzle.

### Known open questions

- Does `pgorelease.nianticlabs.com/plfe/rpc2` still carry the real
  rpc2 traffic on pogo-0.743, or has it moved to a newer path? v24
  log shows only `/plfe/version` task completions on that host — but
  our hook_dt wrap did fire a template capture, suggesting SOME
  `/plfe/rpc2` request completed via the completion-handler path
  (hook_dt), just not visibly in the `niantic task done:` log
  (which only fires from the delegate-based `hook_done`). Adding a
  log line inside the hook_dt wrap would resolve this.

- Are other PoGo hosts hosting rpc2-shaped traffic? The v24 log
  shows these Niantic hosts flowing: `identity-public`, `identity`,
  `platform-account-assets`, `pgorelease`, `maptiles`,
  `prodholoholo-public-images`. Of these, only `pgorelease` has
  been a historical rpc2 host. If PoGo moved to e.g. `platform-game`
  or a new subdomain, our URL filter `containsString:@"/plfe/rpc2"`
  misses it entirely. TODO: widen to any `pgorelease.nianticlabs.com`
  POST ≥500B if the v25 template-quality gate still doesn't catch
  a good envelope.

## ★ ROOT CAUSE (v25): /plfe/rpc2 is FlatBuffers, not Protocol Buffers

The single most important finding of the whole effort. On-device v25 log
(`da42e313-sppro_plus.log`) with the template-quality gate finally gave
us the raw bytes:

```
800  [SP+] template REJECTED (thin/pre-login): 384B url=.../plfe/rpc2
801  [SP+] thin template (384B, first 64):
     100000000c00140010000f00080004000c000000100000000100000000000002
     0100000058010000100000000000000008000a00090004000800000018000000
```

Decoded as FlatBuffers (NOT protobuf):

```
[0..3]  root table uoffset = 16
[16]    soffset to vtable   = 12   -> vtable at offset 4
[4]     vtable_size = 12 bytes, table_inline_size = 20 bytes
          field[0] table-relative offset = 16
          field[1] table-relative offset = 15
          field[2] table-relative offset = 8
          field[3] table-relative offset = 4
```

`vtable_size / table_size / 16-bit-aligned field-offset table` is the
unmistakable FlatBuffers layout. Protocol Buffers has no vtable, no
fixed-width offsets, no root uoffset. **PoGo 0.743's rpc2 envelope is
FlatBuffers.**

### Why this invalidates the entire rpc2-splice approach

Every assumption SPPlus was built on is a protobuf assumption:

| SPPlus assumes (protobuf) | Reality (FlatBuffers) |
|---------------------------|------------------------|
| `requests[]` repeated submessage at field 4 | no "fields"; a vtable + inline table |
| method id = varint, first inner field | method dispatch encoded structurally |
| `returns[]` repeated bytes at field 100 | FlatBuffer table/vector, no field 100 |
| splice = append a protobuf field | splice = rebuild the whole FlatBuffer + fix all offsets |
| `pb_varint` / `pb_field` walk | reads FlatBuffer bytes as garbage → `f0×1 f2×1` |

The `f0×1 f2×1` "layout" we saw every build was our protobuf parser
mis-reading FlatBuffer bytes. The 100B spliced responses were
FlatBuffer-encoded errors. Real traffic flows fine (a 3696B inventory
response is in the same log) — we simply can't read or write the format.

### Connection to _GetN2Api

The "N2" (Niantic 2.0 / NIA platform) API we fought for 22 builds — the
`_GetN2Api` brk-poison saga — IS the FlatBuffers rpc channel. SpooferPro
caches the N2 API table at init and poisons the export precisely because
N2 is the live rpc2 surface. It was never a protobuf endpoint.

### The only viable path: il2cpp (the C# layer)

We cannot practically hand-build FlatBuffer N2 envelopes (need the full
.fbs schema + the N2 request signing SpooferPro's own cache encapsulates).
But we don't have to: the game's C# code already does it. Call

```
IPokemonBag.ReleasePokemon(PokemonProto)   // il2cpp probe: RESOLVED
```

via il2cpp and the game serializes the FlatBuffer and signs the N2
request itself. We hand C# a managed PokemonProto; we never touch the
wire format. This sidesteps FlatBuffers entirely.

Blocker (known): getting the live `PokemonBagImpl` instance to call the
method on. v20 used Zenject `DiContainer.Resolve` and hit a CODESIGNING
Invalid Page crash. Non-Zenject instance-acquisition options:
  1. il2cpp GC heap walk — enumerate all objects, find the single
     `PokemonBagImpl` (il2cpp_gc_foreach / managed heap iteration).
  2. Hook a frequently-called `PokemonBagImpl` instance method and
     capture `this` the first time the game calls it; cache the pointer.
  3. Find a static singleton field / get_Instance accessor if one
     exists on the bag or a holder class (v20 probe said no static
     Instance on PokemonBagImpl itself — check holder classes).

Recommendation: option 2 (capture `this` from a hooked bag method) is
the lowest-risk — no Resolve, no heap walk, just a trampoline that
stores a pointer. Once we have the instance, ReleasePokemon is a
direct il2cpp_runtime_invoke with a PokemonProto arg we build via
il2cpp (not via the wire).

### rpc2 code status

`handle_response`, the splice path, `post_env_handle`, and the whole
protobuf envelope machinery are DEAD CODE against 0.743. Keep for now
(older game versions may still be protobuf; and the parsing helpers are
reusable), but gate all splicing behind an explicit
`allow_protobuf_splice` config flag defaulting OFF, and make the UI say
"release runs via il2cpp" once the il2cpp release path lands.

## v26 — il2cpp release path via GC heap walk (bag instance w/o Zenject)

Given the FlatBuffers finding, release must go through the game's own C#
`IPokemonBag.ReleasePokemon(PokemonProto)` (the game serializes the
FlatBuffer + signs the N2 request itself). The only blocker was getting
the live bag instance:

- v20 used Zenject `DiContainer.Resolve` → CODESIGNING Invalid Page SIGKILL.
- Inline-hooking a bag method to capture `this` → fails the hardened-runtime
  code-signature check the same way (can't make `__text` writable).

Solution: **GC heap walk.** `il2cpp_gc_foreach_heap(cb, user)` (present in
0.743 UnityFramework at VMA 0x20c320) enumerates every live managed object
with the GC world stopped. We match the first object whose class is
(assignable to) `PokemonBagImpl`. No Zenject, no code-patching, no
crash-class exposure.

New symbols dumped + bound: `il2cpp_gc_foreach_heap`, `il2cpp_gc_disable`,
`il2cpp_gc_enable`, `il2cpp_class_is_assignable_from` (45/45 total).

New bag-resolve order (`spp_il2cpp_get_pokemon_bag`):
  E. GC heap walk            ← primary, tried first
  A. static Instance field
  B. get_Instance property
  C. Zenject Resolve         ← OFF by default (known crasher; opt-in via
                               spp_il2cpp_set_allow_zenject)
  D. GameManager.PokemonBag

Runs at feature time only (post-login, when the bag exists) — never at
launch. The heap walk + subsequent invokes run on the main thread (Unity's
thread, always il2cpp-attached); the walk hitch is a few hundred ms for a
one-shot button press.

### Open: enumeration API not yet known

We can now find the bag and release one pokemon by uid. We still need the
bag's own pokemon list (we can't read inventory off the wire — it's
FlatBuffers). `spp_il2cpp_bag_inspect()` dumps the bag class's methods +
probes common enumeration accessors (`GetPokemon` / `get_Pokemon` /
`get_Count` / …) and logs the returned collection's class. Clean Bag Now
calls it (when il2cpp is ready) so the next build can wire
enumerate → should_keep → ReleasePokemon against this build's real method
names. The keep-rule evaluation moves from wire-parse (`parse_mon`) to
il2cpp field reads on each pokemon object.

## v26 anti-tamper: il2cpp symbol IOC (force-close on launch)

v26 force-closed at the loading screen with SpooferPro's "This ipa appears
to be tampered with or something is injected" warning. v25 (identical base,
identical stripped libSpooferPro, identical inject + sign steps) launched
fine. The ONLY variable was the SPPlus.dylib binary.

Binary diff of SPPlus-v25.dylib vs SPPlus-v26.dylib
(debug/bin/, pulled from the two IPAs):

- Same linked dylibs (libSystem + self), same 55 imported symbols.
- v26 adds these DEFINED EXTERNAL symbols (exported in the Mach-O export
  trie / symbol table):
    _spp_il2cpp_gc_foreach_heap        ← the smoking gun
    _spp_il2cpp_gc_disable
    _spp_il2cpp_gc_enable
    _spp_il2cpp_class_is_assignable_from
    _spp_il2cpp_bag_inspect  _bag_heap_cb  _g_allow_zenject  …

`il2cpp_gc_foreach_heap` is a textbook IOC (indicator of compromise) for
il2cpp memory-dumping cheats — Il2CppDumper, cheat engines, and heap
scanners all call it, and anti-cheat / anti-tamper systems signature-scan
loaded images for exactly this symbol name. v25's symbol table already
carried `spp_il2cpp_runtime_invoke`, `spp_il2cpp_object_new`, etc. (all
containing "il2cpp") and did NOT trip — so SpooferPro is not scanning for
"il2cpp" broadly; it flags the specific `gc_foreach_heap` heap-enumeration
API the instant it appears.

Verified the IOC strings live in __LINKEDIT (symbol table / export trie),
not __cstring: `foreach_heap` at file offsets 0x1c6aa / 0x1de61, both above
__cstring's end (0x12ced). So they are symbol names, not string literals.
`strip` alone does not remove them (they are exported external symbols the
export trie keeps).

### Fix

SPPlus exports nothing — it runs from a single `__mod_init_func`
constructor, invoked by pointer, never by symbol. So every symbol can be
hidden with zero functional impact (the il2cpp calls resolve by VMA offset,
not by name). CI now builds with:

    -fvisibility=hidden  -Wl,-x  -Wl,-unexported_symbol,'*'
    + strip -x
    + a grep gate that FAILS the build if foreach_heap / is_assignable_from
      / spp_il2cpp / gc_disable survive

This empties SPPlus's symbol name surface, so no il2cpp symbol IOC is
scannable. The gate guarantees we never ship another tamper-tripping dylib
by accident.

Note: this is symbol stripping, NOT code-signature stripping — the
self-signed CMS signature is still applied afterward, so re-signers that
enumerate nested binaries by CMS still see SPPlus.

Open: if a future build still trips, the next suspects are __cstring
literals, but the only SP+-specific ones are log strings and the
`GetPokemon`/`GetPokedex` enumerator names — and those also appear in the
game's own binary, so SpooferPro can't blocklist them without
false-positiving PoGo itself.

## v26/v27 anti-tamper is SERVER-SIDE: raw.spooferpro.com

The tamper warning ("ipa appears tampered / something is injected", force-
close) is NOT a scan of SPPlus's content. Proof, in order:

- Symbol strip (v27) removed every il2cpp symbol — still warned.
- v25 (works) is full of the most incriminating strings possible
  (`ReleasePokemon`, `PokemonBagImpl`, `il2cpp bridge`, `Zenject`, 85
  pokemon/il2cpp cstrings) — SpooferPro does not care.
- v25 vs v26 Mach-O structure (load commands, segments) is identical.

The actual signal is in the network log:

| build | spooferpro hosts hit |
|-------|----------------------|
| v20, v21, v23 (work) | static.spooferpro.com only |
| v27 (warns)          | static.spooferpro.com + raw.spooferpro.com (×3) |

`raw.spooferpro.com` appears ONLY in the force-closing builds, once per
launch, shortly before the kill. It is SpooferPro's tamper-policy/verdict
endpoint — the client fetches a verdict there and acts on it. That is why
no change to SPPlus's own bytes ever moved the needle.

### Fix (v28): starve the tamper endpoint

We already hook every NSURLSession request. For raw.spooferpro.com we now:
- completion-handler path (hook_dt): log the real response (length + first
  48 bytes hex), then invoke SpooferPro's handler with an EMPTY NSData so
  its anti-tamper reads a blank policy.
- delegate path (hook_recvdata): drop every data chunk for that host so the
  delegate's body arrives empty.
Blocked by default; `"allow_raw_spooferpro":1` in sppro_plus.json lets it
through for comparison.

Rationale for empty-200: most "fetch anti-tamper policy" flows treat an
empty/absent policy as "nothing to block = pass". If SpooferPro instead
fails-closed on an empty policy, the logged response body (now captured)
tells us the exact shape to synthesize instead. This is the first move in
what is now a cat-and-mouse with SpooferPro's server — they can change the
endpoint or make the check fail-closed on their next push.

Open: we do not yet know raw.spooferpro.com's real response shape (this
build logs it). If empty-200 fails-closed, next step is to return a crafted
"clean" verdict, or to block the host at the config layer
(static.spooferpro.com likely tells the client to call raw.spooferpro.com —
intercepting that config is the deeper fix).

## v29 — the REAL anti-tamper: local dyld image enumeration

raw.spooferpro.com was a red herring. The uploaded 149-byte POST body to it
decodes to device fingerprint + game state ("MapExplore", "Ultra High",
iPhone18,2, iOS 26.2) — SpooferPro TELEMETRY, not a tamper verdict. Our
stub dropped its response (log: "raw.spooferpro.com delegate data DROPPED")
and the warning still fired. The detector is LOCAL.

Disassembly of libSpooferPro found a SECOND anti-tamper path the add-image
strip misses: libSpooferPro directly enumerates loaded images via
`dyld_image_count` + `dyld_get_image_name`/`dyld_get_image_header`
(+ `task_info` / `mach_vm_region_recurse` anti-debug) at 0xc4f7e4 / 0xc4cfa4,
spots our injected SPPlus.framework in the image list, and shows the
"ipa appears tampered / Game will close" warning. The warning text is
XOR-obfuscated so it never appeared in a strings scan.

Why v25 passed and v26 didn't with the SAME stripped libSpooferPro remains
unproven (likely a SpooferPro server-gated enable flag flipped between the
tests, OR a timing difference in when the scan runs) — but it no longer
matters, because the fix is content-independent.

### Fix: defang dyld_image_count (inject_spooferpro.py)

`DYLD_COUNT_STUB_PATCH` overwrites the `dyld_image_count` stub @0xea54e8 to
return 1 (only the main executable), so every image-enumeration loop sees
nothing to flag:

```
0xea54e8  adrp x16,..  -> mov w0,#1   (52800020)
0xea54ec  ldr  x16,..  -> ret         (d65f03c0)
0xea54f0  br   x16     -> nop         (d503201f)
```

Verified: exactly 7 callers of the stub, all Sentry symbolication (0x3f19xx,
cosmetic) or the anti-tamper cluster (0xc4f/0xc50/0xc51). None in
SpooferPro's core / UnityFramework-lookup path, so location spoofing is
unaffected. Applied under `--strip_antitamper` alongside the existing
add-image strip.

### raw.spooferpro.com stub → opt-in

The SPPlus-side raw.spooferpro.com block is now OFF by default
(block_raw_spooferpro=1 to re-enable as a diagnostic) since it did nothing
and dropping telemetry is a needless confound.

### Fallback if the warning persists

If the scan reads image[0]'s macho header instead of relying on the count,
force the two direct-scan function entries to `ret`: 0xc4f7e4, 0xc4cfa4.
Surgical alternative: patch the single verdict-store (strb/cset) inside
0xc4f7e4 so it always writes "clean" — needs disasm of 0xc4f7e4..0xc4fb00.

## v29 crash → v30: il2cpp managed exec trips the N2 anti-cheat BRK

Anti-tamper is beaten (v29 reached the map, no warning). But tapping Clean
bag now crashed: EXC_BREAKPOINT (SIGTRAP) at UnityFramework+0x7196310.
Decoded stack (debug/crashes/v29-PokmonGO-2026-11-11-125033.ips):

```
0  UnityFramework +0x7196310   ← BRK (N2 anti-cheat tripwire)
11 UnityFramework +0x29b578    ← il2cpp_runtime_invoke
...
36 libSpooferPro  +0x56c830    ← SpooferPro willEnterForeground hook
39 -[_UISceneLifecycleMonitor willEnterForeground]
```

NO SPPlus frames. The BRK is a different tripwire than the _GetN2Api entry
our watch guards (hence restores=0). Mechanism: v29's Clean bag now was the
first build to run the il2cpp path — the heap walk's gc_disable /
gc_foreach_heap, runtime_class_init, and enumeration invokes destabilized
the runtime/GC; the next managed execution (SpooferPro's foreground scene
hook, fired by our sheet dismiss's scene transition) then hit the N2 BRK.
Earlier builds' Clean bag now did the rpc2 splice with zero il2cpp, so the
dismiss→foreground path never crashed.

### v30 fix: metadata-only inspect, no managed execution

spp_il2cpp_bag_inspect now reads ONLY class metadata — method names + arg
counts (il2cpp_class_get_methods) and field names (il2cpp_class_get_fields).
No heap walk, no runtime_class_init (no static ctor), no invoke, no GC
disable/foreach. It runs synchronously BEFORE the sheet dismiss so there is
no scene-transition interleaving. This learns the bag's real enumeration API
(GetPokemon / get_Count / a pokemon-collection field) without touching the
runtime, so the keep-rule clean can be designed against it.

Design consequence: the eventual release must minimize managed execution and
never destabilize the GC. A pokemon-collection FIELD read (no managed code)
is preferred over method invokes for enumeration; the release itself
(ReleasePokemon invoke) must be done carefully, possibly off the
foreground-transition window, with the GC left untouched.

## v36 crash → the Zenject Resolve invoke is unusable on 0.743

v36 flipped `g_allow_zenject=1` at feature time and let Strategy C run
`il2cpp_runtime_invoke(DiContainer.Resolve, typeof(IPokemonBag))`. It SIGKILL'd.

Crash (`debug/crashes/v36-PokmonGO-2026-11-12-065937.ips`):

```
EXC_BAD_ACCESS (SIGKILL) KERN_PROTECTION_FAILURE at 0x11444c700
termination: namespace CODESIGNING, indicator "Invalid Page"
faulting thread 0:
  ?+0x11444c700            <- executed a NON-signed (heap/data) page: died
  UnityFramework+0x876564c
  UnityFramework+0x6940eb8   <- real Zenject Resolve body
  UnityFramework+0x29b694    <- il2cpp_runtime_invoke thunk
  UnityFramework+0x29b578
  SPPlus+0xea50              <- Strategy C
  ... UIAlertController _invokeHandlersForAction (our Clean-bag button)
```

Root cause: runtime_invoke DID dispatch into real, signed Zenject code
(`+0x6940eb8`). That code looked up a binding keyed on the `System.Type` object
we built by hand (`class_get_type` + `type_get_object`). Because that Type is
not the exact RuntimeType instance Zenject's dictionary was keyed with, the
lookup produced an uninitialised/garbage binding whose delegate target pointed
into a heap page (`0x11444c700`). Zenject indirect-called it; the hardened
runtime kills any jump to a page without a valid code signature.

**Rule: never invoke `Resolve` (or any generic-shared / delegate-dispatching
method) ourselves on 0.743.** Simple AOT getters (`get_Count`, `get_Container`,
`get_Instance`) invoke fine — the danger is methods that dispatch through a
runtime-built delegate/dictionary keyed on a managed object we fabricated.

Every *self-invoked* instance-acquisition path is now exhausted:
heap walk (dead — `foreach_heap` yields no clean objects on 0.743), static
Instance field (none), `get_Instance` (none), GameManager (not found),
Zenject Resolve (CODESIGNING SIGKILL).

### v37: reach the bag by DATA READS, no Resolve invoke

`spp_il2cpp_zenject_probe()` walks the container with pure memory reads:

```
Zenject.ProjectContext  (static _instance, field_static_get_value — safe)
  -> ._container  (instance field, read at its metadata offset — DiContainer)
  -> ._providers  (Dictionary<BindingId, List<ProviderInfo>>)
```

It dumps the DiContainer field layout (names + type names + byte offsets), the
provider dictionary's layout + entry count, and the ProviderInfo / BindingId
type metadata — enough to write the exact provider walk from REAL offsets with
no further device round-trip. Every dereference is guarded (aligned + in-range),
so a wrong offset logs and bails; and because no managed code runs, there is no
code-signature page to trip. FieldInfo.offset is read straight from the struct
(`+0x18`, stable across the Unity 2019-2022 il2cpp line).

Open risk to confirm from the v37 log: if `IPokemonBag` is bound in a
per-scene `SceneContext` (a child container) rather than the root
ProjectContext container, the root `_providers` won't hold it and v38 must
follow the container hierarchy (or find the active SceneContext) instead. The
provider-dict entry count in the log will tell us which.

### v37 result — the probe worked, zero crash, full layout captured

No `.ips`. The data-read chain reached everything:

```
ProjectContext._instance @ 0x136eabf50 (Zenject.ProjectContext)   # non-null
DiContainer            @ 0x1338384d0 (Zenject.DiContainer)
  _providers @ +0x18 : Dictionary<BindingId, List<DiContainer.ProviderInfo>>
_providers dict @ 0x136e8f720 (stock .NET-Core Dictionary`2):
  _buckets @ +0x10 ; _entries @ +0x18 ; _count @ +0x20 (= 269) ; _comparer @ +0x30
ProviderInfo: Container@+0x10  NonLazy@+0x18  Provider@+0x20  Condition@+0x28
BindingId:    _type@+0x10 (System.Type)   _identifier@+0x18
```

So the bag binding lives in the ROOT container (269 bindings) — no SceneContext
chase needed.

### v38 — provider-dictionary walk (data reads) to the live instance

`zj_find_bag_instance(container)` (Strategy F in `get_pokemon_bag`) scans the
269 entries:

```
entries = *(container + 0x18 [_providers] + 0x18 [_entries])   # Entry[]
Entry stride 0x20: hashCode@0, next@4, key(BindingId)@8, value(List)@0x18
  key._type (System.Type obj)   @ entry+0x08
  value (List<ProviderInfo>)    @ entry+0x18
for each entry with non-null key:
  Il2CppType* = *(key._type + 0x10 [Il2CppReflectionType.type])
  class = il2cpp_class_from_type(type)         # metadata, safe
  if class name contains "PokemonBag":
     List<ProviderInfo> -> _items[j].Provider (ref-type) -> cached instance
```

Instance is pulled from the provider by scanning its fields for one named
`*instance*`/`*cached*` (CachedProvider caches `_instances` : List<object>;
dereference element 0), one level of `_creator` recursion for the wrapper.

Crash-safety: a one-time **set of every registered il2cpp class** is built, and
every class derived from a walked pointer is trusted only if (a) the pointer is
in the heap range and (b) it is in that set — otherwise skipped. This is the
v34/v35 lesson applied rigorously: no `class_get_name`/`class_get_fields` ever
runs on an unvalidated pointer, so a wrong layout guess (e.g. if `ProviderInfo`
turns out to be a value type) just misses — it cannot SIGSEGV. On a miss the
items array is hex-dumped once so a struct layout can be finalized in v39
without another blind guess. Once the instance is cached, `bag_inspect` reads
`get_Count()` / `get_AllPokemon()` (safe AOT getters) to confirm and map the
enumeration API for the keep-rule release.
