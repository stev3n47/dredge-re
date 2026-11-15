# Total Battle — capability map (native binary recon)

Engine: cocos2d-x NATIVE C++ · 75MB Mach-O · NO il2cpp — managed-metadata
toolchain does NOT apply; everything is native offsets/hooks.

## Confirmed surfaces

### Shipped dev cheat panel (highest value target)
CheatInput, CheatButton, CheatTapLabel, CheatSectionHeader,
onCheatsButtonClick, command::CheatUpdatePaymentStatus
→ the game's own cheat UI is in the binary. Find its gate
   (debug flag / server role / menu entry) and enable = the cheat menu
   the devs use. Best ROI in the whole recon.

### Embedded Lua console
lua_cocos2dx_Console_addCommand, cocos2d::Console execCommand
→ cocos2d console + Lua binding = scriptable command surface if reachable.

### Admin panel
AdminPanelLayer, Admin Panel, ACCOUNT_ADMIN_IMPERSONATION, AdminSurveyView
→ gated by server role; client gate likely a flag check.

### VIP / premium / subscription flags
vipLevel=, hasPremium=, premiums=, 20SubscriptionsManager,
GOLDEN/GOLDEN_PURCHASED (battlepass tiers)
→ client-side flag flips are cosmetic unless server revalidates.

### IAP / receipt
StoreKit 2 Transaction APIs + client receipt check strings
("Transaction missing in receipt will be reported as invalid",
V_useReceiptValidationSandbox)
→ client-side validation can be neutered; server entitlements still
   authoritative (server:: namespaces everywhere —
   RollVipDiceResponse, PurchaseBonusDelayedRewardState…).

### Server-authoritative economy
command:: + server:: response classes for everything money-adjacent
(gold bars, gems, speedups, VIP dice). Client patches change what's
DISPLAYED, not what server state holds. Speedup timers (speedupItemCount,
usedSpeedups) may have client-observable fields worth freezing.

## Toolchain implications
- Needs a TBPlus.dylib + NATIVE patching: vtable/func detours, flag flips,
  data writes — via REA disasm for offsets. Injector still applies
  (LC_LOAD_DYLIB), signature/OBJC machinery reusable.
- MMO ban risk is real: Sendbird/Firebase/Crashlytics/AppsFlyer
  telemetry + server-side cheat detection (CHEATING_* string classes:
  CHEATING_EXPLOITS/TOOLS/USER_DATA = telemetry categories).
  Recommend: offline/single-session features first, cheat-panel enable
  behind a toggle, no economy writes.
