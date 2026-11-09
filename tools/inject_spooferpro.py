"""Reproduce the SpooferPro 0.435.1 Pro/Elite unlock as static byte patches.

By default, writes:
 - The four tier wrappers (already patched in every shipped release)
 - The fifth gate at 0x7da430  (entry-point patch, safe)
 - LEVEL getter RETURN VALUE override at 0xbdbc8 (NOT the entry) — the
   stock function at 0xbcf70 is a 4.5 KB function with TLS side effects
   (atomic op on the slot at 0x1bac75c) that downstream code depends on.
   Both the shipped v2 (which overwrote the entry with `mov x0,#0xff;ret`)
   and v3 (same approach, `mov x0,#4;ret`) crash on-device at launch
   because the function's side effects never run. The fix is to let the
   function execute in full and override ONLY the last instruction
   before the ret — `mov x0, x21` at 0xbdbc8 — so x0 reports max tier
   while every side effect is preserved.

The three "v2 patches" can be toggled individually for bisecting. The
documented-bad entry-point variants are also available behind
--level-getter-entry / --fifth-gate for reproducing the shipped crashes.

  # recommended (default — fifth gate + safe LEVEL override):
  python tools/inject_spooferpro.py in.ipa out.ipa

  # conservative, v1-equivalent (no fifth gate, no LEVEL override):
  python tools/inject_spooferpro.py in.ipa out.ipa --no-fifth-gate --no-level-override

  # reproduce shipped v2 (CRASHES on-device):
  python tools/inject_spooferpro.py in.ipa out.ipa --no-level-override --level-getter-entry

  # reproduce shipped v3 (also CRASHES):
  python tools/inject_spooferpro.py in.ipa out.ipa --no-fifth-gate --no-level-override --level-getter-entry --level-entry-value 4

Target binary (verified):
  path   Payload/PokmonGO.app/Frameworks/libSpooferPro.dylib
  size   30_295_600 bytes
  sha256 shipped-v1 6014374be941440e61fd889db8ad49555004542a20195df00536d418cfcaa7b8
         shipped-v2 be3e5ec019c766d725729904f4aced920b201a9f72aed1573b5dd813b2f0e8df
         shipped-v3 658578b2633ba3625b691c523e097a5591ae38a2d9023e6df8c220138c510247

Each site is checked before patching: if the word is already the expected
patched value, the site is reported idempotent-skip. If it's neither the
known stock value nor an expected patched one, the tool bails loudly.
"""
import argparse
import hashlib
import os
import struct
import sys
import zipfile

DYLIB_PATH = 'Payload/PokmonGO.app/Frameworks/libSpooferPro.dylib'
DYLIB_SIZE = 30_295_600

# File offset == virtual address for every section in this dylib
# (see SPOOFERPRO-FINDINGS.md).
RET      = 0xD65F03C0   # ret
MOV_W0_1 = 0x52800020   # mov w0, #1
MOV_X0_FF= 0xD2801FE0   # mov x0, #0xff
MOV_X0_X21 = 0xAA1503E0 # mov x0, x21   (stock 4-byte word at 0xbdbc8)

def mov_x0_imm16(imm: int) -> int:
    """Encode `mov x0, #imm` (imm fits in 16 unsigned bits)."""
    assert 0 <= imm <= 0xFFFF
    return 0xD2800000 | ((imm & 0xFFFF) << 5)

# The four tier wrappers were already patched to mov w0,#1; ret in v1.
TIER_WRAPPER_SITES = [
    (0x7d9ae0, 'tier wrapper 1'),
    (0x7d9bec, 'tier wrapper 2'),
    (0x7d9edc, 'tier wrapper 3'),
    (0x7da154, 'tier wrapper 4'),
]

# 8-byte entry-point patches. `stock` is the first word confirmed by v1→v2
# cmp diff. A third word is the untouched function prologue, so we only
# overwrite 8 bytes.
FIFTH_GATE = (0x7da430, 0xa9ba6ffc, MOV_W0_1, RET,
              'fifth gate — 13 BL callers, entry patch (safe)')
LEVEL_ENTRY = (0x000bcf70, 0xd10203ff,
               'LEVEL getter ENTRY — DO NOT USE: skips TLS side effects, crashes')

# Safer LEVEL fix: 4-byte override of `mov x0, x21` at the function's single
# epilogue (0xbdbc8), so the function runs in full and only the return value
# is substituted. See SPOOFERPRO-FINDINGS.md for the epilogue dump.
LEVEL_EPILOGUE_OFF = 0xbdbc8


def rd_u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def wr_u32(b, off, val):
    struct.pack_into('<I', b, off, val)


