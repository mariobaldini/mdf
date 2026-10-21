#!/usr/bin/env python3
"""Append the uncompressed UI engine; its ELF section is never mapped at exec."""
import argparse
import os
from pathlib import Path
import struct
import re
import subprocess
import tempfile

SECTION = '.mdf_ui'
MAX_MODULE = 256*1024*1024

def embed(binary, module, objcopy='objcopy'):
    data=module.read_bytes()
    if not (64<=len(data)<=MAX_MODULE and data[:6]==b'\x7fELF\x02\x01' and struct.unpack_from('<HH',data,16)==(3,62)):
        raise ValueError('Expected a bounded x86-64 shared UI engine')
    # Raw ELF avoids a decompression pass on the first-viewport path. The
    # loader validates its ABI after dlopen; installation remains one file.
    with tempfile.TemporaryDirectory(prefix='.ui-pack-',dir=binary.parent) as directory:
        base,final=Path(directory)/'base',Path(directory)/'final'
        dependencies=Path(directory)/'dependencies'
        dynamic=subprocess.check_output(['readelf','-W','-d',str(module)],text=True)
        names=re.findall(r'\(NEEDED\).*?\[([^\]]+)\]',dynamic)
        dependencies.write_bytes(b''.join(name.encode()+b'\0' for name in dict.fromkeys(names)))
        subprocess.run([objcopy,'--remove-section='+SECTION,'--remove-section=.mdf_ui_deps',str(binary),str(base)],check=True)
        subprocess.run([objcopy,'--add-section='+SECTION+'='+str(module),
                        '--set-section-flags='+SECTION+'=readonly,contents',
                        '--add-section=.mdf_ui_deps='+str(dependencies),
                        '--set-section-flags=.mdf_ui_deps=readonly,contents',str(base),str(final)],check=True)
        final.chmod(binary.stat().st_mode & 0o777)
        os.replace(final,binary)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--module',type=Path,required=True)
    parser.add_argument('--objcopy',default='objcopy')
    args=parser.parse_args()
    embed(args.binary,args.module,args.objcopy)
