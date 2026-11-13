from PIL import Image, ImageDraw, ImageFont
import os

OUT = os.path.join(os.path.dirname(__file__), "tiles")
os.makedirs(OUT, exist_ok=True)
BOLD = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"

W, H = 640, 360

def font(size):
    return ImageFont.truetype(BOLD, size)

def center_text(d, cx, cy, text, f, fill):
    b = d.textbbox((0, 0), text, font=f)
    d.text((cx - (b[2]-b[0]) / 2, cy - (b[3]-b[1]) / 2 - b[1]), text, font=f, fill=fill)

def gradient(top, bottom):
    img = Image.new("RGB", (W, H), top)
    d = ImageDraw.Draw(img)
    for y in range(H):
        t = y / H
        c = tuple(int(top[i] + (bottom[i]-top[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
    return img

# --- Bollywood: warm gold/maroon film-card look with film-strip edges ---
img = gradient((45, 12, 22), (130, 45, 22))
d = ImageDraw.Draw(img)
# film strip holes top and bottom
for x in range(24, W, 60):
    d.rounded_rectangle([x, 12, x+34, 40], radius=6, fill=(20, 8, 10))
    d.rounded_rectangle([x, H-40, x+34, H-12], radius=6, fill=(20, 8, 10))
center_text(d, W/2, H/2 - 18, "BOLLYWOOD", font(74), (255, 201, 92))
center_text(d, W/2, H/2 + 46, "HINDI CINEMA", font(30), (238, 220, 190))
img.save(os.path.join(OUT, "hindi.png"))

# --- Live TV: red badge like the reference logo ---
img = gradient((20, 24, 30), (10, 12, 16))
d = ImageDraw.Draw(img)
# red rounded outline
d.rounded_rectangle([70, 90, 570, 270], radius=28, outline=(214, 30, 40), width=10)
center_text(d, 250, H/2, "LIVE", font(96), (214, 30, 40))
# TV in a red filled box
d.rounded_rectangle([370, 128, 520, 232], radius=16, fill=(214, 30, 40))
center_text(d, 445, H/2, "TV", font(80), (255, 255, 255))
img.save(os.path.join(OUT, "alllive.png"))

print("wrote hindi.png and alllive.png")
