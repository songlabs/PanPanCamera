"""Generate tiny PNGs in memory; exercise the real screenshot verifier."""
import contextlib
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_screenshots import dimensions, verify


def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))


def png(width=2, height=2, depth=8, color=6, interlace=0, idat=None, raw=None):
    header = struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, interlace)
    if idat is None:
        channels = 3 if color == 2 else 4
        rows = raw if raw is not None else (b'\0' + b'\x80' * width * channels) * height
        idat = [zlib.compress(rows)]
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + b''.join(chunk(b'IDAT', p) for p in idat) + chunk(b'IEND', b'')


class MemoryPNG:
    def __init__(self, data): self.data = data
    def read_bytes(self): return self.data
    def __str__(self): return 'generated test PNG'


class ScreenshotPNGTests(unittest.TestCase):
    def rejects(self, data, message):
        with self.assertRaisesRegex(ValueError, message):
            dimensions(MemoryPNG(data))

    def testValidRGBAndRGBAPNG(self):
        for color in (2, 6):
            self.assertEqual(dimensions(MemoryPNG(png(color=color))), (2, 2))

    def testConsecutiveIDATChunksFormOneStream(self):
        compressed = zlib.compress((b'\0' + b'\x80' * 8) * 2)
        self.assertEqual(dimensions(MemoryPNG(png(idat=[compressed[:4], b'', compressed[4:]]))), (2, 2))

    def testNoIDATFails(self):
        self.rejects(png(idat=[]), 'Missing or empty.*IDAT')

    def testEmptyIDATFails(self):
        self.rejects(png(idat=[b'']), 'Missing or empty.*IDAT')

    def testCorruptZlibFails(self):
        self.rejects(png(idat=[b'not a zlib stream']), 'zlib')

    def testTruncatedZlibFailsEvenWithCorrectScanlineLength(self):
        compressed = zlib.compress((b'\0' + b'\x80' * 8) * 2)
        self.rejects(png(idat=[compressed[:-2]]), 'Truncated.*zlib')

    def testTrailingZlibDataFails(self):
        compressed = zlib.compress((b'\0' + b'\x80' * 8) * 2)
        self.rejects(png(idat=[compressed + b'extra']), 'trailing.*zlib')

    def testWrongCRCFails(self):
        data = bytearray(png())
        data[29] ^= 1
        self.rejects(bytes(data), 'checksum')

    def testTruncatedPNGFails(self):
        for data in (png()[:-1], png()[:40], png()[:-12]):
            self.rejects(data, 'Truncated|Incomplete')

    def testDimensionsMustMatchDecodedScanlines(self):
        self.rejects(png(raw=b'\0' * 9), 'scanline length')
        self.rejects(png(raw=b'\0' * 19), 'scanline length')
        self.rejects(png(width=0), 'dimensions')

    def testUnsupportedPixelFormatsFailClearly(self):
        for options in (dict(interlace=1), dict(depth=16), dict(color=3), dict(color=0)):
            self.rejects(png(**options), 'Unsupported PNG format')

    def testInvalidFilterFails(self):
        self.rejects(png(raw=(b'\5' + b'\x80' * 8) * 2), 'scanline filter')

    def testCoverageAndNativeResolutionAreRequired(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'screenshots'
            native = Path(directory) / 'native.png'
            native.write_bytes(png())
            names = [f'{language}/camera.png' for language in ['ja', 'zh-Hans', 'zh-Hant', 'en', 'ko']]
            names += [f'ja/{screen}.png' for screen in ['beauty', 'reshape', 'filter', 'makeup', 'settings']]
            for name in names:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(png())
            with contextlib.redirect_stdout(io.StringIO()):
                verify(root, native)
            (root / names[0]).write_bytes(png(width=3))
            with self.assertRaisesRegex(ValueError, 'Non-native screenshot resolution'):
                verify(root, native)
            (root / names[0]).unlink()
            with self.assertRaisesRegex(ValueError, 'coverage mismatch'):
                verify(root, native)


if __name__ == '__main__':
    unittest.main()
