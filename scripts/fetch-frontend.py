#!/usr/bin/env python3
"""Fetch pinned frontend sources during make setup. Builds stay offline."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from zig_deps import cached_packages

root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "frontend/dependencies.json").read_text())
work = root / "build/downloads"
work.mkdir(parents=True, exist_ok=True)
pkg = root / "zig-pkg"
pkg.mkdir(exist_ok=True)
for module in ['pozeiden','zig-svg']:
    if not (root/'modules'/module/'src/root.zig').is_file():
        subprocess.run(['git','submodule','update','--init','--recursive','--','modules/'+module],cwd=root,check=True)
for name, record in manifest.items():
    if name in ('pozeiden','zig_svg'):
        continue  # The parent repository's gitlink pins this source dependency.
    destination = pkg / {"fltk": "fltk", "nlohmann_json": "nlohmann/json.hpp",
                         "nlohmann_license": "nlohmann/LICENSE.MIT"}[name]
    marker = pkg / f".{name}-{record['version']}.sha256"
    if destination.exists() and marker.exists() and marker.read_text().strip() == record["sha256"]:
        print(f"Using cached {name} {record['version']}", flush=True)
        continue
    downloaded = work / (name + (".tar.gz" if name == "fltk" else ".txt"))
    print(f"Fetching {name} {record['version']}...", flush=True)
    with urllib.request.urlopen(record["url"], timeout=60) as response, downloaded.open("wb") as output:
        shutil.copyfileobj(response, output)
    if hashlib.sha256(downloaded.read_bytes()).hexdigest() != record["sha256"]:
        raise SystemExit(f"{name}: downloaded source checksum mismatch")
    if name == "fltk":
        with tempfile.TemporaryDirectory(prefix=name+'-', dir=work) as temporary:
            with tarfile.open(downloaded) as archive:
                archive.extractall(temporary, filter="data")
            source = next(Path(temporary).iterdir())
            if destination.exists():
                shutil.rmtree(destination)
            shutil.move(source, destination)
    else:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(downloaded, destination)
    marker.write_text(record["sha256"] + "\n")
subprocess.run(['python3', 'scripts/prepare-fltk.py'], cwd=root, check=True)
cached_packages([root/'build.zig.zon',root/'modules/pozeiden/build.zig.zon'],fetch=True)
