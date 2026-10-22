#!/bin/sh
# Test the real Make targets with isolated, offline build-tool stubs.
set -eu
unset ZIG ZIG_GLOBAL_CACHE_DIR OPTIMIZE BUILD_PREFIX MAKEFLAGS MFLAGS MAKEOVERRIDES MDF_REFERENCE MDF_OPTIONAL_MODULE_COMPRESSION
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
real_make=$(command -v make)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/project/scripts" "$scratch/project/zig-pkg/fltk" "$scratch/project/modules/pozeiden/src" "$scratch/project/modules/zig-svg/src" "$scratch/bin"
mkdir -p "$scratch/project/modules/zignal/src"
mkdir -p "$scratch/project/modules/zigmark/src" "$scratch/project/modules/mecha"
mkdir -p "$scratch/project/tests"
mkdir -p "$scratch/project/zig-pkg/pango" "$scratch/project/zig-pkg/meson/mesonbuild"
mkdir -p "$scratch/project/zig-pkg/cairo"
: > "$scratch/project/zig-pkg/cairo/meson.build"
: > "$scratch/project/zig-pkg/pango/meson.build"
: > "$scratch/project/zig-pkg/meson/mesonbuild/mesonmain.py"
for script in workflow.sh install.sh;do printf '#!/bin/sh\nexit 0\n' > "$scratch/project/tests/$script";done
cp "$root/Makefile" "$root/.zig-version" "$scratch/project/"
cp "$root/scripts/common.sh" "$root/scripts/check-requirements.sh" "$root/scripts/build-frontend.sh" "$root/scripts/build-reference.sh" "$scratch/project/scripts/"
: > "$scratch/project/zig-pkg/fltk/CMakeLists.txt"
: > "$scratch/project/modules/pozeiden/src/root.zig"
: > "$scratch/project/modules/zig-svg/src/root.zig"
: > "$scratch/project/modules/zignal/src/root.zig"
: > "$scratch/project/modules/zigmark/src/root.zig"
: > "$scratch/project/modules/mecha/mecha.zig"
: > "$scratch/libstdc++.a"
export MDF_TEST_LOG="$scratch/commands" MDF_TEST_STDLIB="$scratch/libstdc++.a"
for utility in sh bash dirname cat head grep rm mktemp id mkdir cp mv chmod cmp env;do ln -s "$(command -v "$utility")" "$scratch/bin/$utility";done
ln -s "$real_make" "$scratch/bin/make"
for name in ninja gcc pkg-config rpm sudo rpmbuild dpkg-deb strace objcopy strip wayland-scanner;do printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/$name";chmod +x "$scratch/bin/$name";done
cat > "$scratch/bin/g++" <<'STUB'
#!/bin/sh
printf '%s\n' "$MDF_TEST_STDLIB"
STUB
cat > "$scratch/bin/python3" <<'STUB'
#!/bin/sh
printf 'python3 %s\n' "$*" >> "$MDF_TEST_LOG"
STUB
cat > "$scratch/bin/objcopy" <<'STUB'
#!/bin/sh
while [ "$#" -gt 1 ];do shift;done
: > "$1"
STUB
cat > "$scratch/bin/zig" <<'STUB'
#!/bin/sh
printf 'zig %s\n' "$*" >> "$MDF_TEST_LOG"
if [ "$1" = version ];then printf '%s\n' "${MDF_TEST_VERSION:-0.17.0}";exit 0;fi
case " $* " in *' --system '*) test "${MDF_TEST_CACHE_MISSING:-0}" != 1 || exit 1;;esac
case " $* " in *' build test '*)
 if [ "${MDF_TEST_UNIT_FAILURE:-0}" = 1 ];then printf '%s\n' 'Forced unit-test failure' >&2;exit 1;fi;;
esac
output=
while [ "$#" -gt 0 ];do case "$1" in --prefix) shift;output=$1;;-o) shift;mkdir -p "$(dirname "$1")";: > "$1";;rcs) shift;: > "$1";;esac;shift;done
if [ -n "$output" ];then
 mkdir -p "$output/lib" "$output/bin";: > "$output/lib/libmdf-core.a"
 printf '#!/bin/sh\nprintf "run %%s\\n" "$*" >> "$MDF_TEST_LOG"\n' > "$output/bin/mdf-launcher"
 chmod +x "$output/bin/mdf-launcher"
