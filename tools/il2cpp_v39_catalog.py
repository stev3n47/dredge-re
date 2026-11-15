#!/usr/bin/env python3
"""Version-agnostic il2cpp global-metadata.dat cataloger.

Does not rely on exact struct layouts for the target metadata version:
detects record strides by scoring candidate columns (nameIndex must decode
to identifier-ish strings; index columns must be non-decreasing and bounded).

Usage:
  il2cpp_v39_catalog.py <global-metadata.dat> <out-dir>
Writes:
  images.txt     image index \t image-name (from string heap via nameIndex)
  types.txt      image \t typeIdx \t ns \t name \t methodStart \t methodCount
  methods.txt    typeIdx \t methodIdx \t name \t flags \t params
"""
import struct, sys, os, re

def u32(b, o): return struct.unpack_from('<I', b, o)[0]
def u16(b, o): return struct.unpack_from('<H', b, o)[0]
def i32(b, o): return struct.unpack_from('<i', b, o)[0]

def load(dat):
    d = open(dat, 'rb').read()
    assert u32(d, 0) == 0xFAB11BAF, 'bad magic'
    ver = u32(d, 4)
    # v24+ header: sanity, version, then 31 (offset,size) pairs.
    secs = []
    for i in range(31):
        secs.append((u32(d, 8 + i * 8), u32(d, 12 + i * 8)))
    names = [
        'stringLiteral', 'stringLiteralData', 'string', 'events', 'properties',
        'methods', 'parameterDefaultValues', 'fieldDefaultValues',
        'fieldAndParameterDefaultValueData', 'fieldMarshaledSizes',
        'parameters', 'fields', 'genericParameters', 'genericParameterConstraints',
        'genericContainers', 'nestedTypes', 'interfaces', 'vtableMethods',
        'interfaceOffsets', 'typeDefinitions', 'images', 'assemblies',
        'metadataUsageLists', 'metadataUsagePairs', 'fieldRefs',
        'referencedAssemblies', 'attributeData', 'attributeDataRange',
        'unresolvedVirtualCallParameterTypes', 'unresolvedVirtualCallParameterRanges',
        'windowsRuntimeTypeNames',
    ]
    return d, ver, dict(zip(names, secs))

def cstr(d, blob_off, idx):
    o = blob_off + idx
    e = d.find(b'\x00', o)
    if e < 0 or e - o > 200: return None
    try: return d[o:e].decode('utf-8')
    except UnicodeDecodeError: return None

def valid_name(s):
    return s is not None and re.match(r'^[A-Za-z_][A-Za-z0-9_<>`\.\[\]\, \+\-\*/=()&:]*$', s) is not None

def detect_stride(d, sec, rows, name_col, str_off, str_size):
    """Find record stride so that column name_col is a valid string index."""
    so, ss = sec
    for stride in range(24, 200, 4):
        if ss % stride: continue
        n = ss // stride
        if n != rows and rows > 0: continue
        ok = 0
        probe = min(n, 400)
        for r in range(probe):
            idx = i32(d, so + r * stride + name_col * 4)
            if 0 <= idx < str_size and valid_name(cstr(d, str_off, idx)):
                ok += 1
        if ok >= probe * 0.9:
            return stride
    return None

