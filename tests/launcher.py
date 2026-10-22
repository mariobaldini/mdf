#!/usr/bin/env python3
"""Check the production bootstrap boundary and failures without a compositor."""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
profile=module('profile',ROOT/'scripts/profile.py')
packer=module('pack_ui',ROOT/'scripts/pack-frontend.py')

def main():
    binary=Path(sys.argv[1]).resolve()
    image=profile.elf_file(binary)
    sections={s['name']:s for s in image['sections']}
    ui=sections['.mdf_ui'];deps=sections['.mdf_ui_deps']
    assert not ui['flags'] & 2 and not deps['flags'] & 2
    sizes=profile.binary_breakdown(ROOT,binary)
    def leaves(node):return sum(leaves(child) for child in node['children']) if node.get('children') else node['bytes']
    assert leaves(sizes)==binary.stat().st_size
    assert sizes['ui_module']['bytes']==ui['bytes']
    dynamic=subprocess.check_output(['readelf','-W','-d',str(binary)],text=True)
    assert [line.split('[')[1].split(']')[0] for line in dynamic.splitlines() if '(NEEDED)' in line]==['libc.so.6']
    with tempfile.TemporaryDirectory(prefix='mdf-bootstrap-') as directory:
        temp=Path(directory)
        app=temp/'mdf';shutil.copy2(binary,app)
        engine=temp/'ui.so';engine.write_bytes(image['data'][ui['offset']:ui['offset']+ui['bytes']])
        engine.chmod(0o700)
        assert struct.unpack_from('<HH',engine.read_bytes(),16)==(3,62)
        exports=subprocess.check_output(['nm','-D','--defined-only',str(engine)],text=True)
        assert [line.split()[-1] for line in exports.splitlines()]==['mdf_frontend_api']
        host_symbols={line.split()[-1] for line in subprocess.check_output(['nm','-D','--defined-only',str(binary)],text=True).splitlines()}
        imports={line.split()[-1] for line in subprocess.check_output(['nm','-D','--undefined-only',str(engine)],text=True).splitlines()}
        assert {name for name in imports if name.startswith('mdf_')} <= host_symbols
        dependencies=subprocess.check_output(['readelf','-Wd',str(engine)],text=True)
        pango_dependencies=[line for line in dependencies.splitlines() if '(NEEDED)' in line and 'libpango' in line]
        if not pango_dependencies:
            assert not any(name.startswith(('pango_','_pango_')) for name in imports)
            assert 'libgio-2.0.so.0' in dependencies  # Real upstream GListModel support.
            print('PASS: one private bundled Pango implementation; no system Pango dependency or leaked exports')
        if 'libcairo.so.' not in dependencies:
            assert not any(name.startswith('cairo_') for name in imports)
            closure=subprocess.check_output(['ldd',str(engine)],text=True)
            assert not any(name in closure for name in ('libcairo.so.', 'libX11.so.', 'libXext.so.', 'libXrender.so.', 'libxcb', 'libXau.so.'))
            assert 'libpixman-1.so.0' in closure
            print('PASS: private minimal Cairo; no external Cairo or X11/XCB dependency')
        for flag,expected in [('--version','mdf 0.2.0'),('--help','Usage: mdf'),('--licenses','Pozeiden')]:
            run=subprocess.run([str(app),flag],cwd=temp,capture_output=True,text=True,timeout=10)
            assert run.returncode==0 and expected in run.stdout,(flag,run.stderr)
        env={**os.environ,'WAYLAND_DISPLAY':'mdf-bootstrap-unavailable'}
        env.pop('WAYLAND_SOCKET',None)
        def probe(target,expected):
            run=subprocess.run([str(target),'--profile',str(ROOT/'SAMPLE-SMALL.md')],cwd=temp,env=env,capture_output=True,text=True,timeout=15)
            assert run.returncode!=0 and expected in run.stderr,run.stderr
        missing=temp/'missing'
        subprocess.run(['objcopy','--remove-section=.mdf_ui',str(app),str(missing)],check=True)
        probe(missing,'MissingUiEngine')
        data=bytearray(image['data']);data[ui['offset']:ui['offset']+4]=b'BAD!'
        broken=temp/'broken';broken.write_bytes(data);broken.chmod(0o755)
        probe(broken,'InvalidUiEngine')
        (temp/'bad.c').write_text('#include "frontend/launch.h"\n'
            'const struct MdfFrontendApi *mdf_frontend_api(uint32_t abi) {\n'
            ' static const struct MdfFrontendApi api={.abi=999,.size=sizeof(struct MdfFrontendApi)}; return &api; }\n')
        subprocess.run(['/usr/bin/gcc','-shared','-fPIC','-I',str(ROOT),str(temp/'bad.c'),'-o',str(temp/'bad.so')],check=True)
        wrong=temp/'wrong';shutil.copy2(app,wrong);packer.embed(wrong,temp/'bad.so');probe(wrong,'UiAbiMismatch')
        # Atomic repacking retains a single UI section and exact bytes.
        packer.embed(app,engine);first=app.read_bytes();packer.embed(app,engine)
        assert app.read_bytes()==first
        assert len([s for s in profile.elf_file(app)['sections'] if s['name']=='.mdf_ui'])==1
    print('PASS: libc-only bootstrap, private UI ABI, fast CLI, missing/corrupt engine errors and deterministic single-file packing')

if __name__=='__main__':main()
