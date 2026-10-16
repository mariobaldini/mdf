# Shared by the setup and requirements scripts. All paths stay project-local.
set -eu
MDF_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$MDF_ROOT"
ZIG=${ZIG:-zig}
OPTIMIZE=${OPTIMIZE:-Debug}
MDF_TARGET=${MDF_TARGET:-x86_64-linux-gnu.2.38}
ZIG_GLOBAL_CACHE_DIR=${ZIG_GLOBAL_CACHE_DIR:-$MDF_ROOT/build/.zig-cache/global}
export ZIG_GLOBAL_CACHE_DIR
MDF_ZIG_VERSION=$(cat .zig-version)

check_tools() {
    mdf_errors=0
    if ! command -v make >/dev/null 2>&1; then
        printf '%s\n' 'Missing GNU Make. Fedora 44: sudo dnf install make' >&2
        mdf_errors=1
    elif ! make --version | head -n 1 | grep -q 'GNU Make'; then
        printf '%s\n' 'GNU Make is required. Fedora 44: sudo dnf install make' >&2
        mdf_errors=1
    fi
    if ! command -v "$ZIG" >/dev/null 2>&1; then
        printf 'Missing Zig %s (%s). Fedora 44: sudo dnf install zig\n' "$MDF_ZIG_VERSION" "$ZIG" >&2
        mdf_errors=1
    else
        mdf_actual=$("$ZIG" version 2>/dev/null || true)
        if [ "$mdf_actual" != "$MDF_ZIG_VERSION" ]; then
            printf 'Zig %s is required. Found: %s.\n' "$MDF_ZIG_VERSION" "${mdf_actual:-unusable compiler}" >&2
            printf 'Fedora 44: sudo dnf install zig-%s\n' "$MDF_ZIG_VERSION" >&2
            printf 'Or use the official toolchain: make setup ZIG=/path/to/zig\n' >&2
            mdf_errors=1
        fi
    fi
    if command -v rpm >/dev/null 2>&1 && ! rpm -q ca-certificates >/dev/null 2>&1; then
        printf '%s\n' 'Missing certificates. Fedora 44: sudo dnf install ca-certificates' >&2
        mdf_errors=1
    fi
    for mdf_tool in cmake ninja gcc g++ pkg-config python3 cargo rustc; do
        if ! command -v "$mdf_tool" >/dev/null 2>&1; then
            printf 'Missing %s. Run make setup (Fedora: cmake ninja-build gcc-c++ pkgconf-pkg-config python3 cargo rust).\n' "$mdf_tool" >&2
            mdf_errors=1
        fi
    done
    if command -v pkg-config >/dev/null 2>&1; then
        for mdf_library in pangocairo pangoft2 cairo fontconfig wayland-client wayland-cursor xkbcommon; do
            if ! pkg-config --exists "$mdf_library"; then
                printf 'Missing %s development files. Run make setup (Fedora: pango-devel cairo-devel fontconfig-devel wayland-devel libxkbcommon-devel).\n' "$mdf_library" >&2
                mdf_errors=1
            fi
        done
    fi
    if command -v g++ >/dev/null 2>&1; then
        if [ ! -r "$(g++ -print-file-name=libstdc++.a)" ]; then
            printf '%s\n' 'Missing static C++ runtime. Fedora: sudo dnf install libstdc++-static' >&2
            mdf_errors=1
        fi
    fi
    return "$mdf_errors"
}

offline_graph_check() {
    mkdir -p "$MDF_ROOT/build"
    mdf_log=$(mktemp "$MDF_ROOT/build/.requirements.XXXXXX")
    if "$ZIG" build --system "$MDF_ROOT/zig-pkg" \
        --cache-dir "$MDF_ROOT/build/.zig-cache" \
        "-Dtarget=$MDF_TARGET" -Dcpu=baseline \
        "-Doptimize=$OPTIMIZE" --help >"$mdf_log" 2>&1; then
        rm -f "$mdf_log"
    else
        cat "$mdf_log" >&2
        rm -f "$mdf_log"
        printf '%s\n' 'The offline dependency check failed. Run make setup to fetch missing packages.' >&2
        return 1
    fi
}

check_frontend_cache() {
    test -f "$MDF_ROOT/zig-pkg/fltk/CMakeLists.txt" && test -f "$MDF_ROOT/zig-pkg/nlohmann/json.hpp" && \
        test -f "$MDF_ROOT/zig-pkg/mermaid-renderer/Cargo.toml" && test -d "$MDF_ROOT/zig-pkg/mermaid-deps" || {
        printf '%s\n' 'Missing pinned FLTK/JSON/Mermaid sources. Run make setup.' >&2
        return 1
    }
}
