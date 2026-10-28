#!/usr/bin/env python3
"""Check the native Zig module ABI against the existing renderer test host."""
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]


def main():
    prefix = Path(sys.argv[1]).resolve()
    host = Path(sys.argv[2]).resolve()
    fixtures = Path(sys.argv[3]).resolve()
    output = ROOT/'build/native-module-tests'
    output.mkdir(exist_ok=True)
    spec = importlib.util.spec_from_file_location('mdf_native_packer', ROOT/'tools/scripts/pack-native.py')
    packer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(packer)
    for kind in ('mermaid', 'svg'):
        library = prefix/f'lib/libmdf-native-{kind}.so'
        dependencies = subprocess.check_output(['ldd', str(library)], text=True)
        assert not any(name in dependencies for name in ('fltk', 'cairo', 'pango', 'libstdc++')), dependencies
        versions = subprocess.check_output(['readelf', '--version-info', str(library)], text=True)
        required = [tuple(map(int, version.split('.'))) for version in re.findall(r'GLIBC_([0-9.]+)', versions)]
        assert all(version <= (2, 38) for version in required), versions
    target = output/'mdf-image-tests'
    shutil.copy2(host, target)
    packer.pack(target, prefix/'lib')
    subprocess.run([str(target), str(ROOT/'assets'), str(fixtures)], cwd=ROOT, check=True)
    subprocess.run([sys.executable, str(ROOT/'tests/diagram-module.py'), str(target)], cwd=ROOT, check=True)
    print('PASS: native Zig module wrappers, private exports, glibc minimum, all diagram families and damaged payload recovery')


if __name__ == '__main__':
    main()
