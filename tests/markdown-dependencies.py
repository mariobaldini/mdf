#!/usr/bin/env python3
"""Check parser pins, licenses, generated adapters and the C-free boundary."""
from pathlib import Path
import configparser
import hashlib
import json
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
records=json.loads((root/'frontend/dependencies.json').read_text())
modules=configparser.ConfigParser();modules.read(root/'.gitmodules')
for name in ['zigmark','mecha']:
    record=records[name];path='modules/'+name
    entry=modules[f'submodule "{path}"']
    assert entry['path']==path and entry['url']==record['url']
    mode,commit,stage,index_path=subprocess.check_output(['git','ls-files','--stage',path],cwd=root,text=True).split()
    assert mode=='160000' and commit==record['commit']
    assert subprocess.check_output(['git','-C',path,'rev-parse','HEAD'],cwd=root,text=True).strip()==commit
    assert not subprocess.check_output(['git','-C',path,'diff','--name-only','HEAD'],cwd=root,text=True).strip()
    assert (root/path/'LICENSE').read_text().strip() in (root/'assets/NOTICE.txt').read_text()
assert '.md4c =' not in (root/'build.zig.zon').read_text()
assert '#include <md4c.h>' not in (root/'src/native.h').read_text()
assert 'c.md_parse' not in (root/'src/document.zig').read_text()
assert 'b.dependency("md4c"' not in (root/'frontend/core-build.zig').read_text()
patches=sorted((root/'frontend/patches/zigmark').glob('*.patch'))
with tempfile.TemporaryDirectory() as directory:
    output=Path(directory)/'generated'
    command=['python3',str(root/'scripts/prepare-zigmark.py'),str(root/'modules/zigmark/src'),str(output),*[str(p) for p in patches]]
    subprocess.run(command,check=True)
    def digest():return {str(p.relative_to(output)):hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob('*') if p.is_file()}
    first=digest();subprocess.run(command,check=True);assert digest()==first
    assert 'std.heap.page_allocator' not in (output/'markdown/parser.zig').read_text()
print('PASS: pinned pristine Zigmark/Mecha, notices, deterministic adapters and no MD4C runtime dependency')
