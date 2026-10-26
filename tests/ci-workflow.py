#!/usr/bin/env python3
"""Exercise branch gates, release metadata, and publishing without GitHub writes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.load((ROOT / '.github/workflows/build-release.yml').read_text(), Loader=yaml.BaseLoader)


def enabled(entry, event, ref, release='skipped'):
    expression = entry.get('if', 'True').removeprefix('${{').removesuffix('}}').strip()
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    return bool(eval(expression, {'__builtins__': {}}, {
        'True': True, 'github': SimpleNamespace(event_name=event, ref=ref),
        'needs': SimpleNamespace(release=SimpleNamespace(result=release)),
        'startsWith': str.startswith,
    }))


class WorkflowTests(unittest.TestCase):
    def test_branch_events_and_publication_gates(self):
        self.assertEqual(set(WORKFLOW['on']['push']['branches']), {'main', 'dev'})
        for event, ref, publish in [
            ('push', 'refs/heads/main', True), ('push', 'refs/heads/dev', False),
            ('push', 'refs/tags/v0.2.1', True), ('pull_request', 'refs/pull/1/merge', False),
            ('pull_request', 'refs/heads/main', False), ('workflow_dispatch', 'refs/heads/main', False),
        ]:
            with self.subTest(event=event, ref=ref):
                steps = [step for step in WORKFLOW['jobs']['build']['steps'] if enabled(step, event, ref)]
                commands = [step.get('run', '') for step in steps]
                self.assertIn('make build', commands)
                self.assertIn('make test', commands)
                self.assertIn('make test-gui OPTIMIZE=ReleaseFast', commands)
                self.assertEqual('make release' in commands, publish)
                self.assertEqual('make test-packages' in commands, publish)
                self.assertEqual(any(step.get('uses', '').startswith('actions/upload-artifact@') for step in steps), publish)
                self.assertEqual(enabled(WORKFLOW['jobs']['release'], event, ref), publish)
                self.assertEqual(enabled(WORKFLOW['jobs']['promote'], event, ref, 'success' if publish else 'skipped'), publish)

    def test_permissions_and_build_dependencies(self):
        self.assertEqual(WORKFLOW['permissions']['contents'], 'read')
        self.assertEqual(WORKFLOW['jobs']['release']['needs'], 'build')
        self.assertEqual(WORKFLOW['jobs']['promote']['needs'], 'release')
        for job in ('release', 'promote'):
            self.assertEqual(WORKFLOW['jobs'][job]['permissions']['contents'], 'write')
        self.assertNotIn('concurrency', WORKFLOW['jobs']['release'])
        self.assertEqual(WORKFLOW['jobs']['promote']['concurrency']['cancel-in-progress'], 'false')

    def test_main_tag_is_unique_and_tag_releases_keep_their_version(self):
        code = next(step['run'] for step in WORKFLOW['jobs']['build']['steps'] if step.get('id') == 'release')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'build').mkdir()
            binary = root / 'build/mdf'
            binary.write_text('#!/bin/sh\nprintf "mdf 0.2.0\\n"\n')
            binary.chmod(0o755)
            for ref, number, expected in [('refs/heads/main', '41', 'v0.2.0-41'),
                                           ('refs/heads/main', '42', 'v0.2.0-42'),
                                           ('refs/tags/v0.2.0', '43', 'v0.2.0')]:
                output = root / 'output'
                output.write_text('')
                env = {**os.environ, 'GITHUB_REF': ref, 'GITHUB_REF_NAME': ref.rsplit('/', 1)[1],
                       'GITHUB_RUN_NUMBER': number, 'GITHUB_OUTPUT': str(output)}
                subprocess.run(['bash', '-euo', 'pipefail', '-c', code], cwd=root, env=env, check=True)
                self.assertEqual(output.read_text(), 'tag=' + expected + '\n')

    def test_invalid_package_revision_stops_before_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            for revision in ('0', '01', '-1', '42x', '42\n7'):
                result = subprocess.run(['sh', str(ROOT / 'scripts/packages.sh'), directory, '0.2.0'],
                                        cwd=ROOT, env={**os.environ, 'MDF_PACKAGE_RELEASE': revision},
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must be a positive integer', result.stderr)
                self.assertEqual(list(Path(directory).iterdir()), [])


class PublishTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mdf-ci-release-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'bin').mkdir()
        self.bundle = self.root / 'build'
        self.bundle.mkdir()
        shutil.copy2(ROOT / 'scripts/publish-release.sh', self.root / 'scripts')
        self.files = ['mdf', 'mdf-0.2.0-42.x86_64.rpm', 'mdf_0.2.0-42_amd64.deb']
        for name in self.files:
            (self.bundle / name).write_bytes(('payload ' + name).encode())
        (self.bundle / 'build-info.txt').write_text('ReleaseFast\n')
        (self.bundle / 'mdf.sha256').write_text(''.join(
            hashlib.sha256((self.bundle / name).read_bytes()).hexdigest() + '  ' + name + '\n'
            for name in self.files))
        self.log = self.root / 'gh.log'
        stub = self.root / 'bin/gh'
        stub.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['MDF_TEST_GH_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[:2] == ['release', 'view']:
    value = os.environ.get('MDF_TEST_DRAFT', 'missing')
    if value == 'missing': raise SystemExit(1)
    print(value)
elif args[0] == 'api':
    print(os.environ.get('MDF_TEST_TAGS', 'v0.2.0-42'))
if len(args) > 1 and args[1] == os.environ.get('MDF_TEST_GH_FAIL'):
    raise SystemExit(1)
''')
        stub.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.root / 'bin') + ':' + os.environ['PATH'],
                    'GH_REPO': 'owner/project', 'GITHUB_SHA': 'a' * 40, 'GITHUB_REF': 'refs/heads/main',
                    'MDF_TEST_GH_LOG': str(self.log)}

    def run_publish(self, argument='v0.2.0-42'):
        return subprocess.run(['bash', str(self.root / 'scripts/publish-release.sh'), argument],
                              env=self.env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_release_attaches_both_packages_before_publication_and_targets_built_commit(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        create, publish = self.calls()[-2:]
        self.assertEqual(create[:3], ['release', 'create', 'v0.2.0-42'])
        self.assertIn('--draft', create)
        self.assertEqual(create[create.index('--target') + 1], 'a' * 40)
        for name in self.files + ['mdf.sha256', 'build-info.txt']:
            self.assertIn('build/' + name, create)
        self.assertEqual(publish, ['release', 'edit', 'v0.2.0-42', '--draft=false', '--latest=false'])

    def test_tag_release_verifies_the_existing_tag(self):
        self.env['GITHUB_REF'] = 'refs/tags/v0.2.0'
        result = self.run_publish('v0.2.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--verify-tag', self.calls()[-2])

    def test_retry_keeps_a_published_release_and_resumes_a_draft(self):
        self.env['MDF_TEST_DRAFT'] = 'false'
        self.assertEqual(self.run_publish().returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.log.unlink()
        self.env['MDF_TEST_DRAFT'] = 'true'
        self.assertEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.calls()[-2][:3], ['release', 'upload', 'v0.2.0-42'])
        self.assertIn('--clobber', self.calls()[-2])

    def test_missing_or_corrupt_package_never_reaches_github(self):
        rpm = self.bundle / self.files[1]
        rpm.unlink()
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.calls(), [])
        rpm.write_bytes(b'corrupted')
        self.assertNotEqual(self.run_publish().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_manifest_must_cover_both_packages(self):
        manifest = self.bundle / 'mdf.sha256'
        manifest.write_text(manifest.read_text().splitlines()[0] + '\n')
        result = self.run_publish()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not cover', result.stderr)
        self.assertEqual(self.calls(), [])

    def test_failed_draft_or_asset_upload_cannot_publish(self):
        for operation in ('create', 'upload'):
            self.env['MDF_TEST_GH_FAIL'] = operation
            self.env['MDF_TEST_DRAFT'] = 'true' if operation == 'upload' else 'missing'
            result = self.run_publish()
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(call[:2] == ['release', 'edit'] for call in self.calls()))
            self.log.unlink()

    def test_latest_promotion_uses_all_published_versions_instead_of_completion_order(self):
        for tags, expected in [('v0.2.0-42\nv0.2.0-9\nv0.2.0-100', 'v0.2.0-100'),
                               ('v0.2.0-100\nv0.2.1\nv0.1.9-200', 'v0.2.1')]:
            self.env['MDF_TEST_TAGS'] = tags
            result = self.run_publish('--promote')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.calls()[-1], ['release', 'edit', expected, '--latest'])


if __name__ == '__main__':
    unittest.main()
