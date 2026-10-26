#!/usr/bin/env bash
# Exercise the real copy/uninstall targets and the piped installer in temporary folders.
set -euo pipefail
mdf_test_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mdf_test_scratch=$(mktemp -d)
trap 'rm -rf "$mdf_test_scratch"' EXIT
mdf_test_make=$(command -v make)
mkdir -p "$mdf_test_scratch/project/build/bin" "$mdf_test_scratch/bin" "$mdf_test_scratch/release"
cp "$mdf_test_root/Makefile" "$mdf_test_scratch/project/"

if "$mdf_test_make" --no-print-directory -C "$mdf_test_scratch/project" install BINDIR="$mdf_test_scratch/source bin" > "$mdf_test_scratch/output" 2>&1; then
    printf '%s\n' 'Installation succeeded without the built executable.' >&2
    exit 1
fi
test ! -d "$mdf_test_scratch/source bin"
printf '#!/bin/sh\nprintf "mdf test\\n"\n' > "$mdf_test_scratch/project/build/bin/mdf"
mkdir -p "$mdf_test_scratch/source bin"
printf 'retired companion library\n' > "$mdf_test_scratch/source bin/libmdf-extra.so"
"$mdf_test_make" --no-print-directory -C "$mdf_test_scratch/project" install BINDIR="$mdf_test_scratch/source bin" > "$mdf_test_scratch/output" 2>&1
cmp "$mdf_test_scratch/project/build/bin/mdf" "$mdf_test_scratch/source bin/mdf"
test ! -e "$mdf_test_scratch/source bin/libmdf-extra.so"
test -x "$mdf_test_scratch/source bin/mdf"
test "$(find "$mdf_test_scratch/source bin" -type f | wc -l)" -eq 1
mkdir -p "$mdf_test_scratch/config/mdf" "$mdf_test_scratch/config/other"
printf 'settings\n' > "$mdf_test_scratch/config/mdf/settings.json"
touch "$mdf_test_scratch/config/other/keep" "$mdf_test_scratch/source bin/keep"
printf 'retired companion library\n' > "$mdf_test_scratch/source bin/libmdf-extra.so"
"$mdf_test_make" --no-print-directory -C "$mdf_test_scratch/project" uninstall BINDIR="$mdf_test_scratch/source bin" MDF_CONFIG_HOME="$mdf_test_scratch/config" > "$mdf_test_scratch/output" 2>&1
test ! -e "$mdf_test_scratch/source bin/mdf"
test ! -e "$mdf_test_scratch/source bin/libmdf-extra.so"
test ! -e "$mdf_test_scratch/config/mdf"
test -f "$mdf_test_scratch/config/other/keep"
test -f "$mdf_test_scratch/source bin/keep"
printf '%s\n' 'PASS: install copies one executable and removes the old companion; uninstall preserves unrelated files'

