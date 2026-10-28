# Architecture

Markdown FAST is a read-only Markdown viewer for Linux x86_64 with Wayland and glibc 2.38 or later.
The production UI uses FLTK, Cairo, and Pango. `make native` retains the experimental Zig/z2d viewer.
Both use the same Zig document core and distribute as one executable.

## Components and ownership

| Component | Responsibility |
| --- | --- |
| Launcher | CLI, core lifetime, parallel startup, embedded modules, and bundled fonts. Its only linked platform library is libc. |
| Zig core | Zigmark/Mecha parsing, document loading, settings, file watching, navigation, geometry, text projection, workers, JSON, and compression. |
| Private UI engine | Main-thread controls, Wayland presentation, text layout, and drawing. The engine borrows the launcher's core. |
| Optional modules | Independent Mermaid layout, SVG rendering, and raster codecs. Loading one does not load the others. |
| System libraries | Wayland, XKB, Pixman, GLib/GIO, FriBidi, HarfBuzz, Fontconfig, and FreeType. |

Compiler identity comes from `.zig-version`. Dependency archives and checksums come from `frontend/dependencies.json` and the pinned submodules.
The current stack includes FLTK 1.4.5, Cairo 1.18.6, Pango 1.57.1, Zigmark 0.11.1, and Mecha 0.11.0.
Mermaid uses Pozeiden 0.4.1. SVG uses zig-svg 0.2.0 with z2d. Raster codecs use Zignal 0.11.0.
Sources stay unchanged under `modules/` and `zig-pkg/`. Checked compatibility adaptations use generated build-cache copies.

Document blocks, spans, rendered text, and position arrays cross the UI boundary as borrowed typed views.
Their storage belongs to the document arena until replacement.
Workers retain their inputs until cancellation and joining finish.
Navigation and image state use document revisions to reject stale results.
Explicit HTML anchors and generated heading anchors both resolve to document blocks.
The source view copies the original Markdown on demand and returns to the retained formatted view without reparsing.

## Startup and presentation

1. Handle `--help`, `--version`, and `--licenses` without loading the UI.
2. Start the document and persistent navigation workers, plus regular/bold font inflation.
3. Create both UI preparation threads behind a barrier before any `dlopen` call.
4. Prepare the anonymous UI image while another worker loads its system dependencies.
5. Load the private engine, hand off the existing core, and adopt ready document data on the main thread.
6. Prepare shared-memory buffers and visible layout while Wayland configures the window, then commit and flush the first Markdown frame.
7. Release deferred system fonts, Mermaid/SVG rendering, and preview work after their presentation gates.

The thread barrier avoids dynamic-loader lock conflicts with pthread initialization.
Extra `dlopen` threads cannot parallelize the loader's serialized work. Parsing, font inflation, and advisory read-ahead can overlap it.
Dependency names come from the built engine. Normal loader search rules, including `LD_LIBRARY_PATH`, still apply.
Preload failures do not hide the final UI load error.

The launcher switches its atomic wake callback from eventfd to the GUI and sends another wake notification.
The engine consumes the pending document packet once and never creates a second core or parses that packet again.
All widget creation, text layout, and drawing stay on the main thread.
Navigation resets wait for borrowed documents. Destruction joins workers before releasing their arenas.

The first-frame preparation path reuses measured layout and available shared memory.
A repaint uses private storage while the compositor owns its previous buffer.
Resize and scale changes invalidate geometry that no longer fits.
`MDF_PREPARE_FRAME=OFF` disables early preparation for diagnostics. Its current default is on.

## Embedded modules and formats

| ELF section | Contents | Load policy |
| --- | --- | --- |
| `.mdf_ui` | Uncompressed private UI ELF | Every GUI launch, in parallel with core preparation. |
| `.mdf_ui_deps` | UI `DT_NEEDED` sonames | Dependency preload and read-ahead hints. |
| `.mdf_mermaid` | Mermaid layout module | On demand after the first committed and flushed Markdown viewport. |
| `.mdf_svg` | SVG renderer | On demand for local SVG or successful Mermaid output, after the viewport gate. |
| `.mdf_image` | Raster decoder and PNG encoder | First raster decode or explicit screenshot export. |

These resource sections have no `SHF_ALLOC`. The kernel does not map them at launcher startup.
Modules load from checked, sealed executable memfds through `RTLD_NOW | RTLD_LOCAL`, without named-file extraction.
GUI launches require permission to create executable memfds.
Successful modules and their callbacks remain valid until process exit.
Cancellation releases presentation gates and leaves interrupted module loads retryable.
Persistent failures retain a readable diagnostic for the affected resource.

The UI exports only `mdf_frontend_api` through ABI 1.
Diagram modules export `mdf_diagram_api` through ABI 3. Raster codecs export `mdf_image_api` through ABI 1.
Consumers check version, table size, module kind, and reserved fields before initialization.
The host supplies prepared fonts to renderers. Returned SVG text, missing-glyph text, and pixels use C allocation and host `free()`.

Optional modules default to independent zlib streams.
`MDF_OPTIONAL_MODULE_COMPRESSION=raw` changes storage while preserving decoded module bytes and load conditions.
The little-endian payload header is independent of each module's ABI:

