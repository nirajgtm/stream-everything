from PIL import Image, ImageDraw, ImageFont
import urllib.request, os, io

OUT = os.path.join(os.path.dirname(__file__), "brand")
os.makedirs(OUT, exist_ok=True)
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
BASE = "https://image.tmdb.org/t/p/w200"

# 9 services for a clean 3x3 grid (logo_path from TMDB).
LOGOS = [
    "/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg",  # Netflix
    "/97yvRBw1GzX7fXprcF80er19ot.jpg",   # Disney+
    "/pvske1MyAoymrs5bguRfVqYiM9a.jpg",  # Prime
    "/jbe4gVSfRlbPTdESXhEKpornsfu.jpg",  # Max
    "/bxBlRPEPpMVDc4jMhSrTf2339DW.jpg",  # Hulu
    "/mcbz1LgtErU9p4UdbZ0rG6RTWHX.jpg",  # Apple TV
    "/fts6X10Jn4QT0X6ac3udKEn2tJA.jpg",  # Paramount+
    "/2aGrp1xw3qhwCYvNGAJZPdjfeeX.jpg",  # Peacock
    "/fzN5Jok5Ig1eJ7gyNGoMhnLSCfh.jpg",  # Crunchyroll
]

def fetch(path):
    with urllib.request.urlopen(BASE + path, timeout=20) as r:
        return Image.open(io.BytesIO(r.read())).convert("RGB")

def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0], img.size[1]], radius=radius, fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out

def grid(cell, gap, pad, bg):
    logos = [fetch(p) for p in LOGOS]
    side = pad * 2 + cell * 3 + gap * 2
    canvas = Image.new("RGBA", (side, side), bg)
    for i, logo in enumerate(logos):
        row, col = divmod(i, 3)
        sq = logo.resize((cell, cell))
        x = pad + col * (cell + gap)
        y = pad + row * (cell + gap)
        canvas.paste(rounded(sq, int(cell * 0.22)), (x, y), rounded(sq, int(cell * 0.22)))
    return canvas

# App icon: 3x3 grid filling the frame on a dark ground.
icon = grid(cell=150, gap=14, pad=20, bg=(15, 18, 24, 255))
icon.convert("RGB").save(os.path.join(OUT, "ic_launcher.png"))

# Banner 320x180: grid on the left, title on the right.
banner = Image.new("RGB", (320, 180), (15, 18, 24))
g = grid(cell=48, gap=6, pad=0, bg=(15, 18, 24, 255)).convert("RGB")
banner.paste(g, (12, (180 - g.size[1]) // 2))
bd = ImageDraw.Draw(banner)
bd.text((186, 60), "Stream", font=ImageFont.truetype(BOLD, 32), fill=(255, 255, 255))
bd.text((186, 98), "Everything", font=ImageFont.truetype(BOLD, 24), fill=(128, 203, 196))
banner.save(os.path.join(OUT, "tv_banner.png"))
print("wrote ic_launcher.png + tv_banner.png")
