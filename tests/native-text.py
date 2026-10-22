#!/usr/bin/env python3
"""Check deferred FT2 text through the actual packed executable and loader."""
import importlib.util
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def main():
    prefix = Path(sys.argv[1]).resolve()
    binary = prefix/'bin/mdf-native-window'
    library = prefix/'lib/libmdf-native-text.so'
    for target in (binary, library):
        dependencies = subprocess.check_output(['ldd', str(target)], text=True)
        assert not any(name in dependencies for name in ('fltk', 'libcairo', 'pangocairo', 'libstdc++')), dependencies
    executable_deps = subprocess.check_output(['ldd', str(binary)], text=True)
    assert not any(name in executable_deps for name in ('pango', 'fontconfig', 'freetype', 'harfbuzz')), executable_deps
    symbols = subprocess.check_output(['nm', '-D', '--defined-only', str(library)], text=True)
    entry = ctypes.CDLL(str(library)).mdf_text_api
    entry.argtypes = [ctypes.c_uint32]; entry.restype = ctypes.c_void_p
    assert not entry(1) and entry(2), 'Text ABI change accepted the old function table'
    assert [line.split()[-1] for line in symbols.splitlines()] == ['mdf_text_api'], symbols
    versions = subprocess.check_output(['readelf', '--version-info', str(library)], text=True)
    assert all(tuple(map(int, version.split('.'))) <= (2, 38) for version in re.findall(r'GLIBC_([0-9.]+)', versions)), versions
    profile = load('mdf_profile_for_text', ROOT/'scripts/profile.py')
    packing = load('mdf_native_text_packer', ROOT/'scripts/pack-native.py').packer
    elf = profile.elf_file(binary)
    section = next(row for row in elf['sections'] if row['name'] == '.mdf_text')
    assert not section['flags'] & 2
    payload = elf['data'][section['offset']:section['offset']+section['bytes']]
    magic, abi, header, packed, expanded, checksum, flags = packing.HEADER.unpack_from(payload)
    decoded = zlib.decompress(payload[header:])
    assert magic == packing.MAGIC and abi == packing.ABI and header == 40 and flags == 0
    assert packed == len(payload)-header and expanded == len(decoded) and zlib.crc32(decoded) == checksum
    output = ROOT/'build/native-text-tests'
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='run-', dir=output) as directory:
        work = Path(directory)
        target = work/'mdf'
        shutil.copy2(binary, target)
        def probe(path, expected=None):
            result = subprocess.run([str(path), '--text-probe', str(work/'text.png')], cwd=work, capture_output=True, text=True, timeout=25)
            if expected is not None:
                assert result.returncode != 0 and expected.lower() in result.stderr.lower(), result.stderr
                return None
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)
        result = probe(target)
        assert sorted(item.name for item in work.iterdir()) == ['mdf', 'text.png'], 'Text support wrote extra files'
        shutil.copy2(work/'text.png', output/'text.png')
        (output/'result.json').write_text(json.dumps(result, indent=2)+'\n')
        independent = work/'independent'
        subprocess.run(['objcopy', '--remove-section=.mdf_svg', '--remove-section=.mdf_mermaid', str(target), str(independent)], check=True)
        probe(independent)
        for name, relative, data, expected in [
            ('bad-version', 8, struct.pack('<I', 999), 'version'),
            ('bad-size', 24, struct.pack('<Q', 2**63), 'size'),
            ('bad-checksum', 32, struct.pack('<I', 0), 'checksum'),
            ('bad-stream', 40, b'\x00\x00', 'compressed'),
        ]:
            content = bytearray(elf['data']); at = section['offset']+relative
            content[at:at+len(data)] = data
            damaged = work/name; damaged.write_bytes(content); damaged.chmod(0o755)
            probe(damaged, expected)
        missing = work/'missing'
        subprocess.run(['objcopy', '--remove-section=.mdf_text', str(target), str(missing)], check=True)
        probe(missing, 'missing')
        bad_source = work/'bad-api.c'
        bad_source.write_text('#include "frontend/text-api.h"\nconst struct MdfTextApi *mdf_text_api(uint32_t abi) {\n'
            'static const struct MdfTextApi api={.abi=999,.size=sizeof(struct MdfTextApi)};return &api;}\n')
        subprocess.run(['/usr/bin/gcc', '-shared', '-fPIC', '-I', str(ROOT), str(bad_source), '-o', str(work/'bad-api.so')], check=True)
        packing.compress(work/'bad-api.so', work/'bad-api.payload')
        wrong = work/'bad-api'; shutil.copy2(target, wrong)
        packing.embed(wrong, work/'bad-api.payload', 'objcopy', 'text'); probe(wrong, 'ABI mismatch')
        bad_source.write_text('#include "frontend/text-api.h"\nconst struct MdfTextApi *mdf_text_api(uint32_t abi) {\n'
            'static const struct MdfTextApi api={.abi=MDF_TEXT_ABI,.size=sizeof(struct MdfTextApi),.kind=MDF_MODULE_TEXT};return &api;}\n')
        subprocess.run(['/usr/bin/gcc', '-shared', '-fPIC', '-I', str(ROOT), str(bad_source), '-o', str(work/'bad-api.so')], check=True)
        packing.compress(work/'bad-api.so', work/'bad-api.payload')
        packing.embed(wrong, work/'bad-api.payload', 'objcopy', 'text'); probe(wrong, 'ABI mismatch')
    print('PASS: deferred FT2 text, private ABI, font ownership, cancellation, no Cairo, independent packing and corrupt-module recovery')


if __name__ == '__main__':
    main()
