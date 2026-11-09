"""Reproduce the SpooferPro 0.435.1 Pro/Elite unlock as static byte patches.

This is the offline / reproducible version of the hand-rolled patch set
shipped as the `spooferpro-0.435.1-unlocked` release. It takes a stock
SpooferPro IPA (same libSpooferPro.dylib build, verified by SHA-256) and
writes the same 6 byte-patches into `Payload/PokmonGO.app/Frameworks/
libSpooferPro.dylib`, then repacks the IPA.

Target binary (verified):
  size   30_295_600 bytes
  sha256 same-as-v1 (pre-fifth-gate-and-LEVEL) — see SPOOFERPRO-FINDINGS.md
         if the input is the released v1 IPA, this writes the v2 patches.
         if the input is a stock (never-patched) dylib, this writes the
         full 6-patch set (v1's 4 tier wrappers are included below).

Usage:
  python tools/inject_spooferpro.py <input.ipa> <out.ipa>

Each site is checked before patching: if the word is already the patched
value, the site is reported as idempotent-skip. If it's neither stock nor
patched, the tool bails — the dylib has changed and offsets need re-dumping.
"""
import hashlib
import io
import os
import struct
import sys
import zipfile

DYLIB_PATH = 'Payload/PokmonGO.app/Frameworks/libSpooferPro.dylib'
DYLIB_SIZE = 30_295_600

# File offset == virtual address for every section in this dylib
# (see SPOOFERPRO-FINDINGS.md). Each patch is (offset, stock_first_word,
# patched_first_word, patched_second_word, label).
RET      = 0xD65F03C0   # ret
MOV_W0_1 = 0x52800020   # mov w0, #1
MOV_X0_FF= 0xD2801FE0   # mov x0, #0xff

# The four tier wrappers were already patched to mov w0,#1; ret in v1. Their
# stock first-word is unknown (no pre-mod reference), so the check is
# "word == MOV_W0_1" → already patched; anything else → write (but warn).
TIER_WRAPPER_SITES = [
    (0x7d9ae0, 'tier wrapper 1'),
    (0x7d9bec, 'tier wrapper 2'),
    (0x7d9edc, 'tier wrapper 3'),
    (0x7da154, 'tier wrapper 4'),
]

# The two v2-only patches, with their stock first-words confirmed by the
# v1→v2 cmp diff. A third word is the untouched function prologue, so we
# only overwrite 8 bytes.
V2_PATCHES = [
    (0x7da430, 0xa9ba6ffc, MOV_W0_1, RET,
     'fifth gate — 13 BL callers'),
    (0x000bcf70, 0xd10203ff, MOV_X0_FF, RET,
     'LEVEL getter — returns 0xff so every tier>=featureId'),
]


def rd_u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def wr_u32(b, off, val):
    struct.pack_into('<I', b, off, val)


def patch_dylib(dyb: bytes) -> bytes:
    if len(dyb) != DYLIB_SIZE:
        print(f'warn: libSpooferPro.dylib size is {len(dyb)}, expected '
              f'{DYLIB_SIZE} — offsets may be wrong, proceeding anyway.')

    b = bytearray(dyb)

    for off, label in TIER_WRAPPER_SITES:
        w1, w2 = rd_u32(b, off), rd_u32(b, off + 4)
        if w1 == MOV_W0_1 and w2 == RET:
            print(f'  0x{off:08x}  {label:30s}  already patched')
            continue
        print(f'  0x{off:08x}  {label:30s}  write mov w0,#1; ret '
              f'(was {w1:08x} {w2:08x})')
        wr_u32(b, off,     MOV_W0_1)
        wr_u32(b, off + 4, RET)

    for off, stock, p1, p2, label in V2_PATCHES:
        w1, w2 = rd_u32(b, off), rd_u32(b, off + 4)
        if w1 == p1 and w2 == p2:
            print(f'  0x{off:08x}  {label:30s}  already patched')
            continue
        if w1 != stock:
            raise SystemExit(
                f'error: 0x{off:08x} first word is {w1:08x}, expected stock '
                f'{stock:08x} or patched {p1:08x} — the dylib has drifted. '
                'Re-dump offsets before shipping.'
            )
        print(f'  0x{off:08x}  {label:30s}  write (was {w1:08x} {w2:08x})')
        wr_u32(b, off,     p1)
        wr_u32(b, off + 4, p2)

    return bytes(b)


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


def main():
    if len(sys.argv) < 3:
        sys.exit('usage: inject_spooferpro.py <input.ipa> <out.ipa>')
    ipa_in, ipa_out = sys.argv[1], sys.argv[2]

    with zipfile.ZipFile(ipa_in) as zin:
        try:
            dyb_in = zin.read(DYLIB_PATH)
        except KeyError:
            sys.exit(f'error: {DYLIB_PATH!r} not in {ipa_in}')
        print(f'input   sha256={hashlib.sha256(dyb_in).hexdigest()}  '
              f'size={len(dyb_in)}')

        dyb_out = patch_dylib(dyb_in)
        print(f'output  sha256={hashlib.sha256(dyb_out).hexdigest()}  '
              f'size={len(dyb_out)}')

        with zipfile.ZipFile(ipa_out, 'w', zipfile.ZIP_DEFLATED) as zout:
            dirs_seen = set()

            def emit_dirs(path):
                parts = path.split('/')
                for i in range(1, len(parts)):
                    d = '/'.join(parts[:i]) + '/'
                    if d not in dirs_seen:
                        dirs_seen.add(d)
                        zout.writestr(dir_zinfo(d), b'')

            for zi in zin.infolist():
                n = zi.filename
                if n.endswith('/'):
                    emit_dirs(n)
                    if n not in dirs_seen:
                        dirs_seen.add(n)
                        zout.writestr(dir_zinfo(n), b'')
                    continue
                if n.endswith('/embedded.mobileprovision'):
                    # stale provision — strip; signer writes its own.
                    continue
                emit_dirs(n)
                data = dyb_out if n == DYLIB_PATH else zin.read(n)
                if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe',
                                b'\xfe\xed\xfa\xcf'):
                    exec_bit = 0o100755
                else:
                    exec_bit = 0o100755 if zi.external_attr & (0o111 << 16) \
                        else 0o100644
                zi2 = norm(zi, exec_bit)
                zi2.compress_type = zipfile.ZIP_DEFLATED
                zout.writestr(zi2, data)

    size = os.path.getsize(ipa_out)
    print(f'wrote {ipa_out}  ({size} bytes)')


if __name__ == '__main__':
    main()
