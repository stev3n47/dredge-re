"""Duplicate an IPA: new bundle IDs + display name so it installs alongside
the original with its own login/data container.

Rewrites CFBundleIdentifier in the app + every .appex Info.plist by
suffixing the last component, and sets CFBundleDisplayName. No binary
changes — the signer handles entitlements/embedded.provision.

Usage: dupe_ipa.py <input.ipa> <out.ipa> <suffix> <display name>
  e.g. dupe_ipa.py discord.ipa discord2.ipa 2 "Discord 2"
"""
import sys, zipfile, os, plistlib

def main():
    ipa, out, suffix, dname = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    zin = zipfile.ZipFile(ipa)
    names = zin.namelist()

    # app plist + all appex plists carrying a CFBundleIdentifier
    plists = {}
    for n in names:
        if n.endswith('/Info.plist') and ('.app/' in n or '.appex/' in n):
            try:
                p = plistlib.loads(zin.read(n))
                if 'CFBundleIdentifier' in p:
                    plists[n] = p
            except Exception:
                pass
    assert any('.app/Info.plist' in k for k in plists), 'no app plist found'

    # app id gets the suffix; appex ids re-nest under it
    app_plist = next(k for k in plists if '.app/Info.plist' in k and '.appex/' not in k)
    old_app = plists[app_plist]['CFBundleIdentifier']
    new_app = old_app + suffix

    for n, p in plists.items():
        old = p['CFBundleIdentifier']
        if old == old_app:
            p['CFBundleIdentifier'] = new_app
        elif old.startswith(old_app + '.'):
            p['CFBundleIdentifier'] = new_app + old[len(old_app):]
        else:
            p['CFBundleIdentifier'] = old + suffix
        if n == app_plist:
            p['CFBundleDisplayName'] = dname
        print(' ', old, '->', p['CFBundleIdentifier'])

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

    zout = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
    dirs_seen = set()
    def emit_dirs(path):
        parts = path.split('/')
        for i in range(1, len(parts)):
            d = '/'.join(parts[:i]) + '/'
            if d not in dirs_seen:
                dirs_seen.add(d)
                zout.writestr(dir_zinfo(d), b'')

    # Drop every embedded.mobileprovision — the stale sideloaded profile is
    # bound to the original bundle id and will confuse the re-signer.
    # Previously only Discord's path was listed, which broke dupe for any
    # other app.
    def is_embedded_prov(n):
        parts = n.split('/')
        return len(parts) >= 2 and parts[-1] == 'embedded.mobileprovision' and \
               (parts[-2].endswith('.app') or parts[-2].endswith('.appex'))
    for zi in zin.infolist():
        n = zi.filename
        if is_embedded_prov(n):
            continue
        if n.endswith('/'):
            # Dir entry — write it with directory attrs and skip the generic
            # file writer below (which would encode it as an empty regular
            # file with 0o100644 and bloat the zip central directory).
            emit_dirs(n)  # parents
            if n not in dirs_seen:
                dirs_seen.add(n)
                zout.writestr(dir_zinfo(n), b'')
            continue
        emit_dirs(n)
        data = plistlib.dumps(plists[n], fmt=plistlib.FMT_BINARY) if n in plists else zin.read(n)
        exec_bit = 0o100755 if data[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf') else 0o100644
        zi2 = norm(zi, exec_bit)
        zi2.compress_type = zipfile.ZIP_DEFLATED
        zout.writestr(zi2, data)
    zout.close(); zin.close()

    z = zipfile.ZipFile(out)
    assert z.testzip() is None
    print('wrote', out, os.path.getsize(out), 'bytes')

if __name__ == '__main__':
    main()
