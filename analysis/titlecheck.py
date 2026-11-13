import struct, re, os
BINS = os.path.join(os.path.dirname(__file__), "bins")
def read_bin(path):
    d=open(path,"rb").read(); o=8; names=[]
    n=struct.unpack_from(">i",d,4)[0]
    for _ in range(n):
        sl=struct.unpack_from(">H",d,o)[0]; o+=2
        nm=d[o:o+sl].decode("utf-8","replace"); o+=sl; o+=8
        el=struct.unpack_from(">H",d,o)[0]; o+=2; o+=el
        names.append(nm)
    return names
for k in ("vod","series","live"):
    ns=read_bin(os.path.join(BINS,f"{k}.bin"))
    print(f"--- {k} samples ---")
    for nm in ns[:8]: print("  ", nm)
