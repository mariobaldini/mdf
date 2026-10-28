#!/usr/bin/env python3
"""Reuse the checked independent module packer for the native executable."""
import importlib.util
from pathlib import Path
import sys
import shutil
import subprocess
import tempfile
import os

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('mdf_diagram_packer', ROOT/'tools/scripts/pack-diagram.py')
packer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packer)
packer.SECTIONS['text'] = '.mdf_text'
ui_spec=importlib.util.spec_from_file_location('mdf_ui_packer',ROOT/'tools/scripts/pack-frontend.py')
ui_packer=importlib.util.module_from_spec(ui_spec)
ui_spec.loader.exec_module(ui_packer)


def pack(binary, libraries):
    for kind in ('mermaid', 'svg', 'image', 'text'):
        payload = libraries/f'mdf-native-{kind}.payload'
        if kind == 'text':
            packer.compress(libraries/f'libmdf-native-{kind}.so', payload)
        else:
            packer.pack_module(libraries/f'libmdf-native-{kind}.so', payload,
                               compressed=os.environ.get('MDF_OPTIONAL_MODULE_COMPRESSION','zlib')=='zlib')
        packer.embed(binary, payload, 'objcopy', kind)


if __name__ == '__main__':
    prefix = Path(sys.argv[1])
    if '--application-only' not in sys.argv[2:]:
        pack(prefix/'bin/mdf-native-window', prefix/'lib')
    application=prefix/'bin/mdf-native'
    with tempfile.TemporaryDirectory(prefix='.native-pack-',dir=application.parent) as directory:
        work=Path(directory)
        host,engine=work/'mdf-native',work/'ui.so'
        host_debug,engine_debug=work/'host.debug',work/'ui.debug'
        shutil.copy2(prefix/'bin/mdf-launcher',host)
        shutil.copy2(prefix/'lib/libmdf-native-ui.so',engine)
        for binary,debug in ((host,host_debug),(engine,engine_debug)):
            subprocess.run(['objcopy','--only-keep-debug',str(binary),str(debug)],check=True)
            subprocess.run(['strip','--strip-unneeded',str(binary)],check=True)
        ui_packer.embed(host,engine)
        pack(host,prefix/'lib')
        os.replace(host_debug,application.with_name(application.name+'.debug'))
        os.replace(engine_debug,application.with_name(application.name+'-ui.debug'))
        os.replace(host,application)
