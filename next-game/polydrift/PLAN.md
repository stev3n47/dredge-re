# PolyDrift 2 — PDPlus plan

Target: `com.FiredreamLabs.PolyDrift2` 2.1.1 · Unity IL2CPP metadata v39 ·
backend: LootLocker + Unity.Purchasing (Apple App Store listing seen in
metadata). No EOS/SignalR MP surface — mostly single-player racing.

## v1 scope (this build)

Invoke-writer features only — Polytopia v1.0.2 proved methodPointer/vtable
swaps never fire on compiled direct-`bl` callsites, and PolyDrift2's
unlock/currency surface is dominated by writer methods that ARE reachable
via `il2cpp_runtime_invoke` on the main runloop.

| key | default | mechanism |
|-----|---------|-----------|
| vehicles | 1 | `AddVehicleUnlock(uid)` uid=0..255 + `SaveUnlockedVehiclesUID` |
| gold | 0 | `GetPlayerGold` read → `GiveGold` top-up to 999,999,999 |
| coins | 0 | `set_Coins`/`set_CoinsEarnt` pinned at 999,999,999 |
| noads | 0 | pac-hook every Show*/Load* method on ad classes + invoke disable-writers |
| boost | 0 | pin `set_SpeedMultiplier`(2.0) + `set_SpeedBoostActive`(true) |
| mp_safe | 0 | gates gameplay hooks before any online mode |

Runtime discovery: declaring classes are found by method-name scan
(`find_class_owning`) because the .dat section layout is irregular on
this build (header pairs not standard-ordered; offline catalog TBD).
Instance methods resolve `self` via static singleton getters → heap walk.

Boot diagnostic (`feature_diag`): class-scan dump of every class matching
Unlock/Vehicle/Coin/Gold/Wallet/Admob/Boost/Speed/Save/Purchase/Premium/
Upgrade/Tuning/Drift/Garage/Inventory/Shop — method signatures
(static/argc) drive the v1.1 hook table.

## v1.1 candidates (need diag evidence)

- Hook rows for `IsUnlocked`/`CheckIfVehicleUnlockedUID` once the real
  declaring class is known (likely still dead vs direct `bl` — keep for
  invoke-coverage only).
- Persisted-unlock verification: does `SaveUnlockedVehiclesUID` actually
  write the save, or is unlock state server-side via LootLocker
  `GetSavedStateOrDefaultOrEmptyForPlayer`?
- Free-IAP path: `InitiateAsyncPurchase*` → LootLocker catalog; prefer
  save/flag side (receipt is backend-checked).
- Track/map unlocks if `GetUnlockedTracks`-style methods surface in diag.

## Known limits

- `AddVehicleUnlock(uid)` over 0..255 may no-op or throw on invalid UIDs —
  exceptions are caught (exc != NULL -> skip). If UIDs are strings/ULIDs,
  the int pass does nothing and diag tells us the real signature.
- `GiveGold`/`set_Coins` may write a local wallet that LootLocker later
  reconciles server-side — flag in test notes if balances revert.
- Boost pinning fights the game's own writers at 10 Hz — acceptable.
