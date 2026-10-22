# Independent lazy rendering resources

MDF distributes one executable with two independently compressed rendering modules.
They stay outside the startup mappings and load only for documents that need their renderer.
The Mermaid module parses diagrams, calculates layout, and produces SVG text. The SVG module parses and rasterizes SVG.
Pozeiden calculates Mermaid layout in Zig. zig-svg and z2d parse and rasterize SVG in Zig.
SVG-only documents skip Mermaid entirely.
The UI engine is a separate uncompressed embedded module loaded during [parallel startup](parallel-bootstrap.md).
Its mandatory loading precedes the first viewport; the optional rendering modules below keep their post-viewport gate.
Raster codecs use a third independent `.mdf_image` module, described in [image decoding](image-decoding.md).
The default `MDF_OPTIONAL_MODULE_COMPRESSION=zlib` compresses each of these three modules independently.
Set it to `raw` for comparison; this changes storage, without changing compilation or loading conditions.

## Startup and ownership

The `.mdf_mermaid` and `.mdf_svg` ELF sections contain checked zlib payloads. Neither section has `SHF_ALLOC`.
The application does not map or read them before the first viewport.
SVG-only documents load `.mdf_svg` only. Mermaid documents load Mermaid layout, then SVG rendering when layout succeeds.
Documents without Mermaid or local SVG skip both loaders.

The image worker decodes ordinary PNG and JPEG images first.
Before the first optional rendering call, the worker waits for the first Markdown viewport.
The GUI releases this gate after the actual buffer commit and socket flush.
Cancellation also releases the gate, so shutdown does not wait for a frame that cannot arrive.

The loader reads the payload from `/proc/self/exe`.
The loader inflates each requested payload into a writable mapping of an anonymous memory file.
It checks the stream, declared length and CRC32 in bounded, cancellation-aware chunks, then removes the writable mapping and seals the memory file.
Zig's existing standard-library decoder handles inflation; no external extractor is needed.
Raw comparison builds read and verify the requested ELF directly into that mapping without inflation.
Then `dlopen` maps the module with `RTLD_NOW | RTLD_LOCAL`.
The loader never extracts a module to a disk file.

Each loaded module stays until process exit. Its callbacks and thread-local state remain valid for that lifetime.
The application joins image workers before it releases their inputs and results.
The host supplies a font callback. Initialization requests regular and bold only.
SVG's font resolver requests an italic face only when an actual text style requires it, including inherited CSS styles.
The module borrows prepared font data for each rendering call. It does not discover system fonts.
Successful pixels use libc `malloc`. The host releases them with `free`.

## Build and ABI

Both modules retain full release optimization and unused-code removal.
`frontend/pozeiden.zig` adapts the pinned submodule to the existing C ABI. The Zig build produces `libmdf-pozeiden.a`.
`frontend/svg.zig` adapts zig-svg to the same C ABI. The Zig build produces `libmdf-svg.a` beside the core and Mermaid archives.
Zig 0.17.0 builds all three archives offline. Rust and Cargo are not required.
CMake links each archive with `diagram-module.c` and the existing libm compatibility adapter.
Only `mdf_diagram_api` appears in the exported symbol table.
The ABI 3 table contains version, size, module kind, reserved flags, font-provider initialization, and the applicable rendering function.
SVG rendering can also return owned UTF-8 containing missing label characters.
The native viewer uses these characters to request deferred fonts without a second XML parser or a second SVG parse.
The checked payload container remains at format version 2; its version is separate from the renderer API version.
Container flag 0 marks the default zlib stream. Flag 1 marks raw ELF and requires equal stored/loaded byte lengths.
Both formats remain supported. Fonts keep their separate compressed, on-demand resource format.
The Mermaid function returns C-allocated SVG text. The SVG function returns C-allocated pixels. The host frees both.
The host checks every table field before it calls initialization.

## Pozeiden integration and upgrades

The Git submodule `modules/pozeiden` pins version 0.4.1 at `071fbbb85fb73a06994c163c6093123bd3ac11f6`.
Its public license is PolyForm Noncommercial 1.0.0. Commercial use requires separate upstream permission.
`assets/MERMAID-NOTICE.txt` includes the complete license, required notice, mvzr license, and SVG dependency licenses.
`make setup` initializes a missing submodule and downloads its pinned mvzr dependency. Normal builds stay offline.

MDF uses strict type detection. The 17 supported families generate SVG, then the independent SVG module rasterizes that output.
Journey, packet, architecture, treemap, radar, and ZenUML retain source text with an unsupported-type message.
No legacy Mermaid renderer remains. Unsupported types do not load the SVG module.
Input is limited to 256 KiB of UTF-8, and generated SVG is limited to 16 MiB.
Pozeiden estimates label widths instead of measuring font metrics. The SVG module draws the final text with actual font outlines.
Advanced syntax, Markdown labels, newer shape declarations, and embedded images remain compatibility limits.

