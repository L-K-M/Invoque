#!/usr/bin/env python3
"""Renders Invoque's app icon set from the shipped source artwork.

    python3 scripts/make-app-icon.py

Reads media-sources/icon2.png and writes
Invoque/Resources/Assets.xcassets/AppIcon.appiconset/*.png plus its
Contents.json and the AccentColor colorset — every size regenerated in
step, so the sizes cannot drift apart. Re-run it after changing the
source art.

No dependencies on purpose: no Pillow, no ImageMagick — the PNG is decoded
and re-encoded here with zlib, and each target size is an area-average
downscale (a box filter, the right quality for a ~80x reduction). The one
drawn element is the alpha edge: a superellipse clip with a 2% inset, the
same shape Pict's icon uses, so the square artwork reads as an icon rather
than a hard crop on macOS 13-15 (macOS 26 masks everything anyway).
"""

import os
import struct
import zlib

SOURCE = "media-sources/icon2.png"
ASSETS = os.path.join("Invoque", "Resources", "Assets.xcassets")
ICONSET = os.path.join(ASSETS, "AppIcon.appiconset")
ACCENTSET = os.path.join(ASSETS, "AccentColor.colorset")

# The icon's Memphis pink — the brand accent for system-tinted controls
# (Settings pickers, the angle dial). Written here so icon and accent
# can't drift: the accent IS a color of the artwork.
ACCENT = (0xF2 / 255.0, 0x33 / 255.0, 0x9E / 255.0)

INSET = 0.02          # fraction of the canvas left clear on every side
SQUIRCLE_N = 5.0      # superellipse exponent; ~5 approximates Apple's corner
# macOS wants each nominal size at 1x and 2x — ten files, seven renders.
CONTENTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
            (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def decode_png(path):
    """One RGB image as (width, height, flat bytearray of RGB triplets).

    Handles the formats a hand-exported PNG actually uses: 8-bit truecolor
    (with or without alpha), non-interlaced, all five scanline filters.
    """
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos = 8
    width = height = None
    color_type = None
    idat = bytearray()
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        payload = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            (width, height, bit_depth, color_type,
             _comp, _filt, interlace) = struct.unpack(">IIBBBBB", payload)
            if bit_depth != 8 or color_type not in (2, 6) or interlace != 0:
                raise ValueError(f"unsupported PNG format: depth {bit_depth}, "
                                 f"type {color_type}, interlace {interlace}")
        elif kind == b"IDAT":
            idat += payload
        elif kind == b"tRNS":
            # A color-type-2 source can still mark pixels transparent —
            # same policy as RGBA alpha: flatten it deliberately.
            raise ValueError("source artwork uses a tRNS transparency chunk; "
                             "flatten it before rendering icons")
        elif kind == b"IEND":
            break
    channels = 4 if color_type == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    px = bytearray(width * height * 3)
    prev = bytearray(stride)
    for y in range(height):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        if f == 1:      # Sub
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif f == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:    # Average
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:    # Paeth
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        for x in range(width):
            s = x * channels
            d = (y * width + x) * 3
            # Transparent pixels carry arbitrary RGB; a half-transparent
            # edge would box-average stale dark values into the icon.
            # Fail fast — flatten the artwork deliberately instead.
            if channels == 4 and line[s + 3] != 255:
                raise ValueError("source artwork has transparency; "
                                 "flatten it before rendering icons")
            px[d:d + 3] = line[s:s + 3]
        prev = line
    return width, height, px


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def squircle_coverage(x, y, half):
    """Anti-aliased coverage of the plate edge, one-pixel band."""
    nx, ny = abs(x) / half, abs(y) / half
    if nx == 0.0 and ny == 0.0:
        return 1.0
    distance = ((nx ** SQUIRCLE_N + ny ** SQUIRCLE_N)
                ** (1.0 / SQUIRCLE_N) - 1.0) * half
    return clamp(0.5 - distance)


def render(source, size):
    """Area-average `source` (w, h, RGB) down to `size` px, squircle-clipped."""
    sw, sh, spx = source
    half = size * (0.5 - INSET)
    centre = size / 2.0
    pixels = bytearray(size * size * 4)
    for py in range(size):
        y = py + 0.5
        row = py * size * 4
        for px in range(size):
            a = squircle_coverage(px + 0.5 - centre, y - centre, half)
            if a <= 0.0:
                continue
            # Source rect covered by this pixel — area average over it.
            x0 = int(px * sw / size)
            x1 = max(x0 + 1, int((px + 1) * sw / size))
            y0 = int(py * sh / size)
            y1 = max(y0 + 1, int((py + 1) * sh / size))
            r = g = b = n = 0
            for sy in range(y0, min(y1, sh)):
                for sx in range(x0, min(x1, sw)):
                    s = (sy * sw + sx) * 3
                    r += spx[s]
                    g += spx[s + 1]
                    b += spx[s + 2]
                    n += 1
            i = row + px * 4
            pixels[i] = r // n
            pixels[i + 1] = g // n
            pixels[i + 2] = b // n
            pixels[i + 3] = int(round(255 * a))
    return pixels


def write_png(path, size, pixels):
    """Minimal RGBA8 PNG: no interlacing, filter 0 on every scanline."""
    raw = bytearray()
    stride = size * 4
    for py in range(size):
        raw.append(0)
        raw += pixels[py * stride:(py + 1) * stride]

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload
                + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    source_path = os.path.join(root, SOURCE)
    iconset = os.path.join(root, ICONSET)
    accentset = os.path.join(root, ACCENTSET)
    os.makedirs(iconset, exist_ok=True)
    os.makedirs(accentset, exist_ok=True)

    source = decode_png(source_path)
    print(f"  source {SOURCE}: {source[0]}x{source[1]}")

    drawn = {}
    for nominal, scale in CONTENTS:
        pixels = nominal * scale
        if pixels not in drawn:
            drawn[pixels] = render(source, pixels)
        name = f"icon_{nominal}x{nominal}@{scale}x.png"
        write_png(os.path.join(iconset, name), pixels, drawn[pixels])
        print(f"  {name} ({pixels}px)")

    images = ',\n'.join(
        '    {\n'
        '      "idiom" : "mac",\n'
        f'      "size" : "{nominal}x{nominal}",\n'
        f'      "scale" : "{scale}x",\n'
        f'      "filename" : "icon_{nominal}x{nominal}@{scale}x.png"\n'
        '    }'
        for nominal, scale in CONTENTS)
    with open(os.path.join(iconset, "Contents.json"), "w") as handle:
        handle.write('{\n  "images" : [\n' + images + '\n  ],\n'
                     '  "info" : {\n    "author" : "xcode",\n'
                     '    "version" : 1\n  }\n}\n')
    print("  Contents.json")

    with open(os.path.join(accentset, "Contents.json"), "w") as handle:
        handle.write(
            '{\n  "colors" : [\n    {\n      "color" : {\n'
            '        "color-space" : "srgb",\n'
            '        "components" : { "alpha" : "1.000", '
            f'"blue" : "{ACCENT[2]:.3f}", "green" : "{ACCENT[1]:.3f}", '
            f'"red" : "{ACCENT[0]:.3f}" }}\n'
            '      },\n      "idiom" : "universal"\n    }\n  ],\n'
            '  "info" : { "author" : "xcode", "version" : 1 }\n}\n')
    print("  AccentColor.colorset/Contents.json")


if __name__ == "__main__":
    main()
