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

**il2cpp bridge (the architecturally-correct automation path):**

Mirrors iPoGo's and SpooferPro's design. Rough plan:

1. Write a Python tool (`tools/dump_il2cpp_offsets.py`) that reads the
   SpooferPro UnityFramework, locates the `il2cpp_*` entry points by
   signature matching (the function prologues are stable because they're
   libil2cpp runtime glue), and emits a C header with offsets for
   PoGo v0.743.
2. In the dylib: `dlopen` UnityFramework, resolve each entry point by
   base + offset, cache in a per-version table.
3. Implement `invoke_il2cpp(image, namespace, class_name, method_name,
   args[])` — iterate `il2cpp_domain_get_assemblies`,
   `il2cpp_assembly_get_image`, `il2cpp_image_get_class`,
   `il2cpp_class_get_method_from_name`, then `il2cpp_runtime_invoke`.
4. For `release_on_catch`: resolve `IPokemonBag` via
   `ProjectContext._instance.Container` Zenject chain (POGO-FINDINGS has
   the chain for PoGo 0.435.1 — needs re-dumping for 0.743).
5. Switch `release_pokemon()` to call
   `IPokemonBag.ReleasePokemon(PokemonProto)` with uid set.

Once the bridge exists, bag-clean, auto-catch, berry-feeding, auto-spin
and bulk-evolve all become 5-line functions that just resolve+invoke the
matching method (`MethodReleasePokemon`, `MethodUseItemEncounter`,
`MethodFortSearch`, etc — same names SpooferPro uses).
