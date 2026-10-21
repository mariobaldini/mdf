#!/usr/bin/env python3
"""Check pinned renderer identities, notices, and the Rust-free build path."""
import configparser
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
record = json.loads((ROOT / 'frontend/dependencies.json').read_text())['pozeiden']
modules = configparser.ConfigParser()
modules.read(ROOT / '.gitmodules')
entry = modules['submodule "modules/pozeiden"']
assert entry['path'] == 'modules/pozeiden' and entry['url'] == record['url']

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()

mode, commit, _stage, path = git('ls-files', '--stage', 'modules/pozeiden').split()
assert mode == '160000' and commit == record['commit'] and path == entry['path']
assert git('-C', entry['path'], 'rev-parse', 'HEAD') == commit
assert not git('-C', entry['path'], 'diff', '--name-only', 'HEAD'), 'Keep the upstream submodule unchanged'
assert record['license'] == 'PolyForm-Noncommercial-1.0.0'
notices = (ROOT / 'assets/MERMAID-NOTICE.txt').read_text()
license_text = (ROOT / entry['path'] / 'LICENSE').read_text().strip()
assert license_text in notices and 'Required Notice:' in license_text
assert f"Pozeiden {record['version']}" in notices

svg_record = json.loads((ROOT / 'frontend/dependencies.json').read_text())['zig_svg']
svg_entry = modules['submodule "modules/zig-svg"']
mode,commit,_stage,path = git('ls-files','--stage','modules/zig-svg').split()
assert mode == '160000' and commit == svg_record['commit'] and path == svg_entry['path']
assert git('-C',path,'rev-parse','HEAD') == commit
assert not git('-C',path,'diff','--name-only','HEAD')
assert svg_entry['url'] == svg_record['url'] and svg_record['license'] == 'MIT'
assert (ROOT/path/'LICENSES/MIT.txt').read_text().strip() in notices
assert (ROOT/'assets/licenses/z2d-MPL-2.0.txt').read_text().strip() in notices
assert not list((ROOT/'frontend').rglob('Cargo.*'))
assert not list((ROOT/'frontend').rglob('*.rs'))
assert (ROOT/'frontend/svg.zig').is_file()
assert not (ROOT / 'frontend/mermaid').exists(), 'Remove the legacy Rust Mermaid adapter'
print('PASS: pinned pristine Pozeiden/zig-svg submodules, complete notices, and Rust-free renderer sources')
