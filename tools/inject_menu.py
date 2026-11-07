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
    # v15 hook choices — picked for REAL callers (verified via bl-scan; the
    # previous getter patches were dead code — il2cpp inlines tiny getters):
    #   flag+0 Sell ×4:  GameManager.AddFunds entry. Arg is a .NET decimal by
    #       value in x1:x2 = 96-bit mantissa + flags. ×4 = mantissa << 2.
    #       Skipped when sign bit (x2[63]) set → negative adds (debt) untouched.
    #       13 real bl callers incl. SellFocusedItem.
    #   flag+1 Pot auto-catch: SerializedCrabPotPOIData.CalculateCatchRoll
    #       (float roll, this) -> w0 bool. Flag on → w0=1 (always caught).
    #       Crab pots only; rod/trawl use a different path.
    # God/Immune are menu-driven `SetGodMode`/`SetImmuneMode` terminal commands
    # (write real Player fields) — no patch needed.
    SLOT = 0x46DF528
    CAVE = 0x3E46D40
    def adrp(rd, pc_va, tgt_page):
        imm = (((tgt_page & ~0xFFF) - (pc_va & ~0xFFF)) >> 12) & 0x1FFFFF
        return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd
    def ldrb(rt, rn, off):
        return 0x39400000 | ((off & 0xFFF) << 10) | (rn << 5) | rt
    def cbz(rt, imm19):
        return 0x34000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def cbnz(rt, imm19):
        return 0x35000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def tbnz(rt, bit, imm14):
        return 0x37000000 | (((bit >> 5) & 1) << 31) | ((bit & 31) << 19) \
               | ((imm14 & 0x3FFF) << 5) | rt
    def mov_r(rd, rs, wide):
        return (0xAA0003E0 if wide else 0x2A0003E0) | (rs << 16) | rd
    def lsr_i(rd, rn, sh, wide):      # UBFM rd,rn,#sh,#(bits-1)
        bits = 64 if wide else 32
        return (0xD3400000 if wide else 0x53000000) \
               | (sh << 16) | ((bits - 1) << 10) | (rn << 5) | rd
    def lsl_i(rd, rn, sh, wide):      # UBFM rd,rn,#(bits-sh),#(bits-sh-1)
        bits = 64 if wide else 32
        return (0xD3400000 if wide else 0x53000000) \
               | ((bits - sh) << 16) | ((bits - sh - 1) << 10) | (rn << 5) | rd
    def orr_r(rd, rn, rm, wide):
        return (0xAA000000 if wide else 0x2A000000) | (rm << 16) | (rn << 5) | rd
    def bfi(rd, rn, lsb, width):      # BFM rd,rn,#(64-lsb),#width-1
        return 0xB3400000 | (((64 - lsb) & 63) << 16) | ((width - 1) << 10) \
               | (rn << 5) | rd
    def b(pc_va, tgt_va):
        return 0x14000000 | (((tgt_va - pc_va) >> 2) & 0x3FFFFFF)
    RET = 0xD65F03C0
    def w32s(*words): return b''.join(struct.pack('<I', w) for w in words)

    uf = bytearray(zin.read(uf_path))
    orig = lambda va: struct.unpack('<I', uf[va:va+4])[0]

    ADDFUNDS, CATCHROLL = 0x13F6E30, 0x1289B38

    # stub0 @CAVE+0x00 — AddFunds(decimal amount{x1:x2}, ...): flag on && x2
    # sign bit clear -> mantissa96 <<= 2 (decimal ×4), then resume at +4.
    # mantissa = {x2[31:0] hi32 : x1 lo64}; <<2: new_hi = hi<<2 | lo>>62;
    # new_lo = lo<<2 (hi top bits = overflow, discarded).
    stub0 = w32s(
        orig(ADDFUNDS),                          # stp x26,x25,[sp,#-0x50]!
        adrp(9, CAVE + 0x04, SLOT), ldrb(10, 9, 0x528),
        cbz(10, 9),                              # flag off -> resume
        tbnz(2, 63, 8),                          # negative amount -> resume
        mov_r(11, 2, False),                     # w11 = old hi32
        mov_r(13, 1, True),                      # x13 = old lo64
        lsr_i(12, 13, 62, True),                 # lo64 top2 -> new hi32 low
        lsl_i(1, 13, 2, True),                   # new lo64 = lo64 << 2
        lsl_i(15, 11, 2, False),                 # new hi32 = hi32 << 2
        orr_r(15, 15, 12, False),                #          | lo64 top2
        bfi(2, 15, 0, 32),                       # x2 = flags(top32) | new_hi32
        b(CAVE + 0x30, ADDFUNDS + 4),            # resume AddFunds+4
    )
    # stub1 @CAVE+0x34 — CalculateCatchRoll(roll, this)->bool: flag -> w0=1.
    S1 = CAVE + len(stub0)
    stub1 = w32s(
        adrp(9, S1 + 0x00, SLOT), ldrb(9, 9, 0x529),
        cbnz(9, 3),                              # flag on -> forced catch
        orig(CATCHROLL),                         # sub sp,sp,#0x50
        b(S1 + 0x10, CATCHROLL + 4),             # resume original
        0x52800020,                              # mov w0,#1
        RET,
    )
    uf[CAVE:CAVE + len(stub0) + len(stub1)] = stub0 + stub1

    patches = [
        # always-on: full game, all DLC, free research
        (0x12948BC, w32s(0x52800000, RET)),                       # trial -> 0
        (0x13E358C, w32s(0x52800020, RET)),                       # entitlement -> 1
        (0x134C5B8, w32s(0x52800000, RET)),                       # research -> 0
        # toggle trampolines (original word replicated inside each stub)
        (ADDFUNDS,  w32s(b(ADDFUNDS, CAVE))),
        (CATCHROLL, w32s(b(CATCHROLL, S1))),
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
