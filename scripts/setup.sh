#!/bin/sh
. "$(dirname -- "$0")/common.sh"

# Install supported Linux build tools and fetch pinned source dependencies.
if [ ! -r /etc/os-release ]; then
    printf '%s\n' 'Automatic setup requires Fedora 44 or Ubuntu 26.04.' >&2
    exit 1
fi
. /etc/os-release
case "$ID:$VERSION_ID" in
    fedora:44)
        mdf_package_manager=dnf
        mdf_packages='make ca-certificates pkgconf-pkg-config binutils python3 python3-pyyaml git git-lfs sudo coreutils curl tar xz rpm-build dpkg cpio strace pango-devel fontconfig-devel wayland-devel wayland-protocols-devel libxkbcommon-devel weston weston-devel'
        if [ "$MDF_REFERENCE" = 1 ]; then
            mdf_packages="$mdf_packages cmake ninja-build gcc gcc-c++ libstdc++-static clang-tools-extra cairo-devel pixman-devel glib2-devel fribidi-devel harfbuzz-devel freetype-devel dejavu-sans-mono-fonts"
        fi
        ;;
    ubuntu:26.04)
        mdf_package_manager=apt-get
        mdf_packages='make ca-certificates pkg-config binutils python3 python3-yaml git git-lfs sudo coreutils curl tar xz-utils rpm dpkg-dev cpio strace libpango1.0-dev libfontconfig1-dev libwayland-dev wayland-protocols libxkbcommon-dev weston libweston-14-dev'
        if [ "$MDF_REFERENCE" = 1 ]; then
            mdf_packages="$mdf_packages cmake ninja-build gcc g++ clang-tools libcairo2-dev libpixman-1-dev libglib2.0-dev libfribidi-dev libharfbuzz-dev libfreetype-dev fonts-dejavu-core"
        fi
        ;;
    *)
        printf 'Automatic setup supports Fedora 44 and Ubuntu 26.04. Install GNU Make, Zig %s, and CA certificates manually.\n' "$MDF_ZIG_VERSION" >&2
        exit 1
        ;;
esac

mdf_package_installed() {
    case "$mdf_package_manager" in
        dnf) rpm -q "$1" >/dev/null 2>&1 ;;
        apt-get) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx 'install ok installed' ;;
    esac
}

mdf_as_root() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

set --
if [ "$ZIG" != zig ] && ! command -v "$ZIG" >/dev/null 2>&1; then
    printf 'The requested compiler does not exist: %s\n' "$ZIG" >&2
    exit 1
fi
for mdf_package in $mdf_packages; do
    mdf_package_installed "$mdf_package" || set -- "$@" "$mdf_package"
done
if [ "$#" -gt 0 ]; then
    printf 'Installing %s dependencies:' "$ID"
    printf ' %s' "$@"
    printf '\n'
    if [ "$mdf_package_manager" = apt-get ]; then mdf_as_root apt-get update; fi
    mdf_as_root "$mdf_package_manager" install -y "$@"
fi
if [ "$ZIG" = zig ] && { ! command -v zig >/dev/null 2>&1 || [ "$(zig version)" != "$MDF_ZIG_VERSION" ]; }; then
    ZIG=$(python3 scripts/fetch-zig.py)
fi
export ZIG
check_tools
printf '%s\n' 'Fetching pinned application dependencies...'
python3 scripts/fetch-frontend.py
offline_graph_check
check_frontend_cache
printf '%s\n' 'Setup complete. Run make build.'
