#!/usr/bin/env bash
# Inspect and run extracted release bundles without installing system packages.
set -euo pipefail
mdf_test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$mdf_test_root"
mdf_version=$(build/mdf --version)
mdf_version=${mdf_version#mdf }
mdf_rpm="$mdf_test_root/build/mdf-$mdf_version-1.x86_64.rpm"
mdf_deb="$mdf_test_root/build/mdf_${mdf_version}_amd64.deb"
mdf_scratch=$(mktemp -d)
trap 'rm -rf "$mdf_scratch"' EXIT
(cd build && sha256sum --check mdf.sha256)
python3 - <<'PY'
import importlib.util,re,subprocess,tempfile,zlib,struct
from pathlib import Path
versions = re.findall(r'GLIBC_([0-9.]+)', subprocess.check_output(['readelf', '--version-info', 'build/mdf'], text=True))
maximum = max(tuple(map(int, version.split('.'))) for version in versions)
assert maximum <= (2, 38), f'Executable needs glibc {maximum}; installer/packages promise 2.38'
print('PASS: executable GLIBC symbol requirements stay within the declared 2.38 minimum')
spec=importlib.util.spec_from_file_location('mdf_profile','scripts/profile.py')
profile=importlib.util.module_from_spec(spec);spec.loader.exec_module(profile)
image=profile.elf_file(Path('build/mdf'))
ui=next(s for s in image['sections'] if s['name']=='.mdf_ui')
assert not ui['flags'] & 2
with tempfile.NamedTemporaryFile(suffix='.so') as file:
    file.write(image['data'][ui['offset']:ui['offset']+ui['bytes']]);file.flush()
    versions=re.findall(r'GLIBC_([0-9.]+)',subprocess.check_output(['readelf','--version-info',file.name],text=True))
    assert max(tuple(map(int,v.split('.'))) for v in versions)<=(2,38)
    symbols=subprocess.check_output(['nm','-D','--defined-only',file.name],text=True)
    assert [line.split()[-1] for line in symbols.splitlines()]==['mdf_frontend_api']
print('PASS: private embedded UI engine stays within the declared glibc 2.38 minimum')
for name in ('.mdf_mermaid','.mdf_svg'):
    section=next(s for s in image['sections'] if s['name']==name)
    assert not section['flags'] & 2
    magic,abi,header,packed,expanded,checksum,flags=struct.unpack_from('<8sIIQQII',image['data'],section['offset'])
    assert magic==b'MDFDG01\0' and abi==2 and header==40 and packed==section['bytes']-40 and flags==0
    module=zlib.decompress(image['data'][section['offset']+header:section['offset']+section['bytes']])
    assert len(module)==expanded and zlib.crc32(module)==checksum
    with tempfile.NamedTemporaryFile(suffix='.so') as file:
        file.write(module);file.flush()
        versions=re.findall(r'GLIBC_([0-9.]+)',subprocess.check_output(['readelf','--version-info',file.name],text=True))
        assert max(tuple(map(int,v.split('.'))) for v in versions)<=(2,38)
        symbols=subprocess.check_output(['nm','-D','--defined-only',file.name],text=True)
        assert [line.split()[-1] for line in symbols.splitlines()]==['mdf_diagram_api']
print('PASS: both independent payloads, private ABIs, and GLIBC requirements stay within glibc 2.38')
PY
test "$(rpm -qp --queryformat '%{NAME} %{VERSION} %{ARCH}' "$mdf_rpm")" = "mdf $mdf_version x86_64"
test "$(dpkg-deb --field "$mdf_deb" Package)" = mdf
test "$(dpkg-deb --field "$mdf_deb" Version)" = "$mdf_version"
test "$(dpkg-deb --field "$mdf_deb" Architecture)" = amd64
mkdir -p "$mdf_scratch/rpm" "$mdf_scratch/deb"
(cd "$mdf_scratch/rpm" && rpm2cpio "$mdf_rpm" | cpio --extract --make-directories --no-absolute-filenames --no-preserve-owner --quiet)
dpkg-deb --extract "$mdf_deb" "$mdf_scratch/deb"
for mdf_format in rpm deb; do
    mdf_bundle="$mdf_scratch/$mdf_format"
    test "$(find "$mdf_bundle/usr" -type f | wc -l)" -eq 1
    test ! -L "$mdf_bundle/usr/bin/mdf"
    test ! -e "$mdf_bundle/usr/libexec/mdf"
    cmp build/mdf "$mdf_bundle/usr/bin/mdf"
    test "$("$mdf_bundle/usr/bin/mdf" --version)" = "mdf $mdf_version"
    printf 'PASS: %s package metadata, single executable at /usr/bin/mdf, exact bytes, and version\n' "$mdf_format"
done
