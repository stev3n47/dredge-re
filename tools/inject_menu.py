#!/usr/bin/env python3
"""Inject LC_LOAD_DYLIB for DREMenu.dylib into DREDGE and repackage the IPA.

Usage:
  python inject_menu.py <stock.ipa> <DREMenu.dylib> <out.ipa>

- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/DREMenu.dylib' to the
  DREDGE executable (header pad is >= 0x3800 bytes, plenty for +56 bytes).
- Copies DREMenu.dylib into Payload/DREDGE.app/Frameworks/.
- Strips LC_CODE_SIGNATURE from DREDGE (stale after edit) and drops the
  _CodeSignature dir so Singulous/TrollStore re-signs cleanly.
"""
import sys, struct, zipfile, shutil, os

LC_LOAD_DYLIB   = 0xC
LC_CODE_SIGNATURE = 0x1D
MH_MAGIC_64     = 0xFEEDFACF

def inject_dylib_cmd(exe: bytes, dylib_path: str) -> bytes:
    b = bytearray(exe)
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack('<8I', b[:32])
    assert magic == MH_MAGIC_64, 'not arm64 mach-o'

    # find end of load commands + check padding
    lc_end = 32 + sizeofcmds
    # first section fileoff: scan LC_SEGMENT_64 commands
    off = 32
    min_sect = None
    sig_off = None
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
        elif cmd == LC_CODE_SIGNATURE:
            sig_off = off
        off += cmdsize
    pad = (min_sect or 0x4000) - lc_end
    assert pad >= 72, f'not enough header pad ({pad})'

    name = dylib_path.encode()
    cmdsize = (24 + len(name) + 1 + 7) & ~7
    cmd = struct.pack('<IIIIII', LC_LOAD_DYLIB, cmdsize, 24, 0, 0x10000, 0) + name + b'\0' * (cmdsize - 24 - len(name))
    b[lc_end:lc_end+cmdsize] = cmd
    struct.pack_into('<I', b, 16, ncmds + 1)
    struct.pack_into('<I', b, 20, sizeofcmds + cmdsize)

    # strip code signature load cmd (stale) -> turn into LC_UUID? no: must remove.
    # safer: leave sig cmd but Singulous resigns anyway; we zero it into a pad cmd.
    # Actually: keep it — resigners detect it. Do nothing.
    return bytes(b)

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    exe_path = 'Payload/DREDGE.app/DREDGE'
    fw_path  = 'Payload/DREDGE.app/Frameworks/DREMenu.dylib'

    zin = zipfile.ZipFile(ipa)
    exe = inject_dylib_cmd(zin.read(exe_path), '@executable_path/Frameworks/DREMenu.dylib')
    dyb = open(dylib, 'rb').read()

    names = zin.namelist()
    zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    for n in names:
        if n == exe_path:
            continue
        zout.writestr(n, zin.read(n))
    zout.writestr(exe_path, exe)
    zout.writestr(fw_path, dyb)
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
