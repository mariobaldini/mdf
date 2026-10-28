#!/usr/bin/env python3
"""Apply the pinned MDF patch series, including cached and partially patched trees."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
SERIES = ROOT / 'frontend/patches/fltk/series.json'


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def changes(patch):
    lines = patch.splitlines(keepends=True)
    result, index = {}, 0
    while index < len(lines):
        if not lines[index].startswith('--- '):
            raise ValueError('Unsupported FLTK patch header')
        old = lines[index][4:].strip()
        new = lines[index + 1][4:].strip()
        if not lines[index + 1].startswith('+++ '):
            raise ValueError('Missing FLTK patch target')
        name = new[2:] if new != '/dev/null' else old[2:]
        if Path(name).is_absolute() or '..' in Path(name).parts:
            raise ValueError('Invalid FLTK patch path')
        index += 2
        hunks = []
        while index < len(lines) and not lines[index].startswith('--- '):
            header = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@.*\n', lines[index])
            if not header:
                raise ValueError('Unsupported FLTK patch hunk')
            index += 1
            body = []
            while index < len(lines) and not lines[index].startswith(('@@ ', '--- ')):
                if lines[index][:1] not in (' ', '+', '-'):
                    raise ValueError('Unsupported FLTK patch line')
                body.append(lines[index]); index += 1
            hunks.append((int(header[1]), int(header[3]), body))
        result[name] = (old == '/dev/null', new == '/dev/null', hunks)
    return result


def transform(data, change, reverse=False):
    create, remove, hunks = change
    if reverse:
        create, remove = remove, create
    if create != (data is None):
        raise ValueError('Unexpected FLTK source existence')
    source = (data or b'').decode().splitlines(keepends=True)
    output, cursor = [], 0
    for old, new, body in hunks:
        position = max(0, (new if reverse else old) - 1)
        if position < cursor:
            raise ValueError('Overlapping FLTK patch hunks')
        output.extend(source[cursor:position]); cursor = position
        for line in body:
            tag = {'+': '-', '-': '+'}.get(line[0], line[0]) if reverse else line[0]
            if tag in (' ', '-'):
                if cursor >= len(source) or source[cursor] != line[1:]:
                    raise ValueError('FLTK patch context changed')
                cursor += 1
            if tag in (' ', '+'):
                output.append(line[1:])
    output.extend(source[cursor:])
    return None if remove else ''.join(output).encode()


def prepare(source, manifest=SERIES):
    metadata = json.loads(manifest.read_text())
    upstream = json.loads((ROOT / 'frontend/dependencies.json').read_text())['fltk']
    if (metadata['version'], metadata['upstream_sha256']) != (upstream['version'], upstream['sha256']):
        raise ValueError('Unsupported FLTK version: port and review the MDF patches first')
    patches = []
    identity = hashlib.sha256(manifest.read_bytes())
    histories = {}
    for entry in metadata['patches']:
        raw = (manifest.parent / entry['patch']).read_bytes()
        identity.update(raw)
        patch = changes(raw.decode())
        if set(patch) != set(entry['files']):
            raise ValueError('FLTK patch manifest does not match its files')
        patches.append((entry, patch))
        for name, hashes in entry['files'].items():
            histories.setdefault(name, []).append((hashes, patch[name]))
    # Recognize only pristine sources and exact states from this patch series.
    # Reverse known changes in memory, then apply the whole series. This also
    # migrates the previously inline title-height patch without extracting an archive.
    original, current = {}, {}
    for name, history in histories.items():
        path = source / name
        data = path.read_bytes() if path.exists() else None
        current[name] = data
        actual = digest(data)
        if actual != history[0][0]['before']:
            state = next((i for i in range(len(history)-1, -1, -1)
                          if history[i][0]['after'] == actual), None)
            if state is None:
                raise ValueError(f'Unrecognized FLTK source change: {name}. Preserve local edits and restore the pinned upstream source.')
            for hashes, change in reversed(history[:state+1]):
                data = transform(data, change, True)
                if digest(data) != hashes['before']:
                    raise ValueError(f'FLTK reverse checksum mismatch: {name}')
        original[name] = data
    prepared = dict(original)
    for entry, patch in patches:
        for name, change in patch.items():
            hashes = entry['files'][name]
            if digest(prepared[name]) != hashes['before']:
                raise ValueError(f'FLTK input checksum mismatch: {name}')
            prepared[name] = transform(prepared[name], change)
            if digest(prepared[name]) != hashes['after']:
                raise ValueError(f'FLTK output checksum mismatch: {name}')
    # Validate every file before changing any file. An interrupted write is
    # recoverable because every replacement is another recognized series state.
    for name, data in prepared.items():
        if data == current[name]:
            continue
        path = source / name
        if data is None:
            path.unlink(missing_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + '.mdf-new')
            temporary.write_bytes(data)
            temporary.replace(path)
    return identity.hexdigest()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'zig-pkg/fltk')
    args = parser.parse_args()
    try:
        print(prepare(args.source))
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