| Offset | Field |
| --- | --- |
| 0 | Eight-byte magic `MDFDG01\0`. |
| 8 | 32-bit format version `2`. |
| 12 | 32-bit header size `40`. |
| 16 | 64-bit stored byte length. |
| 24 | 64-bit expanded ELF length, at most 256 MiB. |
| 32 | 32-bit CRC32 of the expanded ELF. |
| 36 | 32-bit encoding: `0` for zlib, `1` for raw. Raw lengths must match. |

Zig validates headers, exact stream lengths, zlib Adler32, and resource CRC32 before sealing memory.
Inflation and checksum passes poll cancellation every 64 KiB.
Font resources use a separate 16-byte header: `MDFONT1\0`, expanded length, and CRC32.
The font decoder also checks the font signature.

## Text and layout

The first Markdown frame uses the embedded Latin subsets of Open Sans, with no system-font or Fontconfig-cache reads.
Regular and bold inflate on the bootstrap worker. Required italic faces prepare independently after parsing.
Unused faces do not inflate. Failed thread creation permits the requesting consumer to prepare its face.
Decoded bytes remain immutable for process lifetime.

Missing document glyphs trigger a Sans worker after the first viewport.
Code blocks trigger a separate monospace worker. Inline code can use its result but does not trigger discovery.
Prepared font sets retain their backing memory through reference counting.
Font discovery reads existing system files and caches without extracting fonts or writing persistent caches.
Pango maps, descriptions, layout state, font resources, and ownership live in Zig. The frontend supplies its drawing context.

Visible blocks use measured Pango runs and bounded word-width caching: at most 2,048 words, each at most 128 bytes.
The key includes face, size, and full word. Long tokens use ordinary measurement.
Width changes reuse word measurements. Font, zoom, scale, and deferred-font changes invalidate incompatible measurements.
Runs retain height and descent so selection, backgrounds, and text share metrics.
Words can span styles and links. Grapheme boundaries support long-token wrapping and pointer selection.

Zig owns block heights, offsets, indexing, scroll state, horizontal extents, and geometry revisions.
Wide tables preserve readable column minimums and allow horizontal panning while ordinary paragraphs remain wrapped.
TOC jumps reveal collapsed ancestors. Details changes preserve the reading anchor.
The minimap retains its image surface while its viewport marker moves.
Mermaid figures keep independent zoom/Fit state and reuse prepared pixels when their scale changes.

### Bundled text libraries

Cairo retains image/font rendering, recording surfaces, groups, compositing, FreeType, and Fontconfig.
Pango retains its Cairo, Fontconfig, and FreeType backends.
Both use optimized static archives with LTO, position-independent code, and unused-section removal.
The engine exposes one implementation of each library and keeps their symbols private.

