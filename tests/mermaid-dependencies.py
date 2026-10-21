#!/usr/bin/env python3
"""Check the vendored renderer identity, notices, and Zig/Rust boundary."""
import configparser
import json
from pathlib import Path
import subprocess
import tomllib

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

manifest = tomllib.loads((ROOT / 'frontend/svg/Cargo.toml').read_text())
assert manifest['package']['name'] == 'mdf-svg'
assert set(manifest['dependencies']) == {'resvg', 'roxmltree'}
packages = tomllib.loads((ROOT / 'frontend/svg/Cargo.lock').read_text())['package']
assert not any('mermaid' in package['name'] for package in packages)
assert not (ROOT / 'frontend/mermaid').exists(), 'Remove the legacy Rust Mermaid adapter'
print('PASS: pinned clean Pozeiden submodule, noncommercial notice, and SVG-only Rust dependencies')