fi
STUB
cat > "$scratch/bin/cmake" <<'STUB'
#!/bin/sh
printf 'cmake %s\n' "$*" >> "$MDF_TEST_LOG"
if [ "$1" = --build ];then
 case "$2" in */fltk-ui/*)
  mkdir -p "$2"
  : > "$2/mdf-ui.debug"
  : > "$2/mdf-ui.debug"
  printf '#!/bin/sh\nprintf "run %%s\\n" "$*" >> "$MDF_TEST_LOG"\n' > "$2/mdf"
  chmod +x "$2/mdf";;
 esac
 for native_test in mdf-image-tests mdf-buffer-tests mdf-cairo-tests mdf-startup-tests mdf-monospace-tests;do
  case " $* " in *" --target $native_test "*)
   printf '#!/bin/sh\nexit 0\n' > "$2/$native_test"
   chmod +x "$2/$native_test";;
  esac
 done
else
 while [ "$#" -gt 0 ];do
  if [ "$1" = -B ];then shift;mkdir -p "$1";fi
  shift
 done
fi
STUB
chmod +x "$scratch/bin/g++" "$scratch/bin/python3" "$scratch/bin/zig" "$scratch/bin/cmake" "$scratch/bin/objcopy"
printf '#!/bin/sh\nprintf "release %%s\\n" "$OPTIMIZE" >> "$MDF_TEST_LOG"\n' > "$scratch/project/scripts/release.sh"
run(){ PATH="$scratch/bin" "$real_make" --no-print-directory -C "$scratch/project" "$@" >"$scratch/output" 2>&1; }
no_downloads(){ if grep -Eq 'fetch|^sudo |^dnf |cargo|rustc' "$MDF_TEST_LOG";then cat "$MDF_TEST_LOG" >&2;exit 1;fi; }
expect_failure(){ if run "$@";then printf 'Expected failure: %s\n' "$*" >&2;exit 1;fi; }
: > "$MDF_TEST_LOG"
mkdir -p "$scratch/project/build/bin" "$scratch/project/build/fltk-core/Debug/bin"
: > "$scratch/project/build/bin/libmdf-extra.so"
: > "$scratch/project/build/fltk-core/Debug/bin/libmdf-extra.so"
run build || { cat "$scratch/output" >&2; exit 1; }
grep -q -- '-DMDF_OPTIONAL_MODULE_COMPRESSION=zlib' "$MDF_TEST_LOG"
grep -q -- 'zig build test .* -Doptimize=Debug --summary all' "$MDF_TEST_LOG"
grep -q -- '-Doptimize=Debug' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Debug' "$MDF_TEST_LOG"
grep -q -- '-DMDF_SVG_LIBRARY=.*libmdf-svg.a' "$MDF_TEST_LOG"
grep -q -- '-DMDF_IMAGE_LIBRARY=.*libmdf-image.a' "$MDF_TEST_LOG"
grep -q -- '-DMDF_UI_WORKERS_LIBRARY=.*libmdf-ui-workers.a' "$MDF_TEST_LOG"
grep -q -- 'python3 scripts/build-text-stack.py .* --mode Debug' "$MDF_TEST_LOG"
grep -q -- '-DMDF_BUNDLED_PANGO=ON' "$MDF_TEST_LOG"
grep -q -- 'python3 scripts/build-cairo.py .* --mode Debug' "$MDF_TEST_LOG"
grep -q -- '-DMDF_BUNDLED_CAIRO=ON' "$MDF_TEST_LOG"
grep -q -- 'python3 scripts/pack-frontend.py .*libmdf-ui.so' "$MDF_TEST_LOG"
grep -q -- '-DFLTK_BACKEND_WAYLAND=ON -DFLTK_BACKEND_X11=OFF -DFLTK_BUILD_GL=OFF' "$MDF_TEST_LOG"
grep -q -- '-DFLTK_USE_LIBDECOR_GTK=OFF' "$MDF_TEST_LOG"
test -f "$scratch/project/build/bin/mdf"
test ! -e "$scratch/project/build/bin/libmdf-extra.so"
test ! -e "$scratch/project/build/fltk-core/Debug/bin/libmdf-extra.so"
no_downloads
printf '%s\n' 'PASS: Debug builds offline, with Wayland enabled and X11/OpenGL/GTK decorations disabled'
: > "$MDF_TEST_LOG"
run build MDF_OPTIONAL_MODULE_COMPRESSION=raw
grep -q -- '-DMDF_OPTIONAL_MODULE_COMPRESSION=raw' "$MDF_TEST_LOG"
no_downloads
printf '%s\n' 'PASS: optional modules default to zlib; explicit raw comparisons remain available'
for utility in gcc g++ cmake ninja;do mv "$scratch/bin/$utility" "$scratch/bin/$utility.off";done
mv "$scratch/project/zig-pkg/fltk/CMakeLists.txt" "$scratch/fltk.saved"
expect_failure build
grep -q 'Missing' "$scratch/output"
run check-native-requirements
for utility in gcc g++ cmake ninja;do mv "$scratch/bin/$utility.off" "$scratch/bin/$utility";done
mv "$scratch/fltk.saved" "$scratch/project/zig-pkg/fltk/CMakeLists.txt"
printf '%s\n' 'PASS: FLTK is required by default; the experimental native requirements stay separate'
: > "$MDF_TEST_LOG"
export MDF_TEST_UNIT_FAILURE=1
expect_failure build
grep -q 'Forced unit-test failure' "$scratch/output"
if grep -q -- '--prefix\|^cmake -S' "$MDF_TEST_LOG";then cat "$MDF_TEST_LOG" >&2;exit 1;fi
unset MDF_TEST_UNIT_FAILURE
printf '%s\n' 'PASS: a failed unit suite stops the build before compiling or replacing the executable'
: > "$MDF_TEST_LOG"
run tests OPTIMIZE=ReleaseFast || { cat "$scratch/output" >&2;exit 1; }
for mode in Debug ReleaseSafe ReleaseFast;do
 grep -q -- "zig build test .* -Doptimize=$mode --summary all" "$MDF_TEST_LOG"
done
grep -q 'python3 tests/json-boundary.py ' "$MDF_TEST_LOG"
grep -q 'python3 tests/image-fixtures.py ' "$MDF_TEST_LOG"
no_downloads
printf '%s\n' 'PASS: make tests runs all three core modes plus the native JSON and image suites offline'
: > "$MDF_TEST_LOG"
run release OPTIMIZE=Debug
grep -q -- '-DMDF_OPTIONAL_MODULE_COMPRESSION=zlib' "$MDF_TEST_LOG"
grep -q -- '-Doptimize=ReleaseFast' "$MDF_TEST_LOG"
grep -q -- 'zig ld.lld -r -O3 --lto-O3' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Release' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_CXX_FLAGS_RELEASE=-O3' "$MDF_TEST_LOG"
grep -q -- 'libmdf-svg.a' "$MDF_TEST_LOG"
grep -q '^release ReleaseFast$' "$MDF_TEST_LOG"
if grep -q -- '-Doptimize=Debug\|-DCMAKE_BUILD_TYPE=Debug' "$MDF_TEST_LOG";then exit 1;fi
no_downloads
printf '%s\n' 'PASS: release forces optimized Zig, FLTK, C++ UI and bundled image-library build settings'
: > "$MDF_TEST_LOG"
mkdir -p "$scratch/project/build/profile/runtime/bin"
: > "$scratch/project/build/profile/runtime/bin/libmdf-extra.so"
run profile OPTIMIZE=Debug BUILD_PREFIX=debug-output PROFILE_RUNS=2
grep -q -- '-DMDF_OPTIONAL_MODULE_COMPRESSION=zlib' "$MDF_TEST_LOG"
grep -q -- '-Doptimize=ReleaseFast' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Release' "$MDF_TEST_LOG"
grep -q 'python3 scripts/profile.py --binary build/profile/runtime/bin/mdf --output build/profile/profile.html --runs 2$' "$MDF_TEST_LOG"
test -f "$scratch/project/build/profile/runtime/bin/mdf";test ! -d "$scratch/project/debug-output"
test ! -e "$scratch/project/build/profile/runtime/bin/libmdf-extra.so"
no_downloads
printf '%s\n' 'PASS: profiling uses the six-edition defaults and an isolated optimized runtime, even with Debug/output overrides'
: > "$MDF_TEST_LOG"
run profile-trace OPTIMIZE=Debug
grep -q -- '-Doptimize=ReleaseFast' "$MDF_TEST_LOG"
grep -q 'python3 scripts/profile-trace.py --binary build/profile-trace/runtime/bin/mdf --document SAMPLE.md --document SAMPLE-HUGE.md' "$MDF_TEST_LOG"
if grep -q 'python3 scripts/profile.py ' "$MDF_TEST_LOG";then exit 1;fi
no_downloads
printf '%s\n' 'PASS: syscall tracing is a separate target and cannot replace regular startup timing'
: > "$MDF_TEST_LOG"
run
grep -q '^run SAMPLE.md$' "$MDF_TEST_LOG"
no_downloads
printf '%s\n' 'PASS: default make rebuilds and opens SAMPLE.md'
: > "$MDF_TEST_LOG"
export MDF_TEST_VERSION=0.15.2
expect_failure build
grep -q 'Found: 0.15.2' "$scratch/output"
unset MDF_TEST_VERSION
export MDF_TEST_CACHE_MISSING=1
expect_failure build
grep -q 'Run make setup' "$scratch/output"
unset MDF_TEST_CACHE_MISSING
rm "$scratch/project/modules/zignal/src/root.zig"
expect_failure build
grep -q 'Run make setup' "$scratch/output"
: > "$scratch/project/modules/zignal/src/root.zig"
no_downloads
printf '%s\n' 'PASS: incompatible compiler and missing dependencies fail without network or installation'
mkdir -p "$scratch/project/zig-pkg/keep" "$scratch/project/zig-out" "$scratch/project/.zig-cache" "$scratch/project/dist"
: > "$scratch/project/zig-pkg/keep/source"
: > "$MDF_TEST_LOG"
run clean ZIG=/missing/zig
for dir in build zig-out .zig-cache dist;do test ! -e "$scratch/project/$dir";done
test -f "$scratch/project/zig-pkg/keep/source";test ! -s "$MDF_TEST_LOG"
printf '%s\n' 'PASS: clean removes outputs and compiler caches and preserves downloaded sources'
