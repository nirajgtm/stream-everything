from PIL import Image, ImageDraw, ImageFont
import os

OUT = os.path.join(os.path.dirname(__file__), "brand")
os.makedirs(OUT, exist_ok=True)
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

TEAL = (26, 160, 148)
TEAL_D = (18, 120, 112)
BOX = (230, 126, 42)
BOX_D = (196, 100, 28)
BOX_L = (245, 160, 90)
TILE_COLORS = [
    (229, 9, 20), (0, 168, 225), (17, 60, 207), (142, 68, 173),
    (28, 231, 131), (245, 166, 35), (233, 30, 99), (46, 139, 120),
]

def rr(d, box, r, fill):
    d.rounded_rectangle(box, radius=r, fill=fill)

def draw_bundle(size):
    """Open box with colorful app tiles popping out."""
    img = Image.new("RGB", (size, size), TEAL)
    d = ImageDraw.Draw(img)
    u = size / 100.0
    # subtle darker teal corner wedges
    d.polygon([(0, 0), (size*0.4, 0), (0, size*0.4)], fill=TEAL_D)
    d.polygon([(size, size), (size*0.6, size), (size, size*0.6)], fill=TEAL_D)

    # box body (front face) - lower middle
    bx0, by0, bx1, by1 = 22*u, 52*u, 78*u, 88*u
    d.rectangle([bx0, by0, bx1, by1], fill=BOX)
    # open rim (top of box, lighter)
    d.polygon([(bx0, by0), (bx1, by0), (bx1-6*u, by0-8*u), (bx0+6*u, by0-8*u)], fill=BOX_L)
    # left/right inner flaps
    d.polygon([(bx0, by0), (bx0+6*u, by0-8*u), (bx0+6*u, by0+2*u)], fill=BOX_D)
    d.polygon([(bx1, by0), (bx1-6*u, by0-8*u), (bx1-6*u, by0+2*u)], fill=BOX_D)

    # colorful tiles popping out of the box (grid, slight stagger)
    ts = 15*u
    gap = 3*u
    cols, rows = 3, 2
    total_w = cols*ts + (cols-1)*gap
    start_x = (size - total_w) / 2
    start_y = 20*u
    idx = 0
    for row in range(rows):
        for col in range(cols):
            x = start_x + col*(ts+gap) + (row*ts*0.15)
            y = start_y + row*(ts+gap)
            rr(d, [x, y, x+ts, y+ts], int(3*u), TILE_COLORS[idx % len(TILE_COLORS)])
            idx += 1
    return img

# App icon (square, fills frame)
draw_bundle(512).save(os.path.join(OUT, "ic_launcher.png"))

# TV banner 320x180: bundle on left, title on right
banner = Image.new("RGB", (320, 180), TEAL)
bd = ImageDraw.Draw(banner)
logo = draw_bundle(160)
banner.paste(logo, (6, 10))
bd.text((176, 62), "Stream", font=ImageFont.truetype(BOLD, 34), fill=(255, 255, 255))
bd.text((176, 100), "Everything", font=ImageFont.truetype(BOLD, 26), fill=(255, 214, 160))
banner.save(os.path.join(OUT, "tv_banner.png"))

print("wrote ic_launcher.png (512) and tv_banner.png (320x180)")
