#!/usr/bin/env python3
"""Original Home Garden Studio plan symbol; standard-library-only, no source images."""
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1] / "HomeGardenStudio/Assets.xcassets"
OUT = ROOT / "AppIcon.appiconset"

def rounded(x, y, left, top, right, bottom, radius):
    dx = max(left + radius - x, 0, x - (right - radius))
    dy = max(top + radius - y, 0, y - (bottom - radius))
    return left <= x <= right and top <= y <= bottom and dx * dx + dy * dy <= radius * radius

def color(x, y):
    # A plan seen from above: two garden beds, a path, and one tree canopy.
    if not rounded(x, y, 126, 126, 898, 898, 150):
        return (244, 240, 226)
    if 454 <= x <= 570 or 632 <= y <= 730:
        return (232, 209, 169)
    if rounded(x, y, 198, 206, 414, 580, 52):
        if any((x - 306)**2 + (y - cy)**2 <= 44**2 for cy in (284, 394, 504)):
            return (222, 234, 170)
        return (119, 155, 91)
    if rounded(x, y, 614, 206, 826, 580, 52):
        if 655 <= x <= 785 and any(abs(y - cy) <= 12 for cy in (280, 370, 460, 530)):
            return (207, 222, 152)
        return (121, 158, 96)
    if (x - 315)**2 + (y - 792)**2 <= 68**2:
        return (154, 183, 110)
    if (x - 293)**2 + (y - 771)**2 <= 25**2:
        return (188, 209, 136)
    if rounded(x, y, 621, 770, 812, 824, 18):
        return (180, 194, 144)
    return (43, 82, 62)

def png(size):
    samples = 3 if size < 512 else 1
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            values = [color((x + (sx + .5) / samples) * 1024 / size,
                            (y + (sy + .5) / samples) * 1024 / size)
                      for sy in range(samples) for sx in range(samples)]
            rows.extend(round(sum(c[channel] for c in values) / len(values)) for channel in range(3))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) + chunk(b'sRGB', b'\0') + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b'')

OUT.mkdir(parents=True, exist_ok=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    (OUT / f'icon-{size}.png').write_bytes(png(size))
images = [{'filename': 'icon-1024.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}]
for points in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        images.append({'filename': f'icon-{points * scale}.png', 'idiom': 'mac', 'scale': f'{scale}x', 'size': f'{points}x{points}'})
(OUT / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
(ROOT / 'Contents.json').write_text('{"info":{"author":"xcode","version":1}}\n')
