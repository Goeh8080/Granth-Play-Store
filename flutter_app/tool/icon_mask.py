#!/usr/bin/env python3
"""Export the alpha mask of the status-bar icon and verify it is a flat monochrome shape.

Android only uses the ALPHA of a notification small icon (it tints it). This renders
android/app/src/main/res/drawable/ic_stat_granth.xml at 24/48/96 px (mdpi/xhdpi/xxxhdpi-ish),
checks every pixel is white-or-transparent, that the shape covers a sensible part of the
24 dp box without touching its edge, and writes docs/icon/ic_stat_granth_mask_<px>.png
(black = transparent, white = what Android tints). Needs: pip install cairosvg pillow.
  python3 tool/icon_mask.py
"""
import re, sys, os
import cairosvg
from PIL import Image

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
xml = open(os.path.join(root, 'android/app/src/main/res/drawable/ic_stat_granth.xml'), encoding='utf-8').read()
xml = re.sub(r'<!--.*?-->', '', xml, flags=re.S)
d = re.findall(r'android:pathData="([^"]+)"', xml)
fills = re.findall(r'android:fillColor="([^"]+)"', xml)
assert d and fills and all(f.upper() == '#FFFFFFFF' for f in fills), fills
assert 'strokeColor' not in xml and 'gradient' not in xml.lower() and 'tint' not in xml.lower()
svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="{p}" height="{p}">%s</svg>' % ''.join(
    '<path fill="#fff" d="%s"/>' % x for x in d)
out = os.path.join(root, 'docs/icon'); os.makedirs(out, exist_ok=True)
ok = True
for px in (24, 48, 96):
    png = os.path.join(out, 'ic_stat_granth_%d.png' % px)
    cairosvg.svg2png(bytestring=svg.format(p=px).encode(), write_to=png)
    im = Image.open(png).convert('RGBA')
    w, h = im.size
    px_data = list(im.getdata())
    colours = {(r, g, b) for r, g, b, a in px_data if a > 0}
    assert colours <= {(255, 255, 255)}, 'not monochrome: %s' % sorted(colours)[:5]
    alpha = [a for *_, a in px_data]
    cover = sum(1 for a in alpha if a > 127) / len(alpha)
    edge = [im.getpixel((x, y))[3] for x in range(w) for y in (0, h - 1)] + [im.getpixel((x, y))[3] for y in range(h) for x in (0, w - 1)]
    mask = Image.new('L', im.size); mask.putdata(alpha)
    mask.save(os.path.join(out, 'ic_stat_granth_mask_%d.png' % px))
    os.remove(png)
    print('%3dpx: colours=%s coverage=%.0f%% edge-alpha-max=%d' % (px, 'white only', cover * 100, max(edge)))
    ok &= 0.12 < cover < 0.6 and max(edge) == 0
sys.exit(0 if ok else 1)
