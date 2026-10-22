#!/usr/bin/env python3
"""Pack the standard entity data without per-entry pointer relocations."""
from pathlib import Path
import struct
import sys

entries=[]
for line in Path(sys.argv[1]).read_text().splitlines():
    if not line or line.startswith('#'):continue
    name,first,second=line.split('\t')
    value=chr(int(first))+(chr(int(second)) if int(second) else '')
    entries.append((name.encode('ascii'),value.encode('utf-8')))
entries.sort()
assert len(entries)==2125 and len({name for name,_ in entries})==len(entries)
names=bytearray();values=bytearray();indices=bytearray();known={}
for name,value in entries:
    at=known.get(value)
    if at is None:at=len(values);known[value]=at;values.extend(value)
    assert len(names)<65536 and at<65536 and len(name)<256 and len(value)<=8
    indices.extend(struct.pack('<HHBB',len(names),at,len(name),len(value)))
    names.extend(name)
Path(sys.argv[2]).write_bytes(struct.pack('<III',len(entries),len(names),len(values))+indices+names+values)
