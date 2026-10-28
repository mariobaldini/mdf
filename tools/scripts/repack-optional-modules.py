#!/usr/bin/env python3
"""Change optional payload storage without recompiling executable code."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


packer = module('mdf_packer', ROOT/'tools/scripts/pack-diagram.py')
profile = module('mdf_profile', ROOT/'tools/scripts/profile.py')


def allocated(image):
    return [(s['name'], s['address'], s['bytes'], s['flags'],
             image['data'][s['offset']:s['offset']+s['bytes']] if s['type'] != 8 else b'')
            for s in image['sections'] if s['flags'] & 2]


def decode(image, kind):
    section = next((s for s in image['sections'] if s['name'] == packer.SECTIONS[kind]), None)
    if section is None:
        raise ValueError('Missing optional module: '+kind)
    info = profile.renderer_payload_info(image, section)
    if info is None:
        raise ValueError('Invalid optional module: '+kind)
    start = section['offset']+info['header_bytes']
    data = image['data'][start:start+info['packed_bytes']]
    if info['codec'] == 'zlib':
        inflater = zlib.decompressobj()
        data = inflater.decompress(data, info['expanded_bytes']+1)
        if not inflater.eof or inflater.unused_data or inflater.unconsumed_tail:
            raise ValueError('Invalid compressed module stream: '+kind)
    checksum = struct.unpack_from('<I', image['data'], section['offset']+32)[0]
    if len(data) != info['expanded_bytes'] or zlib.crc32(data) != checksum:
        raise ValueError('Module checksum/length mismatch: '+kind)
    return data


def repack(source, output, compression, objcopy='objcopy'):
    original = profile.elf_file(source)
    decoded = {kind: decode(original, kind) for kind in packer.SECTIONS}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.module-pack-', dir=output.parent) as temporary:
        folder = Path(temporary)
        pending = folder/'mdf'
        shutil.copy2(source, pending)
        for kind, data in decoded.items():
            library = folder/(kind+'.so'); library.write_bytes(data)
            payload = folder/(kind+'.payload')
            packer.pack_module(library, payload, compressed=compression=='zlib')
            packer.embed(pending, payload, objcopy, kind)
        result = profile.elf_file(pending)
        if allocated(result) != allocated(original):
            raise ValueError('Repacking changed allocated executable code or data')
        for name in ('.mdf_ui', '.mdf_ui_deps'):
            def content(image):
                section = next((s for s in image['sections'] if s['name']==name), None)
                return image['data'][section['offset']:section['offset']+section['bytes']] if section else None
            if content(result) != content(original):
                raise ValueError('Repacking changed the UI engine or dependencies')
        for kind, data in decoded.items():
            if decode(result,kind) != data:
                raise ValueError('Repacking changed module code: '+kind)
        os.replace(pending, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--compression', choices=('raw','zlib'), required=True)
    args = parser.parse_args()
    repack(args.input.resolve(), args.output.resolve(), args.compression)
    print(f'{args.compression}: {args.output.stat().st_size:,} bytes: {args.output}')


if __name__ == '__main__':
    main()