The submodule stays unchanged. `frontend/core-build.zig` copies its sources into the Zig cache and normalizes these renderer files:

| Generated file | MDF adjustment | Reason |
| --- | --- | --- |
| `renderers/sequence.zig` | Use theme fields for note and reference fills/strokes. Use the loop theme fill for default dark blocks. | Keep light text readable on dark notes and sequence blocks. Explicit rectangle colors remain intact. |
| `renderers/flowchart.zig` | Use subgraph theme fields and the theme text color for subgraph titles. | Keep dark subgraphs and titles readable. |
| `renderers/state.zig` | Use note theme fields for note fill/stroke. | Keep dark state notes readable. |
| `renderers/class.zig` | Use note theme fields and dark namespace fills, titles, and stereotype text. | Keep dark notes, namespaces, and labels readable. Light namespace colors stay intact. |
| `renderers/timeline.zig` | Use the dark node fill for default event boxes. | Keep light event text readable. |
| `renderers/quadrant.zig` | Use the dark subgraph fill for the default plot area. | Keep light point labels readable. |
| `renderers/pie.zig` | Use the theme text color for dark percentage labels. | Keep percentages readable outside the slices. |
| `renderers/c4.zig` | Use light text for dark boundary and relationship labels. | Keep labels readable on the dark canvas. Element colors stay intact. |
| `renderers/state.zig`, `renderers/block.zig`, `svg/layout.zig` | Replace removed array repetition with equivalent `@splat` initialization. | Compile the pinned Zig 0.16 sources with Zig 0.17. |

Each source replacement must match exactly once. The build stops if an upstream update changes these source locations.
The adapter preserves upstream light fills and sets dark fills before rendering. It resets the thread-local theme after each call.
For dark SVG, the adapter recolors only the exact canonical `arrow_marker_defs` block from `svg/writer.zig`.
Explicit user colors elsewhere stay intact. A regression check detects changes to the arrow definitions.
The existing image worker calls the renderer serially. Successful SVG buffers use the C allocator and the host calls `free`.

The adapter changes the generated invalid attribute `font-weight="italic"` to the intended `font-style="italic"`.
This repairs sequence separator text for the strict SVG parser. A focused regression check preserves this behavior.
MDF builds Pozeiden's library sources directly because its standalone CLI build still uses the retired `b.args` API.
The parent manifest pins mvzr. `scripts/prepare-mvzr.py` replaces its removed array repetition in a generated cache file.
The mvzr source and submodule sources stay unchanged. The script checks every expected replacement count before writing output.

For an upgrade, update the gitlink, `frontend/dependencies.json`, and the version in `frontend/core-build.zig` together.
Review the palette replacements, canonical markers, supported families, license, and nested dependency hashes.
Also review the Zig 0.17 array adaptations and the sequence font-style correction.
Regenerate notices with `python3 scripts/mermaid-notices.py` after fetching the new dependencies.
Run the checks below and inspect light/dark diagrams before accepting the upgrade.

## zig-svg integration and limits

`modules/zig-svg` pins version 0.2.0 at `6feaa8d4aee609b0945473931fb27fdcdf1ebfef`.
Its source stays unchanged. The parent build imports its public SVG and z2d modules.
The adapter parses an SVG once, checks the resource policy and canvas bounds, then draws from that parsed tree.
SVGs with media-dependent CSS use the library's full rendering path so output-size queries remain correct.
Internal allocations use Zig's SMP allocator. Successful output buffers use libc allocation for the existing host ABI.

The source graph uses the libraries' default features. `scripts/zig_deps.py` fetches transitive pinned packages and excludes inactive lazy dependencies.
Cached sources and the optional cached compiler stay in `zig-pkg/` through `make clean`.
Notices include every active package's license and pinned source URL. z2d's normalized archive omits its license text.
`assets/licenses/z2d-MPL-2.0.txt` supplies that standard text, with copyright notices collected from the pinned source headers.

SVG font callbacks select bundled Open Sans styles and can use an explicitly prepared system face.
Automatic per-character font fallback, Arabic contextual shaping, and RTL/vertical layout remain unsupported.
RTL/vertical requests produce a readable error. Some system font formats produce an unsupported-font error.
Markdown body text keeps its existing Pango shaping and fallback behavior.

The accepted migration trades SVG performance and text coverage for a Zig-only diagram stack.
The isolated evaluation used 12 paired cold runs per engine for each of four workloads, with no discarded outliers.
Its latest prototype reduced executable size by 6.18%, while the SVG-heavy workload's full readiness increased by 72.43%.
First-viewport changes on the standard samples stayed within measurement uncertainty. Those figures describe the frozen prototype, not later builds.

