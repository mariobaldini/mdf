#!/bin/sh
# Provision a fresh Fedora 44 or Ubuntu 26.04 container as root: the build image and the CI jobs both run this.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export DEBIAN_FRONTEND=noninteractive
MDF_REFERENCE=1 MDF_RELEASE_TOOLS=1 sh "$root/tools/scripts/install-packages.sh"
mdf_zig=$(python3 "$root/tools/scripts/fetch-zig.py" --prefix /opt)
ln -sf "$mdf_zig" /usr/local/bin/zig
zig version
