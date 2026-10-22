#!/usr/bin/env python3
"""Check setup's package-cache selection and pinned dependency validation."""
from pathlib import Path
import io
import os
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
import zig_deps


class DependencyFetchTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mdf-zig-deps-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.packages = self.root/'zig-pkg'
        for name, value in [('ROOT', self.root), ('PACKAGES', self.packages)]:
            self.enterContext(patch.object(zig_deps, name, value))
        self.manifest = self.root/'build.zig.zon'
        self.manifest.write_text('''.{ .dependencies = .{
            .local = .{ .path = "modules/local" },
            .optional = .{ .url = "https://unused.invalid/source.tar.gz", .hash = "unused", .lazy = true },
        } }''')
        local = self.root/'modules/local'
        local.mkdir(parents=True)
        (local/'build.zig.zon').write_text('''.{ .dependencies = .{
            .source = .{ .url = "https://example.invalid/source.tar.gz", .hash = "pinned-source" },
        } }''')

    def test_fetch_uses_environment_and_extracts_pinned_source(self):
        def fetch(command, *, env, text):
            self.assertEqual(command, ['/test/zig', 'fetch', 'https://example.invalid/source.tar.gz'])
            self.assertTrue(text)
            cache = self.root/'build/.zig-cache/package-fetch'
            self.assertEqual(env['ZIG_GLOBAL_CACHE_DIR'], str(cache))
            self.assertEqual(env['HTTPS_PROXY'], 'http://proxy.invalid:8080')
            archive_path = cache/'p/pinned-source.tar.gz'
            archive_path.parent.mkdir(parents=True)
            with tarfile.open(archive_path, 'w:gz') as archive:
                content = b'pinned fixture source\n'
                entry = tarfile.TarInfo('pinned-source/source.zig')
                entry.size = len(content)
                archive.addfile(entry, io.BytesIO(content))
            return 'pinned-source\n'

        with patch.dict(os.environ, {'ZIG': '/test/zig', 'ZIG_GLOBAL_CACHE_DIR': '/other/cache',
                                    'HTTPS_PROXY': 'http://proxy.invalid:8080'}):
            with patch.object(zig_deps.subprocess, 'check_output', side_effect=fetch) as process:
                packages = zig_deps.cached_packages([self.manifest], fetch=True)
                self.assertEqual(list(packages), ['pinned-source'])
                self.assertEqual((packages['pinned-source']['directory']/'source.zig').read_bytes(),
                                 b'pinned fixture source\n')
                self.assertEqual(zig_deps.cached_packages([self.manifest]), packages)
                process.assert_called_once()

    def test_checksum_mismatch_is_rejected_before_installing(self):
        with patch.object(zig_deps.subprocess, 'check_output', return_value='other-source\n'):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                zig_deps.cached_packages([self.manifest], fetch=True)
        self.assertFalse((self.packages/'pinned-source').exists())

    def test_missing_offline_dependency_does_not_fetch(self):
        with patch.object(zig_deps.subprocess, 'check_output') as process:
            with self.assertRaisesRegex(ValueError, 'run make setup'):
                zig_deps.cached_packages([self.manifest])
            process.assert_not_called()


if __name__ == '__main__':
    unittest.main()
