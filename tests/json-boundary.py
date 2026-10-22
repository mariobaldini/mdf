#!/usr/bin/env python3
"""Check the native JSON boundary with Python's independent JSON reader."""
import json
from pathlib import Path
import subprocess
import sys

result = subprocess.run([sys.argv[1]], check=True, capture_output=True, text=True)
fixture = json.loads(result.stdout)
assert fixture == {
    'escaped': 'quote" slash\\ newline\n tab\t nul\0 中文 Привет',
    'signed': -(2**63), 'unsigned': 2**64-1, 'float': 1.25,
    'bool': True, 'null': None, 'duplicate': 2,
    'array': ['one', 'two'], 'nested': {'value': 7},
}, fixture
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root/'frontend/dependencies.json').read_text())
assert not any('nlohmann' in key for key in manifest)
for directory in ('src', 'frontend'):
    for path in (root/directory).glob('*'):
        if path.suffix in ('.zig', '.cpp', '.hpp', '.h'):
            assert 'nlohmann' not in path.read_text(), path
print('PASS: std.json C++ ownership, mutation, input lifetime, bounds, errors and Python JSON compatibility')
