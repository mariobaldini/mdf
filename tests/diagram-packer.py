#!/usr/bin/env python3
"""Raw renderer payloads retain exact bytes, bounds and atomic ELF embedding."""
import importlib.util
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
from unittest import mock
import zlib

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('packer',ROOT/'tools/scripts/pack-diagram.py')
packer=importlib.util.module_from_spec(spec);spec.loader.exec_module(packer)
spec=importlib.util.spec_from_file_location('repacker',ROOT/'tools/scripts/repack-optional-modules.py')
repacker=importlib.util.module_from_spec(spec);spec.loader.exec_module(repacker)


def image():
    data=bytearray(96);data[:6]=b'\x7fELF\x02\x01'
    struct.pack_into('<HH',data,16,3,62)
    return bytes(data)


class Payloads(unittest.TestCase):
    def test_raw_payload_preserves_elf_and_unchanged_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            module=Path(temporary)/'renderer.so';module.write_bytes(image())
            payload=Path(temporary)/'renderer.payload'
            packer.pack_module(module,payload)
            raw=payload.read_bytes();magic,abi,header,stored,expanded,checksum,flags=packer.HEADER.unpack_from(raw)
            self.assertEqual((magic,abi,header,flags),(packer.MAGIC,packer.ABI,40,packer.RAW))
            self.assertEqual((stored,expanded),(len(image()),len(image())))
            self.assertEqual(raw[header:],image())
            self.assertEqual(checksum,zlib.crc32(image()))
            stamp=payload.stat().st_mtime_ns
            packer.pack_module(module,payload)
            self.assertEqual(payload.stat().st_mtime_ns,stamp)

    def test_legacy_zlib_payload_remains_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            module=Path(temporary)/'renderer.so';module.write_bytes(image())
            payload=Path(temporary)/'renderer.payload'
            packer.compress(module,payload)
            raw=payload.read_bytes();values=packer.HEADER.unpack_from(raw)
            self.assertEqual(values[-1],0)
            self.assertEqual(zlib.decompress(raw[40:]),image())

    def test_invalid_elf_and_size_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            module=Path(temporary)/'renderer.so';payload=Path(temporary)/'renderer.payload'
            for bad in (b'',b'not an ELF',image()[:30],image()[:16]+struct.pack('<HH',2,62)+image()[20:]):
                module.write_bytes(bad)
                with self.assertRaises(ValueError):packer.pack_module(module,payload)
            module.write_bytes(image())
            with mock.patch.object(packer,'MAX_MODULE',80):
                with self.assertRaises(ValueError):packer.pack_module(module,payload)

    def test_raw_length_and_unknown_flags_fail_before_embedding(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);payload=folder/'renderer.payload'
            for flags,expanded in ((packer.RAW,1000),(2,len(image()))):
                payload.write_bytes(packer.HEADER.pack(packer.MAGIC,packer.ABI,40,len(image()),expanded,0,flags)+image())
                with self.assertRaises(ValueError):packer.embed(folder/'missing-binary',payload,'objcopy')

    def test_embedding_is_deterministic_and_not_allocated_at_exec(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);module=folder/'renderer.so';module.write_bytes(image())
            payload=folder/'renderer.payload';packer.pack_module(module,payload)
            binary=folder/'mdf';shutil.copy2(shutil.which('true'),binary)
            packer.embed(binary,payload,'objcopy','svg');first=binary.read_bytes()
            packer.embed(binary,payload,'objcopy','svg');self.assertEqual(binary.read_bytes(),first)
            elf=struct.unpack_from('<16sHHIQQQIHHHHHH',first)
            sections=[struct.unpack_from('<IIQQQQIIQQ',first,elf[6]+i*elf[11]) for i in range(elf[12])]
            names=sections[elf[13]];strings=first[names[4]:names[4]+names[5]]
            section=next(s for s in sections if strings[s[0]:].split(b'\0',1)[0]==b'.mdf_svg')
            self.assertEqual(section[2]&2,0)
            self.assertEqual(first[section[4]:section[4]+section[5]],payload.read_bytes())

    def test_repacking_three_modules_preserves_the_exact_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);source=folder/'raw';shutil.copy2(shutil.which('true'),source)
            for kind in packer.SECTIONS:
                library=folder/(kind+'.so');library.write_bytes(image()+kind.encode()*64)
                payload=folder/(kind+'.payload');packer.pack_module(library,payload)
                packer.embed(source,payload,'objcopy',kind)
            compressed=folder/'compressed';restored=folder/'restored'
            repacker.repack(source,compressed,'zlib')
            repacker.repack(compressed,restored,'raw')
            a,b,c=map(repacker.profile.elf_file,(source,compressed,restored))
            self.assertEqual(repacker.allocated(a),repacker.allocated(b))
            self.assertEqual(repacker.allocated(a),repacker.allocated(c))
            for kind in packer.SECTIONS:
                self.assertEqual(repacker.decode(a,kind),repacker.decode(b,kind))
                self.assertEqual(repacker.decode(a,kind),repacker.decode(c,kind))
            self.assertLess(compressed.stat().st_size,source.stat().st_size)

    def test_repacking_does_not_publish_missing_or_corrupt_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);source=folder/'source';output=folder/'output'
            shutil.copy2(shutil.which('true'),source);output.write_bytes(b'keep existing output')
            with self.assertRaisesRegex(ValueError,'Missing optional module'):
                repacker.repack(source,output,'zlib')
            self.assertEqual(output.read_bytes(),b'keep existing output')
            for kind in packer.SECTIONS:
                library=folder/(kind+'.so');library.write_bytes(image())
                payload=folder/(kind+'.payload');packer.pack_module(library,payload)
                data=bytearray(payload.read_bytes());data[32:36]=bytes(4);payload.write_bytes(data)
                packer.embed(source,payload,'objcopy',kind)
            with self.assertRaisesRegex(ValueError,'checksum'):
                repacker.repack(source,output,'zlib')
            self.assertEqual(output.read_bytes(),b'keep existing output')


if __name__=='__main__':unittest.main()
