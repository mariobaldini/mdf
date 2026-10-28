#!/usr/bin/env python3
"""Exercise real RPM signatures, repository metadata, and DNF upgrades in temporary roots."""
import configparser
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from threading import Thread
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('rpm_repository', ROOT / 'tools/scripts/rpm-repository.py')
REPOSITORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPOSITORY)
VERSION = (ROOT / 'VERSION').read_text().strip() + '.0'


class SelectionTests(unittest.TestCase):
    def test_versions_and_revisions_use_integer_order(self):
        for tags, expected in [(['v0.9.0-100', 'v0.10.0-2'], 'v0.10.0-2'),
                               (['v1.0.0-9', 'v1.0.0-100', 'v1.0.0-42'], 'v1.0.0-100'),
                               (['v1.0.0-100', 'v1.0.1'], 'v1.0.1')]:
            self.assertEqual(REPOSITORY.newest_tag(tags), expected)
        with self.assertRaises(ValueError):
            REPOSITORY.newest_tag(['v1.0', '../bad', 'v1.0.0-0', 'v1.0.0-01'])

    def test_selection_ignores_drafts_and_prereleases_and_checks_asset(self):
        def release(tag, **extra):
            return {'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': [], **extra}
        name = f'mdf-{VERSION}-10.x86_64.rpm'
        asset = {'name': name, 'state': 'uploaded', 'digest': 'sha256:' + 'a' * 64,
                 'browser_download_url': f'https://github.com/owner/project/releases/download/v{VERSION}-10/{name}'}
        releases = [release(f'v{VERSION}-10', assets=[asset]), release(f'v{VERSION}-9'),
                    release('v99.0.0', draft=True), release('v99.1.0', prerelease=True)]
        tag, selected = REPOSITORY.release_asset(releases, 'owner/project')
        self.assertEqual(tag, f'v{VERSION}-10')
        self.assertEqual(selected, asset)
        for field, value in [('digest', None), ('state', 'new'), ('browser_download_url', 'https://example.invalid/rpm')]:
            with self.subTest(field=field), patch.dict(asset, {field: value}), self.assertRaises(ValueError):
                REPOSITORY.release_asset(releases, 'owner/project')
        releases[0]['assets'].append(dict(asset))
        with self.assertRaises(ValueError):
            REPOSITORY.release_asset(releases, 'owner/project')


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class RepositoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='mdf-repository-tests-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        home = cls.root / 'key-generation'
        home.mkdir(mode=0o700)
        cls.gpg_env = {**os.environ, 'GNUPGHOME': str(home)}
        cls.addClassCleanup(lambda: subprocess.run(['gpgconf', '--kill', 'gpg-agent'], env=cls.gpg_env,
                                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        password = cls.root / 'passphrase'
        password.write_text('temporary-test-passphrase\n')
        password.chmod(0o600)
        cls.keys = []
        for number in range(2):
            identity = f'MDF repository test {number} <test{number}@example.invalid>'
            REPOSITORY.run('gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase-file', str(password),
                           '--quick-generate-key', identity, 'rsa2048', 'sign', '0', env=cls.gpg_env)
            listing = REPOSITORY.run('gpg', '--batch', '--with-colons', '--list-keys', identity, env=cls.gpg_env)
            fingerprint = REPOSITORY.fingerprints(listing)[0]
            public = cls.root / f'public-{number}.asc'
            public.write_bytes(REPOSITORY.run('gpg', '--batch', '--armor', '--export', fingerprint, env=cls.gpg_env))
            private = REPOSITORY.run('gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase-file', str(password),
                                     '--armor', '--export-secret-keys', fingerprint, env=cls.gpg_env).decode()
            cls.keys.append((public, private))
        cls.env = {'MDF_RPM_GPG_PRIVATE_KEY': cls.keys[0][1], 'MDF_RPM_GPG_PASSPHRASE': password.read_text().strip()}
        cls.fixture_rpms = {}
        top = cls.root / 'rpmbuild'
        (top / 'SPECS').mkdir(parents=True)
        for revision in (9, 10, 11):
            spec = top / 'SPECS/mdf.spec'
            spec.write_text(f'''%global debug_package %{{nil}}
Name: mdf
Version: {VERSION}
Release: {revision}
Summary: MDF repository transaction fixture
License: MIT
BuildArch: x86_64

%description
Temporary fixture for signed repository transaction tests.

%install
mkdir -p "%{{buildroot}}/usr/share/mdf-repository-test"
printf '%s\\n' '{revision}' > "%{{buildroot}}/usr/share/mdf-repository-test/revision"

%files
/usr/share/mdf-repository-test/revision
''')
            REPOSITORY.run('rpmbuild', '--quiet', '-bb', '--define', f'_topdir {top}', str(spec))
            cls.fixture_rpms[revision] = top / f'RPMS/x86_64/mdf-{VERSION}-{revision}.x86_64.rpm'
        cls.unsigned = cls.root / cls.fixture_rpms[11].name
        shutil.copy2(cls.fixture_rpms[11], cls.unsigned)
        with patch.dict(os.environ, cls.env), REPOSITORY.signing_key(cls.keys[0][0]) as key:
            for rpm in cls.fixture_rpms.values():
                key.sign_rpm(rpm)
        cls.foreign = cls.root / 'foreign' / cls.fixture_rpms[11].name
        cls.foreign.parent.mkdir()
        shutil.copy2(cls.unsigned, cls.foreign)
        with patch.dict(os.environ, {**cls.env, 'MDF_RPM_GPG_PRIVATE_KEY': cls.keys[1][1]}), \
                REPOSITORY.signing_key(cls.keys[1][0]) as key:
            key.sign_rpm(cls.foreign)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='case-', dir=self.root)
        self.addCleanup(temporary.cleanup)
        self.case = Path(temporary.name)
        self.environment = patch.dict(os.environ, self.env)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_sign_release_updates_the_manifest_and_preserves_deb_and_payload(self):
        rpm = self.case / self.unsigned.name
        shutil.copy2(self.unsigned, rpm)
        deb = self.case / 'mdf.deb'
        deb.write_bytes(b'unchanged DEB package')
        manifest = self.case / 'mdf.sha256'
        manifest.write_text(''.join(f'{REPOSITORY.checksum(path)}  {path.name}\n' for path in (rpm, deb)))
        original_payload = REPOSITORY.run('rpm2cpio', str(rpm))
        original = manifest.read_text()
        REPOSITORY.sign_release(self.case, self.keys[0][0])
        self.assertNotEqual(manifest.read_text(), original)
        self.assertEqual(deb.read_bytes(), b'unchanged DEB package')
        self.assertEqual(REPOSITORY.run('rpm2cpio', str(rpm)), original_payload)
        REPOSITORY.run('sha256sum', '--check', 'mdf.sha256', cwd=self.case)

    def test_missing_wrong_or_locked_key_stops_without_changing_the_release(self):
        rpm = self.case / self.unsigned.name
        shutil.copy2(self.unsigned, rpm)
        deb = self.case / 'mdf.deb'
        deb.write_bytes(b'DEB')
        manifest = self.case / 'mdf.sha256'
        manifest.write_text(''.join(f'{REPOSITORY.checksum(path)}  {path.name}\n' for path in (rpm, deb)))
        original = {path.name: path.read_bytes() for path in self.case.iterdir()}
        for override in [{'MDF_RPM_GPG_PRIVATE_KEY': ''}, {'MDF_RPM_GPG_PASSPHRASE': ''},
                         {'MDF_RPM_GPG_PRIVATE_KEY': self.keys[1][1]}, {'MDF_RPM_GPG_PASSPHRASE': 'incorrect'}]:
            with self.subTest(override=list(override)), patch.dict(os.environ, override):
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    REPOSITORY.sign_release(self.case, self.keys[0][0])
                self.assertEqual({path.name: path.read_bytes() for path in self.case.iterdir()}, original)

    def test_key_creation_refuses_to_overwrite_a_public_key_or_backup(self):
        backup = self.case / 'backup'
        public = self.case / 'public.asc'
        public.write_text('existing public key\n')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            REPOSITORY.create_signing_key(backup, public)
        self.assertFalse(backup.exists())
        self.assertEqual(public.read_text(), 'existing public key\n')
        backup.mkdir()
        public.unlink()
        with self.assertRaisesRegex(ValueError, 'already exists'):
            REPOSITORY.create_signing_key(backup, public)
        self.assertFalse(public.exists())

    def test_unsigned_foreign_and_corrupt_rpms_are_rejected(self):
        corrupt = self.case / 'corrupt.rpm'
        data = bytearray(self.fixture_rpms[11].read_bytes())
        data[-1] ^= 1
        corrupt.write_bytes(data)
        with REPOSITORY.signing_key(self.keys[0][0], private=False) as key:
            for rpm in (self.unsigned, self.foreign, corrupt):
                with self.subTest(rpm=rpm.name), self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    key.verify_rpm(rpm)

    def test_metadata_mismatch_and_unsigned_inputs_produce_no_snapshot(self):
        output = self.case / 'site'
        with REPOSITORY.signing_key(self.keys[0][0]) as key:
            for rpm, tag in [(self.unsigned, f'v{VERSION}-11'), (self.fixture_rpms[9], f'v{VERSION}-10')]:
                with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    REPOSITORY.build_repository(rpm, tag, 'https://example.invalid/mdf',
                                                'https://github.com/owner/project/releases/download/', output, key)
                self.assertFalse(output.exists())

    def test_github_digest_mismatch_produces_no_snapshot(self):
        rpm = self.fixture_rpms[10]
        tag = f'v{VERSION}-10'
        releases = [[{'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': [{
            'name': rpm.name, 'state': 'uploaded', 'digest': 'sha256:' + '0' * 64,
            'browser_download_url': f'https://github.com/owner/project/releases/download/{tag}/{rpm.name}'}]}]]
        original_run = REPOSITORY.run
        def run(*args, **kwargs):
            return json.dumps(releases).encode() if args[0] == 'gh' else original_run(*args, **kwargs)
        with patch.object(REPOSITORY, 'run', side_effect=run), \
                patch.object(REPOSITORY, 'download', side_effect=lambda url, target: shutil.copy2(rpm, target)):
            with self.assertRaisesRegex(ValueError, 'GitHub SHA-256'):
                REPOSITORY.build_from_releases('owner/project', 'https://example.invalid/mdf',
                                               self.case / 'site', self.keys[0][0])
        self.assertFalse((self.case / 'site').exists())

    @unittest.skipUnless(os.geteuid() == 0, 'Run inside a disposable Fedora 44 container for DNF transactions')
    def test_dnf_add_install_upgrade_and_signature_rejections_over_http(self):
        web = self.case / 'web'
        web.mkdir()
        server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(web)))
        self.addCleanup(server.server_close)
        Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        base = f'http://127.0.0.1:{server.server_port}'
        site_url, download_base = base + '/site', base + '/releases/download/'
        installroot = self.case / 'installroot'
        repos = self.case / 'repos'
        repos.mkdir()
        command = ['dnf', '-y', '--installroot=' + str(installroot), '--releasever=44',
                   '--setopt=reposdir=' + str(repos), '--setopt=logdir=' + str(self.case / 'logs'),
                   '--setopt=cachedir=' + str(self.case / 'cache')]

        def dnf(*args, succeeds=True):
            result = subprocess.run([*command, *args], capture_output=True, text=True)
            if succeeds:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertRegex(result.stdout + result.stderr, '(?i)signature|gpg|not signed')
            return result

        def publish(revision, key):
            tag = f'v{VERSION}-{revision}'
            rpm = self.fixture_rpms[revision]
            target = web / 'releases/download' / tag
            target.mkdir(parents=True, exist_ok=True)
            shutil.copy2(rpm, target / rpm.name)
            output = self.case / f'snapshot-{revision}'
            REPOSITORY.build_repository(rpm, tag, site_url, download_base, output, key)
            self.assertFalse(list(output.rglob('*.rpm')))
            if (web / 'site').exists():
                shutil.rmtree(web / 'site')
            shutil.copytree(output, web / 'site')

        def installed_revision():
            return REPOSITORY.run('rpm', '--root', str(installroot), '-q', '--queryformat', '%{RELEASE}', 'mdf').decode()

        with REPOSITORY.signing_key(self.keys[0][0]) as key:
            publish(9, key)
            config = configparser.ConfigParser(interpolation=None)
            config.read(web / 'site/mdf.repo')
            self.assertEqual(config['mdf']['gpgcheck'], '1')
            self.assertEqual(config['mdf']['repo_gpgcheck'], '1')
            self.assertEqual(config['mdf']['metadata_expire'], '1h')
            self.assertEqual(config['mdf']['baseurl'], site_url + '/rpm/fedora/$releasever/$basearch/')
            dnf('config-manager', 'addrepo', '--from-repofile=' + site_url + '/mdf.repo')
            dnf('--refresh', 'install', 'mdf')
            self.assertEqual(installed_revision(), '9')
            publish(10, key)
            dnf('--refresh', 'update', 'mdf')
            self.assertEqual(installed_revision(), '10')

            signature = web / 'site/rpm/fedora/44/x86_64/repodata/repomd.xml.asc'
            signature.write_text('invalid metadata signature\n')
            dnf('--refresh', 'makecache', succeeds=False)
            self.assertEqual(installed_revision(), '10')

            # A valid metadata signature cannot authorize an unsigned or foreign RPM.
            repo = web / 'site/rpm/fedora/44/x86_64'
            tag = f'v{VERSION}-11'
            package_dir = repo / tag
            package_dir.mkdir()
            for source in (self.unsigned, self.foreign):
                shutil.copy2(source, package_dir / self.unsigned.name)
                target = web / 'releases/download' / tag
                target.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target / self.unsigned.name)
                REPOSITORY.run('createrepo_c', '--baseurl', download_base, str(repo))
                key.sign_metadata(repo / 'repodata/repomd.xml')
                dnf('--refresh', 'update', 'mdf', succeeds=False)
                self.assertEqual(installed_revision(), '10')


if __name__ == '__main__':
    for tool in ('rpmbuild', 'rpmkeys', 'rpmsign', 'rpm2cpio', 'createrepo_c', 'gpg', 'gpgconf', 'dnf'):
        if not shutil.which(tool):
            raise SystemExit(f'{tool} is required. Run these tests in Fedora 44 with the repository tools installed.')
    unittest.main(verbosity=2)
