#!/usr/bin/env python3
"""Read, check, and increase the application version without build side effects."""
import sys
sys.dont_write_bytecode = True

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\n")
MANIFEST = re.compile(r'(^[ \t]*\.version[ \t]*=[ \t]*")([^"\n]+)(",)', re.MULTILINE)


def read(root=ROOT):
    text = (root / "VERSION").read_text(encoding="ascii")
    match = VERSION.fullmatch(text)
    if match is None:
        raise ValueError("VERSION must contain MAJOR.MINOR and one final newline, for example 0.3")
    return text[:-1]


def semver(root=ROOT):
    return read(root) + ".0"


def check(root=ROOT):
    expected = semver(root)
    manifest = (root / "build.zig.zon").read_text()
    versions = list(MANIFEST.finditer(manifest))
    if len(versions) != 1 or versions[0].group(2) != expected:
        raise ValueError(f'build.zig.zon must contain exactly one .version = "{expected}" entry')
    return read(root)


def bump(root=ROOT):
    current = check(root)
    major, minor = map(int, current.split("."))
    updated = f"{major}.{minor + 1}"
    manifest_path = root / "build.zig.zon"
    manifest = MANIFEST.sub(lambda match: match[1] + updated + ".0" + match[3], manifest_path.read_text())
    manifest_path.write_text(manifest)
    (root / "VERSION").write_text(updated + "\n", encoding="ascii")
    return updated


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("show", "semver", "check", "bump"), nargs="?", default="show")
    args = parser.parse_args()
    try:
        if args.command == "check":
            version = check()
            print(f"version {version} ({version}.0): all checks passed")
        else:
            print({"show": read, "semver": semver, "bump": bump}[args.command]())
    except (OSError, ValueError) as error:
        parser.exit(1, f"version: {error}\n")


if __name__ == "__main__":
    main()
