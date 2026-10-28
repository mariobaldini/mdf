#!/usr/bin/env python3
"""Exercise version increases and the build guard without changing this checkout."""
import sys
sys.dont_write_bytecode = True

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mdf_version", ROOT / "tools/scripts/version.py")
version = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(version)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mdf-version-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture("0.3")

    def fixture(self, value):
        (self.root / "VERSION").write_text(value + "\n")
        (self.root / "build.zig.zon").write_text('.{\n    .version = "' + value + '.0",\n    .minimum_zig_version = "0.17.0",\n    .dependencies = .{ .parser = .{ .url = "https://example.invalid/0.3.0" } },\n}\n')

    def test_current_project_and_cli_match(self):
        current = version.check(ROOT)
        self.assertEqual(version.semver(ROOT), current + ".0")
        for command, expected in (("show", current), ("semver", current + ".0")):
            result = subprocess.run([sys.executable, str(ROOT / "tools/scripts/version.py"), command], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), expected)

    def test_bump_updates_the_manifest_without_changing_dependency_versions(self):
        self.assertEqual(version.bump(self.root), "0.4")
        self.assertEqual(version.check(self.root), "0.4")
        manifest = (self.root / "build.zig.zon").read_text()
        self.assertIn('.minimum_zig_version = "0.17.0"', manifest)
        self.assertIn('https://example.invalid/0.3.0', manifest)

    def test_bumps_count_integers_instead_of_decimal_fractions(self):
        for current, expected in (("0.9", "0.10"), ("0.99", "0.100"), ("1.0", "1.1")):
            with self.subTest(current=current):
                self.fixture(current)
                self.assertEqual(version.bump(self.root), expected)
                self.assertEqual(version.check(self.root), expected)

    def test_invalid_version_formats_are_rejected(self):
        for text in ("", "0.3", "0.3.0\n", "v0.3\n", "0.03\n", "03.0\n", "-1.3\n", "0.3\n0.4\n", "0.3 \n"):
            with self.subTest(text=text):
                (self.root / "VERSION").write_text(text)
                with self.assertRaises(ValueError):
                    version.read(self.root)

    def test_inconsistent_manifest_stops_before_writing(self):
        path = self.root / "build.zig.zon"
        for content in ('.{ .version = "0.2.0", }', '.{}', '.version = "0.3.0",\n.version = "0.3.0",'):
            with self.subTest(content=content):
                path.write_text(content)
                with self.assertRaises(ValueError):
                    version.bump(self.root)
                self.assertEqual((self.root / "VERSION").read_text(), "0.3\n")
                self.assertEqual(path.read_text(), content)

    def test_make_commands_and_guard_need_no_compiler(self):
        shutil.copy2(ROOT / "Makefile", self.root / "Makefile")
        shutil.copy2(ROOT / ".zig-version", self.root / ".zig-version")
        (self.root / "tools/scripts").mkdir(parents=True)
        shutil.copy2(ROOT / "tools/scripts/version.py", self.root / "tools/scripts/version.py")
        for target, expected in (("version", "0.3"), ("version-bump", "0.4"), ("version-check", "all checks passed")):
            result = subprocess.run(["make", "--no-print-directory", target], cwd=self.root, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn(expected, result.stdout)
        (self.root / "VERSION").write_text("0.5\n")
        result = subprocess.run(["make", "--no-print-directory", "check-requirements"], cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('build.zig.zon must contain', result.stderr)
        self.assertNotIn('check-requirements.sh', result.stderr)


if __name__ == "__main__":
    unittest.main()
