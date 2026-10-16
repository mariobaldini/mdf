#!/usr/bin/env python3
"""Audit bundled startup fonts and strictly deferred, read-only font workers."""

from pathlib import Path
import re
import sys

font_path = re.compile(r'/(?:fonts|fontconfig|\.fonts|\.fontconfig)(?:/|"|\\)|'
                       r'/(?:fonts\.conf|\.fonts\.conf)(?:"|\\)|\.(?:ttf|otf|ttc|pcf)(?:"|\\)')


def audit(trace, deferred=True, faces=2):
    viewport = False
    workers = set()
    violations = []
    for line in trace.splitlines():
        match = re.match(r'\s*(?:\[pid\s+)?(\d+)\]?\s+(.*)', line)
        tid, call = match.groups() if match else (None, line)
        if 'prctl(PR_SET_NAME, "mdf-viewport"' in call:
            viewport = True
        if any('prctl(PR_SET_NAME, "'+name+'"' in call for name in ('mdf-monospace', 'mdf-fallback')):
            if not viewport or not deferred:
                violations.append('Font worker started before the viewport: '+line)
            workers.add(tid)
        if 'libmdf-extra.so' in call:
            violations.append(line)
        if font_path.search(call):
            if not deferred or not viewport or tid not in workers:
                violations.append(line)
            if re.search(r'\b(O_WRONLY|O_RDWR|O_CREAT|O_TRUNC)\b|\b(mkdir|unlink|rename)\w*\(', call):
                violations.append('Persistent font write: '+line)
    if violations:
        raise AssertionError('Unexpected font filesystem access:\n'+'\n'.join(violations[:15]))
    assert len(re.findall(r'memfd_create\("mdf-font"', trace)) == faces, f'Expected {faces} bundled anonymous fonts'
    assert '/proc/self/fd/' in trace, 'Embedded memory files were not opened'
    if deferred:
        assert viewport and workers, 'Missing first-viewport/deferred-worker trace markers'
    else:
        assert 'mdf-mono-font' not in trace, 'A document without code loaded a system font'
        assert 'mdf-sans-font' not in trace, 'A Latin document loaded a fallback font'


if __name__ == '__main__':
    faces = int(sys.argv[sys.argv.index('--faces')+1]) if '--faces' in sys.argv else 2
    audit(Path(sys.argv[1]).read_text(), '--no-deferred' not in sys.argv[2:], faces)
    print(f'PASS: {faces} requested bundled faces; system font access only on the post-viewport worker; no persistent font writes or companion loads')
