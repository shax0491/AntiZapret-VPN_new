# Генерация иконок приложения: чёрный фон, бирюзовый градиентный «play» в кольце. Запуск: python gen_icons.py
from PIL import Image, ImageDraw
import os
R = 'app/src/main/res'
def grad(size, c1=(102, 252, 241), c2=(31, 40, 51)):
    g = Image.new('RGB', (size, size))
    px = g.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * size)
            px[x, y] = tuple(int(c1[i] * (1 - t) + c2[i] * t) for i in range(3))
    return g
def glyph(size, safe=1.0):
    """прозрачный фон; кольцо + треугольник play с градиентом. safe<1 — уменьшенный глиф (для adaptive foreground)"""
    S = size * 4
    m = Image.new('L', (S, S), 0); d = ImageDraw.Draw(m)
    c = S / 2; r = S * 0.34 * safe; w = S * 0.045 * safe
    d.ellipse([c - r, c - r, c + r, c + r], outline=255, width=int(w))
    t = r * 0.62
    d.polygon([(c - t * 0.45, c - t), (c - t * 0.45, c + t), (c + t * 0.95, c)], fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0)); out.paste(grad(size), (0, 0), m)
    return out
def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True); img.save(path)
dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for n, k in dens.items():
    fg = int(108 * k)
    save(glyph(fg, 0.78), f'{R}/mipmap-{n}/ic_launcher_foreground.png')          # adaptive: глиф в безопасной зоне
    ic = int(48 * k)                                                               # legacy: скруглённый чёрный квадрат
    base = Image.new('RGBA', (ic, ic), (0, 0, 0, 0)); ImageDraw.Draw(base).rounded_rectangle([0, 0, ic - 1, ic - 1], int(ic * 0.22), fill=(11, 12, 16, 255))
    base.alpha_composite(glyph(ic, 1.0)); save(base, f'{R}/mipmap-{n}/ic_launcher.png')
# TV-баннер 320x180dp -> xhdpi 640x360 (+ xxhdpi 960x540)
for n, w in (('xhdpi', 640), ('xxhdpi', 960)):
    h = w * 9 // 16
    b = Image.new('RGB', (w, h), (11, 12, 16)); d = ImageDraw.Draw(b)
    for y in range(h):  # мягкий градиент снизу
        a = int(40 * y / h); d.line([(0, y), (w, y)], fill=(11 + a // 4, 12 + a // 3, 16 + a))
    g = glyph(int(h * 0.62), 1.0); b.paste(g, (int(w * 0.10), int(h * 0.19)), g)
    from PIL import ImageFont
    try: f = ImageFont.truetype('C:/Windows/Fonts/segoeuib.ttf', int(h * 0.20))
    except Exception: f = ImageFont.load_default()
    d.text((int(w * 0.42), int(h * 0.30)), 'Kinolink', font=f, fill=(255, 255, 255))
    try: f2 = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', int(h * 0.10))
    except Exception: f2 = f
    d.text((int(w * 0.43), int(h * 0.56)), 'TV', font=f2, fill=(102, 252, 241))
    save(b, f'{R}/drawable-{n}/banner.png')
print('ok')
