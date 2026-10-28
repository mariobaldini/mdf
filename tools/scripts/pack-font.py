#!/usr/bin/env python3
"""Create one deterministic zlib resource for one optional bundled font."""
from pathlib import Path
import struct
import sys
import zlib


def pack(source, output):
    raw = source.read_bytes()
    if not 12 <= len(raw) <= 16 * 1024 * 1024 or raw[:4] not in (b'\0\1\0\0', b'OTTO'):
        raise ValueError('Expected a bounded TrueType/OpenType font')
    payload = struct.pack('<8sII', b'MDFONT1\0', len(raw), zlib.crc32(raw)) + zlib.compress(raw, 9)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(payload)


if __name__ == '__main__':
    pack(Path(sys.argv[1]), Path(sys.argv[2]))
