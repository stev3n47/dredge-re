#!/usr/bin/env python3
"""Inject LC_LOAD_DYLIB for IPAuto.framework into PokmonGO and repackage the IPA.

Usage:
  python inject_ipauto.py <ipogo.ipa> <IPAuto-binary> <out.ipa>

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/IPAuto.framework/IPAuto'
  to the PokmonGO stub executable (same injection point iPoGo uses for Sentry).
- Assembles Payload/PokmonGO.app/Frameworks/IPAuto.framework/ (binary +
  Info.plist) — proper framework bundle so re-signers that recurse .framework
  dirs detect and sign it.
- Enables UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace so
  Documents/ipauto.json (keep-rules) and ipauto.log (runtime schema log)
  are browsable in Files.app / Finder.
- No static game-binary patches: IPAuto is pure NSURLSession-hook — nothing
  in UnityFramework is touched.
"""
import sys, struct, zipfile, plistlib

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

def strip_codesig(exe: bytes) -> bytes:
    b = bytearray(exe)
    ncmds, sizeofcmds = struct.unpack('<II', b[16:24])
    off = 32
    cs_off = cs_sz = None
    data_off = None
    linkedit = []
    for i in range(ncmds):
        cmd, sz = struct.unpack('<II', b[off:off+8])
        if cmd == LC_CODE_SIGNATURE:
            cs_off, cs_sz = off, sz
            data_off = struct.unpack('<I', b[off+8:off+12])[0]
        if cmd == 0x19:
            linkedit.append(off)
        off += sz
    if cs_off is None:
        return exe
    end = 32 + sizeofcmds
    b[cs_off:end-cs_sz] = b[cs_off+cs_sz:end]
    del b[end-cs_sz:end]
    struct.pack_into('<I', b, 16, ncmds - 1)
    struct.pack_into('<I', b, 20, sizeofcmds - cs_sz)
    # truncate at the superblob offset (it's the tail); shrink __LINKEDIT filesize to match
    if data_off and data_off < len(b):
        for off in linkedit:
            name = b[off+8:off+24].split(b'\0')[0]
            if name == b'__LINKEDIT':
                fileoff, filesize = struct.unpack('<QQ', b[off+40:off+56])
                if fileoff + filesize > data_off:
                    struct.pack_into('<Q', b, off+48, data_off - fileoff)
        del b[data_off:]
    return bytes(b)

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    exe_path  = 'Payload/PokmonGO.app/PokmonGO'
    fw_path   = 'Payload/PokmonGO.app/Frameworks/IPAuto.framework/IPAuto'
    fw_plist  = 'Payload/PokmonGO.app/Frameworks/IPAuto.framework/Info.plist'
    info_path = 'Payload/PokmonGO.app/Info.plist'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path),
                           '@executable_path/Frameworks/IPAuto.framework/IPAuto')
    # Strip the stub's now-stale LC_CODE_SIGNATURE: editing any signed binary
    # invalidates its CMS blob, and strict re-signers (Signulous) pre-verify
    # and refuse invalidly-signed binaries. Unsigned re-signs cleanly.
    exe = strip_codesig(exe)
    dyb = open(dylib, 'rb').read()

    fw_info = plistlib.dumps({
        'CFBundleExecutable': 'IPAuto',
        'CFBundleIdentifier': 'com.ipauto',
        'CFBundleName': 'IPAuto',
        'CFBundlePackageType': 'FMWK',
        'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0',
        'CFBundleInfoDictionaryVersion': '6.0',
        'MinimumOSVersion': '13.0',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
    }, fmt=plistlib.FMT_BINARY)

    ip = plistlib.loads(zin.read(info_path))
    ip.pop('UISupportedDevices', None)
    ip.pop('ITSDRMScheme', None)
    ip['UIFileSharingEnabled'] = True
    ip['LSSupportsOpeningDocumentsInPlace'] = True
    info_bytes = plistlib.dumps(ip, fmt=plistlib.FMT_BINARY)

    # zip shape matching the installable IPAs: dir entries, no zip64,
    # extract_version 20, exec bit on mach-o
    def dir_zinfo(name):
        zi = zipfile.ZipInfo(name); zi.create_system = 3
        zi.external_attr = 0o40755 << 16
        zi.compress_type = zipfile.ZIP_STORED
        zi.extract_version = 20; zi.create_version = 20
        return zi
    def norm(zi, exec_bit):
        zi.extra = b''; zi.flag_bits = 0
        zi.extract_version = 20; zi.create_version = 20; zi.create_system = 3
        zi.external_attr = exec_bit << 16
        return zi
    def macho_zinfo(name):
        zi = norm(zipfile.ZipInfo(name), 0o100755); zi.compress_type = zipfile.ZIP_DEFLATED
        return zi

    zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    dirs_seen = {z.filename for z in zin.infolist() if z.filename.endswith('/')}
    def emit_dirs(path):
        parts = path.split('/')
        for i in range(1, len(parts)):
            d = '/'.join(parts[:i]) + '/'
            if d not in dirs_seen:
                dirs_seen.add(d); zout.writestr(dir_zinfo(d), b'')
    def emit(zi, data):
        emit_dirs(zi.filename)
        eb = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zout.writestr(norm(zi, eb), data)

    for zi in zin.infolist():
        n = zi.filename
        if n.endswith('embedded.mobileprovision'):
            continue
        if n in (exe_path, info_path):
            continue
        emit(zi, zin.read(n))
    emit(macho_zinfo(exe_path), exe)
    emit(macho_zinfo(fw_path), dyb)
    emit(norm(zipfile.ZipInfo(fw_plist), 0o100644), fw_info)
    zout.writestr(norm(zipfile.ZipInfo(info_path), 0o100644), info_bytes)
    zout.close(); zin.close()
    print('wrote', out)

if __name__ == '__main__':
    main()
