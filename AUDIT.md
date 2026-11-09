# Project audit — 2026-11-09

Scope: full-repo review focused on CarX + iPoGo (user-reported trouble
areas). Three parallel reviewers covered CXMenu / inject_carx.py, IPAuto.m /
inject_ipauto.py, and the shared tooling (`tools/dupe_ipa.py`,
`tools/inject_menu.py`, `tools/inject_sm27.py`, docs). Findings are kept
below; ones marked ✅ were applied on this branch.

## iPoGo (IPAuto)

### Critical

- ✅ **`release_on_catch` default was `true`** with all PokemonProto field
  numbers still marked `ASSUMED`. `shiny/fav/buddy/lucky/legendary` field
  guesses could each drop a keeper. Default flipped to `false`; user opts
  in from the in-app sheet once they've eyeballed `ipauto.log` and
  confirmed a known shiny catch logs the right fields.
  (`next-game/pogo/IPAuto.m:184`)

- ✅ **Catch-success uid field was also `ASSUMED` (`n2 == 3`)** and when
  wrong there was silent no-op. Added a one-shot blob-hex dump whenever
  `status == 1 && uid == 0` so the real field is visible in the log.
  (`next-game/pogo/IPAuto.m:411`)

- ✅ **Methods-list diagnostic rode `gSeq++`**, so if `gCleanOnce` fired
  first the list was never logged — the exact state the user hits when
  debugging why nothing's being released. Split to a dedicated static.
  (`next-game/pogo/IPAuto.m:390`)

### High

- ✅ **Log rotation.** `ipalog` reopened the file per line and grew
  unboundedly — tens of MB in a long session. Now rotates at ~1 MB to
  `ipauto.log.1`. (`next-game/pogo/IPAuto.m:76`)

- ✅ **NSURLSession class-cluster swizzle.** Base-class
  `method_setImplementation` is a no-op when `__NSCFURLSession*` overrides
  the selector. Walks `objc_getClassList` and installs on every
  NSURLSession subclass too. (`next-game/pogo/IPAuto.m:770`)

- ✅ **Fixed 8-slot delegate table silently dropped overflow.** Now grown
  dynamically (`realloc` on `swizzle_delegate`).
  (`next-game/pogo/IPAuto.m:147`)

- ✅ **`is_legendary` stopped at species 905** — Gen 9 legendaries and
  paradox mons were passing `keep_legendary`. Extended through 1025.
  (`next-game/pogo/IPAuto.m:204`)

- ⚠️ **Unity HTTPBodyStream path is unsupported.** The code already logs
  `rpc2 task body nil — HTTPBodyStream?` and then returns, which matches
  a reported "nothing happens on Unity path" symptom. Fixing it needs an
  `NSURLProtocol` registration or an upload-stream reader, both
  invasive — leaving as a next-session task.
  (`next-game/pogo/IPAuto.m:719`)

### Medium

- ⚠️ `@synchronized (gSyncObj)` serializes every rpc2 response from start
  to end. Parallel in-flight rpc2s block each other. Lock only around
  `gTemplate` / `gRPCURL` / `gPending` mutation; parse captured NSData
  lock-free. (`next-game/pogo/IPAuto.m:351`)
- ⚠️ `release_pokemon` sends both field 1 (legacy single) and field 2
  (repeated) — server may treat as conflicting. Drop field 1 once field 2
  is confirmed to work. (`next-game/pogo/IPAuto.m:303`)
- ⚠️ `walk_mons` depth=6 + `len < 16` filter is coincidence-based. Future
  proto layouts could hide or surface mons. IV `>15` sanity check in
  `handle_mon` is the only safeguard. (`next-game/pogo/IPAuto.m:341`)
- ⚠️ `inject_ipauto.py:48` sets `compat_version=0`; strict loaders can
  reject. Align to current. (not applied — needs a signed IPA to verify)

## CarX

### Critical

- ✅ **`cx_sweep_vcs` dismissed every non-system presented VC.** Any
  Apple-framework VC with a non-whitelisted prefix (StoreKit, GameKit,
  PushKit, CoreBluetooth, AVFoundation, SafariServices, WebKit) and any
  Unity plugin VC got killed. Narrowed to only match on `cx_wall_name`;
  window-level sweep keeps the structural rule since foreign windows
  are a stronger signal. (`next-game/CXMenu.mm:781`)

