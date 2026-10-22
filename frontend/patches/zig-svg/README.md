# Font resolver context

The build generates a copy of the pinned `modules/zig-svg/src` directory.
The submodule stays unchanged.

`frontend/core-build.zig` adds a defaulted `text` field to `raster.FontRequest`.
`FontResolver.faceFor` fills it from the shape's decoded text geometry.
Existing callbacks can ignore the field. No drawing or layout code changes.

The MDF resolver uses this text to check the bundled face's actual glyph coverage.
It uses an already prepared system face when that face covers more missing characters.
Parsed fallback metadata is cached for the duration of the SVG render.
Latin text keeps its requested bundled style.

When updating zig-svg, check whether upstream provides text or coverage context.
Remove this adapter if the upstream callback provides equivalent information.
Otherwise, port both checked replacements to the new callback definition and call.
Each replacement must match exactly once. A changed source stops the build.

Run `make test-svg` and the native window font cases after a port.
The resolver test checks decoded text from XML entities and nested text spans.
The GUI cases check actual body and diagram pixels with deferred system fonts.

Selection applies to a whole text run. A run that needs several font faces can
still contain missing glyphs. Complex-script shaping and SVG text direction
remain separate limitations of the current z2d SVG backend.
