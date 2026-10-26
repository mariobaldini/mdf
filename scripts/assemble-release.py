#!/usr/bin/env python3
"""Verify both native build bundles and assemble the release's public assets."""
import hashlib
from pathlib import Path
import re
import shutil
import sys
import tempfile


def checksum(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def assemble(directory, tag):
    match = re.fullmatch(r'v(\d+\.\d+\.\d+)(?:-([1-9]\d*))?', tag)
    if not match:
        raise ValueError('Invalid MDF release tag')
    version, revision = match.groups()
    rpm = f'mdf-{version}-{revision or "1"}.x86_64.rpm'
    deb = f'mdf_{version}{"-" + revision if revision else ""}_amd64.deb'
    for distro in ('fedora', 'ubuntu'):
        source = directory / distro
        manifest = {}
        for line in (source / 'mdf.sha256').read_text().splitlines():
            row = re.fullmatch(r'([a-f0-9]{64})  ([^/\\]+)', line)
            if not row or row[2] in ('.', '..') or row[2] in manifest:
                raise ValueError(f'{distro}: invalid checksum manifest')
            manifest[row[2]] = row[1]
        for name in ('mdf', rpm, deb):
            if name not in manifest or not (source / name).is_file() or checksum(source / name) != manifest[name]:
                raise ValueError(f'{distro}: missing or corrupt {name}')
        if not (source / 'build-info.txt').is_file():
            raise ValueError(f'{distro}: missing build information')
    selected = {
        'mdf': directory / 'ubuntu/mdf',
        'mdf-fedora': directory / 'fedora/mdf',
        rpm: directory / 'fedora' / rpm,
        deb: directory / 'ubuntu' / deb,
        'build-info.txt': directory / 'ubuntu/build-info.txt',
        'build-info-fedora.txt': directory / 'fedora/build-info.txt',
    }
    # Validate both inputs before replacing any release files.
    with tempfile.TemporaryDirectory(prefix='.assemble-', dir=directory) as temporary:
        stage = Path(temporary)
        for name, source in selected.items():
            shutil.copy2(source, stage / name)
        for name in ('mdf', 'mdf-fedora'):
            (stage / name).chmod(0o755)
        (stage / 'mdf.sha256').write_text(''.join(
            checksum(stage / name) + '  ' + name + '\n' for name in selected))
        for path in stage.iterdir():
            path.replace(directory / path.name)


if __name__ == '__main__':
    assemble(Path('build'), sys.argv[1])
