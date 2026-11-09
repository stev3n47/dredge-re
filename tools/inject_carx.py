"""Inject LC_LOAD_DYLIB for CXMenu.framework into CarXDriftRacing3 and repackage.

- Removes the iOSGods load commands entirely (libcarx in UnityFramework,
  iGameGod in the exe) and drops their files from the bundle. Weakening to
  LC_LOAD_WEAK_DYLIB was NOT sufficient: a weak load of a missing file
  leaves a defunct image in the dependency graph, and dyld's
  runInitializersBottomUpPlusUpwardLinks (hit when the exe dlopens
  UnityFramework via CFBundle) walked it as an upward link and called a
  null initializer — pc=0, CODESIGNING Invalid Page. Both commands are the
  last dylib LC in their binary (ordinal 23/23 and 77/77), so excision
  renumbers nothing.
- Adds LC_LOAD_DYLIB '@executable_path/Frameworks/CXMenu.framework/CXMenu'
- Bakes the resource-seam patch into UnityFramework (see stub notes below)
- Repackages the IPA preserving exec bits and zip layout

Usage: inject_carx.py <input.ipa> <CXMenu dylib> <out.ipa> [stub dylib]

With a stub dylib argument, the iOSGods load commands are left untouched
and the stub is written to their file paths instead — the dep graph then
contains real loadable images (zero-init stubs) rather than defunct
weak-missing entries. Without it, the LCs are excised (v3 behavior).
"""
import sys, struct, zipfile, os, plistlib

LC_LOAD_DYLIB      = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_CODE_SIGNATURE  = 0x1D
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

def remove_load(b: bytearray, needle: bytes) -> int:
    """Excise LC_LOAD_*_DYLIB commands whose path contains needle: slide the
    remaining load commands down over them and shrink ncmds/sizeofcmds.
    Only safe when the removed dylib is the last dylib LC in the binary —
    removing an earlier one renumbers every later dylib ordinal and breaks
    existing binds."""
    ncmds = struct.unpack('<I', b[16:20])[0]
    sizeofcmds = struct.unpack('<I', b[20:24])[0]
    lc_end = 32 + sizeofcmds
    off = 32; hits = 0; i = 0
    while i < ncmds:
        cmd, size = struct.unpack('<II', b[off:off+8])
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB):
            noff = struct.unpack('<I', b[off+8:off+12])[0]
            name = bytes(b[off+noff:off+size]).split(b'\x00')[0]
            if needle in name:
                b[off:lc_end-size] = b[off+size:lc_end]
                b[lc_end-size:lc_end] = b'\x00' * size
                sizeofcmds -= size
                ncmds -= 1
                lc_end -= size
                hits += 1
                continue
        off += size
        i += 1
    struct.pack_into('<I', b, 16, ncmds)
    struct.pack_into('<I', b, 20, sizeofcmds)
    return hits

