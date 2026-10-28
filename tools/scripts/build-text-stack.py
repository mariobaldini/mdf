#!/usr/bin/env python3
"""Build the pinned Cairo/Fontconfig Pango subset without network access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]

def build(directory, mode):
    manifest = json.loads((ROOT/'frontend/dependencies.json').read_text())
    environment = {**os.environ, 'PYTHONPATH': str(ROOT/'zig-pkg/meson'),
                   'CC': os.environ.get('MDF_CC', '/usr/bin/gcc'),
                   'CXX': os.environ.get('MDF_CXX', '/usr/bin/g++')}
    arguments = ['--default-library=static', '--wrap-mode=nodownload', '-Db_staticpic=true',
                 '-Dintrospection=disabled', '-Ddocumentation=false', '-Dman-pages=false',
                 '-Dbuild-testsuite=false', '-Dbuild-examples=false', '-Dxft=disabled',
                 '-Dsysprof=disabled', '-Dcairo=enabled', '-Dfreetype=enabled', '-Dfontconfig=enabled',
                 '-Dlibthai=disabled', '--buildtype='+('release' if mode=='ReleaseFast' else 'debug'),
                 '-Db_lto='+('true' if mode=='ReleaseFast' else 'false'),
                 '-Dc_args=-march=x86-64 -ffunction-sections -fdata-sections']
    identity = hashlib.sha256(json.dumps([manifest['pango'], manifest['meson'], arguments,
        environment['CC'], environment['CXX'], subprocess.check_output([environment['CC'],'--version'],text=True)],sort_keys=True).encode()).hexdigest()
    marker = directory/'.mdf-build-id'
    if directory.exists() and (not marker.exists() or marker.read_text().strip()!=identity):
        shutil.rmtree(directory)
    if not marker.exists():
        subprocess.run([sys.executable, '-m', 'mesonbuild.mesonmain', 'setup', str(directory),
                        str(ROOT/'zig-pkg/pango'), *arguments], env=environment, check=True)
        marker.write_text(identity+'\n')
    subprocess.run(['ninja','-C',str(directory),'-j'+os.environ.get('MDF_BUILD_JOBS','2'),
                    'pango/libpango-1.0.a','pango/libpangoft2-1.0.a','pango/libpangocairo-1.0.a'],env=environment,check=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, required=True)
    parser.add_argument('--mode', choices=['Debug','ReleaseFast'], required=True)
    args=parser.parse_args()
    build(args.build_dir.resolve(), args.mode)
