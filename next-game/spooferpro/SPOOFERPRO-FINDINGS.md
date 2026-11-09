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

## Still to do

1. Flash the proposed v4 IPA and confirm it (a) launches and (b) ungrays
   the menu rows that v1 leaves grayed. If any rows stay grayed, they
   read LEVEL via a different path and need their own patch.
2. Pin down the actual "central compare" address — needs a stock (pre-mod)
   libSpooferPro.dylib to diff against, OR enough on-device testing of v4
   to find any remaining gated menu row.
3. Verify the paywall-string `__cfstring` wrapper VA and its xrefs; its
   caller function is the actual rate-limiter and may need its own patch
   if "unlimited access" is not implied by the tier=255 result.
4. Add a receipt-validation bypass for any server-proxied SpooferPro
   features. Likely lives in the same dylib's auth/JWT flow — look for
   `NSURLRequest` setters, SwiftProtobuf receipts, or App Store API
   calls (`SKPaymentTransactionObserver`).
