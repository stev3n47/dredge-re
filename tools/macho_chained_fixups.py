#!/usr/bin/env python3
"""Decode LC_DYLD_CHAINED_FIXUPS rebase entries in an arm64e Mach-O.

Returns a dict  file_offset -> pointer_value (VMA, preferred base = 0 for
these UnityFramework builds where vma == file offset).

Chained-fixup format reference (dyld source):
  dyld_chained_ptr_64_rebase        target:36 high8:8 reserved:7 next:12 bind:1
  dyld_chained_ptr_64_bind          ordinal:16 addend:16 reserved:19 next:12 bind:1
  dyld_chained_ptr_arm64e_rebase    target:43 high8:8 next:11 bind:1 auth:1
  dyld_chained_ptr_arm64e_bind      ordinal:16 zero:4 multi:4 addrDiv:1 diversity:16 next:12 bind:1 auth:1
  dyld_chained_ptr_arm64e_auth_rebase  target:32 diversity:16 addrDiv:1 key:2 next:11 bind:1 auth:1
  dyld_chained_ptr_arm64e_auth_bind    ordinal:16 zero:16 addrDiv:1 diversity:16 key:2 next:11 bind:1 auth:1

`next` is the distance to the next fixup in units of 4 bytes for the
arm64e formats and units of 8 bytes... it actually varies: the chain
stride is recorded per segment. We honour the page-start entries in
dyld_chained_starts_in_segment which give each chain head; `next`
steps are then taken literally (entry-stride units as used by dyld:
for arm64e the stride is 4 bytes).

Usage as a library:
    from macho_chained_fixups import decode_rebases
    rebases = decode_rebases(path)   # {file_off: ptr_vma}
"""
import struct
import sys

LC_DYLD_CHAINED_FIXUPS = 0x80000034
LC_DYLD_EXPORTS_TRIE = 0x80000033

# dyld_chained_pointer_format values
DYLD_CHAINED_PTR_ARM64E = 1
DYLD_CHAINED_PTR_64 = 2
DYLD_CHAINED_PTR_ARM64E_KERNEL = 3
DYLD_CHAINED_PTR_ARM64E_USERLAND = 4
DYLD_CHAINED_PTR_ARM64E_FIRMWARE = 5
DYLD_CHAINED_PTR_ARM64E_USERLAND24 = 13


def decode_rebases(path, verbose=False):
    with open(path, 'rb') as f:
        b = f.read()
    magic, = struct.unpack('<I', b[:4])
    assert magic == 0xFEEDFACF, 'not arm64 mach-o'
    ncmds, = struct.unpack('<I', b[16:20])
    off = 32
    segs = []          # (vmaddr, fileoff, vmsize)
    chain_lc = None
    for _ in range(ncmds):
        cmd, cs = struct.unpack('<II', b[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            vmaddr, vmsize, foff = struct.unpack('<QQQ', b[off + 24:off + 48])
            segs.append((vmaddr, foff, vmsize))
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            dataoff, datasize = struct.unpack('<II', b[off + 8:off + 16])
            chain_lc = (dataoff, datasize)
        off += cs
    if chain_lc is None:
        return {}, segs
    dataoff, _ = chain_lc

    # dyld_chained_fixups_header:
    #   u32 fixups_version; u32 starts_offset; u32 imports_offset;
    #   u32 symbols_offset; u32 imports_count; u32 imports_format; u32 symbols_format
    starts_offset, = struct.unpack('<I', b[dataoff + 4:dataoff + 8])
    dataoff += starts_offset

    # dyld_chained_starts_in_image:
    #   uint32 seg_count; uint32 seg_info_offset[seg_count];
    seg_count, = struct.unpack('<I', b[dataoff:dataoff + 4])
    info_off = []
    for i in range(seg_count):
        o, = struct.unpack('<I', b[dataoff + 4 + i * 4:dataoff + 8 + i * 4])
        info_off.append(o)

    rebases = {}
    binds = {}

    def seg_index_for(fo):
        for vm, fo0, vs in segs:
            if fo0 <= fo < fo0 + vs:
                return fo - fo0  # offset within segment
        return None

    for i, ioff in enumerate(info_off):
        if ioff == 0:
            continue
        base = dataoff + ioff
        (size, page_size, ptr_fmt, seg_off, max_valid,
         page_count) = struct.unpack('<IHHQIH', b[base:base + 22])
        seg_vmaddr, seg_fileoff, seg_vmsize = segs[i]
        page_starts = []
        for p in range(page_count):
            ps, = struct.unpack('<H', b[base + 22 + p * 2:base + 24 + p * 2])
            page_starts.append(ps)

        for p, ps in enumerate(page_starts):
            if ps == 0xFFFF:
                continue
            stride = 8 if ptr_fmt in (DYLD_CHAINED_PTR_ARM64E,
                                      DYLD_CHAINED_PTR_64) else 4
            # arm64e formats actually stride 4 OR 8 depending on sub-format;
            # dyld walks `next` * 4 bytes for arm64e and * 8 for ptr64.
            next_mul = 4 if ptr_fmt in (DYLD_CHAINED_PTR_ARM64E,
                                        DYLD_CHAINED_PTR_ARM64E_USERLAND,
                                        DYLD_CHAINED_PTR_ARM64E_USERLAND24) else 8
            in_seg_off = p * page_size + ps
            fpos = seg_fileoff + in_seg_off
            steps = 0
            while True:
                v, = struct.unpack('<Q', b[fpos:fpos + 8])
                if ptr_fmt == DYLD_CHAINED_PTR_64:
                    bind_bit = v & 1
                    nxt = (v >> 51) & 0xFFF
                    if bind_bit:
                        binds[fpos] = v
                    else:
                        target = (v & 0xFFFFFFFFF) | ((v >> 36) & 0xFF) << 36 \
                            if False else (v & ((1 << 36) - 1)) | (((v >> 44) & 0xFF) << 36)
                        rebases[fpos] = target
                    step = nxt * 8
                else:
                    # arm64e layouts
                    auth = (v >> 63) & 1
                    bind_bit = (v >> 62) & 1
                    if auth:
                        if bind_bit:
                            binds[fpos] = v
                        else:
                            target = v & 0xFFFFFFFF
                            rebases[fpos] = target
                        nxt = (v >> 51) & 0x7FF
                    else:
                        if bind_bit:
                            binds[fpos] = v
                        else:
                            target = v & ((1 << 43) - 1)
                            high8 = (v >> 43) & 0xFF
                            rebases[fpos] = target | (high8 << 43)
                        nxt = (v >> 51) & 0x7FF
                    step = nxt * next_mul
                if step == 0:
                    break
                fpos += step
                steps += 1
                if steps > 100000 or fpos >= seg_fileoff + seg_vmsize:
                    break
    if verbose:
        sys.stderr.write(f'rebases={len(rebases)} binds={len(binds)}\n')
    return rebases, segs


if __name__ == '__main__':
    r, s = decode_rebases(sys.argv[1], verbose=True)
    vals = sorted(r.items())
    for fo, p in vals[:40]:
        print(f'{fo:#x} -> {p:#x}')
