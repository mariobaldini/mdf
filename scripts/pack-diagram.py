#!/usr/bin/env python3
"""Compress the private renderer and append it to a non-allocated ELF section."""
import argparse
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

SECTIONS = {'mermaid': '.mdf_mermaid', 'svg': '.mdf_svg'}
SECTION = SECTIONS['mermaid']
HEADER = struct.Struct('<8sIIQQII')
MAGIC = b'MDFDG01\0'
ABI = 2
MAX_MODULE = 256 * 1024 * 1024


def compress(module, destination):
    image = module.read_bytes()
    if (len(image) < 64 or image[:6] != b'\x7fELF\x02\x01' or
            struct.unpack_from('<HH', image, 16) != (3, 62) or len(image) > MAX_MODULE):
        raise ValueError('Expected a bounded x86-64 ELF shared module')
    packed = zlib.compress(image, 9)
    payload = HEADER.pack(MAGIC, ABI, HEADER.size, len(packed), len(image), zlib.crc32(image), 0) + packed
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.is_file() or destination.read_bytes() != payload:
        destination.write_bytes(payload)


def embed(binary, payload, objcopy, kind='mermaid'):
    section = SECTIONS[kind]
    data = payload.read_bytes()
    if len(data) < HEADER.size:
        raise ValueError('Truncated diagram payload')
    magic, abi, size, packed, expanded, checksum, flags = HEADER.unpack_from(data)
    if (magic != MAGIC or abi != ABI or size != HEADER.size or packed != len(data)-size or
            not 0 < expanded <= MAX_MODULE or flags):
        raise ValueError('Invalid diagram payload metadata')
    # Atomic replacement preserves the inode used by any already-running app.
    # Section flags deliberately omit ALLOC: neither the loader nor our startup
    # path maps this payload. /proc/self/exe is read only upon the first job.
    with tempfile.TemporaryDirectory(prefix='.diagram-pack-', dir=binary.parent) as temp:
        base, final = Path(temp)/'host', Path(temp)/'packed'
        subprocess.run([objcopy, '--remove-section='+section, str(binary), str(base)], check=True)
        subprocess.run([objcopy, '--add-section='+section+'='+str(payload),
                        '--set-section-flags='+section+'=readonly,contents', str(base), str(final)], check=True)
        final.chmod(binary.stat().st_mode & 0o777)
        os.replace(final, binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pack = sub.add_parser('compress')
    pack.add_argument('--module', type=Path, required=True)
    pack.add_argument('--output', type=Path, required=True)
    add = sub.add_parser('embed')
    add.add_argument('--binary', type=Path, required=True)
    add.add_argument('--payload', type=Path, required=True)
    add.add_argument('--objcopy', default='objcopy')
    add.add_argument('--kind', choices=SECTIONS, required=True)
    args = parser.parse_args()
    if args.command == 'compress':
        compress(args.module, args.output)
    else:
        embed(args.binary, args.payload, args.objcopy, args.kind)


if __name__ == '__main__':
    main()