def patch_dylib(dyb: bytes, args) -> bytes:
    if len(dyb) != DYLIB_SIZE:
        print(f'warn: libSpooferPro.dylib size is {len(dyb)}, expected '
              f'{DYLIB_SIZE} — offsets may be wrong, proceeding anyway.')

    b = bytearray(dyb)

    for off, label in TIER_WRAPPER_SITES:
        w1, w2 = rd_u32(b, off), rd_u32(b, off + 4)
        if w1 == MOV_W0_1 and w2 == RET:
            print(f'  0x{off:08x}  {label:40s}  already patched')
            continue
        print(f'  0x{off:08x}  {label:40s}  write mov w0,#1; ret '
              f'(was {w1:08x} {w2:08x})')
        wr_u32(b, off,     MOV_W0_1)
        wr_u32(b, off + 4, RET)

    if args.fifth_gate:
        off, stock, p1, p2, label = FIFTH_GATE
        w1, w2 = rd_u32(b, off), rd_u32(b, off + 4)
        if w1 == p1 and w2 == p2:
            print(f'  0x{off:08x}  {label:40s}  already patched')
        elif w1 == stock:
            print(f'  0x{off:08x}  {label:40s}  write mov w0,#1; ret')
            wr_u32(b, off, p1); wr_u32(b, off + 4, p2)
        else:
            raise SystemExit(f'error: 0x{off:08x} is {w1:08x} — neither stock '
                             f'{stock:08x} nor patched {p1:08x}; re-dump.')

    if args.level_getter_entry:
        off, stock, label = LEVEL_ENTRY
        enc = mov_x0_imm16(args.level_entry_value)
        w1, w2 = rd_u32(b, off), rd_u32(b, off + 4)
        if w1 == enc and w2 == RET:
            print(f'  0x{off:08x}  {label:40s}  already patched')
        elif w1 == stock or (w1 & 0x7f80001f) == 0xd2800000:
            print(f'  0x{off:08x}  {label:40s}  write mov x0,#{args.level_entry_value}; ret')
            wr_u32(b, off, enc); wr_u32(b, off + 4, RET)
        else:
            raise SystemExit(f'error: 0x{off:08x} is {w1:08x} — not stock '
                             f'{stock:08x} and not a known movz; re-dump.')

    if args.level_override:
        off = LEVEL_EPILOGUE_OFF
        enc = mov_x0_imm16(args.level_value)
        w = rd_u32(b, off)
        if w == enc:
            print(f'  0x{off:08x}  LEVEL epilogue override (safe)       '
                  f'   already patched')
        elif w == MOV_X0_X21 or (w & 0x7f80001f) == 0xd2800000:
            print(f'  0x{off:08x}  LEVEL epilogue override (safe)       '
                  f'   write mov x0,#{args.level_value} (was {w:08x})')
            wr_u32(b, off, enc)
        else:
            raise SystemExit(f'error: 0x{off:08x} is {w:08x}, expected '
                             f'{MOV_X0_X21:08x} (mov x0, x21) or a movz; '
                             'the function may have shifted — re-dump.')

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
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('input', help='input IPA')
    p.add_argument('output', help='output IPA')
    p.add_argument('--fifth-gate', dest='fifth_gate', action='store_true',
                   default=True, help='apply fifth gate entry patch (default on)')
    p.add_argument('--no-fifth-gate', dest='fifth_gate', action='store_false',
                   help='skip fifth gate patch')
    p.add_argument('--level-override', dest='level_override', action='store_true',
                   default=True,
                   help='apply SAFE LEVEL return-value override at 0xbdbc8 (default on)')
    p.add_argument('--no-level-override', dest='level_override', action='store_false',
                   help='skip LEVEL epilogue override')
    p.add_argument('--level-value', type=int, default=0xFF,
                   help='value for mov x0,#imm at the epilogue (default 255)')
    p.add_argument('--level-getter-entry', action='store_true',
                   default=False,
                   help='reproduce shipped-v2/v3 BAD entry-point patch (crashes)')
    p.add_argument('--level-entry-value', type=int, default=0xFF,
                   help='value for the entry-point patch (v2=255, v3=4)')
    args = p.parse_args()
    ipa_in, ipa_out = args.input, args.output

    if args.level_getter_entry and args.level_override:
        print('note: both entry and epilogue LEVEL patches enabled; the entry '
              'one takes effect first since the function returns early.')

    with zipfile.ZipFile(ipa_in) as zin:
        try:
            dyb_in = zin.read(DYLIB_PATH)
        except KeyError:
            sys.exit(f'error: {DYLIB_PATH!r} not in {ipa_in}')
        print(f'input   sha256={hashlib.sha256(dyb_in).hexdigest()}  '
              f'size={len(dyb_in)}')

        dyb_out = patch_dylib(dyb_in, args)
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
