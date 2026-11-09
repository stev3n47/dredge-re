#!/usr/bin/env python3
"""Inject LC_LOAD_DYLIB for libIPAuto.dylib and repackage the IPA.

Usage:
  python inject_ipauto.py <ipogo.ipa> <IPAuto-binary> <out.ipa>

Layout mirrors SpooferPro's distribution, which survives sideload re-signers:
- LC_LOAD_DYLIB '@rpath/libIPAuto.dylib' is added to FBAEMKit.framework (a
  stock binary already in the app and hard-loaded by UnityFramework), NOT to
  the main executable — the stub keeps its original valid signature.
- The tweak ships as a bare dylib at Frameworks/libIPAuto.dylib (no .framework
  bundle, no plist) — re-signers handle foreign .dylib files correctly but
  mis-seal foreign .framework bundles.
- No code signatures are stripped: the re-signer replaces CMS blobs wholesale.
- Enables UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace so
  Documents/ipauto.json and ipauto.log are browsable in Files.app / Finder.
"""
import sys, struct, zipfile, plistlib

LC_LOAD_DYLIB     = 0xC
LC_ID_DYLIB       = 0xD
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

def set_install_name(dylib: bytes, new_name: str) -> bytes:
    """Rewrite LC_ID_DYLIB in place; the new name must fit the existing slot."""
    b = bytearray(dylib)
    ncmds = struct.unpack('<I', b[16:20])[0]
    off = 32
    for i in range(ncmds):
        cmd, cmdsize = struct.unpack('<II', b[off:off+8])
        if cmd == LC_ID_DYLIB:
            name_off = struct.unpack('<I', b[off+8:off+12])[0]
            cap = cmdsize - name_off
            enc = new_name.encode()
            assert len(enc) + 1 <= cap, f'install name too long for slot ({cap})'
            b[off+name_off:off+cmdsize] = enc + b'\0' * (cap - len(enc))
            return bytes(b)
        off += cmdsize
    raise AssertionError('no LC_ID_DYLIB')

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    fb_path   = 'Payload/PokmonGO.app/Frameworks/FBAEMKit.framework/FBAEMKit'
    dyb_path  = 'Payload/PokmonGO.app/Frameworks/libIPAuto.dylib'
    info_path = 'Payload/PokmonGO.app/Info.plist'

    zin = zipfile.ZipFile(ipa)
    # Inject into FBAEMKit (SpooferPro's injection point). Its signature is
    # left stale — the re-signer replaces the CMS blob; stripping proved
    # unnecessary and risky.
    fb = inject_dylib_cmd(zin.read(fb_path), '@rpath/libIPAuto.dylib')
    dyb = set_install_name(open(dylib, 'rb').read(), '@rpath/libIPAuto.dylib')

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
        zi.external_attr = (0o40755 << 16) | 0x10  # S_IFDIR|0755 + DOS dir bit
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
        if n.endswith('embedded.mobileprovision'):
            continue
        if n in (fb_path, info_path):
            continue
        if n.endswith('/'):
            # keep dir entries as directories — emit() would stamp them as files
            zout.writestr(dir_zinfo(n), b'')
            continue
        emit(zi, zin.read(n))
    emit(macho_zinfo(fb_path), fb)
    # bare dylib at 0644 — matches libSpooferPro.dylib's attrs
    zout.writestr(norm(zipfile.ZipInfo(dyb_path), 0o100644), dyb)
    zout.writestr(norm(zipfile.ZipInfo(info_path), 0o100644), info_bytes)
    zout.close(); zin.close()
    print('wrote', out)

if __name__ == '__main__':
    main()
