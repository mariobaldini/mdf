# Pinned text stack

MDF links Pango 1.57.1 into its private UI engine.
The launcher still links only libc. Installation still needs one executable.
The engine retains the Cairo, Fontconfig, and FreeType backends.
The [minimal Cairo build](cairo.md) is also bundled in the default UI engine.
System libraries still provide Pixman, GLib/GIO, FriBidi, HarfBuzz, Fontconfig, and FreeType.
The Latin-focused build disables optional libthai dictionary-based Thai word breaking.
It has no direct libthai or libdatrie runtime dependency. Pango's general Unicode handling remains available.
Complex scripts, glyph fallback, and system monospace keep the existing Pango code paths.

`frontend/dependencies.json` pins the unmodified Pango source archive and its SHA-256.
It also pins a project-local Meson wheel. Meson is a build tool and is not included in the executable.
`make setup` downloads both into `zig-pkg/`. Builds then run without network access.

`scripts/build-text-stack.py` builds only the three Pango static archives.
ReleaseFast uses optimization, LTO, position-independent code, and separate function/data sections.
The UI link discards unused sections and exports only `mdf_frontend_api`.
Xft, introspection, documentation, examples, test programs, and sysprof support are disabled.
Upstream shaping and line-breaking implementations remain intact.
GTK file choosers and libdecor's GTK plugin remain disabled, so the process uses one Pango implementation.

The build identity includes dependency hashes, compiler identity, mode, and configuration options.
A changed identity rebuilds Pango. Ordinary unchanged builds reuse its archives.
`MDF_BUNDLED_PANGO=OFF MDF_BUNDLED_CAIRO=OFF make build OPTIMIZE=ReleaseFast` restores system Pango and Cairo for comparisons.
Restore the previous complete executable to roll back an installed build.

## Source and relinking

Pango's upstream project declares LGPL-2.1-or-later.
The upstream `COPYING` file is retained in `zig-pkg/pango/`.
The source archive is <https://github.com/GNOME/pango/tree/1.57.1>.
MDF's bundled notices identify this dependency and its source.

To rebuild or replace the bundled library:

1. Keep the MDF source revision and submodule revisions used for the executable.
2. Run `make setup` to fetch the pinned source and build tools.
3. Modify the Pango source in `zig-pkg/pango/` as required.
4. Run `make build OPTIMIZE=ReleaseFast` to rebuild and relink the UI engine.
5. Run `make tests` and `make test-gui OPTIMIZE=ReleaseFast`.

The scripts do not restore or patch the Pango source during a normal build.
Meson/Ninja tracks changes to that source. Cached archives and the complete link inputs remain under `build/`.
The frontend packer replaces the embedded engine after relinking; it does not require installed sidecar libraries.
Distributions must preserve access to the matching MDF and Pango source and relinking instructions.

## Text measurement cache

Each document view caches widths for at most 2048 words of at most 128 bytes each.
The key includes font face, size, and the complete word, preserving backend shaping and kerning.
Long tokens use the original measurement path.
System monospace and fallback text continue to use their own font maps.
Layout invalidation clears the cache, including document changes, zoom, viewport width, and display scale.
Deferred font adoption also clears old measurements.

Each laid-out run retains its font height and descent for painting.
Backgrounds, selection, and text therefore use the same metrics without measuring the run again.
The GUI suite checks cached metrics against the real backend across styles, sizes, accents, and wrapped glyphs.
It also checks the memory bound and invalidation behavior.
