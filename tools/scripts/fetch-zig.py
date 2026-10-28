#!/usr/bin/env python3
"""Cache the project's exact official Linux x86_64 compiler, without installation."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

root = Path(__file__).resolve().parents[2]
version = (root/'.zig-version').read_text().strip()
destination = root/'zig-pkg'/('zig-'+version)
compiler = destination/'zig'
if compiler.is_file() and subprocess.check_output([str(compiler),'version'],text=True).strip() == version:
    print(compiler)
    raise SystemExit(0)
print('Fetching the pinned Zig '+version+' compiler into zig-pkg...',file=sys.stderr)
with urllib.request.urlopen('https://ziglang.org/download/index.json',timeout=60) as response:
    release = json.load(response)[version]['x86_64-linux']
if not release['tarball'].startswith('https://ziglang.org/'):
    raise SystemExit('Unexpected compiler download origin')
destination.parent.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='.zig-download-',dir=destination.parent) as temporary:
    temporary = Path(temporary)
    archive_path = temporary/'zig.tar.xz'
    with urllib.request.urlopen(release['tarball'],timeout=60) as response,archive_path.open('wb') as output:
        shutil.copyfileobj(response,output)
    if hashlib.sha256(archive_path.read_bytes()).hexdigest() != release['shasum']:
        raise SystemExit('Zig compiler checksum mismatch')
    unpacked = temporary/'source';unpacked.mkdir()
    with tarfile.open(archive_path) as archive:
        archive.extractall(unpacked,filter='data')
    source = next(unpacked.iterdir())
    if subprocess.check_output([str(source/'zig'),'version'],text=True).strip() != version:
        raise SystemExit('Zig compiler version mismatch')
    (source/'mdf-download.json').write_text(json.dumps(release,indent=2))
    if destination.exists():
        raise SystemExit('Existing compiler cache is incomplete; remove '+str(destination)+' and retry')
    shutil.move(source,destination)
print(compiler)
