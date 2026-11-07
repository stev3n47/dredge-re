# Next game

Drop the iOSGods IPA here. Same pipeline as DREDGE:

- `tools/inject_menu.py` — IPA patcher (offsets get updated per-game)
- `tools/il2cppdumper7/` — metadata dump → dump.cs (run on the new IPA's
  UnityFramework + global-metadata.dat)
- `menu/DREMenu.mm` — menu dylib source (RVAs in it are DREDGE-specific;
  command names come from the new game's AddCommand registrations)
