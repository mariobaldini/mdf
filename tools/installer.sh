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

mdf_repository=https://github.com/mariobaldini/mdf
mdf_latest=$(curl --fail --silent --show-error --location --retry 3 \
    --output /dev/null --write-out '%{url_effective}' "$mdf_repository/releases/latest")
mdf_tag=${mdf_latest##*/}
mdf_version=${mdf_tag#v}
if [[ ! $mdf_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' 'The latest release has an unsupported version tag.' >&2
    exit 1
fi
if [[ $mdf_format == deb ]]; then mdf_package="mdf_${mdf_version}_amd64.deb"
else mdf_package="mdf-${mdf_version}-1.x86_64.rpm"
fi
mdf_download=$(mktemp -d)
trap 'rm -rf "$mdf_download"' EXIT
for mdf_file in "$mdf_package" mdf.sha256; do
    curl --fail --silent --show-error --location --retry 3 \
        "$mdf_repository/releases/download/$mdf_tag/$mdf_file" --output "$mdf_download/$mdf_file"
done
(cd "$mdf_download" && sha256sum --check --ignore-missing mdf.sha256)
# APT's download sandbox must be able to read the local package.
chmod 755 "$mdf_download"
chmod 644 "$mdf_download/$mdf_package"
"${mdf_admin[@]}" "$mdf_manager" install -y "$mdf_download/$mdf_package"