Cairo excludes X11/XCB, PNG functions, PDF/PostScript/SVG export, script/tee surfaces, GObject bindings, and tracing tools.
Pango excludes Xft, libthai/libdatrie, introspection, examples, documentation, and sysprof.
GTK file choosers and libdecor's GTK plugin stay disabled.
System development files remain necessary for the FLTK SDK and reference tests.
Relinking and source-access requirements are in the [release process](release-process.md#source-and-relinking).

## Images and diagrams

The image worker decodes ordinary raster images before optional diagram rendering.
The production viewer streams results through an 8 MiB queue and keeps a 32 MiB decoded raster cache.
Visible images take priority, including an image larger than the budget.
Evicted images retain their dimensions and reload from the document's encoded bytes when needed.
Workers release borrowed inputs after joining. The viewer owns transferred pixels until eviction or document replacement.
Zignal decodes PNG, JPEG, GIF, and BMP from supplied bytes without system codec libraries or additional decoder threads.
PNG preserves channel counts. JPEG returns RGB. GIF returns its first composed frame with transparency.
BMP supports palettes, row direction, bitfields, and RLE.
The adapter enforces caller byte limits, 32,768 pixels per axis, and 67,108,864 total pixels before allocation.
Incomplete input returns an error rather than partial pixels.

Two generated Zignal corrections preserve interlaced grayscale-alpha PNG transparency and compare full 16-bit RGB samples before `tRNS` conversion.
`tools/scripts/prepare-zignal.py` requires exact upstream source matches and stops if they change.
PNG reference pixels must match exactly. JPEG comparisons require mean channel error at most 1/255 and PSNR at least 40 dB.
Zignal also encodes grayscale/RGB/RGBA screenshots. Encoding borrows input and returns separately owned bytes.
Writers check write/close failures. Capture work is excluded from the document's codec-requirement snapshot.

Pozeiden detects and renders 17 Mermaid families, then passes SVG to the independent SVG module.
Journey, packet, architecture, treemap, radar, and ZenUML show source plus an unsupported-type message.
Mermaid input is limited to 256 KiB of UTF-8 and generated SVG to 16 MiB.
Advanced syntax, Markdown labels, newer shapes, and embedded images can differ from the official renderer.
Pozeiden estimates label widths. SVG draws with actual font outlines.

Generated Pozeiden adaptations correct dark notes, blocks, subgraphs, namespaces, timeline events, plot labels, and C4 text.
They preserve explicit user colors, reset thread-local themes after each call, and recolor only canonical arrow-marker definitions.
The adapter corrects `font-weight="italic"` to `font-style="italic"` and adapts removed Zig array repetition in cached sources.
Replacement counts and canonical markers are checked before building.

Local SVG skips Mermaid. It is parsed once, with resource and canvas checks before drawing.
Media-dependent CSS uses the library's complete rendering path.
Local image input is limited to 16 MiB. SVG canvases are limited to 16,384 pixels per axis and the image-allocation cap.
Logical size remains separate from higher-resolution rendered pixels.
Scripts, foreign objects, embedded images, external resources, and external font styles are unsupported.
SVG uses bundled or explicitly prepared fonts, with whole-run fallback.
Automatic per-character fallback, Arabic shaping, and RTL/vertical text remain limitations. Unsupported requests produce readable errors.

Pozeiden uses PolyForm Noncommercial 1.0.0. Commercial use requires separate upstream permission.
Notices include its dependencies and z2d's MPL text. `mdf --licenses` prints bundled notices.
License and dependency upgrade checks belong to the [release process](release-process.md#dependency-updates).

## JSON and settings

`src/json.zig` wraps `std.json` through the C ABI. `frontend/json.hpp` supplies C++ ownership bindings.
Each tree owns an arena and copies parsed strings. Read views retain their arena.
Mutation clones shared trees. Inserted values copy into the destination arena, with at most 256 nested containers.
The binding preserves signed/unsigned 64-bit integers and rejects invalid types, overflow, and nonfinite numbers.
Serialization uses `std.json.Stringify`. Callers release output with `mdf_buffer_free`.
Bulk document data uses typed views rather than JSON.

Settings are saved by default at `~/.config/mdf/settings.json`.
Disabling saving retains only the disabled choice for the next launch.
Theme, mode, font size, preview visibility, window size, and maximized state use the existing schema.
Every launch starts wrapped. No-wrap is a session preference. Legacy `font_family` values are ignored.
The compositor controls window placement. Scroll positions clamp after resize. Fitting documents hide their vertical scrollbar.

## Themes

`src/themes.zig` owns palette IDs, names, colors, and default sizes for both frontends.
The original Classic/Paper/Terminal IDs and saved names remain stable.
Selecting a theme preserves light/dark mode and applies its default size. Reset restores that size.

| Theme | Default size |
| --- | ---: |
| Classic | 12 |
| Paper | 14 |
| Terminal | 11 |
| Nord | 13 |
| Solarized | 14 |
| Gruvbox | 12 |
| Catppuccin | 13 |

Palettes cover reader and panel surfaces, controls, links, selections, highlights, and alerts.
The compiled theme catalog needs no stylesheet parser or extra font discovery.
Text, links, muted labels, selections, and highlights use a 4.5:1 minimum contrast in their tested contexts.
Palette references: [Nord](https://www.nordtheme.com/docs/colors-and-palettes/), [Solarized](https://ethanschoonover.com/solarized/),
[Gruvbox](https://github.com/morhetz/gruvbox), and [Catppuccin](https://catppuccin.com/palette/).

## Profiling and experimental frontend

`make profile` creates a timestamped offline HTML report from 12 cold launches of each SMALL/MID/HUGE TEXT/IMAGES fixture.
Samples live in `assets/samples/`. Assets and generation details are in [assets/SAMPLES.md](../assets/SAMPLES.md).
The report records exact binaries, dependency versions, workload, thread tracks, waits, and readiness dependencies.
Nested spans and parallel branches never count twice in critical-path totals.

The parent starts the monotonic launch clock before process creation.
Pre-main time includes loading, linking, initialization, and scheduling. It is not isolated disk-I/O time.
First Markdown readiness ends after actual buffer commit and socket flush, excluding compositor scanout.
Cold runs fsync inputs, reset Linux reclaimable caches, create an empty application cache, and reject resident input pages through `mincore`.
Desktop libraries, compositor state, and hardware caches can remain warm.
Warm and cold data, CPU/power conditions, uncertainty, and raw pairs stay separate.
Scroll/resize/TOC measurements run from programmatic handlers through synchronous flush and also exclude compositor latency.
Scroll profiles also record settled timings that include visible raster reloads.

Compressed optional modules are the shipping size/latency tradeoff. Raw mode remains the comparison path.
Historical measurements do not establish a general first-render speedup.
Keep binary hashes and matching symbol files when comparing builds. `make clean` deletes local evidence under `build/`.

The native Zig/z2d viewer retains Wayland input, clipboard/drop handling, menus, resizing, scale handling, optional fonts, and deferred assets.
Its optional FreeType text module keeps the eager dependency graph small. XKB remains the system input library.
It remains opt-in after appearance, menu responsiveness, and performance review.
Its final frame-callback endpoint differs from FLTK's submission endpoint and must be aligned before comparing full readiness.
Validation commands are in [tests/README.md](../tests/README.md).
