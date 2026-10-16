#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
printf '%s\n' 'Checking the native FLTK GUI in an isolated Wayland compositor...'
command -v weston >/dev/null && pkg-config --exists libweston-15 || { printf '%s\n' 'GUI tests require Weston 15 and weston-devel. Run make setup.' >&2;exit 1; }
command -v strace >/dev/null || { printf '%s\n' 'GUI font-access tests require strace. Run make setup.' >&2;exit 1; }
mkdir -p build/fltk-tests
/usr/bin/gcc -shared -fPIC -Wno-attributes tests/fltk-seat.c -o build/fltk-tests/virtual-seat.so $(pkg-config --cflags --libs libweston-15 wayland-server)
mdf_test=$(mktemp -d "$root/build/fltk-tests/bundle.XXXXXX")
mdf_app="$mdf_test/app with spaces"
mkdir -p "$mdf_app" "$mdf_test/elsewhere"
cp build/bin/mdf "$mdf_app/"
test "$(find "$mdf_app" -type f | wc -l)" -eq 1
MDF_TEST_CWD="$mdf_test/elsewhere" sh scripts/fltk-gui.sh "$mdf_app/mdf"
if env -u WAYLAND_SOCKET WAYLAND_DISPLAY=mdf-font-failure \
    strace -f -e trace=memfd_create -e inject=memfd_create:error=EMFILE:when=1 \
    -o "$mdf_test/font-failure.trace" "$mdf_app/mdf" --profile SAMPLE.md >"$mdf_test/font-failure.log" 2>&1;then
    printf '%s\n' 'Font preparation failure unexpectedly continued.' >&2;exit 1
fi
grep -q 'mdf: Cannot create font memory file' "$mdf_test/font-failure.log"
for backend in x11 dummy offscreen;do
    if env -u WAYLAND_DISPLAY -u WAYLAND_SOCKET DISPLAY=:12345 FLTK_BACKEND="$backend" "$mdf_app/mdf" --benchmark SAMPLE.md >"$mdf_test/no-wayland.log" 2>&1;then printf '%s\n' 'Unexpected non-Wayland fallback.' >&2;exit 1;fi
    grep -q 'requires a Wayland session' "$mdf_test/no-wayland.log"
done
"$mdf_app/mdf" --version | grep '^mdf 0.2.0$'
printf '%s\n' 'PASS: standalone executable, native GUI, private Open Sans styles, and Wayland-only checks'
