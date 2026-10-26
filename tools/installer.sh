#!/usr/bin/env bash
set -euo pipefail

if (( $# > 1 )) || [[ ${1:-} != '' && ${1:-} != --uninstall ]]; then
    printf '%s\n' 'Usage: installer.sh [--uninstall]' >&2
    exit 1
fi
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    printf '%s\n' 'Markdown FAST release packages require Linux x86_64.' >&2
    exit 1
fi
mdf_libc=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
if [[ ! $mdf_libc =~ ^glibc[[:space:]]+([0-9]+)\.([0-9]+) ]] ||
    (( BASH_REMATCH[1] < 2 || (BASH_REMATCH[1] == 2 && BASH_REMATCH[2] < 38) )); then
    printf '%s\n' 'Markdown FAST requires glibc 2.38 or later.' >&2
    exit 1
fi
mdf_os_release=${MDF_OS_RELEASE:-/etc/os-release}
if [[ ! -r $mdf_os_release ]]; then
    printf '%s\n' 'Cannot identify this Linux distribution.' >&2
    exit 1
fi
. "$mdf_os_release"
case " ${ID:-} ${ID_LIKE:-} " in
    *' debian '*|*' ubuntu '*)
        mdf_format=deb
        mdf_manager=apt-get
        ;;
    *' fedora '*|*' rhel '*|*' centos '*)
        mdf_format=rpm
        if command -v dnf >/dev/null; then mdf_manager=dnf
        elif command -v yum >/dev/null; then mdf_manager=yum
        else printf '%s\n' 'This distribution needs dnf or yum.' >&2; exit 1
        fi
        ;;
    *) printf 'Unsupported Linux distribution: %s.\n' "${ID:-unknown}" >&2; exit 1 ;;
esac
if ! command -v "$mdf_manager" >/dev/null; then
    printf 'The %s package manager is not installed.\n' "$mdf_manager" >&2
    exit 1
fi
mdf_admin=()
if [[ $(id -u) != 0 ]]; then
    if ! command -v sudo >/dev/null; then printf '%s\n' 'Administrator access requires sudo.' >&2; exit 1; fi
    mdf_admin=(sudo)
fi

if [[ ${1:-} == --uninstall ]]; then
    case "$mdf_manager" in
        apt-get) "${mdf_admin[@]}" apt-get remove --purge -y mdf ;;
        *) "${mdf_admin[@]}" "$mdf_manager" remove -y mdf ;;
    esac
    rm -rf -- "${MDF_CONFIG_HOME:-${HOME:?HOME is not set}/.config}/mdf"
    exit 0
fi

if ! command -v python3 >/dev/null; then
    printf '%s\n' 'Python 3 is required to read and verify GitHub release metadata.' >&2
    exit 1
fi
mdf_api=https://api.github.com/repos/mariobaldini/mdf
mdf_curl=(curl --fail --silent --show-error --location --retry 3 --header 'X-GitHub-Api-Version: 2026-03-10')
if [[ -n ${GH_TOKEN:-} ]]; then mdf_curl+=(--header "Authorization: Bearer $GH_TOKEN"); fi
mdf_release=$("${mdf_curl[@]}" --header 'Accept: application/vnd.github+json' "$mdf_api/releases/latest")
mdf_asset=$(printf '%s\n' "$mdf_release" | python3 -c '
import json, re, sys
release = json.load(sys.stdin)
match = re.fullmatch(r"v([0-9]+\.[0-9]+\.[0-9]+)(?:-([1-9][0-9]*))?", release.get("tag_name", ""))
if not match:
    raise SystemExit("The latest release has an unsupported version tag.")
version, revision = match.groups()
suffix = "-" + revision if revision else ""
name = (f"mdf_{version}{suffix}_amd64.deb" if sys.argv[1] == "deb"
        else f"mdf-{version}-{revision or 1}.x86_64.rpm")
assets = [asset for asset in release.get("assets", []) if asset.get("name") == name and asset.get("state") == "uploaded"]
if len(assets) != 1:
    raise SystemExit("The release does not contain the expected package: " + name)
asset = assets[0]
digest = re.fullmatch(r"sha256:([0-9a-f]{64})", str(asset.get("digest", "")))
if not digest or type(asset.get("id")) is not int or asset["id"] <= 0:
    raise SystemExit("The release package has no valid SHA-256 digest or asset ID.")
print(name)
print(digest[1])
print(asset["id"])
' "$mdf_format")
mapfile -t mdf_fields <<< "$mdf_asset"
mdf_package=${mdf_fields[0]}
mdf_digest=${mdf_fields[1]}
mdf_asset_id=${mdf_fields[2]}
mdf_download=$(mktemp -d)
trap 'rm -rf "$mdf_download"' EXIT
"${mdf_curl[@]}" --header 'Accept: application/octet-stream' \
    "$mdf_api/releases/assets/$mdf_asset_id" --output "$mdf_download/$mdf_package"
(cd "$mdf_download" && printf '%s  %s\n' "$mdf_digest" "$mdf_package" | sha256sum --check)
# APT's download sandbox must be able to read the local package.
chmod 755 "$mdf_download"
chmod 644 "$mdf_download/$mdf_package"
"${mdf_admin[@]}" "$mdf_manager" install -y "$mdf_download/$mdf_package"
