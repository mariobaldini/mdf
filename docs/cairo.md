# Minimal Cairo build

The default UI engine includes Cairo 1.18.6 image and font rendering.
It retains FreeType, Fontconfig, user fonts, recording surfaces, groups, and compositing.
System Pixman supplies the CPU pixel operations.
Other system text dependencies remain unchanged.

The build disables Xlib, XCB, Xlib-XCB, PNG functions, PDF/PostScript/SVG export,
script surfaces, tee surfaces, GObject bindings, tracing tools, tests, and documentation.
Disabling Cairo's PNG functions does not disable document images or screenshot capture.
Zignal decodes document PNG/JPEG files; FLTK's bundled PNG encoder writes captures.
Mermaid and SVG rendering still use their separate Zig modules.

`frontend/dependencies.json` pins the official GitLab archive, release commit, and SHA-256.
The commit matches the project's [1.18.6 release announcement](https://www.cairographics.org/news/cairo-1.18.6/).
The source archive differs from the release-server `.tar.xz`; each has its own checksum.
The cached source under `zig-pkg/cairo/` is unmodified.
`make setup` downloads it. `scripts/build-cairo.py` then builds offline with Meson and Ninja.
ReleaseFast enables LTO, optimization, and function/data sections.
The final UI link removes unused sections and keeps Cairo symbols private.

Only one Cairo implementation is used by the default UI and its bundled Pango.
The engine has no system Cairo or X11/XCB dependency.
Bundled Cairo requires bundled Pango. Mixing it with system Pango could introduce another Cairo implementation.
System Cairo development files remain build requirements for the FLTK SDK and reference tests.

For a comparison with the former system Cairo, run:

```sh
MDF_BUNDLED_CAIRO=OFF make build OPTIMIZE=ReleaseFast
```

This keeps bundled Pango and restores the system Cairo dependency.
Use `MDF_BUNDLED_CAIRO=OFF MDF_BUNDLED_PANGO=OFF` to restore both system libraries.
Restore the previous complete executable to roll back an installed build.

## Validation

`make test-cairo OPTIMIZE=ReleaseFast` checks the selected backend capabilities,
image access, clipping, alpha compositing, transforms, and group surfaces.
`make tests` includes this check and verifies the private UI has no unresolved Cairo imports.
The launcher check rejects an unexpected system Cairo or X11/XCB dependency in the bundled build.
GUI tests verify fonts, glyph fallback, code fonts, images, and actual frame submission.
Pixel comparisons and paired cold launches must use matching optimized binaries.

## Source and relinking

Cairo is available under LGPL 2.1 or MPL 1.1.
MDF includes Cairo's LGPL 2.1 text in `assets/NOTICE.txt`.
The cached archive retains `COPYING` and both upstream license files.

To modify and relink Cairo, keep the matching MDF source and submodule revisions,
run `make setup`, edit `zig-pkg/cairo/`, then run `make build OPTIMIZE=ReleaseFast`.
Normal builds preserve local Cairo edits. Meson/Ninja rebuilds changed files.
The static archive and link inputs remain under `build/`; the packer replaces the embedded UI after relinking.
Distributions must preserve access to matching source and these relinking instructions.
