#!/usr/bin/env python3
"""Exercise branch gates, release metadata, and publishing without GitHub writes."""
import hashlib
import importlib.util
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
SPEC = importlib.util.spec_from_file_location('assemble_release', ROOT / 'scripts/assemble-release.py')
ASSEMBLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSEMBLER)


def enabled(entry, event, ref, build='success'):
    expression = entry.get('if', 'True').removeprefix('${{').removesuffix('}}').strip()
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    return bool(eval(expression, {'__builtins__': {}}, {
        'True': True, 'github': SimpleNamespace(event_name=event, ref=ref),
        'needs': SimpleNamespace(build=SimpleNamespace(result=build)),
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
                self.assertEqual('bash tests/package-desktop.sh' in commands, publish)
                self.assertEqual(any(step.get('uses', '').startswith('actions/upload-artifact@') for step in steps), publish)
                self.assertEqual(enabled(WORKFLOW['jobs']['release'], event, ref), publish)

    def test_two_independent_builds_must_both_succeed_before_publication(self):
        build = WORKFLOW['jobs']['build']
        self.assertEqual(build['strategy']['fail-fast'], 'false')
        matrix = build['strategy']['matrix']['include']
        self.assertEqual({row['distro']: row['image'] for row in matrix},
                         {'fedora': 'fedora:44', 'ubuntu': 'ubuntu:26.04'})
        self.assertNotIn('continue-on-error', build)
        for result in ('failure', 'cancelled', 'skipped'):
            self.assertFalse(enabled(WORKFLOW['jobs']['release'], 'push', 'refs/heads/main', result))
        self.assertEqual(set(WORKFLOW['jobs']), {'build', 'release'})

    def test_permissions_and_build_dependencies(self):
        self.assertEqual(WORKFLOW['permissions']['contents'], 'read')
        self.assertEqual(WORKFLOW['jobs']['release']['needs'], 'build')
        self.assertEqual(WORKFLOW['jobs']['release']['permissions']['contents'], 'write')
        self.assertNotIn('concurrency', WORKFLOW['jobs']['release'])

    def test_publication_downloads_and_verifies_both_artifacts(self):
        steps = WORKFLOW['jobs']['release']['steps']
        downloads = [step['with'] for step in steps if step.get('uses', '').startswith('actions/download-artifact@')]
        self.assertEqual({item['name']: item['path'] for item in downloads},
                         {'mdf-linux-x86_64-fedora': 'build/fedora', 'mdf-linux-x86_64-ubuntu': 'build/ubuntu'})
        assemble = next(step for step in steps if 'assemble-release.py' in step.get('run', ''))
        publish = next(step for step in steps if 'publish-release.sh' in step.get('run', ''))
        self.assertLess(steps.index(assemble), steps.index(publish))

    def test_container_trust_allows_checkout_and_nested_submodules_only(self):
        steps = WORKFLOW['jobs']['build']['steps']
        trust = next(step for step in steps if step.get('id') == 'trust')
        checkout = next(step for step in steps if step.get('uses', '').startswith('actions/checkout@'))
        setup = next(step for step in steps if step.get('run') == 'make setup')
        self.assertLess(steps.index(checkout), steps.index(trust))
        self.assertLess(steps.index(trust), steps.index(setup))
        with tempfile.TemporaryDirectory(prefix='mdf-ci-ownership-') as directory:
            root = Path(directory)
            env = {**os.environ, 'GIT_CONFIG_GLOBAL': str(root / 'gitconfig'), 'GIT_CONFIG_NOSYSTEM': '1',
                   'GIT_AUTHOR_NAME': 'MDF CI test', 'GIT_AUTHOR_EMAIL': 'ci@example.invalid',
                   'GIT_COMMITTER_NAME': 'MDF CI test', 'GIT_COMMITTER_EMAIL': 'ci@example.invalid',
                   'GIT_TEST_ASSUME_DIFFERENT_OWNER': '0'}
            def git(path, *args):
                return subprocess.run(['git', '-C', str(path), *args], env=env,
                                      capture_output=True, text=True, check=True)
            def repository(name):
                path = root / name
                subprocess.run(['git', 'init', '-q', str(path)], env=env, check=True)
                (path / 'fixture').write_text('fixture\n')
                git(path, 'add', 'fixture')
                git(path, 'commit', '-qm', 'fixture')
                return path
            leaf = repository('leaf source')
            parent = repository('parent source')
            git(parent, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(leaf), 'nested leaf')
            git(parent, 'commit', '-qm', 'nested submodule')
            workspace = repository('checkout with spaces')
            git(workspace, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(parent), 'modules/parent module')
            git(workspace, '-c', 'protocol.file.allow=always', 'submodule', 'update', '--init', '--recursive')
            env.update({'GIT_TEST_ASSUME_DIFFERENT_OWNER': '1', 'GITHUB_WORKSPACE': str(workspace)})
            def status(path):
                return subprocess.run(['git', '-C', str(path), 'ls-files', '--stage'], env=env,
                                      capture_output=True, text=True)
            before = status(workspace)
            self.assertNotEqual(before.returncode, 0)
            self.assertIn('dubious ownership', before.stderr)
            result = subprocess.run(['bash', '-euo', 'pipefail', '-c', trust['run']], cwd=workspace,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in [workspace, workspace / 'modules/parent module', workspace / 'modules/parent module/nested leaf']:
                result = status(path)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('dubious ownership', status(leaf).stderr)

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


class AssemblyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='mdf-ci-assembly-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.rpm = 'mdf-0.2.0-42.x86_64.rpm'
        self.deb = 'mdf_0.2.0-42_amd64.deb'
        for distro in ('fedora', 'ubuntu'):
            folder = self.root / distro
            folder.mkdir()
            for name in ('mdf', self.rpm, self.deb, 'build-info.txt'):
                (folder / name).write_bytes(f'{distro} {name}'.encode())
            (folder / 'mdf.sha256').write_text(''.join(
                hashlib.sha256((folder / name).read_bytes()).hexdigest() + '  ' + name + '\n'
                for name in ('mdf', self.rpm, self.deb)))

    def test_release_contains_only_native_packages_and_internal_checksums(self):
        ASSEMBLER.assemble(self.root, 'v0.2.0-42')
        for output, distro, original in [(self.rpm, 'fedora', self.rpm), (self.deb, 'ubuntu', self.deb)]:
            self.assertEqual((self.root / output).read_bytes(), (self.root / distro / original).read_bytes())
        self.assertEqual({path.name for path in self.root.iterdir() if path.is_file()},
                         {self.rpm, self.deb, 'mdf.sha256'})
        for line in (self.root / 'mdf.sha256').read_text().splitlines():
            digest, name = line.split('  ')
            self.assertEqual(hashlib.sha256((self.root / name).read_bytes()).hexdigest(), digest)

    def test_corrupt_or_missing_native_bundle_prevents_assembly(self):
        for distro in ('fedora', 'ubuntu'):
            binary = self.root / distro / 'mdf'
            original = binary.read_bytes()
            binary.write_bytes(b'corrupted')
            with self.assertRaisesRegex(ValueError, distro):
                ASSEMBLER.assemble(self.root, 'v0.2.0-42')
            self.assertFalse((self.root / 'mdf').exists())
            binary.write_bytes(original)
        (self.root / 'ubuntu' / self.deb).unlink()
        with self.assertRaisesRegex(ValueError, 'ubuntu'):
            ASSEMBLER.assemble(self.root, 'v0.2.0-42')

    def test_version_mismatch_cannot_be_published(self):
        with self.assertRaises(ValueError):
            ASSEMBLER.assemble(self.root, 'v0.2.1-42')
        self.assertFalse((self.root / 'mdf.sha256').exists())


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
    with open(os.environ['MDF_TEST_GH_LOG']) as log:
        reads = sum(json.loads(line)[0] == 'api' for line in log)
    print(os.environ.get('MDF_TEST_TAGS_AFTER', os.environ.get('MDF_TEST_TAGS', 'v0.2.0-42'))
          if reads > 1 else os.environ.get('MDF_TEST_TAGS', 'v0.2.0-42'))
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
        self.assertEqual({item for item in create if item.startswith('build/')},
                         {'build/mdf-0.2.0-42.x86_64.rpm', 'build/mdf_0.2.0-42_amd64.deb'})
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
            edits = [call for call in self.calls() if call[:2] == ['release', 'edit']]
            self.assertEqual(edits[-1], ['release', 'edit', expected, '--latest'])

    def test_latest_rechecks_a_new_release_during_promotion(self):
        self.env['MDF_TEST_TAGS'] = 'v0.2.0-41'
        self.env['MDF_TEST_TAGS_AFTER'] = 'v0.2.0-41\nv0.2.0-42'
        result = self.run_publish('--promote')
        self.assertEqual(result.returncode, 0, result.stderr)
        edits = [call[2] for call in self.calls() if call[:2] == ['release', 'edit']]
        self.assertEqual(edits, ['v0.2.0-41', 'v0.2.0-42'])


if __name__ == '__main__':
    unittest.main()
