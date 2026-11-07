#!/usr/bin/env python3
"""Decode actual standard/Apple CgBI PNG pixels and reject blank or wrong app icons."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import zlib


def decode_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('Not a PNG: ' + str(path))
    at, packed, optimized, header = 8, bytearray(), False, None
    while at < len(data):
        if at + 12 > len(data):
            raise ValueError('Truncated PNG chunk')
        length = struct.unpack_from('>I', data, at)[0]
        kind, payload = data[at+4:at+8], data[at+8:at+8+length]
        if len(payload) != length or at+12+length > len(data):
            raise ValueError('Truncated PNG payload')
        if zlib.crc32(kind + payload) & 0xffffffff != struct.unpack_from('>I', data, at+8+length)[0]:
            raise ValueError('Invalid PNG chunk checksum')
        at += length + 12
        if kind == b'CgBI':
            optimized = True
        elif kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', payload)
        elif kind == b'IDAT':
            packed.extend(payload)
        elif kind == b'IEND':
            break
    if not header:
        raise ValueError('Missing PNG dimensions')
    width, height, depth, color, compression, filtering, interlace = header
    if not 1 <= width <= 2048 or not 1 <= height <= 2048 or depth != 8 or color not in (2, 6) or compression or filtering or interlace:
        raise ValueError('Expected bounded, noninterlaced8-bit RGB/RGBA PNG')
    channels = 4 if color == 6 else 3
    stride = width * channels
    raw = zlib.decompress(bytes(packed), -15 if optimized else 15)
    if len(raw) != height * (stride+1):
        raise ValueError('Unexpected PNG decompressed size')
    result, previous, offset = bytearray(), bytearray(stride), 0
    for _ in range(height):
        mode = raw[offset]; offset += 1
        if mode not in range(5):
            raise ValueError('Invalid PNG row filter')
        row = bytearray(raw[offset:offset+stride]); offset += stride
        for x in range(stride):
            left = row[x-channels] if x >= channels else 0
            up = previous[x]
            upper_left = previous[x-channels] if x >= channels else 0
            delta = 0
            if mode == 1:
                delta = left
            elif mode == 2:
                delta = up
            elif mode == 3:
                delta = (left + up) // 2
            elif mode == 4:
                p = left + up - upper_left
                a, b, c = abs(p-left), abs(p-up), abs(p-upper_left)
                delta = left if a <= b and a <= c else up if b <= c else upper_left
            row[x] = (row[x]+delta) & 255
        for x in range(0, stride, channels):
            red, green, blue = row[x:x+3]
            alpha = row[x+3] if channels == 4 else 255
            if optimized:
                red, blue = blue, red
                if 0 < alpha < 255:
                    red, green, blue = [min(255, (value*255+alpha//2)//alpha) for value in (red, green, blue)]
            result.extend((red, green, blue, alpha))
        previous = row
    return width, height, result


def metrics(image):
    width, height, pixels = image
    colors = Counter(tuple(pixels[index:index+3]) for index in range(0, len(pixels), 4))
    bright = sum(count for rgb, count in colors.items() if max(rgb) >= 128)
    alpha = pixels[3::4]
    return dict(width=width, height=height, uniqueColors=len(colors),
                channelRange=max(max(rgb) for rgb in colors)-min(min(rgb) for rgb in colors),
                brightFraction=bright/(width*height), opaque=all(value == 255 for value in alpha))


def compare(reference, candidate):
    rw, rh, source = reference; cw, ch, pixels = candidate
    error, count = 0, 0
    # Sample normalized pixel centers; export and Xcode resampling may differ slightly.
    for y in range(min(ch, 64)):
        cy = min(ch-1, int((y+0.5)*ch/min(ch,64)))
        ry = min(rh-1, int((cy+0.5)*rh/ch))
        for x in range(min(cw,64)):
            cx = min(cw-1, int((x+0.5)*cw/min(cw,64)))
            rx = min(rw-1, int((cx+0.5)*rw/cw))
            a, b = (ry*rw+rx)*4, (cy*cw+cx)*4
            alpha = source[a+3]
            expected = [(source[a+channel]*alpha + background*(255-alpha) + 127)//255 for channel, background in enumerate((3, 4, 18))]
            error += sum(abs(expected[channel]-pixels[b+channel]) for channel in range(3)); count += 3
    return error/count


def validate(reference_path, candidate_path, size=None):
    reference, candidate = decode_png(reference_path), decode_png(candidate_path)
    result = metrics(candidate)
    if size and candidate[:2] != (size, size):
        raise ValueError('Wrong exported icon size: ' + str(candidate_path))
    if not result['opaque'] or result['uniqueColors'] < 32 or result['channelRange'] < 96 or result['brightFraction'] < 0.01:
        raise ValueError('Blank/transparent app icon rejected: ' + str(candidate_path) + ' ' + json.dumps(result))
    result['sourceMeanAbsoluteError'] = round(compare(reference, candidate), 3)
    if result['sourceMeanAbsoluteError'] > 18:
        raise ValueError('App icon differs from the original logo: ' + str(candidate_path) + ' ' + json.dumps(result))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--rendered', type=Path, required=True)
    parser.add_argument('--app-bundle', type=Path)
    args = parser.parse_args()
    results = {str(args.rendered): validate(args.source, args.rendered, size=1024)}
    if args.app_bundle:
        icons = sorted(args.app_bundle.glob('AppIcon*.png'))
        if not icons:
            raise SystemExit('No packaged app icon PNGs found')
        for icon in icons:
            results[str(icon)] = validate(args.source, icon)
    print(json.dumps(results, indent=2))

if __name__ == '__main__':
    main()
