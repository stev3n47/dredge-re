# SpooferPro+SPPlus build/crash tracker

Goal: `SpooferPro-0.435.1-0.743` IPA with license/tier ungated + injected
`SPPlus.framework` (SP+ bubble, NSURLSession hooks, IL2CPP bridge), stable
through launch. Base for all v11+ builds: `unlocked-v4strip.ipa`
(anti-tamper-stripped libSpooferPro). CI workflow: `Build SPPlus.dylib`.

## Build matrix

| ver | base | hooks | changes vs prev | result | crash signature | root cause |
|-----|------|-------|-----------------|--------|-----------------|-----------|
| v11 | v4 (UNstripped) | OFF | bisect build | LOADED, played, laggy | first launch hit `_GetN2Api` brk, relaunch fine | flaky poison, race window |
| v12 | v4strip | OFF | stripped base + same dylib | (log only, tiny) | — | — |
| v13 | v4strip | ON | + shared-state locks | skipped by tester | — | — |
| v14 | v4strip | ON | + holo-game resolver | crash ~seconds | SIGSEGV/SIGBUS FBSDK `retain` of returned task | private autorelease pool drained the `+0` task before caller retained it |
| v15 | v4strip | ON | pools removed from hooks | splash watchdog | `0x8BADF00D` 18.2s scene-create | (a) `hook_recvdata` buffered multi-100MB asset download under `gTaskBuf` lock; (b) il2cpp catalog on main runloop |
| v16 | v4strip | ON | rpc2-only buffering, il2cpp off main, ipalog out of lock | mid-launch | `EXC_BREAKPOINT` at `NianticLabsPlugin+0x4df9e4` = `_GetN2Api+0`, `brk #0x80` | runtime-poisoned entry (see poison section) |
| v17 | v4strip | ON | + sigaction SIGTRAP restore-handler | long splash watchdog | `0x8BADF00D`; stack: Unity→sigtramp→Sentry→`pthread_mutex_lock` | guard never armed (dlsym failed, retry was on frozen main runloop); Sentry owns trap, deadlocks |
| v18 | v4strip | ON | + permanent bg watch thread (NSOperationQueue) | long splash watchdog | same Sentry deadlock | armed ok (`insn=a9be4ff4`); Sentry's handler was on top (last-sigaction-wins), ours never ran |
| v19 | v4strip | ON | + re-steal SIGTRAP 64ms, null task brk port, heartbeat, NSThread spawn | "insta" crash | `EXC_BAD_ACCESS` KERN_PROTECTION at `0x16f3e7dd0` — **stack overflow** | handler ping-pong: insn-check read clean (watch restored first) → chained to Sentry → Sentry re-raised → loop |
| v20 | v4strip | ON | pc-match unconditional, depth cap 8→DFL, pthread_create watch, `N2 watch started` | **furthest yet**: watch alive, `restores=0`, il2cpp READY, catalog ok, found `.PokemonBagImpl` | `SIGKILL` CODESIGNING Invalid Page, pc=`0x12ed34e00` (anonymous page, gap above UnityFramework) | `spp_il2cpp_get_pokemon_bag` → Zenject `DiContainer.Resolve` invoke → deep indirect call into non-executable/unsigned runtime page |
| v21 | v4strip | ON | launch probe = metadata-only (bag resolve deferred to feature use) | survived launch probe, il2cpp READY — then watchdog | `0x8BADF00D` 19.1s; stack: Unity+0x7196310→sigtramp→**SPPlus+0x5f70 (our n2_trap)**→Sentry→mutex | our handler RAN but chained to Sentry because **pc ≠ gN2Api** — the brk landed at a different offset (probably +4); watch only polled word 0 |
| v22 | v4strip | ON | handler claims ANY brk insn: in-window→restore captured orig, elsewhere→pc+=4 skip; watch polls 8 words; signal-safe trap pc/insn logging | testing | — | — |
| v23 | v4strip | ON | + Claude commit 242b4d2: "Clean Bag Now (SpooferPro)" button calls `+[gu5nyo3pkexjug7to2 sharedCleaner]` → `-PerformPokemonCleanupManually` — SpooferPro's own ObjC cleaner, bypasses the Pro gate (which lives only in the UI button at 0xa4a934); zero il2cpp/Zenject exposure | watchdog again | `0x8BADF00D` 18.3s; main blocked in **libc stdio fwrite/flockfile** (`libsystem_kernel+0x6c64` → `libsystem_c` write path) inside Unity logging (`UnityFramework+0x11d6ab8` = console writer), entered from `libSpooferPro+0x56c830` | **NOT the brk**: log shows entry clean + `restores=0` + 7 heartbeats + **zero `N2 trap` lines** — poison never fired, handler never ran. il2cpp also never init'd (`READY` absent) because the +2s NSTimer is on the main runloop, which was frozen. Main thread is blocked either on stdout's FILE lock (another thread holding it) or a write() to a full redirected stdout pipe. ipalog uses NSFileHandle (no FILE lock). Candidates: libSpooferPro's stdout redirect pipe filling, or a stdio lock held by a killed thread |
| v24 | v4strip | ON | Claude a48a6f7+efdb55d: ObjC cleaner REMOVED (license-tied VM dispatcher — free tier can't decode magic `0xc991c472`, silent no-op confirmed on-device 3 presses/4min); "Clean Bag Now" now = own rpc2 path: `gCleanOnce=1` + spliced `GET_HOLOHOLO_INVENTORY` (M 4) on `gOwnSession` + `post_env_handle()` → `handle_response()` → bag scan → M_RELEASE batch; keep-rules + `bag_clean_max` abort unchanged. Plus SP+ menu redesign: flat 24-row sheet → 5 panes (Main/Keeps/etc) | testing | — | — |

## The `_GetN2Api` poison (summary for remote analysis)

- Victim: `NianticLabsPlugin+0x4df9e4` (`_GetN2Api` entry). On-disk word
  `0xa9be4ff4` (`stp x20,x19,[sp,#-0x20]!`); runtime word `0xd4201000`
  (`brk #0x80`, nonstandard imm — a signature, not stock Gum).
- Called from `UnityFramework+0x7196310` at ~15-18s — flaky timing.
- libSpooferPro `dlsym`s it at init (`0x5e9ca0`), memcpy's the 288-byte
  API table to `0x1bb7a60`, never needs the export again.
- Subagent static hunt (all 4 binaries): **no instruction ever
  materializes `0xd4201000`**; only `gum_arm64_writer_put_brk_imm`
  (`libSpooferPro+0xc4b768`) can encode it but is dead code (0 callers).
  Gum `replace` writes `ldr x16;br x16` trampolines, not brk. The 137
  hook records don't include `0x4df9e4`. Writer is obfuscated/indirect.
- Best theory: **deliberate API lockout** — libSpooferPro caches the N2
  table then kills the export so nothing else can call it (disguised as
  Niantic bug). Restoring the byte is harmless to the spoofer.
- Defense (current): bg pthread polls entry 1ms + restores brk;
  POSIX sigaction claims pc==_GetN2Api unconditionally (never chains);
  task brk port nulled; handler re-stolen 64ms. Worked in v20
  (`restores=0`, entry stayed clean — poison didn't fire that run).
- Untried: hardware watchpoint on `_GetN2Api+0` via `thread_set_state`
  debug regs to name the writer directly.

## v20 crash detail (CODESIGNING Invalid Page)

- `pc=0x12ed34e00` sits in gap `0x11cef0000..0x19f362000` (between
  UnityFramework end and dyld) — anonymous region: Gum trampolines /
  JIT / patched pages live there. KERN_PROTECTION + CODESIGNING =
  executed a page whose CS slot is invalid (dirty file page or
  non-JIT anonymous RX).
- Stack: `NSOperationQueue → SPPlus+0x5d58 → +0xc72c → +0xbf5c` =
  `il2cpp_runtime_invoke` inside `_spp_il2cpp_get_pokemon_bag` →
  `UnityFramework+0x29b578/0x29b694/0x6940eb8/0x876564c → br 0x12ed34e00`.
- Note: earlier `get_Container` invoke succeeded — `runtime_invoke`
  works; it's `Resolve`'s internals (ctor activation — prime hook
  target) that hit the bad page.
- v21 defers instance resolution to feature-use. RISK: feature-time
  `Resolve` may hit the same page — if so, pivot to non-invoke instance
  discovery (field walk / rpc2 traffic correlation).

## Open questions

1. Does the poisoner write once or sweep? (watch heartbeats show entry)
2. Does it detect repair and escalate? (no evidence yet)
3. Will post-login `DiContainer.Resolve` still hit a bad page?
4. Pro/Elite menu rows still gray — the Swift-UI tier path is NOT
   driven by patched license values; unverified what gates it.

## .ips decode recipe (macOS-style crash json)

```python
import json
d = json.loads(open(path).read().split('\n',1)[1])
print(d['exception'], d.get('termination',{}).get('reasons'))
flt=d['faultingThread']; t=d['threads'][flt]
for f in t['frames'][:25]:
    b=d['usedImages'][f['imageIndex']]
    print(b.get('name') or b['path'], hex(f['imageOffset']))
```
`usedImages[].name` may be missing → fall back to `path`. `imageIndex`
can be 0 with no name = anonymous page.

## Do NOT re-try (already eliminated)

- Private autorelease pools in hook paths (v14)
- Buffering non-rpc2 bodies (v15)
- Main-runloop timers for retry work (v17)
- Chaining non-matching traps at `_GetN2Api` to previous handler (v19)
- NSThread/NSOperationQueue for the watch (v19 silent-fail risk) — use pthread
- Eager `DiContainer.Resolve` during launch (v20)
- Searching binaries for a `0xd4201000` constant (none exists)
