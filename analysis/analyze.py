import struct, re, json, collections, os

BINS = os.path.join(os.path.dirname(__file__), "bins")

def read_bin(path):
    with open(path, "rb") as f:
        data = f.read()
    off = 0
    (ver,) = struct.unpack_from(">i", data, off); off += 4
    (count,) = struct.unpack_from(">i", data, off); off += 4
    names = []
    for _ in range(count):
        (slen,) = struct.unpack_from(">H", data, off); off += 2
        name = data[off:off+slen].decode("utf-8", "replace"); off += slen
        off += 8  # id (long)
        (elen,) = struct.unpack_from(">H", data, off); off += 2
        off += elen  # ext
        names.append(name)
    return names

cats = {k: read_bin(os.path.join(BINS, f"{k}.bin")) for k in ("live","vod","series")}
for k,v in cats.items():
    print(f"{k}: {len(v)} names")
print()

# Leading bracketed/prefixed tokens: split on " - " and "|" and ":" up to first 3 segments
def prefix_tokens(name):
    # capture tokens before the "main" title, i.e. short ALLCAPS-ish segments
    parts = re.split(r"\s*[-|]\s*", name)
    toks = []
    for p in parts[:-1]:  # everything before the last segment is likely a tag
        p = p.strip()
        if 0 < len(p) <= 8:
            toks.append(p)
    return toks

def scan(names):
    prefixes = collections.Counter()
    for n in names:
        for t in prefix_tokens(n):
            prefixes[t] += 1
    return prefixes

print("=== TOP PREFIX TOKENS (vod) ===")
for tok,c in scan(cats["vod"]).most_common(40):
    print(f"{c:7d}  {tok!r}")
print()
print("=== TOP PREFIX TOKENS (series) ===")
for tok,c in scan(cats["series"]).most_common(40):
    print(f"{c:7d}  {tok!r}")
print()
print("=== TOP PREFIX TOKENS (live) ===")
for tok,c in scan(cats["live"]).most_common(40):
    print(f"{c:7d}  {tok!r}")
print()

# Quality / decoration markers anywhere in the name
markers = ["4K","UHD","FHD","HD","SD","RAW","HEVC","H265","H264","HDR","DV","DOLBY","3D","IMAX","ᴿᴬᵂ","ᵁᴴᴰ","#####","▶","★","VIP"]
print("=== QUALITY / DECORATION MARKERS (all cats) ===")
allnames = cats["live"]+cats["vod"]+cats["series"]
for m in markers:
    c = sum(1 for n in allnames if m in n)
    if c: print(f"{c:7d}  {m!r}")
print()

# Year pattern
years = collections.Counter(re.findall(r"\((19|20)\d{2}\)", " ".join(cats["vod"][:100000])))
print("vod names with a (YYYY) year:", sum(1 for n in cats["vod"] if re.search(r"\((19|20)\d{2}\)", n)))
print("series names with a (YYYY) year:", sum(1 for n in cats["series"] if re.search(r"\((19|20)\d{2}\)", n)))
print()

# Sample raw names to eyeball
print("=== SAMPLE VOD NAMES ===")
for n in cats["vod"][:15]: print("  ", n)
print("=== SAMPLE SERIES NAMES ===")
for n in cats["series"][:15]: print("  ", n)
print("=== SAMPLE LIVE NAMES ===")
for n in cats["live"][:15]: print("  ", n)