def find_monotonic_col(d, sec, stride, n, bound):
    so, ss = sec
    best = None
    for col in range(0, stride // 4):
        vals = [i32(d, so + r * stride + col * 4) for r in range(n)]
        if all(0 <= vals[i] <= vals[i + 1] for i in range(n - 1)) and vals[-1] <= bound:
            best = col
    return best

def main():
    dat, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    d, ver, sec = load(dat)
    str_off, str_size = sec['string']
    meth_off, meth_size = sec['methods']
    td_off, td_size = sec['typeDefinitions']
    img_off, img_size = sec['images']

    # ---- images: Il2CppImageDefinition {nameIndex i32, assemblyIndex i32, ...}
    # stride detect: nameIndex @ col0.
    img_stride = detect_stride(d, sec['images'], 0, 0, str_off, str_size)
    if img_stride is None:
        for s in (24, 32, 40, 48, 56, 64, 72, 80, 88, 96):
            if img_size % s == 0:
                img_stride = s; break
    n_img = img_size // img_stride
    images = []
    for r in range(n_img):
        images.append(cstr(d, str_off, i32(d, img_off + r * img_stride)) or f'img{r}')
    # typeStart column: monotonic, bounded by typedef count — find via heuristic later.
    # Assembly-CSharp image: first non-system image containing our known class names.

    # ---- typeDefinitions: nameIndex@0, namespaceIndex@4 are fixed for all v24+.
    n_td_guess = td_size // 88
    td_stride = None
    for s in range(80, 160, 4):
        if td_size % s: continue
        n = td_size // s
        ok = 0; probe = min(n, 400)
        for r in range(probe):
            idx = i32(d, td_off + r * s)
            if 0 <= idx < str_size and valid_name(cstr(d, str_off, idx)):
                ok += 1
        if ok >= probe * 0.9:
            td_stride = s; break
    assert td_stride, 'typedef stride not found'
    n_td = td_size // td_stride

    # methods section: Il2CppMethodDefinition — nameIndex@0 for all versions.
    meth_stride = None
    for s in range(20, 60, 4):
        if meth_size % s: continue
        n = meth_size // s
        ok = 0; probe = min(n, 400)
        for r in range(probe):
            idx = i32(d, meth_off + r * s)
            if 0 <= idx < str_size and valid_name(cstr(d, str_off, idx)):
                ok += 1
        if ok >= probe * 0.9:
            meth_stride = s; break
    assert meth_stride, 'method stride not found'
    n_meth = meth_size // meth_stride

    # methodStart: non-decreasing i32 column in typedef bounded by n_meth.
    ms_col = find_monotonic_col(d, sec['typeDefinitions'], td_stride, min(n_td, 3000), n_meth)
    assert ms_col is not None, 'methodStart column not found'
    # method_count: u16 that sums correctly — located after the i32 block;
    # scan u16 columns in typedef tail for values consistent with deltas of methodStart.
    # simpler: methodCount[i] = methodStart[i+1] - methodStart[i] (last = n_meth - start)
    typedefs = []
    for r in range(n_td):
        base = td_off + r * td_stride
        name = cstr(d, str_off, i32(d, base)) or f't{r}'
        ns = cstr(d, str_off, i32(d, base + 4)) or ''
        ms = i32(d, base + ms_col * 4)
        typedefs.append((name, ns, ms))
    # typeStart per image: find i32 col in image defs monotonic & bounded by n_td.
    ts_col = find_monotonic_col(d, sec['images'], img_stride, n_img, n_td)
    img_ranges = []
    if ts_col is not None:
        starts = [i32(d, img_off + r * img_stride + ts_col * 4) for r in range(n_img)]
        for r in range(n_img):
            end = starts[r + 1] if r + 1 < n_img else n_td
            img_ranges.append((starts[r], end))
    else:
        img_ranges = [(0, n_td)]

    def img_of(tidx):
        for i, (a, b) in enumerate(img_ranges):
            if a <= tidx < b: return i
        return -1

    tw = open(os.path.join(outdir, 'types.txt'), 'w', encoding='utf-8')
    mw = open(os.path.join(outdir, 'methods.txt'), 'w', encoding='utf-8')
    iw = open(os.path.join(outdir, 'images.txt'), 'w', encoding='utf-8')
    for i, (a, b) in enumerate(img_ranges):
        iw.write(f'{i}\t{images[i]}\ttypes {a}..{b-1}\n')
    for r, (name, ns, ms) in enumerate(typedefs):
        mend = typedefs[r + 1][2] if r + 1 < n_td else n_meth
        mc = max(0, mend - ms)
        tw.write(f'{img_of(r)}\t{r}\t{ns}\t{name}\t{ms}\t{mc}\n')
        for m in range(ms, min(mend, ms + mc)):
            mb = meth_off + m * meth_stride
            mname = cstr(d, str_off, i32(d, mb)) or f'm{m}'
            flags = u16(d, mb + meth_stride - 12)  # flags near tail; heuristic
            params = u16(d, mb + meth_stride - 2)
            mw.write(f'{r}\t{m}\t{mname}\tfl={flags:#x}\tpc={params}\n')
    tw.close(); mw.close(); iw.close()
    print(f'metadata v{ver}: {n_img} images, {n_td} types, {n_meth} methods (td={td_stride}B meth={meth_stride}B img={img_stride}B)')

if __name__ == '__main__':
    main()
