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
    fw_path   = 'Payload/DREDGE.app/Frameworks/DREMenu.framework/DREMenu'
    fw_plist  = 'Payload/DREDGE.app/Frameworks/DREMenu.framework/Info.plist'
    info_path = 'Payload/DREDGE.app/Info.plist'
    save_dst  = 'Payload/DREDGE.app/dredge-save0.bin'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path), '@executable_path/Frameworks/DREMenu.framework/DREMenu')
    dyb = open(dylib, 'rb').read()

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
        return norm(zipfile.ZipInfo(name), 0o100755)
    def file_zinfo(name):
        return norm(zipfile.ZipInfo(name), 0o100644)

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
        if n == exe_path or n == info_path:
            continue
        emit(zi, None)
    # rewritten/new binaries get explicit exec perms
    emit(macho_zinfo(exe_path), exe)
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
