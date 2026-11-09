"""Inject LC_LOAD_DYLIB for SMMenu.framework into SM27 and repackage.

Clean-slate mod — no iOSGods payload exists to remove, nothing to patch.
The menu dylib calls the game's own IL2CPP reward methods directly.

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/SMMenu.framework/SMMenu'
- Repackages the IPA preserving exec bits and zip layout

Usage: inject_sm27.py <input.ipa> <SMMenu dylib> <out.ipa>
"""
import sys, struct, zipfile, os, plistlib

LC_LOAD_DYLIB      = 0xC
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
        if c == 0x1D:  # LC_CODE_SIGNATURE — keep last
            cs_off = off
            break
        off += s
    ins = cs_off if cs_off is not None else lc_end
    b[ins+cmdsize:lc_end+cmdsize] = b[ins:lc_end]
    b[ins:ins+cmdsize] = cmd
    struct.pack_into('<I', b, 16, ncmds + 1)
    struct.pack_into('<I', b, 20, sizeofcmds + cmdsize)
    return bytes(b)

# Purchase/edition gates — patched to `mov w0,#1; ret` inside UnityFramework
# (VA == file offset in the decrypted image). Forces every "did user buy
# this" check true locally: VIP, Enhanced/Ultimate editions, non-consumables.
# Server-side purchase processing is untouched and remains authoritative.
RET1 = b'\x20\x00\x80\x52\xc0\x03\x5f\xd6'
GATE_PATCHES = [
    0x2A64614,  # InGameItemsContainer.HasPurchasedItem
    0x2A64700,  # InGameItemsContainer.HasPurchasedEnhancedEdition
    0x2A65078,  # InGameItemsContainer.HasPurchasedUltimateEdition
    0x2A64B2C,  # InGameItemsContainer.HasPurchasedNonConsumable
    0x2A65930,  # InGameItemsContainer.HasPurchasedNonConsumableProduct
    0x2A65A08,  # OwnsNonConsumable (shared tail for the edition gates)
    0x2A66C74,  # HasPurchasedAnyBundleSpecialOffer
    0x2A153C8,  # CustomerDataController.get_IsEnhancedEditionUser
    0x2A15490,  # CustomerDataController.get_IsUltimateEditionUser
    0x2A15528,  # CustomerDataController.get_IsVIPUser
]

def patch_uf(data: bytes) -> bytes:
    b = bytearray(data)
    for off in GATE_PATCHES:
        orig = bytes(b[off:off+8])
        if orig == RET1:
            continue  # already patched; idempotent
        # Accept any 8-byte prologue so a future SM27 build moving these
        # functions by a few bytes is caught at diff time, not after a
        # silent miscompile. Stock prologue is a typical sub sp / stp
        # pair — flag anything with a BRK or RET in the first word.
        first = struct.unpack('<I', orig[:4])[0]
        if first == 0xD65F03C0 or (first & 0xFFE0001F) == 0xD4200000:
            raise AssertionError(
                f"VA 0x{off:x} does not look like a function prologue "
                f"(first word 0x{first:08x}) — stock IPA version changed? "
                "Re-dump offsets before shipping."
            )
        b[off:off+8] = RET1
    return bytes(b)

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    app       = 'Payload/SM27.app'
    exe_path  = f'{app}/SM27'
    uf_path   = f'{app}/Frameworks/UnityFramework.framework/UnityFramework'
    fw_path   = f'{app}/Frameworks/SMMenu.framework/SMMenu'
    fw_plist  = f'{app}/Frameworks/SMMenu.framework/Info.plist'
    info_path = f'{app}/Info.plist'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path),
                           '@executable_path/Frameworks/SMMenu.framework/SMMenu')
    dyb = open(dylib, 'rb').read()

    fw_info = plistlib.dumps({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'SMMenu',
        'CFBundleIdentifier': 'com.cheatmenu.sm27',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'SMMenu',
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

    drop_files = {f'{app}/embedded.mobileprovision'}

    def emit(zi, data, exec_bit=None):
        emit_dirs(zi.filename)
        if zi.filename.endswith('/'):
            if zi.filename in dirs_seen:
                return
            dirs_seen.add(zi.filename)
        data = data if data is not None else zin.read(zi.filename)
        if exec_bit is None:
            exec_bit = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zout.writestr(norm(zi, exec_bit), data)

    for zi in zin.infolist():
        n = zi.filename
        if n in drop_files or n in (exe_path, info_path):
            continue
        if n == uf_path:
            emit(zi, patch_uf(zin.read(n)))
            continue
        emit(zi, None)
    emit(macho_zinfo(exe_path), bytes(exe))
    emit(macho_zinfo(fw_path), dyb)
    emit(file_zinfo(fw_plist), fw_info)
    emit(file_zinfo(info_path), info_bytes)
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
