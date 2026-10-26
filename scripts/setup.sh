#!/bin/sh
. "$(dirname -- "$0")/common.sh"

# Install Fedora build tools and fetch the pinned source dependencies.
if [ ! -r /etc/os-release ]; then
    printf '%s\n' 'Automatic setup requires Fedora 44.' >&2
    exit 1
fi
. /etc/os-release
if [ "$ID" != fedora ] || [ "$VERSION_ID" != 44 ]; then
    printf 'Automatic setup supports Fedora 44. Install GNU Make, Zig %s, and CA certificates manually.\n' "$MDF_ZIG_VERSION" >&2
    exit 1
fi

set --
command -v make >/dev/null 2>&1 || set -- "$@" make
if [ "$ZIG" != zig ] && ! command -v "$ZIG" >/dev/null 2>&1; then
    printf 'The requested compiler does not exist: %s\n' "$ZIG" >&2
    exit 1
fi
rpm -q ca-certificates >/dev/null 2>&1 || set -- "$@" ca-certificates
mdf_packages='pkgconf-pkg-config binutils pango-devel fontconfig-devel wayland-devel wayland-protocols-devel libxkbcommon-devel weston weston-devel git git-lfs python3-pyyaml'
if [ "${MDF_REFERENCE:-0}" = 1 ];then
    mdf_packages="$mdf_packages cmake ninja-build gcc gcc-c++ libstdc++-static clang-tools-extra cairo-devel pixman-devel glib2-devel fribidi-devel harfbuzz-devel freetype-devel"
fi
for mdf_package in $mdf_packages; do
    rpm -q "$mdf_package" >/dev/null 2>&1 || set -- "$@" "$mdf_package"
done
command -v rpmbuild >/dev/null 2>&1 || set -- "$@" rpm-build
command -v dpkg-deb >/dev/null 2>&1 || set -- "$@" dpkg
command -v cpio >/dev/null 2>&1 || set -- "$@" cpio
command -v python3 >/dev/null 2>&1 || set -- "$@" python3
command -v strace >/dev/null 2>&1 || set -- "$@" strace
command -v sudo >/dev/null 2>&1 || set -- "$@" sudo
command -v tee >/dev/null 2>&1 || set -- "$@" coreutils
if [ "$#" -gt 0 ]; then
    printf 'Installing Fedora dependencies:'
    printf ' %s' "$@"
    printf '\n'
    if [ "$(id -u)" -eq 0 ]; then
        dnf install -y "$@"
    else
        sudo dnf install -y "$@"
    fi
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
