# Independent compressed rendering resources

MDF distributes one executable with two independent compressed rendering modules and the static zlib decompressor from FLTK.
The Mermaid module parses diagrams, calculates layout, and produces SVG text. The SVG module parses and rasterizes SVG.
Each module contains the Rust support code that it uses. Splitting the modules can duplicate support code, but SVG-only documents skip Mermaid entirely.

## Startup and ownership

The `.mdf_mermaid` and `.mdf_svg` ELF sections contain independent zlib streams. Neither section has `SHF_ALLOC`.
The application does not map or read them before the first viewport.
SVG-only documents load `.mdf_svg` only. Mermaid documents load Mermaid layout, then SVG rendering when layout succeeds.
Documents without Mermaid or local SVG skip both loaders.

The image worker decodes ordinary PNG and JPEG images first.
Before the first optional rendering call, the worker waits for the first Markdown viewport.
The GUI releases this gate after the actual buffer commit and socket flush.
Cancellation also releases the gate, so shutdown does not wait for a frame that cannot arrive.

The loader reads the payload from `/proc/self/exe`.
Bundled zlib decompresses the payload directly into a writable mapping of an anonymous memory file.
The loader checks the size and CRC32, removes the writable mapping, and seals the memory file.
Then `dlopen` maps the module with `RTLD_NOW | RTLD_LOCAL`.
The loader never extracts a module to a disk file.

Each loaded module stays until process exit. This lifetime preserves code pointers in Rust thread-local destructors.
The application joins image workers before it releases their inputs and results.
The host supplies a font callback. Initialization requests regular and bold only.
SVG's font resolver requests an italic face only when an actual text style requires it, including inherited CSS styles.
The module copies prepared fallback font data for each rendering call. It does not discover system fonts.
Successful pixels use libc `malloc`. The host releases them with `free`.

## Build and ABI

The Rust build retains full release optimization and unused-code removal.
Separate Cargo feature builds exclude Mermaid dependencies from SVG and SVG dependencies from Mermaid.
CMake links each archive with `diagram-module.c` and the existing libm compatibility adapter.
Only `mdf_diagram_api` appears in the exported symbol table.
The ABI 2 table contains version, size, module kind, reserved flags, font-provider initialization, and the applicable rendering function.
The Mermaid function returns C-allocated SVG text. The SVG function returns C-allocated pixels. The host frees both.
The host checks every table field before it calls initialization.

The packer compresses the stripped module with zlib level 9.
The module and its debug symbols remain build artifacts. Installers copy only the final executable.
Payload changes force the host link and packing steps to run again.
The executable has no build-directory runtime search path. Desktop libraries resolve through the system loader.
The image worker uses constant initialization for its presentation gate. Ordinary documents do not call a condition-variable constructor.

The payload starts with this 40-byte header. All integers use little-endian order.

| Offset | Field |
| --- | --- |
| 0 | Eight-byte magic: `MDFDG01\0` |
| 8 | 32-bit module ABI version: `2` |
| 12 | 32-bit header size: `40` |
| 16 | 64-bit compressed size |
| 24 | 64-bit expanded size |
| 32 | 32-bit CRC32 of the expanded module |
| 36 | 32-bit reserved flags: `0` |

The loader rejects an expanded module larger than 256 MiB, including Debug builds.
Damaged payloads, incompatible ABIs, and denied executable memory produce an error for the affected diagram or image.
The document and ordinary image decoders remain usable.

## Local SVG

Local SVG files use only the SVG module, with the same pixel ownership rules as Mermaid.
SVG text uses bundled Open Sans and available prepared fallback fonts.
SVG images retain their logical dimensions when the renderer creates pixels at twice the logical resolution.
The existing 16 MiB local-image input limit also applies to SVG.
The renderer rejects canvases larger than 16384 pixels per dimension and respects the image allocation limit.
Embedded images, scripts, foreign objects, external resources, and external font styles are unsupported.
The image area shows a readable error for unsupported SVG input.

## Optional italic fonts

Regular and bold Open Sans remain raw embedded resources for startup.
Each italic face has its own zlib stream, generated during the Zig build by `scripts/pack-font.py`.
The 16-byte header contains `MDFONT1\0`, a 32-bit expanded size, and a 32-bit CRC32, in little-endian order.
Decompression validates the header, bounded length, complete stream, and checksum.
Thread-safe initialization retains the resulting immutable bytes for the process lifetime.
Parsing actual styled spans determines the GUI's required faces before layout. Loading one face does not inflate the other.
SVG uses the same host cache without registering unused faces in the GUI's private Fontconfig configuration.
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

The module checks cover an empty working directory, damaged payloads, an incompatible ABI, cancellation, and repeated use.
The package checks examine glibc requirements in both the host and the expanded module.
The GUI checks require all module preparation to start after the first committed and flushed Markdown viewport.

For a cold comparison, preserve both executable files and their matching debug symbols first.
Then run the benchmark with the compressed-renderer policy:

```sh
python3 scripts/benchmark-startup.py --before BEFORE/mdf --after AFTER/mdf \
  --compressed-renderer --batches 2 --pairs-per-batch 10 \
  --output build/compressed-comparison/report.html
```

The default workloads are `SAMPLE.md` and `SAMPLE-HUGE.md`.
Repeated `--document` arguments replace the workload list.
That list can include both samples and a plain-document control.
Every launch uses the existing cache reset and zero-resident-page checks.
The report keeps scaffold and first-viewport guards separate from optional diagram and full-readiness costs.
Both graphs use timestamps from their selected optimized launch.
The treemap counts the compressed section once. Expanded module bytes appear as separate information, outside executable totals.
