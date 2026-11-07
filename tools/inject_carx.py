"""Inject LC_LOAD_DYLIB for CXMenu.framework into CarXDriftRacing3 and repackage.

- Weakens the iOSGods load commands (libcarx in UnityFramework, iGameGod in
  the exe) and drops their files from the bundle — weak loads of missing
  files skip silently, so nothing external remains.
- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/CXMenu.framework/CXMenu'
- Bakes the resource-seam patch into UnityFramework (see stub notes below)
- Repackages the IPA preserving exec bits and zip layout

Usage: inject_carx.py <input.ipa> <CXMenu dylib> <out.ipa>
"""
import sys, struct, zipfile, os, plistlib

LC_LOAD_DYLIB      = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_CODE_SIGNATURE  = 0x1D
MH_MAGIC_64 = 0xFEEDFACF

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

def weaken_load(b: bytearray, needle: bytes) -> int:
    """LC_LOAD_DYLIB -> LC_LOAD_WEAK_DYLIB for any load whose path contains
    needle. The file is then removed from the bundle, so dyld skips it."""
    ncmds = struct.unpack('<I', b[16:20])[0]
    off = 32; hits = 0
    for _ in range(ncmds):
        cmd, size = struct.unpack('<II', b[off:off+8])
        if cmd == LC_LOAD_DYLIB:
            noff = struct.unpack('<I', b[off+8:off+12])[0]
            name = bytes(b[off+noff:off+size]).split(b'\x00')[0]
            if needle in name:
                struct.pack_into('<I', b, off, LC_LOAD_WEAK_DYLIB)
                hits += 1
        off += size
    return hits

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    app       = 'Payload/CarXDriftRacing3.app'
    exe_path  = f'{app}/CarXDriftRacing3'
    uf_path   = f'{app}/Frameworks/UnityFramework.framework/UnityFramework'
    fw_path   = f'{app}/Frameworks/CXMenu.framework/CXMenu'
    fw_plist  = f'{app}/Frameworks/CXMenu.framework/Info.plist'
    info_path = f'{app}/Info.plist'

    zin = zipfile.ZipFile(ipa)
    exe = bytearray(zin.read(exe_path))
    dyb = open(dylib, 'rb').read()

    # iOSGods payload removal: weaken the loads, drop the files.
    n = weaken_load(exe, b'iGameGod');   assert n == 1, f'exe iGameGod LC x{n}'
    exe = inject_dylib_cmd(bytes(exe), '@executable_path/Frameworks/CXMenu.framework/CXMenu')

    uf = bytearray(zin.read(uf_path))
    n = weaken_load(uf, b'libcarx');     assert n == 1, f'uf libcarx LC x{n}'
    orig = lambda va: struct.unpack('<I', uf[va:va+4])[0]

    # ---- encoders ---------------------------------------------------------
    def adrp(rd, pc_va, tgt_page):
        imm = (((tgt_page & ~0xFFF) - (pc_va & ~0xFFF)) >> 12) & 0x1FFFFF
        return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd
    def ldrb(rt, rn, off):
        return 0x39400000 | ((off & 0xFFF) << 10) | (rn << 5) | rt
    def ldr_w(rt, rn, off):
        return 0xB9400000 | (((off >> 2) & 0xFFF) << 10) | (rn << 5) | rt
    def stp_x(rt, rt2, imm):
        return 0xA9800000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def ldp_x(rt, rt2, imm):
        return 0xA8C00000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def cbz(rt, imm19):
        return 0x34000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def cmp_i(rn, imm12):
        return 0x7100001F | ((imm12 & 0xFFF) << 10) | (rn << 5)
    def bcond(cond, imm19):
        return 0x54000000 | ((imm19 & 0x7FFFF) << 5) | cond
    def b(pc_va, tgt_va):
        return 0x14000000 | (((tgt_va - pc_va) >> 2) & 0x3FFFFFF)
    def madd(rd, rn, rm, ra):
        return 0x1B000000 | (rm << 16) | (ra << 10) | (rn << 5) | rd
    def w32s(*words): return b''.join(struct.pack('<I', w) for w in words)

    # ---- resource seam ----------------------------------------------------
    # Dr3PlayerResourcesUtils.AddResource(dict, name, balance, out*, factor):
    #   new = delta*factor + balance  (madd @SITE, then *out and dict = new)
    # factor +1 on earns, -1 on spends. Both cheats live in ONE stub:
    #   flag+0 Cash Boost: earns (factor>0) use i32 multiplier at flag+4
    #   flag+1 Free Purchases: spends (factor<0) skip the madd — w23 keeps
    #     `balance`, so the store writes the unchanged balance back.
    #
    # Cave/flag safety: zero runs INSIDE live sections are real data —
    # the first cave pick (0x6150690 in __TEXT.__const) crashed dyld's
    # initializer walk (null fn ptr call, CODESIGNING Invalid Page). The
    # only provably dead space is SEGMENT-TAIL page padding: bytes past the
    # last section but inside the mapped segment — never addressed by
    # section machinery, zero branch/pointer xrefs (verified).
    SITE, CAVE, SLOT = 0x283D660, 0x69974D0, 0x7B47000
    SB = CAVE
    stub = w32s(
        stp_x(9, 10, -16),                        # +0x00 save scratch
        adrp(9, SB+4, SLOT),                      # +0x04 flag page
        ldrb(10, 9, SLOT & 0xFFF),                # +0x08 mult flag
        cbz(10, 6),                               # +0x0C -> +0x24 free-check
        cmp_i(22, 0),                             # +0x10 factor sign
        bcond(0xD, 4),                            # +0x14 b.le -> +0x24 (spends unmult)
        ldr_w(10, 9, (SLOT & 0xFFF) + 4),         # +0x18 i32 multiplier
        madd(23, 8, 10, 23),                      # +0x1C new = delta*mult + bal
        b(SB+0x20, SB+0x38),                      # +0x20 exit
        ldrb(10, 9, (SLOT & 0xFFF) + 1),          # +0x24 free-spend flag
        cbz(10, 3),                               # +0x28 -> +0x34 orig
        cmp_i(22, 0),                             # +0x2C
        bcond(0xB, 2),                            # +0x30 b.lt -> +0x38 (spend: skip)
        orig(SITE),                               # +0x34 orig madd
        ldp_x(9, 10, 16),                         # +0x38 restore
        b(SB+0x3C, SITE + 4),                     # +0x3C return
    )
    assert len(stub) <= (0x6998000 - CAVE)
    assert orig(SITE) == madd(23, 8, 22, 23), f'site word {orig(SITE):08x}'
    assert uf[CAVE:CAVE+len(stub)] == b'\x00' * len(stub), 'cave not empty'
    uf[CAVE:CAVE+len(stub)] = stub
    struct.pack_into('<I', uf, SITE, b(SITE, CAVE))
    print(f'patched AddResource madd @0x{SITE:x} -> stub @0x{CAVE:x} ({len(stub)}B)')

    # ---- repack -----------------------------------------------------------
    fw_info = plistlib.dumps({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'CXMenu',
        'CFBundleIdentifier': 'com.cheatmenu.cx',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'CXMenu',
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '1.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
    }, fmt=plistlib.FMT_BINARY)

    ip = plistlib.loads(zin.read(info_path))
    ip.pop('UISupportedDevices', None)
    ip.pop('ITSDRMScheme', None)
    ip['UIFileSharingEnabled'] = True
    ip['LSSupportsOpeningDocumentsInPlace'] = True
    info_bytes = plistlib.dumps(ip, fmt=plistlib.FMT_BINARY)

    def dir_zinfo(name):
        zi = zipfile.ZipInfo(name)
        zi.create_system = 3
        zi.external_attr = 0o40755 << 16
        zi.compress_type = zipfile.ZIP_STORED
        zi.extract_version = 20
        zi.create_version = 20
        return zi
    def norm(zi, exec_bit):
        zi.extra = b''
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

    drop_prefixes = (
        f'{app}/Frameworks/iGameGod.framework/',
    )
    drop_files = {
        f'{app}/Frameworks/libcarx.dylib',
        f'{app}/embedded.mobileprovision',
    }

    def emit(zi, data, exec_bit=None):
        emit_dirs(zi.filename)
        if zi.filename.endswith('/'):   # source dir entries may repeat parents
            if zi.filename in dirs_seen:
                return
            dirs_seen.add(zi.filename)
        data = data if data is not None else zin.read(zi.filename)
        if exec_bit is None:
            exec_bit = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zout.writestr(norm(zi, exec_bit), data)

    for zi in zin.infolist():
        n = zi.filename
        if n in drop_files or n.startswith(drop_prefixes):
            continue
        if n in (exe_path, uf_path, info_path):
            continue
        emit(zi, None)
    emit(macho_zinfo(exe_path), bytes(exe))
    emit(macho_zinfo(uf_path), bytes(uf))
    emit(macho_zinfo(fw_path), dyb)
    emit(file_zinfo(fw_plist), fw_info)
    emit(file_zinfo(info_path), info_bytes)
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
