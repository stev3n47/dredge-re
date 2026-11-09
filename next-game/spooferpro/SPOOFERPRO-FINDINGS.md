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

## Patch set (6 sites, verified by v1→v2 binary diff)

| VA | Kind | Stock first word | Patched first word | Patched 2nd word | In v1 | In v2 |
|---|---|---|---|---|:-:|:-:|
| `0x7d9ae0` | Tier wrapper 1 | *(see note)* | `52800020` (`mov w0, #1`) | `d65f03c0` (`ret`) | ✅ | ✅ |
| `0x7d9bec` | Tier wrapper 2 | *(see note)* | `52800020` | `d65f03c0` | ✅ | ✅ |
| `0x7d9edc` | Tier wrapper 3 | *(see note)* | `52800020` | `d65f03c0` | ✅ | ✅ |
| `0x7da154` | Tier wrapper 4 | *(see note)* | `52800020` | `d65f03c0` | ✅ | ✅ |
| `0x7da430` | Fifth gate (13 BL callers) | `a9ba6ffc` (`stp x28,x27,…`) | `52800020` | `d65f03c0` | ❌ | ✅ |
| `0xbcf70` | LEVEL getter (2 direct BL callers) | `d10203ff` (`sub sp, …`) | `d2801fe0` (`mov x0, #0xff`) | `d65f03c0` | ❌ | ✅ |

Four tier wrappers and the central compare already landed in v1. v2 adds the
two "post-compare" sites — the fifth gate that `v1` missed, and the LEVEL
getter whose return value some menu rows read directly without going through
a gate function (hence v1's "grayed-out rows that didn't actually gate").

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

- v1 (pre-fifth-gate, pre-LEVEL):
  `6014374be941440e61fd889db8ad49555004542a20195df00536d418cfcaa7b8`
- v2 (fully unlocked, shipped):
  `be3e5ec019c766d725729904f4aced920b201a9f72aed1573b5dd813b2f0e8df`

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

## v3 tasks

1. Pin down the actual "central compare" address — needs a stock (pre-mod)
   libSpooferPro.dylib to diff against, OR enough on-device testing of v2
   to find any remaining gated menu row.
2. Verify the paywall-string `__cfstring` wrapper VA and its xrefs; its
   caller function is the actual rate-limiter and may need its own patch
   if "unlimited access" is not implied by the tier=255 result.
3. Add a receipt-validation bypass for any server-proxied SpooferPro
   features. Likely lives in the same dylib's auth/JWT flow — look for
   `NSURLRequest` setters, SwiftProtobuf receipts, or App Store API
   calls (`SKPaymentTransactionObserver`).
