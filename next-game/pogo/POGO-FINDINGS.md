# Pokemon Go (iPoGo build) — own auto-transfer/utility tweak (IPAuto)

Base: `ipogo-4.6.1.ipa` — stock PoGo v0.435.1 Unity IL2CPP ARM64 +
iPoGo payload repacked as `Frameworks/Sentry.framework/Sentry` (16.8MB,
their fork of the Sentry SDK — source path leaks `/Users/dd/Desktop/sentryf/`).
Main exe `PokmonGO` is an 89KB stub; game code lives in
`UnityFramework.framework/UnityFramework` (196MB, metadata v39, Unity 2018.3 —
needs Il2CppInspectorRedux; classic Il2CppDumper 6.7.46 caps at v31).

## iPoGo's architecture (evidence from Sentry binary)

- Injection: `LC_LOAD_DYLIB` on the stub — same seam IPAuto uses.
- Traffic: swizzles `NSURLSession -dataTaskWithRequest:` (`hook_url_request`,
  `_my_dataTaskWithRequest`), watches `pgorelease.nianticlabs.com/plfe/rpc2`.
- Own RPC path: repurposed `SentryQueueableRequestManager`
  (`io.sentry.QueueableRequestManager.OperationQueue`) + bundled SwiftProtobuf.
- il2cpp bridge: 28 `il2cpp_*` names contiguous @Sentry+0x6fd5cb
  (domain_get, runtime_invoke, class_get_method_from_name, field_static_get_value,
  thread_attach...). UnityFramework exports nothing (24-byte export trie) —
  resolved via per-build hardcoded offsets (hence version pin "v0.435.1").
- Virtual Go+: private CoreBluetooth keys (`kCBMsgArgName/DeviceUUID`,
  `kCBAdvDataServiceData`) + `MyProxyDelegate`/`MyProxyCBPeripheralDelegate` —
  a fake CBPeripheral feeding the game the Go+ GATT protocol.
- Obfuscation: sensitive toggles mangled (`qW7gKtGiftBoxesToggle2026Xk`).

## iPoGo data layer

```sql
Preference (key UNIQUE, option INT)          -- toggles
StringPreference (key, value)
Filter (name UNIQUE, settings TEXT)          -- named keep-filters (JSON)
Items (item UNIQUE, amount INT)              -- bag-cleaner keep counts
Favorite (key UNIQUE, name, type INT)
Journal (type, lat, lng, ts, encounterId, pokemon...)
Route (name, gpx), Location, Last
```

Settings keys seen: `releaseOnCatch`, `blockShinyIgnore100`,
`autoCollectGiftBoxes`, `goPlusReConn`, `prioritizeSpin`, `spawnBooster`,
`gymBoosted`, `freezePokemon`, `tapToWalk`, `arPlus`, `FastMap`, `StatsBag`,
`NearbySnipe`, `NearbyShiny`, `catchFlee`, `cooldownTimer`.
Their Swift sources: `IPJoystick`, `IPNearbyView`, `IPFeedsView`,
`ThrowViewController`, `MapViewController`, `SettingsViewController`,
`ShortcutsViewController`, `SpeedViewController`, `FloatyItem`.
il2cpp game objects they touch: `EncounterGuiController` (+`currentEncounterPokemon`),
`IMapController`/`get_LookAtCamera` (tap-to-walk), `ItemInventoryGuiController`.
Species/IV data: `pokemon/index.json` fetched at runtime; `S2Geometry` for cells.

## Game-native path (il2cpp dump, UnityFramework)

- `IPokemonBag.ReleasePokemon(PokemonProto)` -> `IPromise<ReleasePokemonOutProto>`
- `PokemonBagImpl` impl @ VA `0x04B44AC0` (TypeDefIndex 41669; interface 38816)
- `IPokemonBagService.IsFull` (TypeDefIndex 3529); `PokemonBagService` holds
  `[Inject] IPokemonBag` @ field +0x48
- `ProjectContext._instance` @ +0x20 -> `Container` (DiContainer) @ +0x60 —
  Zenject resolve chain if il2cpp invoke is ever preferred over network path.
- `ReleasePokemonProto` fields: `PokemonId` @+0x10 (single), `PokemonIds` @+0x18
  (repeated) -> proto fields 1 and 2.

## Wire schema (verified v0.241 community proto + game classes; v0.435 drift logged at runtime)

- Method ids: HOLO_INVENTORY=4, ENCOUNTER=102, CATCH_POKEMON=103,
  RELEASE_POKEMON=112, RECYCLE_INVENTORY_ITEM=137, DISK_ENCOUNTER=145,
  COLLECT_DAILY_BONUS=138, SET_FAVORITE=148
- ResponseEnvelope: returns = field 100 repeated bytes, positional vs requests[]
- CatchPokemonOutProto: status=1 (CATCH_SUCCESS=1), captured uid = field 3 (ASSUMED)
- ReleasePokemonOutProto.Status: SUCCESS=1, POKEMON_DEPLOYED, FAILED, IS_EGG, IS_BUDDY

## IPAuto design (next-game/pogo/IPAuto.m)

1. `method_setImplementation` swap on `-[NSURLSession dataTaskWithRequest:completionHandler:]`;
   wrapped completion block sees raw rpc2 bodies.
2. Last RequestEnvelope kept as clone template (auth/session/request-id ride the game's).
3. First envelope: census detects which top-level field carries `requests[]`
   (element inner type >= 50 distinguishes from platform_requests) — logged.
4. CATCH=103 return -> uid held; next HOLO_INVENTORY=4 return -> recursive
   blob walk finds PokemonProto -> keep-rules -> splice RELEASE=112 request
   into cloned envelope -> POST on own session (marker header X-IPAuto).
5. Config `Documents/ipauto.json` (auto-generated); log `Documents/ipauto.log`
   dumps every method id + parsed mon so ASSUMED fields get verified on a
   test catch before trusting them.

Keep-rules: shiny, 100IV, favorite, buddy, lucky, legendary/mythical,
IV% >= iv_pct_min (90), species allow/deny lists. `bag_full_clean` ships OFF.

## Build (Windows -> arm64-ios)

- theos `iPhoneOS16.5.sdk` + `zig cc -target aarch64-macos.11.0.0-none -isysroot`
  (zig lld emits Mach-O; LC_BUILD_VERSION platform patched 1->2 post-build)
- zero deps via `-undefined dynamic_lookup`; self-declared ObjC surface —
  no Foundation header needed.
- CI mirrors it on macos-latest via `.github/workflows/build-ipauto.yml`
  (real SDK, self-signed codesign like DREMenu).

## Inject

`python next-game/pogo/inject_ipauto.py ipogo-4.6.1.ipa build/IPAuto-fw/IPAuto out.ipa`
— adds LC_LOAD_DYLIB to the stub, bundles IPAuto.framework, flips
UIFileSharingEnabled, repacks (zip shape = iOSGods convention).

## Still parked

- Virtual Go+ (fake CBPeripheral protocol — biggest single feature)
- block-non-shiny flee method id (capture once: press run button while logging)
- bag-full batch release (needs bag count field — off by default)
