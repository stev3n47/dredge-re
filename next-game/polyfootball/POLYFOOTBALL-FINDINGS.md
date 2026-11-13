# PolyFootball on-device findings

v1a Tier 1 (confirmed working on build 4.5.3 / Unity 6000.3.9f1 / metadata v39):

- `PremiumCurrency` type 4130, method_count 22 matches catalog.
- `UnlockPro`, `UnlockAgent`, `UnlockTripleTicketBoost`, `UnlockCapIncrease`
  are all **static** methods (METHOD_ATTRIBUTE_STATIC = 0x10). No instance
  required — `il2cpp_runtime_invoke(method, self=NULL, args=NULL, &exc)` is
  sufficient.
- In-game shop confirmed owned state after one tick. `3X Boost` shows
  `PRO HAS 4X` (Pro grants 4× tickets, supersedes the 3× standalone).
  `$400M CAP` is bundled into Pro. So `get_HasTripleTicketBoost` and
  `get_HasCapIncrease` returning `true` after Pro unlock is expected
  behaviour, not a bug.
- Main-runloop timer (`CFRunLoopGetMain` + `kCFRunLoopCommonModes`) fires
  reliably at 10 Hz. Required `-framework CoreFoundation` so the common-
  modes global resolves as an explicit import — a runtime-created
  content-equal CFString fails `CFRunLoopAddTimer`'s pointer check.

v1b+ findings land here as feature modules return data. See
`feature_*.c` and `pfplus.log` from on-device runs.
