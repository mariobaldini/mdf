#!/usr/bin/env python3
"""Protect the realistic fixture workload against repeated/absent assets."""
import hashlib
import html
import importlib.util
from pathlib import Path
import re
import struct
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mdf_profile', ROOT/'tools/scripts/profile.py')
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)

small = ROOT/'assets/samples/SAMPLE.md'
text_only = ROOT/'assets/samples/SAMPLE-SMALL.md'
huge = ROOT/'assets/samples/SAMPLE-HUGE.md'
extended = ROOT/'assets/samples/SAMPLE-EXTENDED.md'


def font_characters(path):
    """Read the bundled TrueType Unicode cmap without a FontTools dependency."""
    data=path.read_bytes()
    tables=struct.unpack_from('>H',data,4)[0]
    for index in range(tables):
        tag,_,offset,_=struct.unpack_from('>4sIII',data,12+16*index)
        if tag==b'cmap':
            break
    else:
        raise AssertionError('Missing bundled font cmap: '+str(path))
    characters=set()
    for index in range(struct.unpack_from('>H',data,offset+2)[0]):
        platform,encoding,relative=struct.unpack_from('>HHI',data,offset+4+index*8)
        if platform!=0 and (platform!=3 or encoding not in (1,10)):
            continue
        at=offset+relative
        assert struct.unpack_from('>H',data,at)[0]==4, 'Update coverage reader for a changed bundled font format'
        segments=struct.unpack_from('>H',data,at+6)[0]//2
        ends=at+14;starts=ends+segments*2+2;deltas=starts+segments*2;ranges=deltas+segments*2
        for segment in range(segments):
            first=struct.unpack_from('>H',data,starts+segment*2)[0]
            last=struct.unpack_from('>H',data,ends+segment*2)[0]
            delta=struct.unpack_from('>h',data,deltas+segment*2)[0]
            address=ranges+segment*2
            relative=struct.unpack_from('>H',data,address)[0]
            for char in range(first,min(last+1,0xffff)):
                glyph=struct.unpack_from('>H',data,address+relative+(char-first)*2)[0] if relative else char
                if (not relative or glyph) and (glyph+delta)&0xffff:
                    characters.add(char)
    return characters


coverage=set.intersection(*(font_characters(path) for path in (ROOT/'assets/fonts/open-sans').glob('*.ttf')))
assert len(coverage)>400 and ord('A') in coverage and ord('中') not in coverage
for document in (text_only,small,huge):
    source=document.read_text()
    # Numeric/named entities in prose are decoded by the renderer. Checking
    # both forms prevents an ASCII entity from silently adding a fallback.
    unsupported={ord(char) for char in source+html.unescape(source)}-coverage-{9,10,13}
    assert not unsupported, (document.name, [f'U+{char:04X}' for char in sorted(unsupported)])
assert {ord('П'),ord('中'),ord('ש'),ord('😀')} <= {ord(char) for char in extended.read_text()}-coverage
assert '```zig\n' in small.read_text() and '```json\n' in small.read_text(), 'Keep fenced code in the regular sample'
print('PASS: SMALL, SAMPLE and HUGE use bundled glyphs only; EXTENDED retains non-Latin coverage')
source = text_only.read_text()
assert 1000 < text_only.stat().st_size < 6000, 'Keep the text-only sample small'
assert profile.document_workload(text_only)['image_references'] == 0
assert not re.search(r'[`~]|!\[|<\s*(?:img|svg|em|i)\b|^ {4}\S|\bmermaid\b', source, re.M | re.I), 'Keep images, diagrams, code, and italic HTML out of the text-only sample'
assert not re.search(r'(?<!\*)\*(?!\*)|_', source), 'Use only regular and bold text, without italic markers'
assert all(re.search(pattern, source, re.M) for pattern in (r'^## ', r'\*\*.+?\*\*', r'^- ', r'^1\. ', r'^\| ', r'^> ', r'\]\(')), 'Retain the basic Markdown elements'
print('PASS: SAMPLE-SMALL has regular/bold text and basic Markdown; no optional images, diagrams, italics, or code')
assert 12000 < small.stat().st_size < 25000, 'Keep the normal sample a typical document'
assert 80 < huge.stat().st_size/small.stat().st_size < 125, 'Keep the huge sample approximately 100x'
normal = profile.document_workload(small)
large = profile.document_workload(huge)
assert normal['local_images'] == normal['unique_images'] == 5, normal
assert normal['png_images'] == 3 and normal['jpeg_images'] == 2, normal
assert normal['missing_images'] == 1, 'The compact syntax test has one intentional missing image'
assert large['local_images'] == large['unique_images'] == 100, large
assert large['png_images'] == 60 and large['jpeg_images'] == 40, large
assert large['missing_images'] == 0, large
paths = [huge.parent/path for path in re.findall(r'\]\((\.\./sample-huge/[^\s)]+)', huge.read_text())]
assert len(paths) == len(set(paths)) == len({hashlib.sha256(p.read_bytes()).digest() for p in paths}) == 100
for path in [*paths, *(ROOT/'assets').glob('sample-*.jpg'), *(ROOT/'assets').glob('sample-*.png')]:
    signature = path.read_bytes()[:8]
    assert signature.startswith(b'\xff\xd8\xff') if path.suffix == '.jpg' else signature == b'\x89PNG\r\n\x1a\n', path
assert len(re.findall(r'^## Station \d{3}:', huge.read_text(), re.M)) == 100
for document, data in [(small, normal), (huge, large)]:
    print(f'PASS: {document.name}: {document.stat().st_size:,} text bytes; '
          f'{data["unique_images"]} distinct images ({data["png_images"]} PNG, {data["jpeg_images"]} JPEG); '
          f'{data["asset_bytes"]:,} asset bytes')

spec = importlib.util.spec_from_file_location('samples', ROOT/'tools/scripts/generate-profile-samples.py')
samples = importlib.util.module_from_spec(spec); spec.loader.exec_module(samples)
for size, count in [('SMALL',2),('MID',5),('HUGE',100)]:
    text = ROOT/f'assets/samples/SAMPLE-{size}-TEXT.md'; images = ROOT/f'assets/samples/SAMPLE-{size}-IMAGES.md'
    a = profile.document_workload(text); b = profile.document_workload(images)
    assert a['image_references'] == 0 and '```mermaid' not in text.read_text(), text
    assert b['local_images'] == b['unique_images'] == count+1 and b['missing_images']==0, b
    assert b['png_images']>0 and b['jpeg_images']>0 and images.read_text().count('```mermaid')==1, images
    assert samples.text_only(images.read_text()) == text.read_text(), 'The editions must share the same prose'
    for document in (text,images):
        source=document.read_text()
        unsupported={ord(char) for char in source+html.unescape(source)}-coverage-{9,10,13}
        assert not unsupported,(document,[f'U+{char:04X}' for char in sorted(unsupported)])
    print(f'PASS: {size} TEXT/IMAGES share prose; text skips visuals, images include {count} rasters, SVG and Mermaid')
