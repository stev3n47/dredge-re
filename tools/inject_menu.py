#!/usr/bin/env python3
"""Inject LC_LOAD_DYLIB for DREMenu.dylib into DREDGE and repackage the IPA.

Usage:
  python inject_menu.py <stock.ipa> <DREMenu.dylib> <out.ipa> [save.bin]

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/DREMenu.dylib' to the
  DREDGE executable (header pad is >= 0x3800 bytes, plenty for +56 bytes).
- Copies DREMenu.dylib into Payload/DREDGE.app/Frameworks/.
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
    b[lc_end:lc_end+cmdsize] = cmd
    struct.pack_into('<I', b, 16, ncmds + 1)
    struct.pack_into('<I', b, 20, sizeofcmds + cmdsize)
    return bytes(b)

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    save = sys.argv[4] if len(sys.argv) > 4 else None
    exe_path  = 'Payload/DREDGE.app/DREDGE'
    fw_path   = 'Payload/DREDGE.app/Frameworks/DREMenu.dylib'
    info_path = 'Payload/DREDGE.app/Info.plist'
    save_dst  = 'Payload/DREDGE.app/dredge-save0.bin'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path), '@executable_path/Frameworks/DREMenu.dylib')
    dyb = open(dylib, 'rb').read()

    ip = plistlib.loads(zin.read(info_path))
    ip['UIFileSharingEnabled'] = True
    ip['LSSupportsOpeningDocumentsInPlace'] = True
    info_bytes = plistlib.dumps(ip, fmt=plistlib.FMT_BINARY)

    def macho_zinfo(name):
        zi = zipfile.ZipInfo(name)
        zi.create_system = 3            # Unix -> honour permission bits
        zi.external_attr = 0o755 << 16  # rwxr-xr-x
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi
    def file_zinfo(name):
        zi = zipfile.ZipInfo(name)
        zi.create_system = 3
        zi.external_attr = 0o644 << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi

    zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for zi in zin.infolist():
        n = zi.filename
        # drop stale signatures/provisioning so signers regenerate them fresh
        if '_CodeSignature' in n or n.endswith('embedded.mobileprovision'):
            continue
        if n == exe_path or n == info_path:
            continue
        # preserve original ZipInfo (keeps posix perms, create_system, timestamps)
        zout.writestr(zi, zin.read(n))
    # rewritten/new binaries get explicit exec perms
    zout.writestr(macho_zinfo(exe_path), exe)
    zout.writestr(macho_zinfo(fw_path), dyb)
    # plist: keep 0644
    zout.writestr(file_zinfo(info_path), info_bytes)
    if save:
        zout.writestr(file_zinfo(save_dst), open(save, 'rb').read())
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
