"""Validate unmodified simctl PNG files, exact coverage, and native resolution."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import zlib


def dimensions(path):
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path}')
    offset, size, ended = 8, None, False
    while offset < len(data):
        length, kind = struct.unpack('>I4s', data[offset:offset + 8])
        payload = data[offset + 8:offset + 8 + length]
        checksum = struct.unpack('>I', data[offset + 8 + length:offset + 12 + length])[0]
        if zlib.crc32(kind + payload) != checksum:
            raise ValueError(f'Invalid PNG checksum: {path}')
        if kind == b'IHDR':
            size = struct.unpack('>II', payload[:8])
        offset += length + 12
        if kind == b'IEND':
            ended = True
            break
    if not size or min(size) <= 0 or not ended or offset != len(data):
        raise ValueError(f'Incomplete PNG: {path}')
    return size


def verify(root, native):
    expected = {f'{language}/camera.png' for language in ['ja', 'zh-Hans', 'zh-Hant', 'en', 'ko']}
    expected |= {f'ja/{screen}.png' for screen in ['beauty', 'reshape', 'filter', 'makeup', 'settings']}
    actual = {path.relative_to(root).as_posix() for path in root.rglob('*.png')}
    if actual != expected:
        raise ValueError(f'Screenshot coverage mismatch: missing={expected - actual}, extra={actual - expected}')
    native_size = dimensions(native)
    inventory = []
    for name in sorted(expected):
        path = root / name
        if dimensions(path) != native_size:
            raise ValueError(f'Non-native screenshot resolution: {name}')
        inventory.append({'path': name, 'bytes': path.stat().st_size, 'width': native_size[0],
                          'height': native_size[1], 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    print(json.dumps(inventory, indent=2))


if __name__ == '__main__':
    verify(Path(sys.argv[1]), Path(sys.argv[2]))
