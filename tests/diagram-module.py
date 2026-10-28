#!/usr/bin/env python3
"""Exercise the actual embedded-module loader, including damaged executables."""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result
profile = module('mdf_profile', ROOT/'tools/scripts/profile.py')
packer = module('mdf_packer', ROOT/'tools/scripts/pack-diagram.py')


def inspect(binary, kind):
    image = profile.elf_file(binary)
    section = next(s for s in image['sections'] if s['name'] == packer.SECTIONS[kind])
    assert not section['flags'] & 2, 'Lazy payload must not have SHF_ALLOC'
    payload = image['data'][section['offset']:section['offset']+section['bytes']]
    magic, abi, header, packed, expanded, checksum, flags = packer.HEADER.unpack_from(payload)
    assert magic == packer.MAGIC and abi == packer.ABI and header == 40 and flags in (0,packer.RAW)
    assert packed == len(payload)-header
    decoded = payload[header:] if flags==packer.RAW else zlib.decompress(payload[header:])
    assert len(decoded) == expanded and zlib.crc32(decoded) == checksum
    return image, section, decoded


def check_module(binary, kind):
    image, section, expanded = inspect(binary, kind)
    raw=packer.HEADER.unpack_from(image['data'],section['offset'])[-1]==packer.RAW
    with tempfile.TemporaryDirectory(prefix='mdf-module-') as directory:
        temp = Path(directory)
        pristine = temp/'mdf-image-tests'
        shutil.copy2(binary, pristine)
        def probe(path, expected=None):
            run = subprocess.run([str(path), '--module-probe-'+kind], cwd=temp, capture_output=True, text=True, timeout=15)
            if expected is None:
                assert run.returncode == 0, run.stderr
            else:
                assert run.returncode != 0 and expected.lower() in run.stderr.lower(), run.stderr
        # Only the executable is present; no source fonts, module or extractor
        # is found relative to cwd. Built-in font views cross the private ABI.
        probe(pristine)
        assert sorted(p.name for p in temp.iterdir()) == [pristine.name]
        cases = [('bad-version', 8, struct.pack('<I', 999), 'version'),
                 ('bad-size', 24, struct.pack('<Q', 2**63), 'size'),
                 ('bad-checksum', 32, struct.pack('<I', 0), 'checksum'),
                 ('bad-stream', 40, b'\x00\x00', 'checksum' if raw else 'compressed'),
                 ('bad-flags',36,struct.pack('<I',2),'version')]
        if raw: cases.append(('bad-raw-length',24,struct.pack('<Q',len(expanded)+1),'size'))
        for name, relative, change, error in cases:
            data = bytearray(image['data']);at=section['offset']+relative
            data[at:at+len(change)] = change
            damaged = temp/name;damaged.write_bytes(data);damaged.chmod(0o755)
            probe(damaged, error)
        missing = temp/'missing'
        subprocess.run(['objcopy', '--remove-section='+packer.SECTIONS[kind], str(pristine), str(missing)], check=True)
        probe(missing, 'missing')
        other = 'svg' if kind == 'mermaid' else 'mermaid'
        independent = subprocess.run([str(missing),'--module-probe-'+other],cwd=temp,capture_output=True,text=True)
        assert independent.returncode == 0, independent.stderr
        (temp/'module.so').write_bytes(expanded)
        symbols = subprocess.check_output(['nm','-D','--defined-only',str(temp/'module.so')], text=True)
        entry='mdf_image_api' if kind=='image' else 'mdf_diagram_api'
        api_type='MdfImageApi' if kind=='image' else 'MdfDiagramApi'
        assert [line.split()[-1] for line in symbols.splitlines()] == [entry], symbols
        # A valid ELF and payload can still expose an incompatible function
        # table. The loader must reject it before calling initialization.
        (temp/'bad-api.c').write_text('#include "frontend/mermaid.h"\n'
            f'const struct {api_type} *{entry}(uint32_t abi) {{\n'
            f' static const struct {api_type} api={{.abi=999,.size=sizeof(struct {api_type})}}; return &api; }}\n')
        env = {**os.environ,'CCACHE_DISABLE':'1','CCACHE_DIR':str(temp/'ccache')}
        subprocess.run(['/usr/bin/gcc','-shared','-fPIC','-I',str(ROOT),str(temp/'bad-api.c'),'-o',str(temp/'bad-api.so')], check=True,env=env)
        packer.pack_module(temp/'bad-api.so',temp/'bad-api.payload')
        wrong = temp/'bad-api';shutil.copy2(pristine,wrong)
        packer.embed(wrong,temp/'bad-api.payload','objcopy',kind);probe(wrong,'ABI mismatch')
        # Repacking is deterministic and does not add a second payload.
        packer.pack_module(temp/'module.so',temp/'module.payload')
        packer.embed(pristine,temp/'module.payload','objcopy',kind);first=pristine.read_bytes()
        packer.embed(pristine,temp/'module.payload','objcopy',kind);assert pristine.read_bytes()==first
        inspect(pristine,kind);probe(pristine)
        # Older compressed resources remain readable, but are not emitted by
        # the production renderer packer. Exercise their checksum/error path.
        packer.compress(temp/'module.so',temp/'legacy.payload')
        legacy=temp/'legacy';shutil.copy2(pristine,legacy)
        packer.embed(legacy,temp/'legacy.payload','objcopy',kind);probe(legacy)
        old,old_section,_=inspect(legacy,kind)
        damaged=bytearray(old['data']);damaged[old_section['offset']+40]=0
        bad_legacy=temp/'legacy-bad';bad_legacy.write_bytes(damaged);bad_legacy.chmod(0o755)
        probe(bad_legacy,'compressed')
    print(f'PASS: independent {kind} module, private ABI, exact sizes/checksum, memory-only loading, corruption errors and deterministic repacking')


def main():
    binary = Path(sys.argv[1]).resolve()
    for kind in packer.SECTIONS:
        check_module(binary, kind)
    image = binary.read_bytes()
    with tempfile.TemporaryDirectory(prefix='mdf-optional-fonts-') as directory:
        temp = Path(directory)
        for mode in ('none','2','3','23'):
            run = subprocess.run([str(binary),'--font-probe-'+mode],cwd=temp,capture_output=True,text=True)
            assert run.returncode == 0, run.stderr
        for style, name in [('2','Italic'),('3','BoldItalic')]:
            raw = (ROOT/f'assets/fonts/open-sans/OpenSans-{name}.ttf').read_bytes()
            payload = struct.pack('<8sII',b'MDFONT1\0',len(raw),zlib.crc32(raw))+zlib.compress(raw,9)
            at = image.find(payload)
            assert at >= 0 and raw not in image, f'Expected only compressed {name} data'
            damaged = bytearray(image);damaged[at+12:at+16]=b'\0'*4
            target = temp/name;target.write_bytes(damaged);target.chmod(0o755)
            skip = subprocess.run([str(target),'--font-probe-none'],cwd=temp,capture_output=True,text=True)
            assert skip.returncode == 0, skip.stderr
            need = subprocess.run([str(target),'--font-probe-'+style],cwd=temp,capture_output=True,text=True)
            assert need.returncode != 0 and 'Corrupt compressed bundled font' in need.stderr, need.stderr
    print('PASS: italic faces are independently compressed, cached, skipped when unused, and validated on demand')


if __name__ == '__main__':
    main()
