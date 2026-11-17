#!/bin/sh
# Run make targets in the Fedora 44 or Ubuntu 26.04 build container with the pinned Zig, as the calling user.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
engine=${MDF_CONTAINER_ENGINE:-}
if [ -z "$engine" ]; then
    if command -v docker >/dev/null 2>&1; then
        engine=docker
    elif command -v podman >/dev/null 2>&1; then
        engine=podman
    else
        printf '%s\n' 'Container builds require Docker or Podman. Fedora 44: sudo dnf install podman' >&2
        exit 1
    fi
fi
distro=${MDF_CONTAINER_DISTRO:-fedora}
case "$distro" in
    fedora) base=fedora:44 ;;
    ubuntu) base=ubuntu:26.04 ;;
    *)
        printf 'Unsupported MDF_CONTAINER_DISTRO: %s. Use fedora or ubuntu.\n' "$distro" >&2
        exit 1
        ;;
esac
image=mdf-build:$distro-zig$(cat "$root/.zig-version")

"$engine" build --build-arg "BASE=$base" --build-arg "MDF_UID=$(id -u)" --build-arg "MDF_GID=$(id -g)" \
    --tag "$image" --file "$root/tools/container/Dockerfile" "$root"

mdf_terminal=
if [ -t 0 ] && [ -t 1 ]; then mdf_terminal=--tty; fi
mdf_userns=
# Rootless Podman maps the container user to a subordinate uid unless the caller's uid is kept.
if "$engine" --version 2>/dev/null | grep -qi podman; then mdf_userns=--userns=keep-id; fi
# The checkout keeps its host path so Zig and CMake caches stay valid for host and container builds.
exec "$engine" run --rm --init --interactive $mdf_terminal $mdf_userns --security-opt label=disable \
    --volume "$root:$root" --workdir "$root" "$image" make "$@"