printf 'rpm payload\n' > "$mdf_test_scratch/release/mdf-0.2.0-1.x86_64.rpm"
printf 'deb payload\n' > "$mdf_test_scratch/release/mdf_0.2.0_amd64.deb"
printf 'main rpm payload\n' > "$mdf_test_scratch/release/mdf-0.2.0-42.x86_64.rpm"
printf 'main deb payload\n' > "$mdf_test_scratch/release/mdf_0.2.0-42_amd64.deb"
(cd "$mdf_test_scratch/release" && sha256sum ./*.rpm ./*.deb > mdf.sha256)
# Release manifests use bare asset names, as the real release script does.
sed -i 's@  ./@  @' "$mdf_test_scratch/release/mdf.sha256"
printf 'ID=fedora\n' > "$mdf_test_scratch/os-release"
cat > "$mdf_test_scratch/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mdf_url=
mdf_output=
while (( $# )); do
    case "$1" in
        --output) mdf_output=$2; shift 2 ;;
        --retry|--write-out) shift 2 ;;
        https://*) mdf_url=$1; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$mdf_url" >> "$MDF_TEST_CURL_LOG"
if [[ ${MDF_TEST_DOWNLOAD_FAIL:-0} == 1 ]]; then exit 22; fi
python3 - "$mdf_url" "$mdf_output" <<'PY'
import hashlib,json,os,shutil,sys
from pathlib import Path
files=sorted([*Path(os.environ['MDF_TEST_RELEASE']).glob('*.rpm'),*Path(os.environ['MDF_TEST_RELEASE']).glob('*.deb')])
api='https://api.github.com/repos/mariobaldini/mdf'
if sys.argv[1]==api+'/releases/latest':
    assets=[{'id':index,'name':path.name,'state':'uploaded',
             'digest':None if os.environ.get('MDF_TEST_NO_DIGEST')=='1' else 'sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()}
            for index,path in enumerate(files,1)]
    print(json.dumps({'tag_name':os.environ.get('MDF_TEST_TAG','v0.2.0'),'assets':assets}))
elif sys.argv[1].startswith(api+'/releases/assets/'):
    source=files[int(sys.argv[1].rsplit('/',1)[1])-1]
    shutil.copyfile(source,sys.argv[2])
    if os.environ.get('MDF_TEST_CORRUPT')=='1':
        with open(sys.argv[2],'ab') as target:target.write(b'corrupt')
else:
    raise SystemExit(22)
PY
STUB
cat > "$mdf_test_scratch/bin/uname" <<'STUB'
#!/bin/sh
case "$1" in -s) printf 'Linux\n' ;; -m) printf '%s\n' "${MDF_TEST_ARCH:-x86_64}" ;; esac
STUB
cat > "$mdf_test_scratch/bin/id" <<'STUB'
#!/bin/sh
printf '%s\n' "${MDF_TEST_UID:-0}"
STUB
cat > "$mdf_test_scratch/bin/getconf" <<'STUB'
#!/bin/sh
printf 'glibc %s\n' "${MDF_TEST_GLIBC:-2.43}"
STUB
cat > "$mdf_test_scratch/bin/dnf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "${0##*/}" "$*" >> "$MDF_TEST_MANAGER_LOG"
case "$1" in
    install) cp "${@: -1}" "$MDF_TEST_INSTALLED_PACKAGE" ;;
    remove) rm -f "$MDF_TEST_INSTALLED_PACKAGE" ;;
    *) exit 1 ;;
esac
STUB
cp "$mdf_test_scratch/bin/dnf" "$mdf_test_scratch/bin/apt-get"
cat > "$mdf_test_scratch/bin/sudo" <<'STUB'
#!/bin/sh
printf 'sudo\n' >> "$MDF_TEST_MANAGER_LOG"
exec "$@"
STUB
chmod +x "$mdf_test_scratch/bin/"*

run_installer() {
    cat "$mdf_test_root/tools/installer.sh" | env \
        PATH="$mdf_test_scratch/bin:$PATH" \
        MDF_OS_RELEASE="$mdf_test_scratch/os-release" \
        MDF_CONFIG_HOME="$mdf_test_scratch/config" \
        MDF_TEST_RELEASE="$mdf_test_scratch/release" \
        MDF_TEST_CURL_LOG="$mdf_test_scratch/curl.log" \
        MDF_TEST_MANAGER_LOG="$mdf_test_scratch/manager.log" \
        MDF_TEST_INSTALLED_PACKAGE="$mdf_test_scratch/installed package" \
        bash -s -- "$@" > "$mdf_test_scratch/output" 2>&1
}

run_installer
cmp "$mdf_test_scratch/release/mdf-0.2.0-1.x86_64.rpm" "$mdf_test_scratch/installed package"
grep -q '^dnf install -y ' "$mdf_test_scratch/manager.log"
printf '%s\n' 'PASS: the piped installer selects and verifies the Fedora RPM'
if grep -q 'mdf.sha256' "$mdf_test_scratch/curl.log"; then
    printf '%s\n' 'Installer still requires a release checksum file.' >&2; exit 1