The packer compresses each stripped module independently and embeds its stream with a size/CRC32 header.
Raw comparison builds embed the stripped module unchanged.
The module and its debug symbols remain build artifacts. Installers copy only the final executable.
Payload changes force the host link and packing steps to run again.
The executable has no build-directory runtime search path. Desktop libraries resolve through the system loader.
The image worker uses constant initialization for its presentation gate. Ordinary documents do not call a condition-variable constructor.

The payload starts with this 40-byte header. All integers use little-endian order.

| Offset | Field |
| --- | --- |
| 0 | Eight-byte magic: `MDFDG01\0` |
| 8 | 32-bit payload format version: `2` |
| 12 | 32-bit header size: `40` |
| 16 | 64-bit stored payload size |
| 24 | 64-bit loaded ELF size |
| 32 | 32-bit CRC32 of the loaded module |
| 36 | 32-bit encoding flags: `0` default zlib, `1` raw comparison |

The loader rejects an expanded module larger than 256 MiB, including Debug builds.
Damaged payloads, incompatible ABIs, and denied executable memory produce an error for the affected diagram or image.
The document and ordinary image decoders remain usable.

## Local SVG

Local SVG files use only the SVG module, with the same pixel ownership rules as Mermaid.
SVG text uses bundled Open Sans or an explicitly selected prepared system face.
It retains the font coverage and shaping limits listed above.
SVG images retain their logical dimensions when the renderer creates pixels at twice the logical resolution.
The existing 16 MiB local-image input limit also applies to SVG.
The renderer rejects canvases larger than 16384 pixels per dimension and respects the image allocation limit.
Embedded images, scripts, foreign objects, external resources, and external font styles are unsupported.
The image area shows a readable error for unsupported SVG input.

## Compressed fonts

Each Open Sans face has its own zlib stream, generated during the Zig build by `scripts/pack-font.py`.
The libc-only bootstrap starts a worker before any UI library loading.
This worker inflates regular and bold with Zig's standard-library decoder, alongside document parsing and UI loading.
Fontconfig and the UI keep receiving immutable, uncompressed font bytes through the existing font API.
If a consumer arrives early, it waits only for its requested face. If thread creation fails, the consumer decodes that face itself.
The worker joins before the document core and profiling recorder are destroyed, including startup error paths.
The decoded data stays available for the process lifetime.
Each italic face inflates only on demand through the same Zig cache and decoder.
The 16-byte header contains `MDFONT1\0`, a 32-bit expanded size, and a 32-bit CRC32, in little-endian order.
Decompression validates the header, bounded length, complete stream, and checksum.
The bootstrap decoder also checks the zlib checksum and the font signature.
Compressed renderer payloads use that same checked decoder through the host C boundary.
Raw comparison payloads bypass the decoder and retain their length and CRC32 checks.
Inflation and checksum passes poll cancellation between 64 KiB chunks.
Expanded modules stay in anonymous memory; only a complete, length- and checksum-validated image is sealed and passed to the loader.
Thread-safe initialization retains the resulting immutable bytes for the process lifetime.
Parsing actual styled spans determines the GUI's required faces before layout. Loading one face does not inflate the other.
SVG uses the same host cache without registering unused faces in the GUI's private Fontconfig configuration.
The native profile records the startup worker on its own track, so overlapping inflation is not added to wall-clock totals.
The source TTF files and their licenses stay unchanged. No runtime font files, caches, or external decompressors are required.

## Verification

Run the release image, module, and GUI checks:

```sh
make test-images OPTIMIZE=ReleaseFast
make test-gui OPTIMIZE=ReleaseFast
make test
make release
make test-packages
```

`make test-mermaid` checks the adapter and upstream Zig tests, including all 17 families in both themes.
The image checks rasterize all 17 families through the actual worker in both themes.
Set `MDF_DIAGRAM_GALLERY` to an output directory to save those 34 images for inspection.
The module checks cover an empty working directory, damaged payloads, an incompatible ABI, cancellation, and repeated use.
The package checks examine glibc requirements in both the host and the expanded module.
The GUI checks require all module preparation to start after the first committed and flushed Markdown viewport.
They also check source/error fallback for the six unsupported families without loading the SVG module.

For a cold comparison, preserve both executable files and their matching debug symbols first.
Then compare both first Markdown submission and full readiness:

```sh
python3 scripts/benchmark-startup.py --before BEFORE/mdf --after AFTER/mdf \
  --batches 2 --pairs-per-batch 10 \
  --output build/lazy-renderer-comparison/report.html
```

The default workloads are the SMALL/MID/HUGE `-TEXT.md` and `-IMAGES.md` pairs.
Repeated `--document` arguments replace the workload list.
That list can include both samples and a plain-document control.
Every launch uses the existing cache reset and zero-resident-page checks.
The report keeps scaffold and first-viewport guards separate from optional diagram and full-readiness costs.
Both graphs use timestamps from their selected optimized launch.
The treemap counts each stored section once and labels raw modules as uncompressed lazy renderers.
Reducing file size is not a success if decompression or later rendering increases user-visible latency.
