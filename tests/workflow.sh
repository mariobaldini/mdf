#!/bin/sh
# Test the real Make targets with isolated, offline build-tool stubs.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
real_make=$(command -v make)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$scratch/project/scripts" "$scratch/project/zig-pkg/fltk" "$scratch/project/zig-pkg/nlohmann" "$scratch/project/modules/pozeiden/src" "$scratch/project/zig-pkg/svg-deps" "$scratch/bin"
cp "$root/Makefile" "$root/.zig-version" "$scratch/project/"
cp "$root/scripts/common.sh" "$root/scripts/check-requirements.sh" "$root/scripts/build-frontend.sh" "$root/scripts/build-svg.sh" "$scratch/project/scripts/"
: > "$scratch/project/zig-pkg/fltk/CMakeLists.txt"
: > "$scratch/project/zig-pkg/nlohmann/json.hpp"
: > "$scratch/project/modules/pozeiden/src/root.zig"
: > "$scratch/libstdc++.a"
export MDF_TEST_LOG="$scratch/commands" MDF_TEST_STDLIB="$scratch/libstdc++.a"
for utility in sh bash dirname cat head grep rm mktemp id mkdir cp mv chmod cmp env;do ln -s "$(command -v "$utility")" "$scratch/bin/$utility";done
ln -s "$real_make" "$scratch/bin/make"
for name in ninja gcc pkg-config rpm sudo rpmbuild dpkg-deb strace cargo rustc;do printf '#!/bin/sh\nexit 0\n' > "$scratch/bin/$name";chmod +x "$scratch/bin/$name";done
cat > "$scratch/bin/g++" <<'STUB'
#!/bin/sh
printf '%s\n' "$MDF_TEST_STDLIB"
STUB
cat > "$scratch/bin/python3" <<'STUB'
#!/bin/sh
printf 'python3 %s\n' "$*" >> "$MDF_TEST_LOG"
STUB
cat > "$scratch/bin/cargo" <<'STUB'
#!/bin/sh
printf 'cargo %s\n' "$*" >> "$MDF_TEST_LOG"
printf 'rustflags %s\n' "$RUSTFLAGS" >> "$MDF_TEST_LOG"
STUB
cat > "$scratch/bin/zig" <<'STUB'
#!/bin/sh
printf 'zig %s\n' "$*" >> "$MDF_TEST_LOG"
if [ "$1" = version ];then printf '%s\n' "${MDF_TEST_VERSION:-0.16.0}";exit 0;fi
case " $* " in *' --system '*) test "${MDF_TEST_CACHE_MISSING:-0}" != 1 || exit 1;;esac
output=
while [ "$#" -gt 0 ];do case "$1" in --prefix) shift;output=$1;;-o) shift;mkdir -p "$(dirname "$1")";: > "$1";;rcs) shift;: > "$1";;esac;shift;done
if [ -n "$output" ];then mkdir -p "$output/lib";: > "$output/lib/libmdf-core.a";fi
STUB
cat > "$scratch/bin/cmake" <<'STUB'
#!/bin/sh
printf 'cmake %s\n' "$*" >> "$MDF_TEST_LOG"
if [ "$1" = --build ];then
 case "$2" in */fltk-ui/*)
  mkdir -p "$2"
  printf '#!/bin/sh\nprintf "run %%s\\n" "$*" >> "$MDF_TEST_LOG"\n' > "$2/mdf"
  chmod +x "$2/mdf";;
 esac
else
 while [ "$#" -gt 0 ];do
  if [ "$1" = -B ];then shift;mkdir -p "$1";fi
  shift
 done
fi
STUB
chmod +x "$scratch/bin/g++" "$scratch/bin/python3" "$scratch/bin/zig" "$scratch/bin/cmake"
printf '#!/bin/sh\nprintf "release %%s\\n" "$OPTIMIZE" >> "$MDF_TEST_LOG"\n' > "$scratch/project/scripts/release.sh"
run(){ PATH="$scratch/bin" "$real_make" --no-print-directory -C "$scratch/project" "$@" >"$scratch/output" 2>&1; }
no_downloads(){ if grep -Eq 'fetch|^sudo |^dnf |cargo (install|vendor|update|generate-lockfile)' "$MDF_TEST_LOG";then cat "$MDF_TEST_LOG" >&2;exit 1;fi; }
expect_failure(){ if run "$@";then printf 'Expected failure: %s\n' "$*" >&2;exit 1;fi; }
: > "$MDF_TEST_LOG"
mkdir -p "$scratch/project/build/bin" "$scratch/project/build/fltk-core/Debug/bin"
: > "$scratch/project/build/bin/libmdf-extra.so"
: > "$scratch/project/build/fltk-core/Debug/bin/libmdf-extra.so"
run build
grep -q -- '-Doptimize=Debug' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Debug' "$MDF_TEST_LOG"
grep -q '^cargo build --offline --frozen ' "$MDF_TEST_LOG"
grep -q -- '-DFLTK_BACKEND_WAYLAND=ON -DFLTK_BACKEND_X11=OFF -DFLTK_BUILD_GL=OFF' "$MDF_TEST_LOG"
grep -q -- '-DFLTK_USE_LIBDECOR_GTK=OFF' "$MDF_TEST_LOG"
test -f "$scratch/project/build/bin/mdf"
test ! -e "$scratch/project/build/bin/libmdf-extra.so"
test ! -e "$scratch/project/build/fltk-core/Debug/bin/libmdf-extra.so"
no_downloads
printf '%s\n' 'PASS: Debug builds offline, with Wayland enabled and X11/OpenGL/GTK decorations disabled'
: > "$MDF_TEST_LOG"
run release OPTIMIZE=Debug
grep -q -- '-Doptimize=ReleaseFast' "$MDF_TEST_LOG"
grep -q -- 'zig ld.lld -r -O3 --lto-O3' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Release' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_CXX_FLAGS_RELEASE=-O3' "$MDF_TEST_LOG"
grep -q '^cargo build --offline --frozen .* --release$' "$MDF_TEST_LOG"
grep -q '^rustflags -C target-cpu=x86-64 -C force-frame-pointers=no$' "$MDF_TEST_LOG"
grep -q '^release ReleaseFast$' "$MDF_TEST_LOG"
if grep -q -- '-Doptimize=Debug\|-DCMAKE_BUILD_TYPE=Debug' "$MDF_TEST_LOG";then exit 1;fi
no_downloads
printf '%s\n' 'PASS: release forces optimized Zig, FLTK, C++ UI and bundled image-library build settings'
: > "$MDF_TEST_LOG"
mkdir -p "$scratch/project/build/profile/runtime/bin"
: > "$scratch/project/build/profile/runtime/bin/libmdf-extra.so"
run profile OPTIMIZE=Debug BUILD_PREFIX=debug-output PROFILE_RUNS=2
grep -q -- '-Doptimize=ReleaseFast' "$MDF_TEST_LOG"
grep -q -- '-DCMAKE_BUILD_TYPE=Release' "$MDF_TEST_LOG"
grep -q 'python3 scripts/profile.py --binary build/profile/runtime/bin/mdf .* --runs 2$' "$MDF_TEST_LOG"
grep -q -- '--document SAMPLE-SMALL.md --document SAMPLE.md --document SAMPLE-HUGE.md' "$MDF_TEST_LOG"
test -f "$scratch/project/build/profile/runtime/bin/mdf";test ! -d "$scratch/project/debug-output"
test ! -e "$scratch/project/build/profile/runtime/bin/libmdf-extra.so"
no_downloads
printf '%s\n' 'PASS: profiling measures all three samples with an isolated optimized runtime, even with Debug/output overrides'
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
rm "$scratch/project/zig-pkg/nlohmann/json.hpp"
expect_failure build
grep -q 'Run make setup' "$scratch/output"
: > "$scratch/project/zig-pkg/nlohmann/json.hpp"
no_downloads
printf '%s\n' 'PASS: incompatible compiler and missing dependencies fail without network or installation'
mkdir -p "$scratch/project/zig-pkg/keep" "$scratch/project/zig-out" "$scratch/project/.zig-cache" "$scratch/project/dist"
: > "$scratch/project/zig-pkg/keep/source"
: > "$MDF_TEST_LOG"
run clean ZIG=/missing/zig
for dir in build zig-out .zig-cache dist;do test ! -e "$scratch/project/$dir";done
test -f "$scratch/project/zig-pkg/keep/source";test ! -s "$MDF_TEST_LOG"
printf '%s\n' 'PASS: clean removes outputs and compiler caches and preserves downloaded sources'
