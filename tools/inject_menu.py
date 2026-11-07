#!/usr/bin/env python3
"""Inject LC_LOAD_DYLIB for DREMenu.framework into DREDGE and repackage the IPA.

Usage:
  python inject_menu.py <stock.ipa> <DREMenu-binary> <out.ipa> [save.bin]

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/DREMenu.framework/DREMenu'
  to the DREDGE executable (header pad is >= 0x3800 bytes).
- Assembles Payload/DREDGE.app/Frameworks/DREMenu.framework/ (binary +
  Info.plist) — a proper framework bundle so re-signers that only recurse
  into .framework directories still detect and sign it (iGameGod precedent).
- Enables UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace in
  Info.plist so Documents is browsable in Files.app / Finder file sharing.
- Optionally bundles a save file inside .app for the menu's restore button.
"""
import sys, struct, zipfile, os, plistlib

LC_LOAD_DYLIB     = 0xC
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64       = 0xFEEDFACF

def inject_dylib_cmd(exe: bytes, dylib_path: str) -> bytes:
    b = bytearray(exe)
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack('<8I', b[:32])
    assert magic == MH_MAGIC_64, 'not arm64 mach-o'

    lc_end = 32 + sizeofcmds
    off = 32
    min_sect = None
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', b[off:off+8])
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack('<I', b[off+64:off+68])[0]
            s = off + 72
            for _ in range(nsects):
                foff = struct.unpack('<I', b[s+48:s+52])[0]
                if foff and (min_sect is None or foff < min_sect):
                    min_sect = foff
                s += 80
        off += cmdsize
    pad = (min_sect or 0x4000) - lc_end
    assert pad >= ((24 + len(dylib_path.encode()) + 1 + 7) & ~7), f'not enough header pad ({pad})'

    name = dylib_path.encode()
    cmdsize = (24 + len(name) + 1 + 7) & ~7
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0) + name + b'\0' * (cmdsize - 24 - len(name))

    # Insert BEFORE LC_CODE_SIGNATURE (Apple's conventional order) — some
    # re-signers parse load commands assuming the codesig command is last.
    cs_off = None
    off = 32
    for i in range(ncmds):
        c, s = struct.unpack('<II', b[off:off+8])
        if c == LC_CODE_SIGNATURE:
            cs_off = off
            break
        off += s
    ins = cs_off if cs_off is not None else lc_end
    b[ins+cmdsize:lc_end+cmdsize] = b[ins:lc_end]
    b[ins:ins+cmdsize] = cmd
    struct.pack_into('<I', b, 16, ncmds + 1)
    struct.pack_into('<I', b, 20, sizeofcmds + cmdsize)
    return bytes(b)

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    save = sys.argv[4] if len(sys.argv) > 4 else None
    exe_path  = 'Payload/DREDGE.app/DREDGE'
    uf_path   = 'Payload/DREDGE.app/Frameworks/UnityFramework.framework/UnityFramework'
    fw_path   = 'Payload/DREDGE.app/Frameworks/DREMenu.framework/DREMenu'
    fw_plist  = 'Payload/DREDGE.app/Frameworks/DREMenu.framework/Info.plist'
    info_path = 'Payload/DREDGE.app/Info.plist'
    save_dst  = 'Payload/DREDGE.app/dredge-save0.bin'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path), '@executable_path/Frameworks/DREMenu.framework/DREMenu')
    dyb = open(dylib, 'rb').read()

    # Static patches — ALWAYS applied here so every build carries them.
    # Runtime patching is impossible under dev/Signulous signing: writing to a
    # signed executable page needs dynamic-codesigning (TrollStore-only) and
    # the kernel kills the app — so every cheat is baked in statically.
    #
    # Data-flag toggles (iOSGods' mechanism, v15): patched functions get
    # `b <stub>` into a code cave — zero padding at __TEXT tail
    # (0x3E46D40..0x3E48000, mapped RX). Stubs read a flag byte from the dead
    # __DATA zerofill page 0x46DF000 (zero adrp/GOT/chained-fixup refs in
    # stock). The menu writes flag bytes at uf_base+0x46DF528 — a plain data
    # write, legal under any signature.
    #
    # v16 hook choices — picked for REAL callers (verified via bl-scan; the
    # previous getter patches were dead code — il2cpp inlines tiny getters):
    #   flag+0 Sell:  ItemManager.GetItemValue(this, item, mode{w2},
    #       sellValueModifier{s0}) entry. mode==SELL(1) && flag on ->
    #       s0 *= f32 multiplier flag at +0x52C (menu-written, default 4.0).
    #       Feeds BOTH the displayed shop price and the credited amount —
    #       9 real bl callers incl. SellModeActionHandler. Buy untouched.
    #   flag+1 Pot auto-catch: SerializedCrabPotPOIData.CalculateCatchRoll
    #       -> w0 bool. Flag on → w0=1 (always caught). Crab pots only.
    #   flag+2 No overheat: BoostAbility.Update mid-function patch at the
    #       `str s0,[x19,#0xF4]` (rawBurnAmount store). Flag on → store
    #       skipped → burn never accumulates → currentBurnProp stays 0 →
    #       no lockout, no explosion. Saves/restores x9/x10 (live regs).
    # God/Immune are menu-driven `SetGodMode`/`SetImmuneMode` terminal
    # commands (write real Player fields) — no patch needed.
    SLOT = 0x46DF528
    CAVE = 0x3E46D40
    def adrp(rd, pc_va, tgt_page):
        imm = (((tgt_page & ~0xFFF) - (pc_va & ~0xFFF)) >> 12) & 0x1FFFFF
        return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd
    def ldrb(rt, rn, off):
        return 0x39400000 | ((off & 0xFFF) << 10) | (rn << 5) | rt
    def ldr_s(rt, rn, off):
        return 0xBD400000 | (((off >> 2) & 0xFFF) << 10) | (rn << 5) | rt
    def str_s(rt, rn, off):
        return 0xBD000000 | (((off >> 2) & 0xFFF) << 10) | (rn << 5) | rt
    def stp_x(rt, rt2, imm):
        return 0xA9800000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def ldp_x(rt, rt2, imm):
        return 0xA8C00000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def cbz(rt, imm19):
        return 0x34000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def cbnz(rt, imm19):
        return 0x35000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def cmp_i(rn, imm12):
        return 0x7100001F | ((imm12 & 0xFFF) << 10) | (rn << 5)
    def bcond(cond, imm19):
        return 0x54000000 | ((imm19 & 0x7FFFF) << 5) | cond
    def tbz(rt, bit, imm14):
        return 0x36000000 | ((bit & 0x1F) << 19) | ((imm14 & 0x3FFF) << 5) | rt
    def fmul_s(rd, rn, rm):
        return 0x1E200800 | (rm << 16) | (rn << 5) | rd
    def fmov_s(rd, imm8):
        return 0x1E201000 | ((imm8 & 0xFF) << 13) | rd   # imm8 0x70 = 1.0f
    def b(pc_va, tgt_va):
        return 0x14000000 | (((tgt_va - pc_va) >> 2) & 0x3FFFFFF)
    RET = 0xD65F03C0
    def w32s(*words): return b''.join(struct.pack('<I', w) for w in words)

    uf = bytearray(zin.read(uf_path))
    orig = lambda va: struct.unpack('<I', uf[va:va+4])[0]

    #   flag+3 Fish Quality — two sites, same flag:
    #     a) GetSaleModifierForSize: the `ldr s1,[x19,#0x50]` size load ->
    #        flag on forces s1=1.0 → lerp hits max-size modifier.
    #     b) GetSaleModifierForFreshness: the `b.le` freshness tier gate ->
    #        flag on forces the top-tier path. adrp/ldrb/cbnz don't touch
    #        NZCV so the off path replays the fcmp flags into a local
    #        inverted b.gt (b.cond can't reach back ~46MB to the cave).
    GETITEMVAL, CATCHROLL, BURNSTORE = 0x1401B84, 0x1289B38, 0x1476D3C
    SIZELOAD, FRESHBR = 0x127AD70, 0x127AF68
    FRESH_TOP, FRESH_LE = 0x127AF6C, 0x127AF8C   # fallthrough / b.le target
    #   flag+5 Free Upgrades — two sites, same flag:
    #     a) ItemCountCondition.Evaluate entry -> flag on returns w0=1
    #        (material-count checks pass; also affects quest item checks).
    #     b) AddUpgrade 'tbnz w20,#0' free gate -> flag on forces the free
    #        path (skips material deduction). Off path replays via local
    #        tbz (tbz can't reach back to the cave).
    ITEMEVAL, UPGGATE = 0x127A194, 0x1420C60
    UPG_FREE, UPG_PAY = 0x1420CC4, 0x1420C64     # tbnz target / fallthrough
    #   flag+3 (same Fish Quality flag) also hooks CreateFishItem entry:
    #   on -> w2=FORCE(2) aberration (FORBID callers kept for quest fish),
    #   w4=FORCE_BIG_TROPHY(2) always — "Fish Quality" means mutant trophies.
    #   AND two internal bail-outs are bypassed: the SaveData progression
    #   gates CanCatchAberrations (cbz @0x14072B4) and GetCaughtCountById
    #   (b.lt @0x1407300, NZCV replayed via local b.ge). Without these the
    #   forced modes still exit to the normal path on fresh saves.
    CREATE_FISH = 0x1407040
    ABERRGATE1, ABERRGATE2 = 0x14072B4, 0x1407300
    ABERR_BAIL, ABERR_CONT1, ABERR_CONT2 = 0x1407D70, 0x14072B8, 0x1407304
    #   flag+9 Free Research: SpendResearchItem entry -> w0=1. The old
    #   ResearchPointsRequired bake was dead code (inlined getter, zero
    #   bl callers) — this is the live spend seam (2 real callers, both
    #   tbz w0 -> failure). Each notch click fills free.
    SPEND_RESEARCH = 0x1311DC4

    # stub0 @CAVE+0x00 — GetItemValue: flag on && mode==SELL -> s0 *= flag f32.
    stub0 = w32s(
        orig(GETITEMVAL),                        # sub sp,sp,#0x60
        adrp(9, CAVE + 0x04, SLOT), ldrb(10, 9, 0x528),
        cbz(10, 5),                              # flag off -> resume
        cmp_i(2, 1),                             # mode == SELL?
        bcond(1, 3),                             # b.ne -> resume (BUY untouched)
        ldr_s(1, 9, 0x52C),                      # s1 = multiplier flag
        fmul_s(0, 0, 1),                         # s0 *= multiplier
        b(CAVE + 0x20, GETITEMVAL + 4),          # resume GetItemValue+4
    )
    # stub1 — CalculateCatchRoll(roll, this)->bool: flag -> w0=1.
    S1 = CAVE + len(stub0)
    stub1 = w32s(
        adrp(9, S1 + 0x00, SLOT), ldrb(9, 9, 0x529),
        cbnz(9, 3),                              # flag on -> forced catch
        orig(CATCHROLL),                         # sub sp,sp,#0x50
        b(S1 + 0x10, CATCHROLL + 4),             # resume original
        0x52800020,                              # mov w0,#1
        RET,
    )
    # stub2 — BoostAbility.Update burn store: flag on -> skip store.
    # x9/x10 live mid-function → save/restore around the flag read.
    S2 = S1 + len(stub1)
    stub2 = w32s(
        stp_x(9, 10, -16),                       # stp x9,x10,[sp,#-0x10]!
        adrp(9, S2 + 0x04, SLOT), ldrb(10, 9, 0x52A),
        cbnz(10, 4),                             # flag on -> restore & skip
        ldp_x(9, 10, 16),                        # ldp x9,x10,[sp],#0x10
        orig(BURNSTORE),                         # str s0,[x19,#0xf4]
        b(S2 + 0x18, BURNSTORE + 4),
        ldp_x(9, 10, 16),                        # skip path: restore
        b(S2 + 0x20, BURNSTORE + 4),
    )
    # stub3 — GetSaleModifierForFreshness b.le gate: flag on -> top tier.
    S3 = S2 + len(stub2)
    stub3 = w32s(
        stp_x(9, 10, -16),
        adrp(9, S3 + 0x04, SLOT), ldrb(10, 9, 0x52B),
        cbnz(10, 5),                             # flag on -> forced top tier
        ldp_x(9, 10, 16),
        bcond(12, 2),                            # b.gt -> not(le) -> top tier
        b(S3 + 0x18, FRESH_LE),                  # le -> second check
        b(S3 + 0x1C, FRESH_TOP),                 # !(le) -> top tier
        ldp_x(9, 10, 16),                        # on path
        b(S3 + 0x24, FRESH_TOP),
    )
    # stub4 — GetSaleModifierForSize ldr site: flag on -> s1 = 1.0.
    S4 = S3 + len(stub3)
    stub4 = w32s(
        stp_x(9, 10, -16),
        adrp(9, S4 + 0x04, SLOT), ldrb(10, 9, 0x52B),
        cbz(10, 4),                              # flag off -> original load
        ldp_x(9, 10, 16),
        fmov_s(1, 0x70),                         # s1 = 1.0 -> max size modifier
        b(S4 + 0x18, SIZELOAD + 4),
        ldp_x(9, 10, 16),                        # off path
        orig(SIZELOAD),                          # ldr s1,[x19,#0x50]
        b(S4 + 0x24, SIZELOAD + 4),
    )
    # stub5 — ItemCountCondition.Evaluate entry: flag on -> w0=1 (all
    # material-count conditions satisfied). Entry patch, x9 scratch.
    S5 = S4 + len(stub4)
    stub5 = w32s(
        adrp(9, S5 + 0x00, SLOT), ldrb(9, 9, 0x530),
        cbnz(9, 3),                              # flag on -> forced true
        orig(ITEMEVAL),                          # stp x20,x19,[sp,#-0x20]!
        b(S5 + 0x10, ITEMEVAL + 4),              # resume original
        0x52800020,                              # mov w0,#1
        RET,
    )
    # stub6 — AddUpgrade `tbnz w20,#0` free/deduct gate: flag on -> free
    # path (skip material deduction). x9/x10 live -> save/restore; off
    # path replays tbnz via a local tbz (tbz can't reach back to cave).
    S6 = S5 + len(stub5)
    stub6 = w32s(
        stp_x(9, 10, -16),
        adrp(9, S6 + 0x04, SLOT), ldrb(10, 9, 0x530),
        cbnz(10, 5),                             # flag on -> forced free
        ldp_x(9, 10, 16),
        tbz(20, 0, 2),                           # free bit clear -> pay path
        b(S6 + 0x18, UPG_FREE),                  # bit set -> free path
        b(S6 + 0x1C, UPG_PAY),                   # pay path (orig fallthrough)
        ldp_x(9, 10, 16),                        # on path: restore
        b(S6 + 0x24, UPG_FREE),
    )
    # stub7 — CreateFishItem entry: flag on -> w2==RANDOM_CHANCE(0) ->
    # FORCE(2) aberration (explicit FORBID kept for quest fish); w4 ->
    # FORCE_BIG_TROPHY(2) unconditionally (size has no story-critical caller).
    S7 = S6 + len(stub6)
    stub7 = w32s(
        adrp(9, S7 + 0x00, SLOT), ldrb(9, 9, 0x52B),
        cbz(9, 4),                               # flag off -> original args
        cbnz(2, 2),                              # w2 set already -> keep it
        0x52800042,                              # mov w2,#2  FORCE aberration
        0x52800044,                              # mov w4,#2  FORCE_BIG_TROPHY
        orig(CREATE_FISH),                       # sub sp,sp,#0xf0
        b(S7 + 0x1C, CREATE_FISH + 4),
    )
    # stub8 — SpendResearchItem entry: flag on -> w0=1 (part spends free).
    S8 = S7 + len(stub7)
    stub8 = w32s(
        adrp(9, S8 + 0x00, SLOT), ldrb(9, 9, 0x531),
        cbnz(9, 3),                              # flag on -> forced success
        orig(SPEND_RESEARCH),                    # stp x26,x25,[sp,#-0x50]!
        b(S8 + 0x10, SPEND_RESEARCH + 4),
        0x52800020,                              # mov w0,#1
        RET,
    )
    # stub9 — CreateFishItem CanCatchAberrations bail (`cbz w0`) — the save
    # progression gate. Forcing w2=2 upstream still exits to the normal path
    # here on any save that hasn't unlocked aberrations. Flag+3 on -> skip
    # the bail; off -> replay cbz (w0!=0 -> continue, else bail).
    S9 = S8 + len(stub8)
    stub9 = w32s(
        stp_x(9, 10, -16),
        adrp(9, S9 + 0x04, SLOT), ldrb(10, 9, 0x52B),
        ldp_x(9, 10, 16),
        cbz(10, 2),                              # flag off -> replay orig
        b(S9 + 0x14, ABERR_CONT1),               # flag on -> continue past cbz
        cbnz(0, 2),                              # w0!=0 -> continue
        b(S9 + 0x1C, ABERR_BAIL),                # w0==0 -> original bail
        b(S9 + 0x20, ABERR_CONT1),               # continue
    )
    # stub10 — CreateFishItem GetCaughtCountById bail (`b.lt`) — second save
    # gate: aberrations only spawn for species already caught once. NZCV is
    # live from `cmp w0,#1`; adrp/ldrb/stp/ldp don't touch it, so the off
    # path replays b.lt as a local b.ge (b.cond can't reach back ~46MB).
    S10 = S9 + len(stub9)
    stub10 = w32s(
        stp_x(9, 10, -16),
        adrp(9, S10 + 0x04, SLOT), ldrb(10, 9, 0x52B),
        ldp_x(9, 10, 16),
        cbz(10, 2),                              # flag off -> replay b.lt
        b(S10 + 0x14, ABERR_CONT2),              # flag on -> skip bail
        bcond(0xA, 2),                           # b.ge -> continue (b.lt inverted)
        b(S10 + 0x1C, ABERR_BAIL),               # lt -> original bail
        b(S10 + 0x20, ABERR_CONT2),              # ge -> continue
    )
    uf[CAVE:CAVE + len(stub0) + len(stub1) + len(stub2) + len(stub3) + len(stub4) + len(stub5) + len(stub6) + len(stub7) + len(stub8) + len(stub9) + len(stub10)] \
        = stub0 + stub1 + stub2 + stub3 + stub4 + stub5 + stub6 + stub7 + stub8 + stub9 + stub10

    patches = [
        # always-on: full game, all DLC (research-points getter baked too —
        # has zero bl callers so likely inlined, but covers virtual calls)
        (0x12948BC, w32s(0x52800000, RET)),                       # trial -> 0
        (0x13E358C, w32s(0x52800020, RET)),                       # entitlement -> 1
        (0x134C5B8, w32s(0x52800000, RET)),                       # research -> 0
        # toggle trampolines (original word replicated inside each stub)
        (GETITEMVAL, w32s(b(GETITEMVAL, CAVE))),
        (CATCHROLL, w32s(b(CATCHROLL, S1))),
        (BURNSTORE, w32s(b(BURNSTORE, S2))),
        (SIZELOAD,  w32s(b(SIZELOAD, S4))),
        (FRESHBR,   w32s(b(FRESHBR, S3))),
        (ITEMEVAL,  w32s(b(ITEMEVAL, S5))),
        (UPGGATE,   w32s(b(UPGGATE, S6))),
        (CREATE_FISH, w32s(b(CREATE_FISH, S7))),
        (SPEND_RESEARCH, w32s(b(SPEND_RESEARCH, S8))),
        (ABERRGATE1, w32s(b(ABERRGATE1, S9))),
        (ABERRGATE2, w32s(b(ABERRGATE2, S10))),
    ]
    for off, blob in patches:
        uf[off:off+len(blob)] = blob
    uf = bytes(uf)

    fw_info = plistlib.dumps({
        'CFBundleExecutable': 'DREMenu',
        'CFBundleIdentifier': 'com.dremenu',
        'CFBundleName': 'DREMenu',
        'CFBundlePackageType': 'FMWK',
        'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0',
        'CFBundleInfoDictionaryVersion': '6.0',
        'MinimumOSVersion': '16.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
    }, fmt=plistlib.FMT_BINARY)

    ip = plistlib.loads(zin.read(info_path))
    # Stock App Store plist restricts install to iPad/Mac/Vision devices only
    # (UISupportedDevices allow-list with zero iPhone identifiers) — iOS
    # installd refuses iPhone installs outright. iOSGods stripped it; we must too.
    ip.pop('UISupportedDevices', None)
    ip.pop('ITSDRMScheme', None)  # leftover FairPlay marker, also stripped by mods
    ip['UIFileSharingEnabled'] = True
    ip['LSSupportsOpeningDocumentsInPlace'] = True
    info_bytes = plistlib.dumps(ip, fmt=plistlib.FMT_BINARY)

    # Build a `zip -r`-shaped container like the iOSGods IPA that Signulous
    # installs successfully: explicit dir entries (Payload/ first), no zip64
    # extra fields, extract_version 20, flag_bits 0.
    def dir_zinfo(name):
        zi = zipfile.ZipInfo(name)
        zi.create_system = 3
        zi.external_attr = 0o40755 << 16
        zi.compress_type = zipfile.ZIP_STORED
        zi.extract_version = 20
        zi.create_version = 20
        return zi
    def norm(zi, exec_bit):
        zi.extra = b''                     # strip zip64 extras
        zi.flag_bits = 0
        zi.extract_version = 20
        zi.create_version = 20
        zi.create_system = 3
        zi.external_attr = exec_bit << 16
        return zi
    def macho_zinfo(name):
        zi = norm(zipfile.ZipInfo(name), 0o100755)
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi
    def file_zinfo(name):
        zi = norm(zipfile.ZipInfo(name), 0o100644)
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi

    zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    dirs_seen = set()
    def emit_dirs(path):
        parts = path.split('/')
        for i in range(1, len(parts)):
            d = '/'.join(parts[:i]) + '/'
            if d not in dirs_seen:
                dirs_seen.add(d)
                zout.writestr(dir_zinfo(d), b'')

    def emit(zi, data, exec_bit=None):
        emit_dirs(zi.filename)
        data = data if data is not None else zin.read(zi.filename)
        if exec_bit is None:
            exec_bit = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zout.writestr(norm(zi, exec_bit), data)

    for zi in zin.infolist():
        n = zi.filename
        # keep _CodeSignature dirs — the working iOSGods IPA ships them
        # (stale) and some signers expect a previously-signed bundle shape;
        # only drop the device-specific provisioning profile
        if n.endswith('embedded.mobileprovision'):
            continue
        if n == exe_path or n == info_path or n == uf_path:
            continue
        emit(zi, None)
    # rewritten/new binaries get explicit exec perms
    emit(macho_zinfo(exe_path), exe)
    emit(macho_zinfo(uf_path), uf)
    emit(macho_zinfo(fw_path), dyb)
    emit(file_zinfo(fw_plist), fw_info)
    emit(file_zinfo(info_path), info_bytes)
    if save:
        emit(file_zinfo(save_dst), open(save, 'rb').read())
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
