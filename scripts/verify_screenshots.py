"""Validate static, non-interlaced, 8-bit RGB/RGBA simctl PNGs without dependencies.

Checks PNG chunks and the complete zlib scanline stream, per https://www.w3.org/TR/png-3/.
Other pixel formats fail explicitly. Optional macOS sips reads the unmodified images too.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import zlib


def dimensions(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    offset, size, ended = 8, None, False
    compressed = bytearray()
    seen_idat, idat_closed, seen_palette = False, False, False
    channels = 0
    while offset < len(data):
        if len(data) - offset < 12:
            raise ValueError(f'Truncated PNG chunk: {path}')
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        end = offset + 12 + length
        if end > len(data):
            raise ValueError(f'Truncated PNG chunk payload: {path}')
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack('>I', data[end - 4:end])[0]
        if zlib.crc32(kind + payload) != checksum:
            raise ValueError(f'Invalid PNG checksum: {path}')
        if any(not (65 <= byte <= 90 or 97 <= byte <= 122) for byte in kind) or not 65 <= kind[2] <= 90:
            raise ValueError(f'Invalid PNG chunk type: {path}')
        if size is None and kind != b'IHDR':
            raise ValueError(f'PNG must start with IHDR: {path}')
        if kind == b'IHDR':
            if size is not None or length != 13:
                raise ValueError(f'Invalid or repeated PNG IHDR: {path}')
            width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', payload)
            size = (width, height)
            if min(size) <= 0 or max(size) > 0x7fffffff:
                raise ValueError(f'Invalid PNG dimensions: {path}')
            if interlace != 0 or depth != 8 or color not in (2, 6) or compression != 0 or filtering != 0:
                raise ValueError(f'Unsupported PNG format; require non-interlaced 8-bit RGB/RGBA: {path}')
            channels = 3 if color == 2 else 4
            if height * (1 + width * channels) > 256 * 1024 * 1024:
                raise ValueError(f'PNG exceeds 256 MiB decoded screenshot limit: {path}')
        elif kind == b'IDAT':
            if idat_closed:
                raise ValueError(f'Non-consecutive PNG IDAT chunks: {path}')
            seen_idat = True
            compressed.extend(payload)
        elif kind == b'PLTE':
            if seen_palette or seen_idat or length == 0 or length % 3 or length > 768:
                raise ValueError(f'Invalid PNG palette: {path}')
            seen_palette = True
        elif kind in (b'acTL', b'fcTL', b'fdAT') or (kind != b'IEND' and kind[0] < 97):
            raise ValueError(f'Unsupported PNG chunk {kind!r}: {path}')
        if seen_idat and kind != b'IDAT':
            idat_closed = True
        offset = end
        if kind == b'IEND':
            if length != 0:
                raise ValueError(f'Invalid PNG IEND: {path}')
            ended = True
            break
    if not size or min(size) <= 0 or not ended or offset != len(data):
        raise ValueError(f'Incomplete PNG: {path}')
    if not seen_idat or not compressed:
        raise ValueError(f'Missing or empty PNG IDAT: {path}')
    stride = 1 + size[0] * channels
    expected = size[1] * stride
    decoder = zlib.decompressobj()
    try:
        pixels = decoder.decompress(compressed, expected + 1)
    except zlib.error as error:
        raise ValueError(f'Invalid PNG IDAT zlib stream: {path}') from error
    if len(pixels) != expected or decoder.unconsumed_tail:
        raise ValueError(f'PNG scanline length does not match IHDR dimensions: {path}')
    if not decoder.eof or decoder.unused_data:
        raise ValueError(f'Truncated or trailing PNG IDAT zlib stream: {path}')
    if any(pixels[index] > 4 for index in range(0, expected, stride)):
        raise ValueError(f'Invalid PNG scanline filter: {path}')
    return size


def native_dimensions(path):
    result = subprocess.run(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(path)],
                            check=True, capture_output=True, text=True)
    values = {}
    for line in result.stdout.splitlines():
        name, separator, value = line.strip().partition(': ')
        if separator and name in ('pixelWidth', 'pixelHeight') and value.isdigit():
            values[name] = int(value)
    if set(values) != {'pixelWidth', 'pixelHeight'}:
        raise ValueError(f'macOS sips could not read PNG dimensions: {path}')
    return values['pixelWidth'], values['pixelHeight']


def verify(root, native, macos_read=False):
    expected = {f'{language}/camera.png' for language in ['ja', 'zh-Hans', 'zh-Hant', 'en', 'ko']}
    expected |= {f'ja/{screen}.png' for screen in ['beauty', 'reshape', 'filter', 'makeup', 'settings']}
    actual = {path.relative_to(root).as_posix() for path in root.rglob('*.png')}
    if actual != expected:
        raise ValueError(f'Screenshot coverage mismatch: missing={expected - actual}, extra={actual - expected}')
    native_size = dimensions(native)
    if macos_read and native_dimensions(native) != native_size:
        raise ValueError('macOS native reference resolution mismatch')
    inventory = []
    for name in sorted(expected):
        path = root / name
        if dimensions(path) != native_size:
            raise ValueError(f'Non-native screenshot resolution: {name}')
        if macos_read and native_dimensions(path) != native_size:
            raise ValueError(f'macOS image read resolution mismatch: {name}')
        inventory.append({'path': name, 'bytes': path.stat().st_size, 'width': native_size[0],
                          'height': native_size[1], 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                          'png_scanlines': 'verified', 'macos_image_read': 'passed' if macos_read else 'not run'})
    print(json.dumps(inventory, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('native', type=Path)
    parser.add_argument('--macos-read', action='store_true', help='also require macOS sips image reads')
    args = parser.parse_args()
    try:
        verify(args.root, args.native, args.macos_read)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
