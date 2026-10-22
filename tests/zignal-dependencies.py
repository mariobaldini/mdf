#!/usr/bin/env python3
"""Check the image module pin, license, decoder boundary and source adapter."""
from pathlib import Path
import configparser
import json
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
record = json.loads((root/'frontend/dependencies.json').read_text())['zignal']
modules = configparser.ConfigParser();modules.read(root/'.gitmodules')
entry = modules['submodule "modules/zignal"']
assert entry['url'] == record['url'] and entry['path'] == 'modules/zignal'
def git(*args):return subprocess.check_output(['git',*args],cwd=root,text=True).strip()
mode,commit,stage,path = git('ls-files','--stage',entry['path']).split()
assert mode == '160000' and commit == record['commit']
assert git('-C',path,'rev-parse','HEAD') == commit
assert not git('-C',path,'diff','--name-only','HEAD'), 'Keep the pinned Zignal sources pristine'
assert record['license'] == 'MIT'
version=re.search(r'\.version\s*=\s*"([^"]+)"',(root/path/'build.zig.zon').read_text()).group(1)
assert version == record['version']
assert f'metrics.set("image_decoder_version", "{version}");' in (root/'frontend/main.cpp').read_text()
assert (root/path/'LICENSE').read_text().strip() in (root/'assets/NOTICE.txt').read_text()
assert not (root/'frontend/image-pixels.c').exists()
assert '@import("zignal")' in (root/'frontend/image-pixels.zig').read_text()
source=root/path/'src/codecs/png.zig'
with tempfile.TemporaryDirectory() as directory:
    out=Path(directory)/'png.zig'
    subprocess.run(['python3',str(root/'scripts/prepare-zignal.py'),str(source),str(out)],check=True)
    first=out.read_bytes()
    subprocess.run(['python3',str(root/'scripts/prepare-zignal.py'),str(source),str(out)],check=True)
    assert first == out.read_bytes()
    # An upstream edit at either corrected branch must stop, not guess.
    changed=Path(directory)/'changed.zig'
    changed.write_text(source.read_text().replace('if (png_state.transparency != null) {','if (true) {'))
    failed=subprocess.run(['python3',str(root/'scripts/prepare-zignal.py'),str(changed),str(out)],capture_output=True,text=True)
    assert failed.returncode and 'source changed' in failed.stderr
print('PASS: pinned pristine Zignal, MIT notice, Zig decoder boundary and checked PNG compatibility fixes')
