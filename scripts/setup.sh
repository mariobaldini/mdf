#!/bin/sh
. "$(dirname -- "$0")/common.sh"

# Install Fedora build tools and fetch the pinned source dependencies.
if [ ! -r /etc/os-release ]; then
    printf '%s\n' 'Automatic setup requires Fedora 44.' >&2
    exit 1
fi
. /etc/os-release
if [ "$ID" != fedora ] || [ "$VERSION_ID" != 44 ]; then
    printf '%s\n' 'Automatic setup supports Fedora 44. Install GNU Make, Zig 0.16.0, and CA certificates manually.' >&2
    exit 1
fi

set --
command -v make >/dev/null 2>&1 || set -- "$@" make
if ! command -v "$ZIG" >/dev/null 2>&1; then
    if [ "$ZIG" != zig ]; then
        printf 'The requested compiler does not exist: %s\n' "$ZIG" >&2
        exit 1
    fi
    set -- "$@" zig
fi
rpm -q ca-certificates >/dev/null 2>&1 || set -- "$@" ca-certificates
for mdf_package in cmake ninja-build gcc gcc-c++ libstdc++-static clang-tools-extra pkgconf-pkg-config pango-devel cairo-devel fontconfig-devel wayland-devel wayland-protocols-devel libxkbcommon-devel weston weston-devel cargo rust; do
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
check_tools
printf '%s\n' 'Fetching pinned dependencies for the application and tests...'
python3 scripts/fetch-frontend.py
offline_graph_check
check_frontend_cache
printf '%s\n' 'Setup complete. Run make build.'