fi
export MDF_TEST_NO_DIGEST=1
if run_installer; then printf '%s\n' 'Missing release digest was accepted.' >&2; exit 1; fi
unset MDF_TEST_NO_DIGEST

export MDF_TEST_CORRUPT=1
if run_installer; then printf '%s\n' 'Corrupt download was accepted.' >&2; exit 1; fi
unset MDF_TEST_CORRUPT
cmp "$mdf_test_scratch/release/mdf-0.2.0-1.x86_64.rpm" "$mdf_test_scratch/installed package"
export MDF_TEST_DOWNLOAD_FAIL=1
if run_installer; then printf '%s\n' 'Failed download was accepted.' >&2; exit 1; fi
unset MDF_TEST_DOWNLOAD_FAIL
cmp "$mdf_test_scratch/release/mdf-0.2.0-1.x86_64.rpm" "$mdf_test_scratch/installed package"
printf '%s\n' 'PASS: corrupt or failed downloads do not reach the package manager'

: > "$mdf_test_scratch/curl.log"
export MDF_TEST_ARCH=aarch64
if run_installer; then printf '%s\n' 'Unsupported architecture was accepted.' >&2; exit 1; fi
test ! -s "$mdf_test_scratch/curl.log"
unset MDF_TEST_ARCH
export MDF_TEST_GLIBC=2.37
if run_installer; then printf '%s\n' 'Unsupported glibc was accepted.' >&2; exit 1; fi
test ! -s "$mdf_test_scratch/curl.log"
unset MDF_TEST_GLIBC
printf 'ID=alpine\n' > "$mdf_test_scratch/os-release"
if run_installer; then printf '%s\n' 'Unsupported distribution was accepted.' >&2; exit 1; fi
test ! -s "$mdf_test_scratch/curl.log"
printf 'ID=ubuntu\nID_LIKE=debian\n' > "$mdf_test_scratch/os-release"
export MDF_TEST_UID=1000
run_installer
cmp "$mdf_test_scratch/release/mdf_0.2.0_amd64.deb" "$mdf_test_scratch/installed package"
grep -q '^sudo$' "$mdf_test_scratch/manager.log"
grep -q '^apt-get install -y ' "$mdf_test_scratch/manager.log"
printf '%s\n' 'PASS: OS and architecture checks reject unsupported hosts; Ubuntu uses the DEB and sudo'
export MDF_TEST_TAG=v0.2.0-42
run_installer
cmp "$mdf_test_scratch/release/mdf_0.2.0-42_amd64.deb" "$mdf_test_scratch/installed package"
printf 'ID=fedora\n' > "$mdf_test_scratch/os-release"
run_installer
cmp "$mdf_test_scratch/release/mdf-0.2.0-42.x86_64.rpm" "$mdf_test_scratch/installed package"
export MDF_TEST_TAG=v0.2.0-invalid
if run_installer; then printf '%s\n' 'Invalid release revision was accepted.' >&2; exit 1; fi
unset MDF_TEST_TAG
printf '%s\n' 'PASS: main build revisions select matching RPM/DEB assets and reject invalid tags'
mkdir -p "$mdf_test_scratch/config/mdf"
printf 'settings\n' > "$mdf_test_scratch/config/mdf/settings.json"
: > "$mdf_test_scratch/curl.log"
run_installer --uninstall
run_installer --uninstall
unset MDF_TEST_UID
test ! -e "$mdf_test_scratch/installed package"
test ! -e "$mdf_test_scratch/config/mdf"
test -f "$mdf_test_scratch/config/other/keep"
test ! -s "$mdf_test_scratch/curl.log"
printf '%s\n' 'PASS: uninstall removes the package and app settings without downloads'
