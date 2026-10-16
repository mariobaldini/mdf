#!/bin/sh
. "$(dirname -- "$0")/common.sh"
mdf_prefix=${1:-build}
mdf_mode=${OPTIMIZE:-Debug}
case "$mdf_mode" in
    ReleaseFast) mdf_cmake_mode=Release;mdf_lto=ON;mdf_rust_profile=release;;
    Debug) mdf_cmake_mode=Debug;mdf_lto=OFF;mdf_rust_profile=debug;;
    *) printf '%s\n' 'The GUI supports Debug or ReleaseFast. Core tests also support ReleaseSafe.' >&2;exit 1;;
esac
printf 'Building native Mermaid renderer (%s, offline)...\n' "$mdf_mode"
sh scripts/build-mermaid.sh "$mdf_mode"
export ZIG_LOCAL_CACHE_DIR="$MDF_ROOT/build/.zig-cache/local"
export CCACHE_DIR="$MDF_ROOT/build/.ccache"
mdf_core="$MDF_ROOT/build/fltk-core/$mdf_mode"
mdf_sdk="$MDF_ROOT/build/fltk/$mdf_mode"
mdf_ui="$MDF_ROOT/build/fltk-ui/$mdf_mode"
printf 'Building Zig core and fonts (%s)...\n' "$mdf_mode"
"$ZIG" build --system zig-pkg --cache-dir build/.zig-cache "-Dtarget=$MDF_TARGET" -Dcpu=baseline "-Doptimize=$mdf_mode" --prefix "$mdf_core"
rm -f "$mdf_core/bin/libmdf-extra.so"
mdf_lib="$mdf_core/lib"
if [ "$mdf_lto" = ON ];then
    mkdir -p "$mdf_core/native"
    "$ZIG" ld.lld -r -O3 --lto-O3 --whole-archive "$mdf_lib/libmdf-core.a" --no-whole-archive -o "$mdf_core/native/core.o"
    rm -f "$mdf_core/native/libmdf-core.next.a"
    "$ZIG" ar rcs "$mdf_core/native/libmdf-core.next.a" "$mdf_core/native/core.o"
    if ! cmp -s "$mdf_core/native/libmdf-core.a" "$mdf_core/native/libmdf-core.next.a";then mv "$mdf_core/native/libmdf-core.next.a" "$mdf_core/native/libmdf-core.a";else rm "$mdf_core/native/libmdf-core.next.a";fi
    mdf_lib="$mdf_core/native"
fi
printf 'Configuring FLTK 1.4.5 (%s, Wayland only, Cairo/Pango, X11=OFF, OpenGL=OFF)...\n' "$mdf_cmake_mode"
mdf_fltk_patch=$(python3 scripts/prepare-fltk.py)
# Replacing pinned sources can retain archive mtimes older than cached objects.
# Rebuild the SDK when the reviewed source/patch identity changes.
if [ -f "$mdf_sdk/build.ninja" ] && { [ ! -f "$mdf_sdk/.mdf-source-id" ] || [ "$(cat "$mdf_sdk/.mdf-source-id")" != "$mdf_fltk_patch" ]; };then
    cmake --build "$mdf_sdk" --target clean
fi
cmake -S zig-pkg/fltk -B "$mdf_sdk" -G Ninja \
    -DCMAKE_C_COMPILER="${MDF_CC:-/usr/bin/gcc}" -DCMAKE_CXX_COMPILER="${MDF_CXX:-/usr/bin/g++}" \
    "-DCMAKE_BUILD_TYPE=$mdf_cmake_mode" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=$mdf_lto" "-DCMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE=$mdf_lto" \
    '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -ffunction-sections -fdata-sections -fomit-frame-pointer' \
    '-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=x86-64 -ffunction-sections -fdata-sections -fomit-frame-pointer' \
    -DFLTK_BACKEND_WAYLAND=ON -DFLTK_BACKEND_X11=OFF -DFLTK_BUILD_GL=OFF -DFLTK_BUILD_SHARED_LIBS=OFF \
    -DFLTK_USE_SYSTEM_LIBDECOR=OFF -DFLTK_USE_LIBDECOR_GTK=OFF \
    -DFLTK_USE_SYSTEM_LIBJPEG=OFF -DFLTK_USE_SYSTEM_LIBPNG=OFF -DFLTK_USE_SYSTEM_ZLIB=OFF \
    -DFLTK_BUILD_TEST=OFF -DFLTK_BUILD_EXAMPLES=OFF -DFLTK_BUILD_FLUID=OFF -DFLTK_BUILD_FLTK_OPTIONS=OFF \
    -DFLTK_BUILD_FORMS=OFF -DFLTK_OPTION_PRINT_SUPPORT=OFF -DFLTK_BUILD_HTML_DOCS=OFF -DFLTK_BUILD_PDF_DOCS=OFF
cmake --build "$mdf_sdk" --parallel "${MDF_BUILD_JOBS:-2}"
printf '%s\n' "$mdf_fltk_patch" > "$mdf_sdk/.mdf-source-id"
cmake -S frontend -B "$mdf_ui" -G Ninja \
    -DCMAKE_C_COMPILER="${MDF_CC:-/usr/bin/gcc}" -DCMAKE_CXX_COMPILER="${MDF_CXX:-/usr/bin/g++}" \
    "-DCMAKE_BUILD_TYPE=$mdf_cmake_mode" "-DFLTK_DIR=$mdf_sdk" "-DMDF_CORE_DIR=$mdf_lib" \
    "-DMDF_FLTK_PATCH_ID=$mdf_fltk_patch" \
    "-DMDF_ASYNC_INPUT=${MDF_ASYNC_INPUT:-ON}" "-DMDF_PREPARE_FRAME=${MDF_PREPARE_FRAME:-OFF}" \
    "-DMDF_MERMAID_LIBRARY=$MDF_ROOT/build/mermaid/mermaid/$mdf_rust_profile/libmdf_mermaid.a" \
    "-DMDF_SVG_LIBRARY=$MDF_ROOT/build/mermaid/svg/$mdf_rust_profile/libmdf_mermaid.a"
cmake --build "$mdf_ui" --parallel "${MDF_BUILD_JOBS:-2}"
mkdir -p "$mdf_prefix/bin"
cp "$mdf_ui/mdf" "$mdf_prefix/bin/mdf.new"
mv "$mdf_prefix/bin/mdf.new" "$mdf_prefix/bin/mdf"
rm -f "$mdf_prefix/bin/libmdf-extra.so" "$mdf_prefix/bin/libmdf-extra.so.new"
printf 'Built %s/bin/mdf\n' "$mdf_prefix"
