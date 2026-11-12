import json, re, glob, os, sys

# extract {"name":..,"declaring_type":..,"index":..} method items from REA view dumps
files = [
    r'C:\Users\steve\AppData\Local\Temp\devin.exe-overflows\1df7d944\content.txt',   # injury cluster
    r'C:\Users\steve\AppData\Local\Temp\devin.exe-overflows\a73b9659\content.txt',   # ThrowController + TicketWallet
]
out = open('next-game/polyfootball/catalog-methods-targets.txt', 'w', encoding='utf-8')
seen = set()
for f in files:
    t = open(f, encoding='utf-8', errors='replace').read()
    for m in re.finditer(r'\{"name":"((?:[^"\\]|\\.)*)","declaring_type":(\d+),"index":(\d+)\}', t):
        name, dt, idx = m.group(1), m.group(2), m.group(3)
        if idx in seen:
            continue
        seen.add(idx)
        out.write(f'{idx}\ttype{dt}\t{name}\n')
out.close()
print(len(seen), 'methods written')
