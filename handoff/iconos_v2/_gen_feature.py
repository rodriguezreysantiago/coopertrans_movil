# Genera el Feature graphic (1024x500) de Google Play con el branding v2.
# Reusa la paleta del icon-master.svg. Sin numpy: gradientes via imagen chica + blur.
# Salida: playstore-feature-1024x500.png (PNG 24-bit RGB, sin alpha — requisito de Play).
#
#   python _gen_feature.py
#
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import os

AQUI = os.path.dirname(os.path.abspath(__file__))
W, H = 1024, 500

FONTS = r"C:\Windows\Fonts"
def font(nombre, size):
    return ImageFont.truetype(os.path.join(FONTS, nombre), size)

def hex2(c):
    c = c.lstrip("#")
    return tuple(int(c[i:i+2], 16) for i in (0, 2, 4))

# Paleta (del icon-master.svg)
BG_IN   = hex2("1c1750")   # centro radial
BG_MID  = hex2("0c0930")
BG_OUT  = hex2("04031a")   # navy profundo (= ic_launcher_background)
PURPLE  = hex2("a855f7")
CYAN    = hex2("22d3ee")
LILA    = hex2("c7b6ff")   # "Móvil"
SUB     = hex2("a9a4d0")   # subtítulo

# ---------------------------------------------------------------- fondo radial
def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

sw, sh = 160, 78
small = Image.new("RGB", (sw, sh))
px = small.load()
cx, cy = 0.34 * sw, 0.46 * sh          # foco del brillo cerca del ícono
maxr = (sw ** 2 + sh ** 2) ** 0.5
for y in range(sh):
    for x in range(sw):
        d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / maxr
        d = min(1.0, d / 0.78)
        if d < 0.55:
            col = lerp(BG_IN, BG_MID, d / 0.55)
        else:
            col = lerp(BG_MID, BG_OUT, (d - 0.55) / 0.45)
        px[x, y] = col
base = small.resize((W, H), Image.BICUBIC)

# ------------------------------------------------------------------- glows
def glow(color, center, radio, alpha, blur):
    capa = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(capa)
    x, y = center
    d.ellipse([x - radio, y - radio, x + radio, y + radio], fill=color + (alpha,))
    return capa.filter(ImageFilter.GaussianBlur(blur))

ICON = 366
ix, iy = 74, (H - ICON) // 2
icx, icy = ix + ICON // 2, iy + ICON // 2

base = base.convert("RGBA")
base.alpha_composite(glow(PURPLE, (icx, icy - 6), 250, 105, 115))   # halo del ícono
base.alpha_composite(glow(CYAN,   (900, 470),     230, 55,  130))   # acento abajo-der
base.alpha_composite(glow(PURPLE, (560, 120),     180, 40,  130))   # respiro arriba

# -------------------------------------------------------------------- ícono
master = Image.open(os.path.join(AQUI, "master-2048.png")).convert("RGBA")
master = master.resize((ICON, ICON), Image.LANCZOS)
rad = int(ICON * 0.225)
mask = Image.new("L", (ICON, ICON), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, ICON - 1, ICON - 1], radius=rad, fill=255)

# sombra suelta bajo el ícono
sombra = Image.new("RGBA", (W, H), (0, 0, 0, 0))
sd = ImageDraw.Draw(sombra)
sd.rounded_rectangle([ix + 6, iy + 16, ix + ICON + 6, iy + ICON + 16],
                     radius=rad, fill=(0, 0, 0, 150))
base.alpha_composite(sombra.filter(ImageFilter.GaussianBlur(22)))

# borde neón sutil
borde = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(borde).rounded_rectangle(
    [ix - 2, iy - 2, ix + ICON + 1, iy + ICON + 1], radius=rad + 2,
    outline=(168, 85, 247, 130), width=3)
base.paste(master, (ix, iy), mask)
base.alpha_composite(borde.filter(ImageFilter.GaussianBlur(1.2)))

# --------------------------------------------------------------------- texto
draw = ImageDraw.Draw(base)
TX = ix + ICON + 70                      # inicio del bloque de texto
maxw = W - TX - 44                        # ancho disponible

def fit(nombre, txt, size, target):
    f = font(nombre, size)
    while size > 20 and draw.textlength(txt, font=f) > target:
        size -= 2
        f = font(nombre, size)
    return f

f_titulo = fit("segoeuib.ttf", "Coopertrans", 86, maxw)
f_movil  = fit("segoeuib.ttf", "Móvil",       86, maxw)

def tracked(xy, txt, f, fill, track):
    x, y = xy
    for ch in txt:
        draw.text((x, y), ch, font=f, fill=fill)
        x += draw.textlength(ch, font=f) + track

# alto del bloque para centrarlo verticalmente
h_t = (f_titulo.getbbox("Coopertrans")[3])
h_m = (f_movil.getbbox("Móvilg")[3])
sub_txt = "GESTIÓN DE FLOTA Y LOGÍSTICA"
f_sub = font("bahnschrift.ttf", 30)
gap1, gap2 = 4, 26
total = h_t + gap1 + h_m + gap2 + 34
y0 = (H - total) // 2 - 6

draw.text((TX, y0), "Coopertrans", font=f_titulo, fill=(255, 255, 255))
y1 = y0 + h_t + gap1
draw.text((TX, y1), "Móvil", font=f_movil, fill=LILA)

# acento: barra corta con degradé lila→cian
y2 = y1 + h_m + gap2
bar = Image.new("RGB", (160, 1))
bp = bar.load()
for i in range(160):
    bp[i, 0] = lerp(hex2("a855f7"), CYAN, i / 159)
bar = bar.resize((150, 6), Image.BICUBIC)
bm = Image.new("L", (150, 6), 0)
ImageDraw.Draw(bm).rounded_rectangle([0, 0, 149, 5], radius=3, fill=255)
base.paste(bar.convert("RGBA"), (TX + 2, y2), bm)

tracked((TX, y2 + 18), sub_txt, f_sub, SUB, 2)

# ------------------------------------------------------------------- guardar
out = os.path.join(AQUI, "playstore-feature-1024x500.png")
base.convert("RGB").save(out, "PNG")
im = Image.open(out)
print("OK ->", out, im.size, im.mode)
