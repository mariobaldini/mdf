#!/bin/sh
# Rust is retained only for SVG parsing, text shaping and rasterization.
. "$(dirname -- "$0")/common.sh"
mdf_svg_mode=${1:-Debug}
mdf_svg_command=${2:-build}
case "$mdf_svg_command" in build|test);; *) exit 2;; esac
case "$mdf_svg_mode" in ReleaseFast) set -- --release;; Debug) set --;; *) exit 2;; esac
export CARGO_HOME="$MDF_ROOT/build/.cargo"
export CARGO_INCREMENTAL=0
export RUSTFLAGS='-C target-cpu=x86-64 -C force-frame-pointers=no'
cargo "$mdf_svg_command" --offline --frozen --manifest-path frontend/svg/Cargo.toml \
    --target-dir "$MDF_ROOT/build/svg" --jobs "${MDF_BUILD_JOBS:-2}" \
    --config 'source.crates-io.replace-with="mdf-vendored"' \
    --config "source.mdf-vendored.directory=\"$MDF_ROOT/zig-pkg/svg-deps\"" "$@"
