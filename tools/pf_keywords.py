import json, re, sys

src = sys.argv[1] if len(sys.argv) > 1 else r'C:\Users\steve\AppData\Local\Temp\devin.exe-overflows\e89c733f\content.txt'
t = open(src, encoding='utf-8', errors='replace').read()
names = re.findall(r'"name":"((?:[^"\\]|\\.)*)","namespace":"((?:[^"\\]|\\.)*)","method_start":(-?\d+),"method_count":(\d+)', t)
print(len(names), 'types parsed')

with open('next-game/polyfootball/catalog-types.txt', 'w', encoding='utf-8') as out:
    for n, ns, ms, mc in names:
        out.write(f'{ns}.{n}\t{ms}\t{mc}\n')

kw = ['injur','fumble','tackle','speed','magnet','throw','pass','arm','ticket','money','cash','skill','point','unlock','premium','vip','agent','save','slot','star','gold','coin','purchas','store','shop','iap','ball','player','team','career','season','drive','coach','train','boost','multi','contract','fan','morale','stamina','health','attribute','stat','level','rank','badge','pack','draft','scout','owner','gm','franchise']
hits = {k: [] for k in kw}
for n, ns, ms, mc in names:
    ln = (ns + '.' + n).lower()
    for k in kw:
        if k in ln:
            hits[k].append((ns + '.' + n, int(mc)))
for k in kw:
    if hits[k]:
        print(f'== {k}: {len(hits[k])}')
        for x in hits[k][:40]:
            print('   ', x)
