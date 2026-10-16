#!/usr/bin/env python3
"""Pinned patch application: pristine/cached trees, migration, and fail-closed checks."""
import difflib
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('prepare_fltk', ROOT / 'scripts/prepare-fltk.py')
prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)


class Patches(unittest.TestCase):
    def fixture(self, directory):
        directory = Path(directory)
        source = directory / 'source'; source.mkdir()
        (source / 'fixture.cxx').write_text('height=24;\n')
        upstream = json.loads((ROOT / 'frontend/dependencies.json').read_text())['fltk']
        manifest = {'version': upstream['version'], 'upstream_sha256': upstream['sha256'], 'patches': []}
        for index, before, after in [(1,'height=24;\n','height=48;\n'), (2,'height=48;\n','height=48;\ntrace();\n')]:
            patch = f'{index}.patch'
            (directory / patch).write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True), fromfile='a/fixture.cxx', tofile='b/fixture.cxx')))
            manifest['patches'].append({'patch': patch, 'files': {'fixture.cxx': {
                'before': hashlib.sha256(before.encode()).hexdigest(), 'after': hashlib.sha256(after.encode()).hexdigest()}}})
        (directory / 'new.patch').write_text('--- /dev/null\n+++ b/new.h\n@@ -0,0 +1 @@\n+// hook\n')
        manifest['patches'].append({'patch': 'new.patch', 'files': {'new.h': {'before': None, 'after': hashlib.sha256(b'// hook\n').hexdigest()}}})
        path = directory / 'series.json'; path.write_text(json.dumps(manifest))
        return source, path

    def test_pristine_and_cached_builds_are_identical_and_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            source, series = self.fixture(directory)
            identity = prepare.prepare(source, series)
            self.assertEqual((source/'fixture.cxx').read_text(), 'height=48;\ntrace();\n')
            self.assertEqual((source/'new.h').read_text(), '// hook\n')
            stamp = (source/'fixture.cxx').stat().st_mtime_ns
            self.assertEqual(prepare.prepare(source, series), identity)
            self.assertEqual((source/'fixture.cxx').stat().st_mtime_ns, stamp)

    def test_previous_title_only_adjustment_migrates_without_an_archive(self):
        with tempfile.TemporaryDirectory() as directory:
            source, series = self.fixture(directory)
            (source/'fixture.cxx').write_text('height=48;\n')
            prepare.prepare(source, series)
            self.assertIn('trace();', (source/'fixture.cxx').read_text())

    def test_unknown_source_or_hunk_change_never_modifies_other_files(self):
        for damage in ('source', 'hunk'):
            with tempfile.TemporaryDirectory() as directory:
                source, series = self.fixture(directory)
                if damage == 'source': (source/'new.h').write_text('user-owned change\n')
                else:
                    patch = Path(directory)/'2.patch'
                    patch.write_text(patch.read_text().replace(' height=48;', ' height=49;'))
                with self.assertRaises(ValueError): prepare.prepare(source, series)
                self.assertEqual((source/'fixture.cxx').read_text(), 'height=24;\n')

    def test_version_and_patch_identity_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            source, series = self.fixture(directory)
            original = json.loads(series.read_text())
            original['version'] = 'future'
            series.write_text(json.dumps(original))
            with self.assertRaisesRegex(ValueError, 'Unsupported FLTK version'): prepare.prepare(source, series)


if __name__ == '__main__': unittest.main()
