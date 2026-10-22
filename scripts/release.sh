#!/bin/sh
. "$(dirname -- "$0")/common.sh"
if [ "$OPTIMIZE" != ReleaseFast ]; then
    printf '%s\n' 'Release packaging requires OPTIMIZE=ReleaseFast.' >&2
    exit 1
fi
mkdir -p build
mdf_stage=$(mktemp -d "$MDF_ROOT/build/.release.XXXXXX")
trap 'rm -rf "$mdf_stage"' EXIT HUP INT TERM
cp build/bin/mdf "$mdf_stage/mdf"
mdf_version=$("$mdf_stage/mdf" --version)
mdf_version=${mdf_version#mdf }
printf '%s\n' "$mdf_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
sh scripts/packages.sh "$mdf_stage" "$mdf_version"
(cd "$mdf_stage" && sha256sum mdf "mdf-$mdf_version-1.x86_64.rpm" "mdf_${mdf_version}_amd64.deb" > mdf.sha256)
{
    "$mdf_stage/mdf" --version
    printf 'compiler: Zig %s\n' "$("$ZIG" version)"
    printf 'target: %s, baseline CPU\nmode: ReleaseFast\n' "$MDF_TARGET"
    printf '%s\n' 'lto: full' 'dead_sections: removed' 'debug_symbols: stripped' 'frame_pointers: omitted' 'zig_unwind_tables: none' 'cpp_unwind_tables: retained for exceptions'
    printf 'size_bytes: %s\n' "$(wc -c < "$mdf_stage/mdf" | tr -d ' ')"
    printf 'runtime_files: mdf (single executable)\n'
    printf 'startup: libc-only Zig bootstrap; parallel document/assets, anonymous UI image, and system UI dependency loading\n'
    printf 'ui_engine: uncompressed non-allocated ELF section; GUI work on the main thread after the private ABI handoff\n'
    printf 'diagrams: independent Mermaid and SVG modules in non-allocated ELF sections; anonymous-memory loading only when needed after first viewport\n'
    printf 'raster_codecs: independent Zignal module; loaded only for raster decoding or explicit PNG export\n'
    printf 'optional_module_compression: %s\n' "${MDF_OPTIONAL_MODULE_COMPRESSION:-zlib}"
    printf 'mermaid: Zig/Pozeiden 0.4.1; 17 supported types; unsupported types show source and an error\n'
    printf 'pozeiden_commit: 071fbbb85fb73a06994c163c6093123bd3ac11f6\n'
    printf 'pozeiden_license: PolyForm-Noncommercial-1.0.0; commercial use requires separate upstream permission\n'
    printf 'images: Zig/Zignal 0.11.0, commit 1719dae43146b836f8382571300dcd84b3950072; MIT\n'
    printf 'decompression: Zig std.compress.flate; no additional runtime extractor\n'
    printf 'fonts: independently compressed Latin Open Sans faces; regular/bold prepare during UI loading; italic styles on demand; conditional system Sans and monospace\n'
    printf 'font_discovery: only after first Markdown frame, on separate font workers; existing caches read-only\n'
    printf 'fltk: 1.4.5, Wayland only, Cairo/Pango, X11/OpenGL disabled\n'
    printf 'pango: 1.57.1, bundled Cairo/Fontconfig/FreeType backend, static LTO, unused sections removed\n'
    grep '^MDF_BUNDLED_CAIRO:BOOL=' build/fltk-ui/ReleaseFast/CMakeCache.txt
    printf 'cairo: pinned 1.18.6 image/font build; no X11/XCB, PNG functions, PS/PDF/SVG export or script backends\n'
    printf 'fltk_patch_sha256: %s\n' "$(python3 scripts/prepare-fltk.py)"
    grep '^MDF_ASYNC_INPUT:BOOL=\|^MDF_PREPARE_FRAME:BOOL=' build/fltk-ui/ReleaseFast/CMakeCache.txt
    printf 'cpp: '
    /usr/bin/g++ --version | head -n1
    printf 'cpp_optimization: O3, full LTO, baseline x86_64\n'
    printf 'svg: Zig/zig-svg 0.2.0 with z2d; no Rust build/runtime dependency\n'
    printf 'svg_commit: 6feaa8d4aee609b0945473931fb27fdcdf1ebfef\n'
    printf 'svg_text_limits: prepared Sans fallback; whole-run selection, complex-script/RTL/vertical limitations and some unsupported font formats\n'
    printf 'libm_compatibility: GLIBC_2.2.5 float entry points; small non-LTO ABI shim\n'
    sha256sum frontend/dependencies.json
    printf 'markdown: Zigmark 0.11.1 with pinned MDF CommonMark compatibility patches\n'
    printf 'zigmark_commit: ceec7fb29b976005d53f8b5cb3e0abe931f2d0e8\n'
    printf 'manifest_sha256: '
    sha256sum build.zig.zon
} > "$mdf_stage/build-info.txt"
# Rename complete files so running viewers keep their existing mappings.
mv "$mdf_stage/mdf" build/mdf
rm -f build/libmdf-extra.so
mv "$mdf_stage/mdf.sha256" build/mdf.sha256
mv "$mdf_stage/build-info.txt" build/build-info.txt
mv "$mdf_stage/mdf-$mdf_version-1.x86_64.rpm" build/
mv "$mdf_stage/mdf_${mdf_version}_amd64.deb" build/
printf '%s\n' 'Release files: executable, RPM, DEB, checksums, and build metadata in build/'
