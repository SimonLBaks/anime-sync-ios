from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from validate_icon import decode_png, validate


def chunk(kind, value):
    return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind+value) & 0xffffffff)


def png(width, height, pixels, optimized=False, mode=0):
    previous = bytes(width*4); raw = bytearray()
    for y in range(height):
        row = bytearray()
        for red, green, blue, alpha in pixels[y*width:(y+1)*width]:
            if optimized:
                row.extend(((blue*alpha+127)//255, (green*alpha+127)//255, (red*alpha+127)//255, alpha))
            else:
                row.extend((red,green,blue,alpha))
        raw.append(mode)
        for x, value in enumerate(row):
            left, up, upper_left = row[x-4] if x>=4 else 0, previous[x], previous[x-4] if x>=4 else 0
            delta = 0
            if mode == 1: delta = left
            elif mode == 2: delta = up
            elif mode == 3: delta = (left+up)//2
            elif mode == 4:
                p=left+up-upper_left; a,b,c=abs(p-left),abs(p-up),abs(p-upper_left)
                delta=left if a<=b and a<=c else up if b<=c else upper_left
            raw.append((value-delta)&255)
        previous = row
    if optimized:
        compressor=zlib.compressobj(wbits=-15); packed=compressor.compress(raw)+compressor.flush()
    else:
        packed=zlib.compress(raw)
    return b'\x89PNG\r\n\x1a\n' + (chunk(b'CgBI',b'\x40\xa0\x60\x82') if optimized else b'') + chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0)) + chunk(b'IDAT',packed) + chunk(b'IEND',b'')


class IconValidationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.source = Path(self.directory.name) / 'source.png'
        self.candidate = Path(self.directory.name) / 'candidate.png'
        self.pixels=[(x*17,y*17,(x+y)*8,255) for y in range(16) for x in range(16)]
        self.source.write_bytes(png(16,16,self.pixels))

    def test_all_png_filters_and_cgbi_channels_decode_losslessly(self):
        for optimized in [False,True]:
            for mode in range(5):
                with self.subTest(optimized=optimized,mode=mode):
                    self.candidate.write_bytes(png(16,16,self.pixels,optimized,mode))
                    width,height,pixels=decode_png(self.candidate)
                    self.assertEqual((width,height),(16,16))
                    self.assertEqual(list(pixels),[value for pixel in self.pixels for value in pixel])
                    self.assertEqual(validate(self.source,self.candidate)['sourceMeanAbsoluteError'],0)

    def test_rejects_uniform_black_packaged_cgbi_and_transparent_export(self):
        for pixels, optimized in [([(0,0,0,255)]*256,True), ([(r,g,b,128) for r,g,b,_ in self.pixels],False)]:
            self.candidate.write_bytes(png(16,16,pixels,optimized))
            with self.assertRaisesRegex(ValueError,'Blank/transparent'):
                validate(self.source,self.candidate)

    def test_composites_original_transparency_against_export_background(self):
        translucent=[(r,g,b,128) for r,g,b,_ in self.pixels]
        self.source.write_bytes(png(16,16,translucent))
        composite=[tuple((value*128+background*127+127)//255 for value,background in zip(pixel[:3],(3,4,18)))+(255,) for pixel in translucent]
        self.candidate.write_bytes(png(16,16,composite))
        self.assertEqual(validate(self.source,self.candidate)['sourceMeanAbsoluteError'],0)

    def test_rejects_changed_artwork_wrong_size_and_corrupt_bytes(self):
        self.candidate.write_bytes(png(16,16,[(b,r,g,a) for r,g,b,a in self.pixels]))
        with self.assertRaisesRegex(ValueError,'differs'):
            validate(self.source,self.candidate)
        self.candidate.write_bytes(png(16,16,self.pixels))
        with self.assertRaisesRegex(ValueError,'size'):
            validate(self.source,self.candidate,size=1024)
        data=bytearray(self.candidate.read_bytes()); data[-15]^=1; self.candidate.write_bytes(data)
        with self.assertRaises(ValueError):
            decode_png(self.candidate)
