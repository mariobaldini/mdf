#!/bin/sh
# Compile the pinned native diagram renderer from project-local sources only.
. "$(dirname -- "$0")/common.sh"
mdf_rust_mode=${1:-Debug}
mdf_rust_command=${2:-build}
case "$mdf_rust_command" in build|test);; *) exit 2;; esac
case "$mdf_rust_mode" in ReleaseFast) set -- --release;; Debug) set --;; *) exit 2;; esac
python3 scripts/prepare-mermaid.py
export CARGO_HOME="$MDF_ROOT/build/.cargo"
export CARGO_INCREMENTAL=0
export RUSTFLAGS='-C target-cpu=x86-64 -C force-frame-pointers=no'
if [ "$mdf_rust_command" = test ];then
    cargo test --offline --frozen --manifest-path frontend/mermaid/Cargo.toml \
        --target-dir "$MDF_ROOT/build/mermaid" --jobs "${MDF_BUILD_JOBS:-2}" \
        --config 'source.crates-io.replace-with="mdf-vendored"' \
        --config "source.mdf-vendored.directory=\"$MDF_ROOT/zig-pkg/mermaid-deps\"" "$@"
else
    for mdf_renderer in mermaid svg;do
        cargo build --offline --frozen --manifest-path frontend/mermaid/Cargo.toml \
            --no-default-features --features "$mdf_renderer" \
            --target-dir "$MDF_ROOT/build/mermaid/$mdf_renderer" --jobs "${MDF_BUILD_JOBS:-2}" \
            --config 'source.crates-io.replace-with="mdf-vendored"' \
            --config "source.mdf-vendored.directory=\"$MDF_ROOT/zig-pkg/mermaid-deps\"" "$@"
    done
fi
