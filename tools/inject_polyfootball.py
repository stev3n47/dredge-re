#!/usr/bin/env python3
"""Inject PFPlus.framework into a PolyFootball IPA.

Usage:
  python tools/inject_polyfootball.py <Poly.ipa> <PFPlus-binary> <out.ipa>

Unlike inject_spooferpro_plus.py, this script discovers the main app bundle
and its executable from the IPA itself (the `.app` directory name and
`CFBundleExecutable` are not known a priori for PolyFootball). It then:

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/PFPlus.framework/PFPlus'
  to the main app stub executable.
- Writes Payload/<App>.app/Frameworks/PFPlus.framework/{PFPlus, Info.plist}
- Enables UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace so the
  Documents/pfplus.json config and pfplus.log output are browsable in
  Files.app.

The output IPA is unsigned; sign it with TrollStore (preferred), AltStore /
SideStore, or a dev-signed provisioning profile before installing. The
install channel is PFPlus's biggest external dependency — this script does
not pick one.
"""
import sys
import struct
import zipfile
import plistlib
import os
import re

LC_LOAD_DYLIB     = 0xC
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64       = 0xFEEDFACF

FW_NAME = 'PFPlus'
FW_ID   = 'com.polyfootballplus'


def discover_app(zin: zipfile.ZipFile):
    """Find Payload/<App>.app, return (app_dir, exe_path, info_path)."""
    app_dirs = set()
    for zi in zin.infolist():
        m = re.match(r'^(Payload/[^/]+\.app)/', zi.filename)
        if m:
            app_dirs.add(m.group(1))
    if not app_dirs:
        sys.exit('error: no Payload/*.app directory in IPA')
    if len(app_dirs) > 1:
        # Take the shortest — nested appex bundles have longer paths.
        app_dir = min(app_dirs, key=len)
    else:
        app_dir = next(iter(app_dirs))
    info_path = f'{app_dir}/Info.plist'
    try:
        info = plistlib.loads(zin.read(info_path))
    except KeyError:
        sys.exit(f'error: {info_path} not in IPA')
    exe = info.get('CFBundleExecutable')
    if not exe:
        sys.exit(f'error: no CFBundleExecutable in {info_path}')
    exe_path = f'{app_dir}/{exe}'
    return app_dir, exe_path, info_path


def inject_dylib_cmd(exe: bytes, dylib_path: str) -> bytes:
    b = bytearray(exe)
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack('<8I', b[:32])
    if magic != MH_MAGIC_64:
        sys.exit(f'error: main exe is not arm64 Mach-O (magic 0x{magic:x})')

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
    required = (24 + len(dylib_path.encode()) + 1 + 7) & ~7
    if pad < required:
        sys.exit(f'error: not enough header pad ({pad} < {required}); re-link with -headerpad_max_install_names')

    # idempotency
    off = 32
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', b[off:off+8])
        if cmd in (LC_LOAD_DYLIB, 0x80000018):
            noff = struct.unpack('<I', b[off+8:off+12])[0]
            name = bytes(b[off+noff:off+cmdsize]).split(b'\x00')[0]
            if name == dylib_path.encode():
                print(f'  LC_LOAD_DYLIB "{dylib_path}" already present — skipping')
                return bytes(b)
        off += cmdsize

    name = dylib_path.encode()
    cmdsize = (24 + len(name) + 1 + 7) & ~7
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0x10000) + name + b'\0' * (cmdsize - 24 - len(name))

    cs_off = None
    off = 32
    for i in range(ncmds):
        c, s = struct.unpack('<II', b[off:off+8])
        if c == LC_CODE_SIGNATURE:
            cs_off = off; break
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
    b[end-cs_sz:end] = b'\0' * cs_sz
    struct.pack_into('<I', b, 16, ncmds - 1)
    struct.pack_into('<I', b, 20, sizeofcmds - cs_sz)
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
    if len(sys.argv) < 4:
        sys.exit('usage: inject_polyfootball.py <Poly.ipa> <PFPlus-binary> <out.ipa>')
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]

    zin = zipfile.ZipFile(ipa)
    app_dir, exe_path, info_path = discover_app(zin)
    print(f'app bundle: {app_dir}')
    print(f'executable: {exe_path}')

    fw_dir    = f'{app_dir}/Frameworks/{FW_NAME}.framework/'
    fw_path   = f'{fw_dir}{FW_NAME}'
    fw_plist  = f'{fw_dir}Info.plist'

    exe = inject_dylib_cmd(
        zin.read(exe_path),
        f'@executable_path/Frameworks/{FW_NAME}.framework/{FW_NAME}')
    exe = strip_codesig(exe)

    dyb = open(dylib, 'rb').read()

    fw_info = plistlib.dumps({
        'CFBundleExecutable': FW_NAME,
        'CFBundleIdentifier': FW_ID,
        'CFBundleName': FW_NAME,
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

    def dir_zinfo(name):
        zi = zipfile.ZipInfo(name); zi.create_system = 3
        zi.external_attr = (0o40755 << 16) | 0x10
        zi.compress_type = zipfile.ZIP_STORED
        zi.extract_version = 10; zi.create_version = 10
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
        if n.endswith('/embedded.mobileprovision'):
            continue
        if n in (exe_path, info_path):
            continue
        if n.endswith('/'):
            zout.writestr(dir_zinfo(n), b'')
            continue
        emit(zi, zin.read(n))
    emit(macho_zinfo(exe_path), exe)
    emit(macho_zinfo(fw_path), dyb)
    emit(norm(zipfile.ZipInfo(fw_plist), 0o100644), fw_info)
    zout.writestr(norm(zipfile.ZipInfo(info_path), 0o100644), info_bytes)
    zout.close(); zin.close()
    print(f'wrote {out}')
    print('next: sign with TrollStore / AltStore / SideStore / dev-signed profile')


if __name__ == '__main__':
    main()
