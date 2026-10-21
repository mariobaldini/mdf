# Bundled fonts

The executable embeds only Open Sans regular, bold, italic, and bold italic.
Open Sans supplies UI/body text and the first Markdown frame, including code.
After parsing, the viewer compares document characters with the embedded font coverage.
Missing characters trigger a system Sans fallback worker after the first frame. It selects only families contributing the required glyphs.
Code blocks separately trigger a monospace worker after that frame. Inline code alone does not start that worker.
The GUI adopts separate private Pango maps and reflows affected text. Selected fallback faces also supply native labels and previews.
Latin text keeps Open Sans. If no system monospace is available, code keeps Open Sans.
Regular and bold are ready before the first window presentation.
Italic and bold italic are separate zlib-compressed resources. Builds preserve the source TTF files unchanged.
Parsed Markdown and HTML emphasis request only their actual rendered styles, including bold table headings.
The GUI decompresses and registers each required face before document measurement, so the first frame has its final fonts.
Each face is decompressed at most once per process and stays available for later documents.
The viewer registers anonymous memory files in a private Fontconfig configuration.
Startup reads no system fonts, Fontconfig files, or font caches. Only the deferred font workers read those resources.
Latin documents without code blocks never start system font discovery.
The viewer creates no extracted font files or persistent caches, and reads existing caches without updating them.
The Latin subset keeps accented Latin text, existing punctuation, and symbols.
Greek, Cyrillic, CJK, and other characters outside its coverage use installed fallback fonts when available.
Characters without an installed font still display missing-glyph markers. No font can guarantee complete Unicode coverage.
The original full Open Sans files add Greek and Cyrillic. They still lack Arabic, Hebrew, CJK, many arrows, and emoji.
Mermaid and SVG use bundled faces and explicitly prepared fallback data for labels needing it.
Pozeiden estimates Mermaid label widths during layout. The SVG rasterizer shapes text with the actual font data.
SVG text requests an italic face only when its resolved text style needs that face. A normal SVG does not inflate either italic font.
The image worker never discovers system fonts.
All license notices remain available through `mdf --licenses`.

## Open Sans

The four faces in `open-sans/` are modified subsets of Fedora 44's `open-sans-fonts-1.10-25.fc44` package.
Markdown FAST generated them with FontTools 4.63.0 and the `subset_face` function in `scripts/benchmark-fonts.py`.
The subset removes Unicode characters classified as Greek or Cyrillic and keeps the other existing characters.
Each face contains 535 Unicode characters and 578 glyphs. The four files total 449,000 bytes.
Kerning, hinting, all layout features, and the missing-glyph outline are preserved.
Each font's description records the modification. Copyright and license records remain intact.
Normal builds embed regular/bold directly and compress the two italic faces independently with Python's standard zlib module.
The existing statically linked FLTK zlib decompresses them at runtime; no external decompressor or FontTools is required.
See `open-sans/COPYRIGHT.txt` and `open-sans/LICENSE.txt` for the copyright and Apache 2.0 license.
