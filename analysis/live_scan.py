import struct, re, os, collections

BINS = os.path.join(os.path.dirname(__file__), "bins")

def read_bin(path):
    d=open(path,"rb").read(); o=8
    n=struct.unpack_from(">i",d,4)[0]; names=[]
    for _ in range(n):
        sl=struct.unpack_from(">H",d,o)[0]; o+=2
        nm=d[o:o+sl].decode("utf-8","replace"); o+=sl; o+=8
        el=struct.unpack_from(">H",d,o)[0]; o+=2; o+=el
        names.append(nm)
    return names

live = read_bin(os.path.join(BINS,"live.bin"))
print("live channels:", len(live))

# Leading token before ':' — often a country/language/quality code.
lead = collections.Counter()
for n in live:
    m = re.match(r"\s*([A-Z0-9+\-#\.\s]{1,8}?)\s*[:\-]", n)
    if m:
        tok = m.group(1).strip()
        if tok: lead[tok] += 1
print("\n=== TOP LEADING CODES (before : or -) ===")
for t,c in lead.most_common(60):
    print(f"{c:6d}  {t!r}")

# Category keywords anywhere in the name.
cats = ["SPORT","SPORTS","NEWS","MOVIE","MOVIES","CINEMA","KIDS","CARTOON","MUSIC",
        "DOCU","DOC","HISTORY","NATURE","COMEDY","SERIES","ENTERTAIN","RELIGION",
        "ISLAM","QURAN","FOOTBALL","SOCCER","CRICKET","NBA","NFL","UFC","F1",
        "RADIO","WEATHER","24/7","PPV","EVENT","LOCAL","HD","FHD","4K"]
print("\n=== CATEGORY KEYWORD COUNTS ===")
for kw in cats:
    c = sum(1 for n in live if kw in n.upper())
    if c: print(f"{c:6d}  {kw}")

# How many start with a 2-3 letter country-ish code + separator
print("\n=== SAMPLE LIVE NAMES (spread across catalog) ===")
step = max(1, len(live)//40)
for i in range(0, len(live), step):
    print("  ", live[i])