- ✅ **`inject_carx.py` opened `next-game/StubDylib` with no error.** The
  repo only ships `.c` — the binary is a CI artifact from
  `.github/workflows/build-cxmenu.yml`. Now surfaces a clear error with
  the build/download hint. (`tools/inject_carx.py:119`)

### High

- ✅ **Sweeper never slept.** The 0.6s loop ran forever, including while
  backgrounded, burning main-thread CPU and walking full window graphs
  every tick. Added: pause-while-background + stop after 50 consecutive
  clean sweeps, wake via `UIApplicationDidBecomeActiveNotification`.
  (`next-game/CXMenu.mm:793`)

### Medium

- ⚠️ **`cx_wall_name` matches on `UIHostingController`/`SwiftUI.` alone.**
  Harmless today, but any iOS 18+ SwiftUI chrome the game picks up
  (review prompts, system sheets) gets hidden. Wall-hiding is
  irreversible (`w.windowScene = nil`). Narrow to require pairing with
  an iOSGods/module hint. (not applied — behavior change needs
  on-device re-test) (`next-game/CXMenu.mm:750`)
- ⚠️ **`inject_carx.py` re-run on already-patched IPA is unsafe past the
  AddResource seam.** The seam check guards against re-patching, but
  the later gated-bool patches embed `orig(site)` into fresh caves —
  if that word is now `b site,OLD_CAVE`, the new cave replays a branch.
  Add a prologue-shape check before using `orig(site)` as the
  displaced instruction. (not applied)
- ⚠️ **`remove_load` doesn't verify the removed LC is the last dylib
  ordinal.** Docstring promises the invariant; code doesn't enforce it.
  (`tools/inject_carx.py:71`)

## Shared tooling

### Critical

- ✅ **`dupe_ipa.py` hardcoded `Payload/Discord.app/embedded.mobileprovision`.**
  Duping any other app left its stale provision in place → signer confusion
  / install failure. Now globs all `*.app` and `*.appex` `embedded.mobileprovision`
  entries. Also fixed a bug where input directory entries fell through to
  the file writer and were re-emitted as empty 0o100644 regular files.
  (`tools/dupe_ipa.py:74`)

### High

- ✅ **`endswith('embedded.mobileprovision')`** in `tools/inject_menu.py:443`
  and `next-game/pogo/inject_ipauto.py:171` would match
  `my-embedded.mobileprovision`. Changed to `/embedded.mobileprovision`.

- ✅ **`inject_sm27.py:75` blindly overwrote 10 VAs** with no stock-word
  check — a Unity 2025+ build with shifted offsets would silently corrupt
  unrelated code. Now flags any VA whose first word looks like a `RET` or
  `BRK` (clearly not a function prologue). Idempotent re-run is now a
  no-op instead of a double-write.

### Medium

- ⚠️ **Three injectors (`inject_menu.py`, `inject_sm27.py`, `inject_carx.py`,
  plus `inject_ipauto.py`) share ~400 lines of Mach-O LC insertion,
  codesig strip, ARM64 encoder helpers, and ZIP repack scaffolding.**
  Extracting into `tools/machoutil.py` would de-dupe, but is scope-creep
  for this audit — flagged for a dedicated refactor.
- ⚠️ **`inject_menu.py:345` stub-blob LHS is a hand-summed slice length.**
  Easy to forget to extend when adding a stub. Prefer
  `blob = stub0 + … ; uf[CAVE:CAVE+len(blob)] = blob`.

### Low

- ⚠️ `next-game/pogo/probe.c` is dead weight after the v6 launch-crash
  bisect concluded. Retain as reference or delete.

## Docs

- ✅ **README expanded** from one line to a proper landing page with the
  directory map and findings index.

---

### Still to do (next session)

1. Unity HTTPBodyStream path for iPoGo — requires `NSURLProtocol` or
   upload-stream reader to catch bodies the game sends via stream.
2. CarX `inject_carx.py` idempotency across all gated-bool patches
   (prologue-shape guard).
3. Extract `tools/machoutil.py` to kill 400 lines of duplication across
   the four injectors.
4. Verify the ASSUMED PokemonProto field numbers from an on-device log.
