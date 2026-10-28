#!/usr/bin/env python3
"""Sign release RPMs and build a DNF repository backed by GitHub Releases."""
import argparse
from contextlib import contextmanager
import hashlib
import html
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[2]
PUBLIC_KEY = ROOT / 'tools/RPM-GPG-KEY-mdf'
TAG = re.compile(r'v([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([1-9][0-9]*))?')


def run(*args, **kwargs):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout


def checksum(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def tag_version(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError('Invalid MDF release tag')
    return tuple(int(part or 1) for part in match.groups())


def newest_tag(tags):
    valid = [tag for tag in tags if TAG.fullmatch(tag)]
    if not valid:
        raise ValueError('No published MDF release found')
    return max(valid, key=lambda tag: (tag_version(tag), tag))


def fingerprints(listing):
    result = []
    primary = False
    for line in listing.decode().splitlines():
        fields = line.split(':')
        if fields[0] in ('pub', 'sec'):
            primary = True
        elif fields[0] in ('sub', 'ssb'):
            primary = False
        elif fields[0] == 'fpr' and primary:
            result.append(fields[9])
            primary = False
    return result


class SigningKey:
    def __init__(self, directory, public_key):
        self.directory = Path(directory)
        self.public_key = public_key.resolve()
        self.env = {**os.environ, 'GNUPGHOME': str(self.directory / 'gnupg')}
        Path(self.env['GNUPGHOME']).mkdir(mode=0o700)
        run('gpg', '--batch', '--import', str(self.public_key), env=self.env)
        keys = fingerprints(run('gpg', '--batch', '--with-colons', '--list-keys', env=self.env))
        if len(keys) != 1:
            raise ValueError('The MDF public key file must contain exactly one primary key')
        self.fingerprint = keys[0]
        self.rpmdb = self.directory / 'rpmdb'
        run('rpmkeys', '--dbpath', str(self.rpmdb), '--import', str(self.public_key))

    def import_private_key(self):
        private_key = os.environ.get('MDF_RPM_GPG_PRIVATE_KEY', '')
        passphrase = os.environ.get('MDF_RPM_GPG_PASSPHRASE', '')
        if not private_key or not passphrase or '\n' in passphrase or '\r' in passphrase:
            raise ValueError('Set MDF_RPM_GPG_PRIVATE_KEY and MDF_RPM_GPG_PASSPHRASE before publication')
        run('gpg', '--batch', '--import', env=self.env, input=private_key.encode())
        keys = fingerprints(run('gpg', '--batch', '--with-colons', '--list-secret-keys', env=self.env))
        if keys != [self.fingerprint]:
            raise ValueError('The private signing key does not match the committed MDF public key')
        self.passphrase_file = self.directory / 'passphrase'
        with open(self.passphrase_file, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
            output.write(passphrase + '\n')

    def verify_rpm(self, path):
        result = run('rpmkeys', '--dbpath', str(self.rpmdb), '--checksig', '--verbose', str(path)).decode()
        if not re.search(r'(?im)^.*\bsignature.*:\s+OK\s*$', result):
            raise ValueError('The RPM has no valid MDF signature')

    def sign_rpm(self, path):
        run('rpmsign', '--addsign', '--define', '_openpgp_sign gpg',
            '--define', f'_openpgp_sign_id {self.fingerprint}',
            '--define', '_gpg_sign_cmd_extra_args --batch --pinentry-mode loopback --passphrase-file '
            + shlex.quote(str(self.passphrase_file)), str(path), env=self.env)
        self.verify_rpm(path)

    def sign_metadata(self, path):
        run('gpg', '--batch', '--yes', '--pinentry-mode', 'loopback', '--passphrase-file',
            str(self.passphrase_file), '--local-user', self.fingerprint, '--digest-algo', 'SHA256',
            '--armor', '--detach-sign', str(path), env=self.env)
        run('gpg', '--batch', '--verify', str(path) + '.asc', str(path), env=self.env)


@contextmanager
def signing_key(public_key, private=True):
    with tempfile.TemporaryDirectory(prefix='mdf-rpm-signing-') as directory:
        env = {**os.environ, 'GNUPGHOME': str(Path(directory) / 'gnupg')}
        try:
            key = SigningKey(directory, public_key)
            if private:
                key.import_private_key()
            yield key
        finally:
            subprocess.run(['gpgconf', '--kill', 'gpg-agent'], env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def sign_release(directory, public_key):
    rpms, debs = list(directory.glob('*.rpm')), list(directory.glob('*.deb'))
    if len(rpms) != 1 or len(debs) != 1:
        raise ValueError('A release must contain exactly one RPM and one DEB')
    run('sha256sum', '--check', '--strict', 'mdf.sha256', cwd=directory)
    for path in (*rpms, *debs):
        if f'{checksum(path)}  {path.name}' not in (directory / 'mdf.sha256').read_text().splitlines():
            raise ValueError(f'The release manifest does not cover {path.name}')
    with signing_key(public_key) as key, tempfile.TemporaryDirectory(dir=directory) as temporary:
        stage = Path(temporary)
        signed_rpm = stage / rpms[0].name
        shutil.copy2(rpms[0], signed_rpm)
        key.sign_rpm(signed_rpm)
        manifest = stage / 'mdf.sha256'
        manifest.write_text(f'{checksum(signed_rpm)}  {signed_rpm.name}\n'
                            f'{checksum(debs[0])}  {debs[0].name}\n')
        signed_rpm.replace(rpms[0])
        manifest.replace(directory / 'mdf.sha256')
    print(f'Signed {rpms[0].name} and updated release checksums')


def release_asset(releases, repository):
    public = [release for release in releases if not release['draft'] and not release['prerelease']]
    tag = newest_tag([release['tag_name'] for release in public])
    release = next(release for release in public if release['tag_name'] == tag)
    major, minor, patch, revision = tag_version(tag)
    name = f'mdf-{major}.{minor}.{patch}-{revision}.x86_64.rpm'
    assets = [asset for asset in release['assets'] if asset['name'] == name and asset['state'] == 'uploaded']
    if len(assets) != 1:
        raise ValueError(f'Release {tag} must contain exactly one uploaded {name}')
    asset = assets[0]
    url = f'https://github.com/{repository}/releases/download/{tag}/{name}'
    if asset['browser_download_url'] != url or not re.fullmatch(r'sha256:[0-9a-f]{64}', asset.get('digest') or ''):
        raise ValueError('The published RPM has an invalid download URL or SHA-256 digest')
    return tag, asset


def download(url, destination):
    for attempt in range(3):
        try:
            with urlopen(url, timeout=60) as source, destination.open('wb') as output:
                shutil.copyfileobj(source, output)
            return
        except OSError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def create_signing_key(directory, public_key):
    """Create one persistent project key, with a local backup outside version control."""
    if directory.exists() or public_key.exists():
        raise ValueError('The signing key or backup directory already exists. Preserve the existing key.')
    directory.mkdir(mode=0o700, parents=True)
    home = directory / 'gnupg'
    home.mkdir(mode=0o700)
    env = {**os.environ, 'GNUPGHOME': str(home)}
    passphrase = directory / 'passphrase'
    with open(passphrase, 'x', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
        output.write(secrets.token_urlsafe(48) + '\n')
    try:
        run('gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase-file', str(passphrase),
            '--quick-generate-key', 'Markdown FAST packages <mariobaldini@users.noreply.github.com>',
            'rsa4096', 'sign', '0', env=env)
        fingerprint = fingerprints(run('gpg', '--batch', '--with-colons', '--list-keys', env=env))[0]
        private = run('gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase-file', str(passphrase),
                      '--armor', '--export-secret-keys', fingerprint, env=env)
        with open(directory / 'private-key.asc', 'xb', opener=lambda path, flags: os.open(path, flags, 0o600)) as output:
            output.write(private)
        public_key.parent.mkdir(parents=True, exist_ok=True)
        public_key.write_bytes(run('gpg', '--batch', '--armor', '--export', fingerprint, env=env))
        (directory / 'fingerprint').write_text(fingerprint + '\n')
    finally:
        subprocess.run(['gpgconf', '--kill', 'gpg-agent'], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'MDF signing key: {fingerprint}\nPublic key: {public_key}\nPrivate backup: {directory}')


def build_repository(rpm, tag, site_url, download_base, output, key):
    """Generate a complete snapshot; callers publish it only after this succeeds."""
    major, minor, patch, revision = tag_version(tag)
    expected = f'mdf {major}.{minor}.{patch} {revision} x86_64'
    key.verify_rpm(rpm)
    actual = run('rpm', '-qp', '--queryformat', '%{NAME} %{VERSION} %{RELEASE} %{ARCH}', str(rpm)).decode()
    if actual != expected:
        raise ValueError('The signed RPM metadata does not match its release tag')
    if output.exists():
        raise ValueError('The repository output directory already exists. Select a new directory.')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.dnf-stage-', dir=output.parent) as temporary:
        site = Path(temporary) / 'site'
        repo = site / 'rpm/fedora/44/x86_64'
        packages = repo / tag
        packages.mkdir(parents=True)
        shutil.copy2(rpm, packages / rpm.name)
        run('createrepo_c', '--checksum', 'sha256', '--baseurl', download_base.rstrip('/') + '/', str(repo))
        key.sign_metadata(repo / 'repodata/repomd.xml')
        shutil.rmtree(packages)
        shutil.copyfile(key.public_key, site / 'RPM-GPG-KEY-mdf')
        site_url = site_url.rstrip('/')
        (site / 'mdf.repo').write_text(
            '[mdf]\nname=Markdown FAST\n'
            f'baseurl={site_url}/rpm/fedora/$releasever/$basearch/\n'
            f'gpgkey={site_url}/RPM-GPG-KEY-mdf\n'
            'enabled=1\ngpgcheck=1\nrepo_gpgcheck=1\nmetadata_expire=1h\n')
        (site / 'index.html').write_text(
            '<!doctype html><html lang="en"><meta charset="utf-8"><title>Markdown FAST RPM repository</title>'
            '<h1>Markdown FAST</h1><p>Signed packages for Fedora 44, x86_64.</p>'
            '<p><a href="mdf.repo">DNF repository configuration</a> · '
            '<a href="RPM-GPG-KEY-mdf">Public signing key</a></p>'
            f'<p>Signing key fingerprint: <code>{html.escape(key.fingerprint)}</code></p>'
            f'<p>Current release: {html.escape(tag)}</p></html>\n')
        site.replace(output)
    print(f'Prepared DNF repository for {tag} in {output}')


def build_from_releases(repository, site_url, output, public_key):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Specify the GitHub repository as owner/name')
    if not re.fullmatch(r'https://[A-Za-z0-9.-]+(?:/[A-Za-z0-9_.-]+)*', site_url.rstrip('/')):
        raise ValueError('Specify an HTTPS Pages URL without a query or fragment')
    with signing_key(public_key) as key:
        pages = json.loads(run('gh', 'api', f'repos/{repository}/releases?per_page=100', '--paginate', '--slurp'))
        tag, asset = release_asset([release for page in pages for release in page], repository)
        with tempfile.TemporaryDirectory(prefix='mdf-published-rpm-') as temporary:
            rpm = Path(temporary) / asset['name']
            # Public downloads must work without a GitHub authentication header.
            download(asset['browser_download_url'], rpm)
            if checksum(rpm) != asset['digest'].removeprefix('sha256:'):
                raise ValueError('The downloaded RPM does not match the GitHub SHA-256 digest')
            build_repository(rpm, tag, site_url, f'https://github.com/{repository}/releases/download/', output, key)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest='command', required=True)
    subcommands.add_parser('newest-tag', help='Select the newest release from tags on standard input')
    create = subcommands.add_parser('create-key', help='Create the persistent MDF signing key once')
    create.add_argument('--directory', type=Path, default=ROOT / '.mdf-signing')
    create.add_argument('--public-key', type=Path, default=PUBLIC_KEY)
    sign = subcommands.add_parser('sign-release', help='Sign the assembled RPM and update its checksum')
    sign.add_argument('directory', type=Path, nargs='?', default=Path('build'))
    sign.add_argument('--public-key', type=Path, default=PUBLIC_KEY)
    build = subcommands.add_parser('build', help='Build a signed snapshot from published GitHub Releases')
    build.add_argument('--repository', default=os.environ.get('GH_REPO', ''))
    build.add_argument('--pages-url', required=True)
    build.add_argument('--output', type=Path, default=Path('build/dnf-repository'))
    build.add_argument('--public-key', type=Path, default=PUBLIC_KEY)
    args = parser.parse_args()
    if args.command == 'newest-tag':
        print(newest_tag(sys.stdin.read().splitlines()))
    elif args.command == 'create-key':
        create_signing_key(args.directory.resolve(), args.public_key.resolve())
    elif args.command == 'sign-release':
        sign_release(args.directory.resolve(), args.public_key)
    else:
        build_from_releases(args.repository, args.pages_url, args.output.resolve(), args.public_key)


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        # Commands never contain secret values. GPG reads the passphrase from a private file.
        print(f'{error.cmd[0]} failed: {error.stderr.decode().strip()}', file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, KeyError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
