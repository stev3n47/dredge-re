# PolyDrift 2 — capability map (metadata v39 string-heap recon)

Engine: Unity IL2CPP v39 · Payload/PolyDrift2.app · backend: LootLocker + Unity.Purchasing (Apple/Google/Steam)

## Confirmed surfaces

### T1 — vehicles (local unlock system, unlock UIDs saved locally)
AddVehicleUnlock, Button_UnlockVehicle, CheckIfVehicleUnlockedUID,
CheckStartingVehicleUnlockedUID, FindFirstUnlockedVehicleUID,
GetVehicleUnlockCount, IsUnlocked, LoadUnlockedVehiclesUID,
SaveUnlockedVehiclesUID, SetInitialVehicleUnlockCount, Button_ResetUnlocks
→ "All vehicles" = force IsUnlocked/unlock-count true, or invoke
   AddVehicleUnlock per UID. Same shape as Polytopia tribes.

### T2 — currencies (local)
Coins / CoinsEarnt (get_/set_), CoinCollectionMultiplier, GetPlayerGold, GiveGold
→ invoke set_Coins/GiveGold on the player object; multiplier hooks.

### T3 — ads (AdMob rewarded + interstitial + APP_OPEN_AD)
AdmobRewarded*, GADU* wrappers present → "no ads" = neuter ad-show/should-show
gates; rewarded-ad payouts may be server(LootLocker)-validated.

### T4 — gameplay (boost/speed)
SpeedBoostActive, m_BoostAmount, netTurnBoost, leftShiftBoost,
exitWaterBoostForce, BoostRamp(+Spawner), GetMaxSpeed, SetSpeed, MaxSpeedUpdate
→ infinite boost / speed multiplier / always-boost pads.

### Purchases
InitiateAsyncPurchase* → LootLockerAsyncPurchaseProcess (server-side
catalog/prices — LootLockerListCatalogPrices*). Receipt is backend-checked;
prefer save/flag paths over receipt spoofing.

## Notes
- No EOS/Firebase/SignalR MP surface found in the framework listing —
  likely single-player + leaderboards (LootLocker). Lower desync risk than
  Polytopia but verify before touching race results.
- Same caveats as Polytopia: getters need the prologue-detour path
  (STPLUS-REVIEW.md) or invoke-writers; methodPointer swap alone won't reach
  compiled callsites.