def main():
    ipa, dylib, out = sys.argv[1], sys.argv[2], sys.argv[3]
    app       = 'Payload/CarXDriftRacing3.app'
    exe_path  = f'{app}/CarXDriftRacing3'
    uf_path   = f'{app}/Frameworks/UnityFramework.framework/UnityFramework'
    fw_path   = f'{app}/Frameworks/CXMenu.framework/CXMenu'
    fw_plist  = f'{app}/Frameworks/CXMenu.framework/Info.plist'
    info_path = f'{app}/Info.plist'

    zin = zipfile.ZipFile(ipa)
    exe = bytearray(zin.read(exe_path))
    dyb = open(dylib, 'rb').read()

    # mode: none=excise both | 'keep'=keep all | path=stub both |
    #       'igg'=stub iGameGod only | 'carx'=stub libcarx only
    mode = sys.argv[4] if len(sys.argv) > 4 else None
    keep_iosgods = mode == 'keep'
    stub_igg = mode == 'igg'
    stub_carx = mode == 'carx'
    # next-game/StubDylib is a CI artifact (built by .github/workflows/
    # build-cxmenu.yml, step 'build StubDylib') — the repo ships only the
    # .c source. Give a clear hint if the compiled binary isn't present.
    def _load_stub(path):
        try:
            return open(path, 'rb').read()
        except FileNotFoundError:
            sys.exit(
                f"error: stub dylib not found at {path!r}\n"
                "  igg/carx/path modes need a built arm64 stub. Either:\n"
                "    - Download the StubDylib artifact from the build-cxmenu CI run, or\n"
                "    - Cross-build locally (see .github/workflows/build-cxmenu.yml), or\n"
                "    - Pass an explicit path as the 4th arg instead of 'igg'/'carx'."
            )
    stub_dyb = _load_stub(os.path.join(os.path.dirname(__file__) or '.', '..', 'next-game', 'StubDylib')) if (stub_igg or stub_carx) else (
        None if keep_iosgods or len(sys.argv) <= 4 else _load_stub(sys.argv[4]))

    if stub_dyb is None and not keep_iosgods and not stub_igg:
        # iOSGods payload removal: excise the loads, drop the files.
        n = remove_load(exe, b'iGameGod');   assert n == 1, f'exe iGameGod LC x{n}'
    if b'CXMenu.framework/CXMenu' not in bytes(exe):
        exe = inject_dylib_cmd(bytes(exe), '@executable_path/Frameworks/CXMenu.framework/CXMenu')

    uf = bytearray(zin.read(uf_path))
    if stub_dyb is None and not keep_iosgods and not stub_carx:
        n = remove_load(uf, b'libcarx');     assert n == 1, f'uf libcarx LC x{n}'
    orig = lambda va: struct.unpack('<I', uf[va:va+4])[0]

    # ---- encoders ---------------------------------------------------------
    def adrp(rd, pc_va, tgt_page):
        imm = (((tgt_page & ~0xFFF) - (pc_va & ~0xFFF)) >> 12) & 0x1FFFFF
        return 0x90000000 | ((imm & 3) << 29) | (((imm >> 2) & 0x7FFFF) << 5) | rd
    def ldrb(rt, rn, off):
        return 0x39400000 | ((off & 0xFFF) << 10) | (rn << 5) | rt
    def ldr_w(rt, rn, off):
        return 0xB9400000 | (((off >> 2) & 0xFFF) << 10) | (rn << 5) | rt
    def stp_x(rt, rt2, imm):
        return 0xA9800000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def ldp_x(rt, rt2, imm):
        return 0xA8C00000 | (((imm >> 3) & 0x7F) << 15) | (rt2 << 10) | (31 << 5) | rt
    def cbz(rt, imm19):
        return 0x34000000 | ((imm19 & 0x7FFFF) << 5) | rt
    def cmp_i(rn, imm12):
        return 0x7100001F | ((imm12 & 0xFFF) << 10) | (rn << 5)
    def bcond(cond, imm19):
        return 0x54000000 | ((imm19 & 0x7FFFF) << 5) | cond
    def b(pc_va, tgt_va):
        return 0x14000000 | (((tgt_va - pc_va) >> 2) & 0x3FFFFFF)
    def madd(rd, rn, rm, ra):
        return 0x1B000000 | (rm << 16) | (ra << 10) | (rn << 5) | rd
    def w32s(*words): return b''.join(struct.pack('<I', w) for w in words)

    # ---- resource seam ----------------------------------------------------
    # Dr3PlayerResourcesUtils.AddResource(dict, name, balance, out*, factor):
    #   new = delta*factor + balance  (madd @SITE, then *out and dict = new)
    # factor +1 on earns, -1 on spends. Both cheats live in ONE stub:
    #   flag+0 Cash Boost: earns (factor>0) use i32 multiplier at flag+4
    #   flag+1 Free Purchases: spends (factor<0) skip the madd — w23 keeps
    #     `balance`, so the store writes the unchanged balance back.
    #
    # Cave/flag safety: zero runs INSIDE live sections are real data —
    # the first cave pick (0x6150690 in __TEXT.__const) crashed dyld's
    # initializer walk (null fn ptr call, CODESIGNING Invalid Page). The
    # only provably dead space is SEGMENT-TAIL page padding: bytes past the
    # last section but inside the mapped segment — never addressed by
    # section machinery, zero branch/pointer xrefs (verified).
    SITE, CAVE, SLOT = 0x283D660, 0x69974D0, 0x7B47000
    SB = CAVE
    stub = w32s(
        stp_x(9, 10, -16),                        # +0x00 save scratch
        adrp(9, SB+4, SLOT),                      # +0x04 flag page
        ldrb(10, 9, SLOT & 0xFFF),                # +0x08 mult flag
        cbz(10, 6),                               # +0x0C -> +0x24 free-check
        cmp_i(22, 0),                             # +0x10 factor sign
        bcond(0xD, 4),                            # +0x14 b.le -> +0x24 (spends unmult)
        ldr_w(10, 9, (SLOT & 0xFFF) + 4),         # +0x18 i32 multiplier
        madd(23, 8, 10, 23),                      # +0x1C new = delta*mult + bal
        b(SB+0x20, SB+0x38),                      # +0x20 exit
        ldrb(10, 9, (SLOT & 0xFFF) + 1),          # +0x24 free-spend flag
        cbz(10, 3),                               # +0x28 -> +0x34 orig
        cmp_i(22, 0),                             # +0x2C
        bcond(0xB, 2),                            # +0x30 b.lt -> +0x38 (spend: skip)
        orig(SITE),                               # +0x34 orig madd
        ldp_x(9, 10, 16),                         # +0x38 restore
        b(SB+0x3C, SITE + 4),                     # +0x3C return
    )
    assert len(stub) <= (0x6998000 - CAVE)
    if orig(SITE) == b(SITE, CAVE):
        print(f'AddResource seam already patched @0x{SITE:x}')
    else:
        assert orig(SITE) == madd(23, 8, 22, 23), f'site word {orig(SITE):08x}'
        assert uf[CAVE:CAVE+len(stub)] == b'\x00' * len(stub), 'cave not empty'
        uf[CAVE:CAVE+len(stub)] = stub
        struct.pack_into('<I', uf, SITE, b(SITE, CAVE))
        print(f'patched AddResource madd @0x{SITE:x} -> stub @0x{CAVE:x} ({len(stub)}B)')

    # iOS 26.2 crash (seen on-device): the per-frame [GCController controllers]
    # poll dies inside SAObjects on a corrupted pointer — unrelated to the
    # auth work, kills the game mid-load after the wall is dismissed. The
    # poll fn at 0xfea0 is tiny (guard global, else call controllers). Its
    # caller uses the return value (the controllers array), so a bare ret
    # leaves x0 = caller's arg -> doesNotRecognizeSelector abort. Patch the
    # entry to `mov x0, xzr; ret` — caller sees nil, [nil x] is a no-op.
    GCFN = 0xFEA0
    w = orig(GCFN)
    if w != 0xAA1F03E0:
        assert w in (0xF003B848, 0xD65F03C0), f'gc poll entry {w:08x}'
        struct.pack_into('<II', uf, GCFN, 0xAA1F03E0, 0xD65F03C0)
        print(f'GCController poll @0x{GCFN:x} -> return nil')

    # ---- gated bool predicates --------------------------------------------
    # Same seam model as AddResource: entry gets `b cave`; the cave checks
    # a flag byte in SLOT — flag on -> `mov w0,#v; ret`; flag off -> replay
    # the displaced first instruction + jump back (untouched behavior).
    next_cave = CAVE + len(stub)
    def gate(site, flag_off, ret_val, label):
        nonlocal next_cave
        cv = next_cave
        gs = w32s(
            adrp(9, cv, SLOT),
            ldrb(9, 9, (SLOT & 0xFFF) + flag_off),
            cbz(9, 3),                      # flag off -> orig path @+0x14
            0x52800020 if ret_val else 0x52800000,  # mov w0,#1 / mov w0,#0
            0xD65F03C0,                     # ret
            orig(site),                     # replay displaced instr
            b(cv + 0x18, site + 4),         # back into the function
        )
        assert len(gs) == 0x1C
        assert cv + len(gs) <= 0x6998000, 'text pad exhausted'
        if orig(site) == b(site, cv):
            print(f'{label} gate already patched @0x{site:x}')
        else:
            assert uf[cv:cv+len(gs)] == b'\x00' * len(gs), 'cave not empty'
            uf[cv:cv+len(gs)] = gs
            struct.pack_into('<I', uf, site, b(site, cv))
            print(f'{label} gate @0x{site:x} -> flag+{flag_off}')
        next_cave = cv + 0x20

    gate(0x28F314C, 2, 1, 'all-tracks')      # BattlePassUtils.IsUnlockedTrack
    gate(0x28D2980, 3, 1, 'all-vinyls')      # PlayerVinylsModel.IsUnlocked
    gate(0x4D19BC0, 4, 0, 'no-interstitial') # AdsUtils.IsAvailableShowInterstitial

    # Instant stand operations — flag 5. GetOperationsAndTimeFor* return
    # ValueTuple<float time, operations> built through a shared ctor; each
    # site either fmuls the final time or stores it into the tuple local.
    # Flag on -> `fmov sN, wzr` before the instruction -> time = 0 while the
    # operations list stays intact. SwapNode delegates into the shared
    # worker at 0x2841c48/0x28429a4 so its path is covered by sites 1-2.
    def gate_zero(site, sreg, flag_off, label):
        nonlocal next_cave
        cv = next_cave
        gs = w32s(
            adrp(9, cv, SLOT),
            ldrb(9, 9, (SLOT & 0xFFF) + flag_off),
            cbz(9, 2),                      # flag off -> orig @+0x10
            0x1E2703E0 | sreg,              # fmov sN, wzr
            orig(site),                     # replay displaced instr
            b(cv + 0x14, site + 4),         # back into the function
        )
        assert len(gs) == 0x18
        assert cv + len(gs) <= 0x6998000, 'text pad exhausted'
        if orig(site) == b(site, cv):
            print(f'{label} gate already patched @0x{site:x}')
        else:
            assert uf[cv:cv+len(gs)] == b'\x00' * len(gs), 'cave not empty'
            uf[cv:cv+len(gs)] = gs
            struct.pack_into('<I', uf, site, b(site, cv))
            print(f'{label} gate @0x{site:x} -> flag+{flag_off}')
        next_cave = cv + 0x20

    gate_zero(0x2842144, 0, 5, 'instant-parts')  # SwapParts/SwapNode fmul tail
    gate_zero(0x2842E04, 0, 5, 'instant-repair') # Repair fmul tail
    gate_zero(0x28472D0, 0, 5, 'instant-fromcar')# FromCar str s0 -> tuple local
    gate_zero(0x28473A8, 0, 5, 'instant-fromnode')
    gate_zero(0x28434CC, 8, 5, 'instant-paint')  # Paint str s8 -> tuple local

    # Free Purchases completeness (same flag+1 as the AddResource skip):
    # 1) the UI afford-check HasResource -> "not enough funds" blocks the
    #    purchase before any debit; force true so the spend path runs.
    gate(0x283D8F8, 1, 1, 'afford-check')
    # 2) ChangeResource debits via `add w8,w8,w20; str` per field — bypasses
    #    the madd seam. Flag on && w20<0 (spend) -> write balance back
    #    unchanged; earns (w20>=0) replay the real add.
    def gate_spend(site, flag_off, label):
        nonlocal next_cave
        cv = next_cave
        gs = w32s(
            adrp(9, cv, SLOT),
            ldrb(9, 9, (SLOT & 0xFFF) + flag_off),
            cbz(9, 6),                      # flag off -> orig @+0x20
            cmp_i(20, 0),                   # count sign
            bcond(0xB, 2),                  # spend -> zero-add @+0x18
            b(cv + 0x14, cv + 0x20),        # earn -> orig
            0x0B1F0108,                     # add w8, w8, wzr (keep balance)
            b(cv + 0x1C, site + 4),
            orig(site),
            b(cv + 0x24, site + 4),
        )
        assert len(gs) == 0x28
        assert cv + len(gs) <= 0x6998000, 'text pad exhausted'
        if orig(site) == b(site, cv):
            print(f'{label} gate already patched @0x{site:x}')
        else:
            assert uf[cv:cv+len(gs)] == b'\x00' * len(gs), 'cave not empty'
            uf[cv:cv+len(gs)] = gs
            struct.pack_into('<I', uf, site, b(site, cv))
            print(f'{label} gate @0x{site:x} -> flag+{flag_off}')
        next_cave = cv + 0x28

    gate_spend(0x282E304, 1, 'spend-soft')   # ChangeResource Soft field
    gate_spend(0x282E344, 1, 'spend-hard')   # ChangeResource Hard field
    gate_spend(0x282E384, 1, 'spend-fans')   # ChangeResource Fans field

    # ---- libcarx: deleted-callback trap fix --------------------------------
    # libcarx registers an NSTimer block whose invoke target was stripped by
    # the iOSGods obfuscator into a "deleted method" stub: it loads the
    # 'Fatal error' assertion and hits brk #1 (SIGTRAP) when the timer fires
    # — observed crash: libswiftCore trap via CFRunLoop/GraphicsServices.
    # The block signature is v16@?0@"NSTimer"8 (void return), so turning the
    # stub entry into a bare `ret` is a safe no-op.
    carx_path = f'{app}/Frameworks/libcarx.dylib'
    carx = bytearray(zin.read(carx_path)) if (keep_iosgods or stub_igg) else None
    if carx is not None:
        def patch_word(addr, exp, want_word, label):
            # Idempotent: accept either the expected original or our value.
            w = struct.unpack('<I', carx[addr:addr+4])[0]
            if w == want_word:
                print(f'{label} already patched @0x{addr:x}')
                return
            assert w == exp, f'{label} word {w:08x} != {exp:08x}'
            struct.pack_into('<I', carx, addr, want_word)
        def gate_b(GATE, END, label):
            # cbz/cbnz -> unconditional b END (idempotent).
            exp_word = 0x14000000 | ((END - GATE) >> 2)
            w = struct.unpack('<I', carx[GATE:GATE+4])[0]
            if w == exp_word:
                print(f'{label} already forced @0x{GATE:x}'); return
            assert (w & 0xFF000000) in (0x34000000, 0xB4000000) and \
                ((w >> 5) & 0x7FFFF) == ((END - GATE) >> 2), f'{label} {w:08x}'
            struct.pack_into('<I', carx, GATE, exp_word)
        DELETED_STUB = 0x47BEC
        patch_word(DELETED_STUB, 0xD10083FF, 0xD65F03C0, 'deleted-stub')
        # Toast presenter: the wall-window construction sits behind a
        # cbnz/cbz gate at 0x1e4e8 (-> 0x1ea9c). The block builds the
        # window + dymFkfP toast VC + windowLevel. Force the branch so the
        # toast is never built. Block is pure UI — 23 msgSends, no state.
        TOAST_GATE, TOAST_END = 0x1E4E8, 0x1EA9C
        gate_b(TOAST_GATE, TOAST_END, 'toast gate')
        # axZEGZ wall window (lvl-1001 SwiftUI login): the window is a
        # swift_once lazy global (0x58a260). Its setup function checks a
        # predicate then calls [window setHidden:NO] at 0x9fe74-0x9ff18.
        # Force the cbz to always skip: window exists (all field access
        # safe) but is never shown. A nil-return ctor would instead crash
        # the reader's direct ivar load — that's why this gates the SHOW.
        WALL_SHOW, WALL_END = 0x9FE74, 0x9FF18
        gate_b(WALL_SHOW, WALL_END, 'wall gate')
        # v12 — the axZEGZ SUBCLASS wall window (v11 still gated on device).
        # Its setup fn has the same os_log-probe shape but INVERTED: `cbz w0`
        # at 0xa2278 branches PAST its epilogue INTO the show block (which
        # ends in [x20 setHidden:NO] @0xa22e4). "Never show" = never branch;
        # nop the cbz so it always falls into the epilogue (early ret).
        SUB_GATE = 0xA2278
        w = struct.unpack('<I', carx[SUB_GATE:SUB_GATE+4])[0]
        if w != 0xD503201F:
            assert (w & 0xFF000000) in (0x34000000, 0xB4000000) and \
                ((w >> 5) & 0x7FFFF) == ((0xA229C - SUB_GATE) >> 2), \
                f'sub gate {w:08x}'
            struct.pack_into('<I', carx, SUB_GATE, 0xD503201F)  # nop
        # Two more wall-family config gates with the axZEGZ shape (cbz skips
        # the ivar-config block) — force the skip unconditionally.
        gate_b(0xA0AC4, 0xA0B38, 'cfg gate a0ac4')
        gate_b(0xA1F8C, 0xA204C, 'cfg gate a1f8c')
        # More obfuscator "deleted method" stubs like 0x47bec — standalone
        # stubs (marker index + 'Fatal error' + assertionFailure + brk) that
        # the auth/decline flow can hit. Entry -> ret (void-safe).
        for STUB in (0x30E234, 0x31D024):
            w = struct.unpack('<I', carx[STUB:STUB+4])[0]
            if w != 0xD65F03C0:
                struct.pack_into('<I', carx, STUB, 0xD65F03C0)
        # iOSGods kill-switch engine (device crash logs): cancelling the
        # ASWebAuth session dispatches a teardown block whose captured fn
        # is the obfuscator's shared table-walker at 0x475ec. It iterates
        # a poisoned class table — msgSend on a WebView class traps in
        # WebKitInitialize off-main (EXC_BREAKPOINT); next a CloudKit
        # object traps under swift_dynamicCast/__forwarding__. The same
        # engine is tail-called by helper 0x4c158's stage-2 and 4 other
        # wrappers — all iOSGods/Jailpatch machinery; game code never
        # calls into it. Return nil: teardown no-ops, callers get the
        # "empty" result. Our cheats (UF seam + CXMenu) are independent.
        ENG = 0x475EC
        w = struct.unpack('<I', carx[ENG:ENG+4])[0]
        if w != 0xAA1F03E0:
            assert w == 0xA9BA6FFC, f'engine entry {w:08x}'
            struct.pack_into('<II', carx, ENG, 0xAA1F03E0, 0xD65F03C0)
            print(f'engine @0x{ENG:x} -> return nil')
        print(f'libcarx: NSTimer stub @0x{DELETED_STUB:x} -> ret; '
              f'toast gate @0x{TOAST_GATE:x} -> b 0x{TOAST_END:x}; '
              f'wall setHidden @0x{WALL_SHOW:x} -> skipped; '
              f'sub gate @0x{SUB_GATE:x} -> nop; cfg gates '
              f'0xa0ac4/0xa1f8c -> skipped; deleted stubs 0x30e234/0x31d024 -> ret')

    # ---- repack -----------------------------------------------------------
    fw_info = plistlib.dumps({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'CXMenu',
        'CFBundleIdentifier': 'com.cheatmenu.cx',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'CXMenu',
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

    keep_igg_files = keep_iosgods or stub_carx   # keep iGameGod unless removing/stubbing it
    keep_carx_file = keep_iosgods or stub_igg    # keep libcarx unless removing/stubbing it
    drop_prefixes = () if keep_igg_files else (
        f'{app}/Frameworks/iGameGod.framework/',
    )
    drop_files = {f'{app}/embedded.mobileprovision'} | (
        set() if keep_carx_file else {f'{app}/Frameworks/libcarx.dylib'})

    def emit(zi, data, exec_bit=None):
        emit_dirs(zi.filename)
        if zi.filename.endswith('/'):   # source dir entries may repeat parents
            if zi.filename in dirs_seen:
                return
            dirs_seen.add(zi.filename)
        data = data if data is not None else zin.read(zi.filename)
        if exec_bit is None:
            exec_bit = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zout.writestr(norm(zi, exec_bit), data)

    for zi in zin.infolist():
        n = zi.filename
        if n in drop_files or n.startswith(drop_prefixes):
            continue
        if n in (exe_path, uf_path, info_path):
            continue
        if n.startswith(f'{app}/Frameworks/CXMenu.framework/'):
            continue
        if n == carx_path and carx is not None:
            continue
        emit(zi, None)
    if carx is not None:
        emit(macho_zinfo(carx_path), bytes(carx))
    emit(macho_zinfo(exe_path), bytes(exe))
    emit(macho_zinfo(uf_path), bytes(uf))
    emit(macho_zinfo(fw_path), dyb)
    emit(file_zinfo(fw_plist), fw_info)
    emit(file_zinfo(info_path), info_bytes)
    if stub_dyb is not None:
        # Neutral stub images at removed paths — real loadable files so the
        # dep graph stays complete. 'igg'/'carx' modes stub only one side.
        both = not (stub_igg or stub_carx)
        if both or stub_carx:
            emit(macho_zinfo(f'{app}/Frameworks/libcarx.dylib'), stub_dyb)
        if both or stub_igg:
            emit(macho_zinfo(f'{app}/Frameworks/iGameGod.framework/iGameGod'), stub_dyb)
            igg_plist = plistlib.dumps({
                'CFBundleExecutable': 'iGameGod',
                'CFBundleIdentifier': 'com.stub.igamegod',
                'CFBundleInfoDictionaryVersion': '6.0',
                'CFBundleName': 'iGameGod',
                'CFBundlePackageType': 'FMWK',
                'CFBundleShortVersionString': '1.0',
                'CFBundleSupportedPlatforms': ['iPhoneOS'],
            }, fmt=plistlib.FMT_BINARY)
            emit(file_zinfo(f'{app}/Frameworks/iGameGod.framework/Info.plist'), igg_plist)
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
