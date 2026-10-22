"""Resolve pinned ZON source dependencies into the persistent offline cache."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ROOT/'zig-pkg'

def records(manifest):
    text = manifest.read_text()
    section = text.split('.dependencies = .{', 1)
    if len(section) == 1:
        return []
    result = []
    for body in re.findall(r'\.[A-Za-z0-9_]+\s*=\s*\.\{([^{}]*)\}', section[1]):
        record = dict(re.findall(r'\.(url|hash|path)\s*=\s*"([^"]+)"', body))
        # MDF uses the libraries' default feature sets. Optional Unicode
        # tables/test backends are not part of that graph or its notices.
        if re.search(r'\.lazy\s*=\s*true\b',body):
            continue
        if 'path' in record or ('url' in record and 'hash' in record):
            result.append(record)
    return result

def cached_packages(manifests, fetch=False):
    packages = {}
    visited = set()
    def walk(manifest):
        manifest = manifest.resolve()
        if manifest in visited or not manifest.is_file():
            return
        visited.add(manifest)
        for record in records(manifest):
            if 'path' in record:
                walk(manifest.parent/record['path']/'build.zig.zon')
                continue
            expected = record['hash']
            destination = PACKAGES/expected
            if not destination.is_dir():
                if not fetch:
                    raise ValueError('Missing pinned Zig source '+expected+'; run make setup')
                cache = ROOT/'build/.zig-cache/package-fetch'
                # Zig 0.17's fetch command no longer accepts --global-cache-dir.
                environment = {**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(cache)}
                actual = subprocess.check_output([os.environ.get('ZIG','zig'),'fetch',record['url']],env=environment,text=True).strip()
                if actual != expected:
                    raise ValueError('Zig dependency checksum mismatch: '+record['url'])
                PACKAGES.mkdir(exist_ok=True)
                with tempfile.TemporaryDirectory(prefix='.source-',dir=PACKAGES) as temporary:
                    with tarfile.open(cache/'p'/(expected+'.tar.gz')) as archive:
                        archive.extractall(temporary,filter='data')
                    shutil.move(Path(temporary)/expected,destination)
            packages[expected] = {**record,'directory':destination}
            walk(destination/'build.zig.zon')
    for manifest in manifests:
        walk(manifest)
    return packages
