# Zig migration

The default build uses FLTK again, following the review of UI appearance and menu responsiveness.
The native Zig/z2d UI is retained as the explicit `make native` experiment.
The Zig document core, parser, codecs, JSON, compression, and Mermaid/SVG modules remain in production.
Wide-table overflow and per-diagram zoom/Fit/panning are also available in the restored FLTK reader.
Earlier stage entries and benchmark results below record the native frontend evaluation.
Current rendering work targets Latin text. Broader script layout is deferred; existing fallback code remains available without a new support guarantee.

Wide tables retain readable minimum column widths when the columns cannot fit together.
Ordinary paragraphs remain wrapped, and the native body gains a 20-pixel horizontal scrollbar for the overflowing table.
The TOC and minimap keep their own positions. Arrow keys, horizontal wheel input, Shift-wheel, and the body scrollbar pan the document.
The wrapped reader derives overflow from tables it has already laid out; it does not measure the entire document to find an offscreen table.
Oversized individual tokens can still wrap, while compact labels and numbers remain intact.
Core regression checks and private Wayland checks cover 8-, 16-, and 24-column tables at narrow widths.
Controlled measurements of the current native frontend are recorded below.

Mermaid figures default to natural size with per-figure zoom and an explicit Fit overview.
Their inline controls remain reachable during horizontal panning, and pointer dragging pans the document body.
Zoom changes reuse the prepared pixels and update one block's geometry. Other figures retain their own scales.
The controls use bundled Latin fonts and appear only after a supported diagram is prepared.
Regular image fitting and the retained reference frontend's default fit policy remain unchanged.

## Controlled native startup comparison

The October 2026 comparison uses the preserved optimized FLTK/Cairo executable and native Zig/z2d build `d291b78`.
There are 480 measured launches: 40 per binary, document, and cache state.
Two batches balance binary order and shuffle the three documents. No outliers are removed.
The private Weston software compositor uses a 1040 × 780 viewport.
CPU affinity, performance governor, frequency preferences, and readable power limits match throughout both datasets.

The common endpoint is the first Markdown buffer flushed to the Wayland socket.
Times include the parent launch request, process creation, executable loading, and application startup.
They do not measure physical key handling or monitor presentation.
Each value is the mean plus or minus its Student-t 95% confidence margin, in milliseconds.
The paired change is native minus FLTK; a negative change means less elapsed time.

| Cache | Sample | FLTK | Native Zig | Paired change | Time change |
|---|---|---:|---:|---:|---:|
| Cold | SMALL | 42.75 ± 2.23 | 22.83 ± 0.80 | −19.92 ± 2.23 | −46.6% |
| Cold | SAMPLE | 39.85 ± 1.57 | 26.78 ± 0.75 | −13.07 ± 1.72 | −32.8% |
| Cold | HUGE | 47.32 ± 3.68 | 51.15 ± 2.05 | +3.83 ± 3.71 | +8.1% |
| Warm | SMALL | 21.62 ± 0.98 | 15.58 ± 0.47 | −6.04 ± 1.03 | −27.9% |
| Warm | SAMPLE | 21.36 ± 0.93 | 20.17 ± 0.60 | −1.18 ± 1.10 | −5.5% |
| Warm | HUGE | 41.81 ± 1.43 | 43.68 ± 1.04 | +1.87 ± 1.76 | +4.5% |

Cold launches flush all input files, request Linux `drop_caches=3`, and verify zero resident executable, document, and local-image pages.
All 8,880 file-residency checks pass. Active shared OS pages and hardware drive caches are not guaranteed cold.
Warm launches pre-run both variants and read the input files before each fresh process.

The executable shrinks from 5,802,360 to 3,643,560 bytes, a 37.21% reduction.
The native renderer does not pass every performance gate: huge-document submission is later, and reported full readiness is later for all samples.
The readiness endpoints differ: native waits for the final Wayland frame callback; FLTK records successful buffer/socket submission.
Those readiness numbers need endpoint alignment before a direct completion-time comparison.
Representative traces also show higher native viewport and minimap rasterization costs.

Memory comparisons exclude native `getrusage().ru_maxrss`, which can retain the parent's pre-exec peak on this launch path.
The reference frontend instead reads the current process's `VmHWM`. A separate fork/exec reproduction confirms this measurement difference.
No application code changes or rebuilds occur during the measurements.
A harness inode-replacement race is fixed with atomic staging before timing; the interrupted warm dataset is restarted in full.

The summary, exact binaries, individual pairs, CPU records, and same-run flame/call graphs are retained under
`build/zig-migration-20261022T031026Z/native-idle-benchmark/`.

The migration preserves the existing Markdown behavior, controls, rendering, font fallback, and standalone executable.
Each stage has its own tests and commit. Previous complete executables provide rollback and visual references.

1. Replace screenshot PNG encoding with the existing Zignal module.
2. Replace diagram/font decompression with Zig's checked inflater, preserving cancellation and lazy loading.
3. Evaluate and migrate the Markdown parser to Zigmark, with specification and MDF behavior checks.
4. Move application-owned layout, state, and workers into the Zig core in separate behavior-preserving commits.
5. Replace FLTK/Cairo UI drawing with a Zig implementation after its controls, layout, input, and text rendering pass the same checks.

The first stages retain the existing UI to keep ownership changes reviewable.
Complex-script shaping, system font selection, and desktop input must remain correct during the transition.
A Zig binding to a C library does not count as replacing that implementation.

## PNG encoding

Screenshot encoding uses Zignal through `mdf_encode_png`.
The input pixels are borrowed; successful output is a separate C-allocator allocation owned by the caller.
Dimensions, byte lengths, and supported pixel formats are checked before encoding.
Unaligned RGBA byte views are copied into aligned storage when required.
The screenshot writer checks write and close errors.

The native codec checks decode encoded images with the independent libpng reference.
The GUI suite exercises screenshots, all font styles, images, diagrams, and both supported cursor paths.
Before/after captures compare document pixels, including wide tables, code, italic text, and glyph fallback.
GIF/BMP decoding also uses Zignal; the application no longer links FLTK's image archive.

The initial optimized comparison measured 5,762,424 → 5,696,888 bytes (64 KiB smaller).
All tests and 44 GUI profiles passed. Twelve reader captures were pixel-identical.
The 144 balanced cold/warm launches showed no clear first-viewport timing change across the three samples.
Average differences include zero in their paired 95% intervals; this is not a claim of a measured startup gain.

## Zig decompression

`src/compression.zig` owns zlib validation and expansion for all fonts and optional renderer modules.
It validates the zlib header, exact input/output lengths, Adler32 trailer, and the resource's CRC32.
Module inflation writes directly into bounded anonymous memory and polls cancellation every 64 KiB.
The checksum pass also polls cancellation. A canceled load remains retryable.

All four font faces use one immutable Zig cache. Startup prepares regular and bold only.
Each required italic face decodes after parsing; a failed or unused sibling face is not touched.
The C++ frontend keeps a small borrowed-buffer adapter and records acquisition time.
The actual early italic preparation has its own recorded span on the navigation worker.
The production binary no longer needs bundled C zlib code. System FreeType can still load its own system zlib dependency.

Required italic data is prepared by the existing early navigation/assets worker after parsing.
The style mask includes nested emphasis, HTML, heading weight, and table-header weight.
This keeps inflation off the GUI path without loading unused faces or creating another thread under the dynamic loader lock.
Fontconfig registration stays on the main thread before layout and first pixels.

The optimized binary measured 5,696,888 → 5,658,120 bytes (37.9 KiB smaller).
All 145 core tests pass in each build mode, along with module/font corruption tests, 44 GUI profiles, and twelve identical reader captures.
The final comparison uses 144 balanced cold/warm launches in isolated headless Weston with unchanged CPU power settings.
Its paired first-viewport 95% intervals include zero for every sample and cache mode.
Earlier desktop and serial-inflation prototype measurements are retained separately.

## Markdown parser

The document core uses Zigmark 0.11.1 with Mecha 0.11.0, both pinned under `modules/`.
Zig converts the parsed AST directly into typed block, span, table, image, and link state.
The C callback tables and MD4C parser/entity implementations are removed.
The existing source-size limit remains unchanged.

The conversion preserves MDF's footnotes, alerts, supported inline HTML, details, task lists, and anchors.
The generated MDF parser disables HTML blocks and nonstandard frontmatter recognition.
All AST text storage belongs to the document arena, so returned text views stay valid until document release.
Table-row temporaries use the supplied allocator and are released with the document or caller scope.

The standard HTML entity data retains its original MIT attribution, but its lookup and numeric-reference decoding are Zig.
Tests cover all 2,125 named expansions and invalid/numeric references.
Image labels are flattened once: escaped punctuation and code stay literal, entities decode once, and autolink text is retained.
Escaped pipes inside table code spans now follow GFM instead of displaying the escape backslash.

The build applies documented patches in `frontend/patches/zigmark/` to generated source copies.
Every build runs 652 CommonMark cases, 24 GFM extension cases, and 90 additional compatibility cases.
Core tests also check nested-image limits and balanced profiling scopes after parse errors.
The profiler identifies Zigmark and Mecha and records parsing/conversion in the same optimized process as rendering.

The entity-reader module retains compilation debug metadata to avoid a Zig 0.17 compiler crash with per-module `-fstrip`.
ReleaseFast optimization remains enabled; final release executables are stripped normally.

The optimized parser migration measured 5,658,120 → 5,712,768 bytes (53.4 KiB larger).
The small and regular samples have no clear measured first-viewport change.
The two-megabyte huge sample remains slower: warm first viewport increased by 12.19 ± 6.45 ms in the final paired comparison.
The entity scan and unnecessary reference work were reduced, but constructing and converting the Zigmark AST still costs more than MD4C's direct callbacks.
The migration is retained for the requested Zig architecture; this stage is not a parser speedup.
Subsequent state/layout and UI work targets the remaining startup critical path.

## Shared layout metrics

Font face selection, heading/code/body sizes, zoom rounding, and document-width modes are resolved in Zig.
The FLTK frontend consumes the numeric result through a small C boundary.
The required-font preparation uses the same face-selection rule.
This removes the temporary C++ heading-size vector allocation and establishes shared metrics for the later drawing backend.

All 152 core tests pass in each mode, along with the 766 parser cases and 44 GUI profiles.
All twelve reader captures are pixel-identical to the preceding parser build.
The binary size changed by 272 bytes; this extraction is not claimed as a measured startup improvement.

## Intrinsic table widths

Zig now distributes measured table-column widths, protects compact cells, caps oversized tokens, and handles no-wrap expansion.
The fitting routine uses caller-provided storage without allocating or calling font functions.
The frontend still measures intrinsic text with the existing backend and passes those measurements across the boundary.

All 155 core tests, 766 parser cases, and 44 GUI profiles pass.
All twelve reader views remain pixel-identical, including the sixteen- and twenty-four-column sample tables.

## Text flow

Zig owns text wrapping, long-word splitting, tab stops, alignment, baselines, and byte positions.
The frontend supplies font measurements through a C callback and translates borrowed run records for the existing painter.
Text measurement without collected runs performs no allocations.
This interface also lets a later Zig painter consume the same layout directly.

Tests cover UTF-8 boundaries, selection positions, explicit newlines, leading code whitespace, styled cells, malformed input, and allocation failures.
All 163 core tests pass in Debug, ReleaseSafe, and ReleaseFast, along with the 766 parser cases and 44 GUI profiles.
All twelve complete captures are pixel-identical to the table-fitting build.
The optimized executable grew by 5,536 bytes; no startup speedup is claimed for this extraction alone.

## Optional module ownership

Zig owns the independent Mermaid and SVG module states, ELF-section reads, anonymous memory, sealing, API validation, and load statistics.
The frontend adapter supplies cancellation and immutable font views.
One loader publishes each module; competing callers wait, canceled requests remain retryable, and persistent failures retain their diagnostic.
This preserves the first-viewport gate and the ordinary-document path that skips both modules.

New checks cover bounded ELF sections, header sizes, cancellation, and nested profiling depth.
Native tests request each real module from eight threads and verify one shared API pointer, independently of the other renderer.
The existing corrupt-stream, checksum, ABI, missing-module, and optional-font tests also pass.
All 169 core tests pass in all three modes, plus 766 parser cases, 44 GUI profiles, and twelve identical reader views.
One full-window comparison has the previously observed three-pixel scrollbar variation outside the reader.
The optimized executable grew by 1,840 bytes.

## Keyboard worker

Zig owns asynchronous Compose and keymap preparation, pending requests, generations, publication, cancellation, and resource release.
The FLTK hook is a small adapter around an opaque worker handle.
The Zig worker archive links into the deferred UI engine, so XKB remains outside the libc-only launcher.
XKB itself remains the system's C implementation; this change replaces application-owned worker code.

The existing native tests cover modifier state, Compose, stale and replaced keymaps, failure recovery, and shutdown during work.
Keyboard and system-font checks now run as part of every `make tests` suite.
The complete optimized suite and 44 GUI profiles pass, with twelve pixel-identical complete captures.
The optimized executable is 4,016 bytes smaller than the preceding module-loader build.

## Image worker

Zig owns the image queue, thread, cancellation, first-viewport condition, fallback-font mappings, diagram calls, and unadopted pixels.
The frontend keeps immutable encoded inputs and prepared-font descriptors alive until the worker joins.
Decoded pixels transfer once into the current GUI image owner; resetting a worker cannot invalidate adopted images.
Ordinary PNG/JPEG decoding still finishes before optional SVG/Mermaid loading waits for the first committed viewport.

The native suite checks 158 PNG/JPEG fixtures, repeated cancellation and restart, adopted-pixel lifetimes, malformed diagrams, and all 17 Mermaid families in both themes.
The full optimized suite, keyboard/system-font checks, and 44 GUI profiles pass.
The keyboard test uses the production dead-section removal rule so unused image-worker functions do not require image decoders.
The optimized executable grew by 4,096 bytes.
All twelve reader captures are pixel-identical; two full-window captures have the known three-pixel scrollbar variation.

## System-font preparation

Zig now owns system-font workers, private lookup configurations, directory traversal, cycle detection, matching, anonymous font files, and prepared-result lifetimes.
The current painter receives immutable metadata and retains an opaque owner for each prepared font set.
Fontconfig still performs system matching; this replaces MDF's C++ discovery and worker code.

Discovery reads existing caches or scans without writing new caches and never replaces the process's bundled-font configuration.
Fallback selection loads only faces that cover requested glyphs and retains bundled Latin faces in the private map.
Tests cover uncached directories, symlink cycles, unavailable fonts, unresolved glyphs, all styles, cancellation, retained results, and descriptor cleanup.
The full optimized suite and 44 GUI profiles pass.
The optimized executable remains 5,718,448 bytes, the same size as the preceding image-worker build.
All twelve complete captures are pixel-identical.

## Intrinsic table text measurement

Zig measures intrinsic column requirements from the typed document through the font-metric callback.
Styled fragments stay in one word until whitespace, explicit newlines reset line widths, and small text truncates the rounded base size.
The real document path uses this shared implementation; hand-built native font fixtures retain their reference adapter during the UI transition.

All 188 core tests pass in each mode, alongside specification/native checks and 44 GUI profiles.
New tests cover styled words, newlines, small-text rounding, many columns, malformed tables, invalid metrics, and allocation failures.
The optimized executable is 5,752,736 bytes, 2,752 bytes larger than the preceding build.
All twelve complete captures are pixel-identical.

## Markdown block geometry

The real document path uses Zig for paragraph and code flow, labels, padding, alerts, table cells and borders, task decorations, heading rules, image fitting, and selection positions.
The font callback supplies measurements and the backend supplies cached column widths.
Run text borrows document storage; generated error labels belong to the returned layout object.
The current painter translates the result and retains its reference path for hand-built regression fixtures during the backend transition.

Tests cover each block kind, labels and semantic roles, aligned cells, images, positions, measurement without text runs, and allocation failures with large span lists.
All 198 core tests pass in the three modes, plus parser/native checks and 44 GUI profiles.
The optimized executable is 5,779,456 bytes, 26,720 bytes larger while both the shared layout and fixture reference path remain available.
The real-font regression also verifies that column measurement cannot leave a stale font selected for split header glyphs.
All twelve complete captures are pixel-identical after restoring the font at that callback boundary.

## Shared backend interface

The core interface is declared once in `frontend/core-api.h` for both C++ and Zig callers.
The C++ wrapper keeps its existing initialization behavior, while the header also compiles as C.
Tests compare size, alignment, and named-field offsets for nineteen records against the actual Zig definitions.
This interface lets the native drawing backend consume the shared layout without maintaining separate declarations.

All 199 core tests pass in each mode, plus specification/native checks and 44 GUI profiles.
The optimized executable remains 5,779,456 bytes.
All twelve reader captures match; one full-window capture has the known three-pixel scrollbar variation.

## Native painting evaluator

The separate build-native-renderer target paints the shared core layout with z2d into native ARGB storage.
It uses the bundled font bytes and Zignal PNG encoder and links only libc.
The regular application remains byte-identical to the preceding verified build.
Native ARGB layout, clipping, proportional metrics, lazy font faces, and text colors have dedicated tests in make tests.

The small sample's opening, lists, task boxes, links, table, and borders were inspected beside the current reader.
Unhinted outlines and kerning produce small differences in glyph widths and wrapping; no missing text or broken cells were found in these views.
The evaluator does not yet provide window/input integration or deferred system fonts and assets.
Its smaller executable therefore is not a final MDF size comparison.

Twelve fresh warm processes with unchanged CPU conditions measured entry through pixels at 18.20 ± 2.24 ms.
Layout and painting took 14.25 ± 1.97 ms.
These approximate 95% margins describe component timings, excluding executable loading, Wayland presentation, and PNG encoding.
The images and raw conditions are retained in build/native-renderer/comparison.html.

## Native Wayland presentation evaluator

The separate build-native-window target connects the z2d reader directly to Wayland shared memory and xdg-shell.
Document parsing runs while the Wayland connection and initial configuration proceed.
The evaluator records configure, commit, flush, and frame-callback times separately; captures occur after those measured boundaries.
Its worker wakeup uses eventfd, and shutdown joins core workers before closing their notification descriptor.

Integration tests run all three basic samples in isolated Weston, check ordered presentation milestones, verify PNG captures, reject unavailable Wayland sessions, and inspect linked libraries.
The library closure contains Wayland/libffi/libc and no FLTK, Cairo, Pango, or C++ runtime.
The generated protocol interfaces are bindings, not a replacement for libwayland's C implementation.
This remains an initial-window evaluator without the full interactive controls or deferred-resource pipeline.
The production executable remains byte-identical to the working reference.

## Native persistent frames

The evaluation window retains its canvas, reader, layout cache, and scroll state across frames.
Two shared-memory buffers prevent overwriting the compositor's current image; each becomes reusable only after its release event.
Frame callbacks limit redraw scheduling.
The interactive evaluation mode connects Wayland pointer-wheel events to the Zig viewport.

The isolated integration test submits six successive scroll frames and checks the final offset and changed pixels.
This caught the single-buffer design's inability to repaint while the compositor retained its current surface.
The corrected test, three-sample presentation checks, and full unit/native suite pass.
The production backend remains unchanged.

## Native reader interaction

The native reader owns selection endpoints, drag state, hit testing, anchor jumps, and open/closed details flags.
Pointer motion and buttons drive that state, while selected text is sliced from the immutable core projection.
Selection backgrounds use the same run metrics as glyph placement.
Following an anchor opens its parent details sections and refreshes geometry.

Integration checks paint a drag selection over two frames and toggle a real details section over three frames.
They verify changed pixels, selected bytes, restored open state, and unchanged worker-owned document flags.
Scrolling, the three initial samples, the full unit/native suite, and the production binary identity check also pass.

## Native keyboard input

The Wayland evaluator uses the existing Zig keyboard worker to compile compositor keymaps asynchronously.
Modifier/key events queue until the matching state is ready, and replacement keymaps preserve Compose ownership.
Navigation keys, select-all, quit, and font-size shortcuts update the native reader.
XKB remains the platform library; unused graphics code is discarded from the worker archive.

The isolated input-seat test receives a real Wayland keymap and checks select-all, font enlargement, and page navigation through queued key/modifier handling.
Existing keyboard, selection, details, scrolling, and full unit/native checks pass.
The evaluator library closure adds XKB while remaining free of FLTK, Cairo, Pango, and C++ runtime dependencies.
The production backend remains unchanged.

## Native word measurements

Native painting caches widths by font face, size, and text with a shared limit of 2,048 words.
Tokens longer than 128 bytes remain uncached.
Cached metrics retain their exact measured widths and use the font's existing vertical metrics.
This bounds memory while supporting repeated layout and offscreen width scans.

Tests verify reuse, the fixed bound, long-token behavior, and allocator cleanup.
The cached evaluator is pixel-identical to the uncached small-sample output.
Native interaction checks and the full unit/native suite pass.

## Native shell controls

The experimental Wayland viewer now draws a toolbar, contents panel, scrollbars, status bar, and minimap in Zig.
Toolbar actions change font size, width, theme, wrapping, and panel visibility.
The horizontal scrollbar occupies only document space, and no-wrap mode uses the selected blue button state.
Selected buttons keep the same blue in both light and dark modes.

The contents panel follows heading anchors, while the minimap and vertical scrollbar scrub document position.
The minimap covers the complete document and keeps its selector at ten percent of the track.
Its current overview uses block markers; the existing frontend's miniature text atlas is not yet replaced.
Panel changes preserve selection, scroll position, and independently owned details flags.

Unit checks cover pane bounds and toolbar actions.
Isolated Wayland checks exercise eight successive toolbar frames, horizontal panning, and initial panel geometry.
This remains an experimental backend: system fonts and desktop integration still need work.
The normal executable continues to use the existing frontend.

## Native window resizing

The native backend applies compositor resize requests after the first frame.
Maximize and fullscreen transitions retain the previous normal size for compositors that leave restoration to the client.
New pixel surfaces replace the old surfaces only after allocation succeeds.
Loaded fonts, word measurements, selection, and details state remain owned by the existing reader.
Layout invalidation retains the reading anchor.

Shared-memory buffers remain untouched while the compositor owns them.
Released buffers are recreated when their dimensions change, including changes with the same pixel count.
The integration test maximizes an 800 × 600 window, restores it, and checks that selection survives all three frames.
The normal regression suite and native canvas checks pass.

## Native clipboard

Copy selection uses Wayland data devices and offers UTF-8 plain text.
Each clipboard source owns a copy of its text, independent of document replacement or selection changes.
Transfers use bounded background writers with nonblocking pipes.
Closed consumers cannot terminate the app with SIGPIPE, and shutdown cancels blocked writers.

Pipe tests cover copied-byte ownership, full transfers, blocked readers, and closed readers.
Isolated Wayland tests copy both the small sample and a multilingual document through real clipboard offers.
The test drains the previous application's selection before testing the new copy.
This synchronization runs only in the integration test, after the first frame.
The full regression suite and native window checks pass.

### Incoming clipboard and file drops

Ctrl+V pastes a UTF-8 path into the native Open dialog through Wayland data offers.
File drops accept `text/uri-list` and negotiate the COPY action.
The viewer opens the first local file and decodes its escaped path without a shell.
Remote file authorities and invalid paths produce a status message.

The event loop reads transfer pipes without blocking.
Each transfer has a 1 MiB limit and a five-second deadline.
Cancellation, errors, and shutdown close the owned descriptor and release partial data.
The destination sends `finish` only after the transfer and a negotiated COPY action.

Pipe tests cover ownership, cancellation, size limits, and timeouts.
URI tests cover local and remote authorities, comments, multiple files, escaped UTF-8, and invalid control characters.
An isolated compositor checks paste and a real drag source, offer negotiation, file opening, and the completion handshake.
These checks include filenames with spaces, accents, and punctuation.

## Historical native launcher handoff

During the native evaluation, `make build` published the Zig viewer at `build/bin/mdf`.
The production default has since returned to FLTK; this stage records the retained experiment.
`make native` also creates the standalone development probe and `build/native-window/bin/mdf-native`.
It uses the existing libc-only launcher and the same private frontend ABI.
The Zig UI engine occupies the uncompressed `.mdf_ui` section.
Mermaid and SVG now use separate compressed, on-demand sections in the same executable.
The optional system text module keeps its separate compressed section.

The launcher starts document workers and prepares bundled fonts while the native UI loads.
The UI borrows that core and consumes the launcher's document packet once.
It does not start another parse or create another core.
Documents that finish after the UI loads use the same polling path.
Native workers stop before the UI returns; the launcher retains ownership of the core.

The engine exports only `mdf_frontend_api`.
Its dependency graph contains no FLTK, Cairo, C++ runtime, or eager system text stack.
Native eager workers compile only keyboard and image preparation, with no Cairo or font-discovery bindings.
The optional text module uses an FT2-only binding set in both Debug and Release.
Private modules and the launcher use LLVM/LLD so export restrictions and build IDs behave consistently across build modes.
The packer retains matching host and UI symbol files beside the build artifact.
It strips the runtime copies before embedding the UI, without changing allocated code or data bytes.
The executable runs without these symbol files; the profiler uses them only for retained-size attribution.
Matching build IDs prevent attribution from unrelated builds.
Native reports record the compiler version from the built engine.
`make reference` retains the FLTK frontend for comparison and compatibility tests; it is not the shipping build.
Native startup and scrolling reports use the shared profiler format.

`make test-native-launcher` checks the private ABI, imports, CLI, damaged engines, and deterministic packing.
It also checks matching symbols, unchanged allocated bytes, and the absence of debug sections in both runtime ELF images.
In Debug, the window test runs a small/full-sample smoke check with keyboard, deferred fonts, diagrams, and captures.
The window suite checks one file read and one document acceptance per launch.
It also checks the initial viewport gate, deferred resources, capture anchors, and reader-only captures.

### Native startup profiling

The native engine records drawing, layout, bundled font preparation, keyboard work, images, fonts, and minimap rasterization in the same optimized launch.
Its report retains the launcher's original timestamp and existing worker recorder.
The external profiler adds process creation and pre-main time with the same clock.
It does not copy durations from a separate instrumented run.

Each native `poll` interval records its result, errno, timeout, watched descriptors, and ready descriptors.
Compositor readiness and the shared worker notification descriptor have separate labels.
Worker request, completion, and adoption signals identify dependencies after a notification.
Wayland roundtrips retain an elapsed label that includes callbacks; they are not presented as pure OS waits.

The first viewport ends after the first Markdown socket flush.
Full readiness also waits for required deferred results, keyboard preparation, final drawing, and the compositor frame callback.
The first native window frame already contains Markdown; there is no separate empty scaffold.
Compositor scanout remains outside the measured boundary.

`mdf-native --profile FILE.md` emits the shared report JSON.
`scripts/profile.py --binary build/native-window/bin/mdf-native` uses the existing balanced, verified-cold workflow for all three samples.
The library inventory identifies z2d and includes optional system text dependencies observed across those documents.
It excludes removed FLTK libraries and their build archives from native reports.

Tests check real optimized captures and exact outer-node sums for both graph endpoints, including the external pre-load interval.
They also check that deferred font, image, and minimap workers do not enter the first-viewport path.

`mdf-native --profile-scroll FILE.md` measures 80 actual submitted frames across the document after full readiness.
Each sample includes native layout, rasterization, chrome, and the shared-memory surface commit request.
Socket flushing and waiting for the compositor frame callback are outside the per-frame drawing sample.
The viewer restores the original scroll position after the measurements.

The startup trace, usage, frame count, and font styles freeze before scrolling starts.
The requested PNG captures that ready viewport before scrolling.
Scrolling samples appear separately in `scroll_draw_ms`; they do not extend the startup critical path.
A document change interrupts the measurement.
GUI checks verify all 80 frames, the restored position, matching startup pixels, and exact startup graph totals.

## Native menus, preferences and document changes

The native menu model supports pointer selection and keyboard navigation.
Long font menus scroll within short windows and remain in bounds after a resize.
Theme presets retain their original colors and default font sizes.
Selected toolbar buttons keep the same blue for every preset and light/dark setting.

File opening uses a native path dialog with UTF-8 editing and Compose input.
The dialog lists folders and files, with Parent, Home, and hidden-file controls.
It supports mouse selection, double-click navigation, wheel scrolling, and keyboard selection.
Ctrl+L focuses the path; Ctrl+H toggles hidden files.
The path field supports a UTF-8 cursor, insertion, forward delete, and mouse selection.
Shift+Arrow extends the selection; Ctrl+A, Ctrl+C, Ctrl+X, and Ctrl+V use the selected text.
Home and End move within the path while that field has focus; they select file-list boundaries after Tab.
Directory scans and typed-path classification run on the directory worker.
Visible filenames request deferred glyph fallback, including when the viewer starts without a document.
Ordinary document startup performs no directory scan.
The directory component creates a worker only when a listing is requested.
It reads Linux directory records in Zig, sorts folders first, and limits each result to 10,000 entries.
Results own their filenames; cancellation and replacement join the worker before releasing them.
Tests cover hidden files, UTF-8 names, symlinks, special files, limits, failed requests, and repeated cancellation.
Native GUI checks navigate from an open document and an empty window, then open a filename with Chinese characters.
They also capture the dialog in light, dark, and small-window layouts.
Open and Reload use the existing asynchronous document loader.
Missing-file errors appear in the status bar without closing the viewer.
Automatic reload uses the existing file watcher and restores the reading anchor.
Preferences use the same Zig values, JSON format, and opt-in settings store as the normal frontend.

The new-document handoff can occur before its reader is created.
File commands therefore operate independently of reader ownership.
Integration checks wait for the corresponding document revision to be painted before issuing their next command.

Checks cover menu commands, opening and reloading a second file, external file edits, missing files, and saving/restoring preferences across two processes.
The tests use an isolated compositor and a temporary home directory.
Menu, dialog, and theme captures were inspected; the full regression suite passes.
The native backend remains experimental while deferred rendering and desktop integration are completed.

## Native optional renderer packaging

`make native OPTIMIZE=ReleaseFast` builds the experimental executable and its private Mermaid and SVG modules.
The native module interfaces are Zig code and use the existing private API table.
Each renderer still has an independent compressed, non-allocated ELF section.
Neither renderer loads until a document requests it.

The native modules export only `mdf_diagram_api` and retain the glibc 2.38 minimum.
The existing renderer test host passes with both native modules, including all 17 diagram families, malformed input, independent loading, damaged payloads, and optional-font checks.
These checks run in `make tests` alongside the existing frontend tests.
The packed native executable also passes the isolated window checks.

## Native images and diagrams

The native viewer uses the existing Zig worker to decode local PNG/JPEG images and render SVG/Mermaid diagrams.
Work starts only after that document's first viewport has been committed and flushed to Wayland.
Documents without image jobs start no image worker and keep their single initial frame.
SVG-only documents load no Mermaid module.

The asset owner copies encoded input before starting a worker.
Those copies survive document and navigation replacement until the worker joins.
Decoded pixels transfer to the GUI once, and worker shutdown precedes core destruction.
Completed images refresh the affected block layouts and retain the reading anchor.
Theme changes retain raster pixels while rendering diagrams again.

The native painter clips and scales grayscale, RGB, and alpha images.
Bilinear interpolation uses premultiplied colors before composition, preventing transparent-edge halos.
Unsupported Mermaid types keep their readable source and an explanation.

Unit checks cover alpha interpolation and clipping.
Isolated window checks cover the small sample, PNG/JPEG images, SVG-only loading, the sample diagram, and unsupported source.
The captures were inspected and the full regression suite passes.
Deferred system text and desktop integration remain before the native backend becomes the default.

## Remaining image formats

GIF and BMP decoding now use Zignal in both frontends.
The existing frontend no longer decodes those files on its GUI thread or links FLTK's image archive.
GIF transparency remains alpha data and follows the current background when the theme changes.

Thirty-seven independent pixel fixtures cover GIF palettes, transparency, interlacing, animated first-frame selection, and BMP formats through bitfields and RLE.
The fixtures were also checked against Pillow during development.
The routine suite uses only Python's standard library to generate them.
Codec checks include repeated ownership transfers, byte limits, oversized headers, truncated data, and 1,024 deterministic mutations.
The profile identifies all four decoders as Zignal.

## Deferred FreeType text module

Native builds include a separate compressed `.mdf_text` section and private `mdf_text_api` table.
The checked memory-only loader validates this table independently of the two diagram modules.
The executable retains no eager Pango, Fontconfig, FreeType, or HarfBuzz dependency.
The helper uses system PangoFT2 for shaping and bitmap generation without linking Cairo.
Font discovery, requested bundled faces, ownership, worker scheduling, and transfer remain Zig code.

The helper receives the host's immutable font provider and profiler callbacks.
It creates no second core, recorder, or font cache and installs no global Fontconfig configuration.
Font discovery and text-map creation finish on the same worker before readiness is published.
Retained font resources can outlive their text maps until an image worker releases the backing descriptors.

The packed-executable probe checks fixed-width code metrics, multilingual glyph coverage, clipped bitmap output, cancellation, and retained descriptor release.
It runs from an otherwise empty directory and checks independent loading, private exports, the glibc minimum, and damaged modules.
The full regression suite and both GUI backends' integration checks pass.
The native document viewer requests this helper only when monospace text or missing glyphs require it.

The first document flush uses bundled Open Sans. Conditional workers then prepare monospace and Sans maps in parallel.
Documents without code blocks or missing glyphs start neither worker and leave the text module compressed.
Inline code alone does not request a monospace map.
Coverage comes from the bundled font's Unicode cmap and includes filenames and dialog text.
Adopting a map invalidates measurements and visible layouts while retaining the reader's scroll anchor and selection.

Diagram workers retain a snapshot of the fallback font files until they join.
Existing raster images survive diagram refreshes when a new font map arrives.
The generated zig-svg adapter supplies decoded text to the font resolver.
This lets SVG and Mermaid labels use prepared fallback faces while Latin labels keep Open Sans.
The adapter and update procedure are documented in `frontend/patches/zig-svg/README.md`.
Fallback selects a whole SVG text run; mixed runs that need several faces and complex-script shaping remain SVG limitations.
The SVG worker reports missing characters from actual decoded label runs, including XML entities and nested spans.
Native SVG-only documents can therefore request fallback fonts after their first image pass.
Metadata and unused source text do not trigger font discovery.
Repeated reports reuse existing requests and do not restart completed font work.

Native GUI tests compare first and completed frames for code, multilingual text, and diagrams.
They verify fixed-width code metrics, deferred scheduling, optional-module failure recovery, and actual changed diagram pixels.

## Native window controls and cursors

The native backend draws its own window buttons and filename in the existing menu band.
This keeps the document, TOC, minimap, and scrollbar bounds unchanged.
The interactive minimum width keeps the menu and window controls from overlapping.
Window commands use xdg-shell for minimize, maximize, restore, move, and resize.
Move and resize requests carry the current pointer-button serial.
Dragging uses the unused title area; a double click toggles maximization.
Resize edges are disabled while the compositor constrains the window.
Both the close button and the compositor's close event save the canonical settings.

Cursor masks are small Zig-generated ARGB buffers with transparent backgrounds and contrasting outlines.
The client creates each immutable shared-memory buffer only when its cursor is needed.
There is no cursor-theme lookup or cursor-library load.
Cursor creation starts on pointer entry after the document surface is mapped.

Unit tests cover control regions, protocol resize values, cursor masks, and hotspots.
The isolated compositor test checks actual pointer entry and cursor commits.
It maximizes, restores the original size, and closes while preserving selection.
The native backend remains experimental while scale handling and other desktop features are completed.
First-viewport captures stop after one frame, even when a redraw is queued during its callback.
The separate ready-mode captures wait for deferred resources and their final frame.

## Logical layout and device pixels

Navigation previews also expose checked, borrowed text views through the private core API.
The native minimap can copy sampled lines directly, without serializing and reparsing the full preview as JSON.
Navigation state and invalid indexes have explicit results; Unicode remains unchanged.

The native canvas stores logical width and height separately from its pixel surface.
Painting scales text, vectors, images, overlays, and shared canvas copies.
Layout, hit testing, scroll positions, and control geometry continue to use logical coordinates.
Scale changes clear measured words while retaining loaded bundled faces.
Invalid dimensions and scale values leave the previous surface usable.
Surface allocations have a fixed pixel budget.

Fractional buffer dimensions respect Wayland's 120 scale subdivisions.
This avoids an extra pixel when a floating-point approximation lies just above an integer boundary.
Unit tests cover fractional dimensions, 2x glyph bounds, compositing, clipping, and retained layout metrics.
Ten 1x screenshots remain byte-for-byte identical, including deferred system text and diagrams.
The window negotiates integer and fractional scale preferences through optional Wayland protocols.
It uses per-surface preferences or entered-output scale when fractional scaling is unavailable.
Fractional buffers use viewporter destinations in logical units; integer buffers use buffer scaling.
Output entry, removal, and scale changes update the next frame without another startup roundtrip.
Buffers use physical strides and damage coordinates. Cursor hotspots remain logical.
Captures report both logical and pixel dimensions, and the scale of the captured frame.

Ready-mode completion runs after pending events and deferred results have been processed.
It waits for the requested scale to be painted, including a preference change after the first buffer.
The isolated HiDPI suite covers 2x, 1.25x, and a live change from 1.25x to 1.5x.
Its test-only compositor extension sends real fractional-scale protocol events.
Cases cover system text, raster and diagram assets, selection, window restoration, and cursor sizing.
Run these checks with `make test-native-window`.

## Deferred native minimap text

The native overview now uses a tiny-text atlas instead of permanent block markers.
It requests wrapped preview text after the first document flush and after image inputs have been copied.
The navigation worker retains encoded image data when preview width changes.
Only sampled UTF-8 lines cross into the raster job; the job owns these copies.
Document replacement, hidden panes, and changed render parameters cancel pending raster work.

Sampling is bounded by twice the minimap height and a physical surface limit.
Atlas size follows the pane size instead of document length.
The GUI places cached text using the current block geometry and omits hidden blocks.
Scrolling and selector dragging reuse the existing text pixels.
The selector and adjacent scrollbar retain the same fixed ten-percent track height.
Theme and scale changes prepare a replacement atlas after the first viewport.
The initial frame retains the lightweight markers until text is ready.
Hidden previews create no raster job and perform no preview reflow.
When the body needs fallback glyphs, the atlas worker retains those prepared font files.
Text API version 2 creates an independent FT2 map from that snapshot without another font search.
The GUI and atlas worker keep separate shaping contexts.
The worker releases its map after rasterization; the atlas retains only its own text and pixels.
Adopting a newer Sans map prepares a replacement atlas.
Latin-only samples continue to skip the optional text module.

Tests cover all three samples, bounded sampling, Unicode copying, clipping, fixed selector size,
dragging without regeneration, hidden panes, and fractional scale changes.
Font-map tests also destroy the original maps and verify that the clone still measures and draws before releasing the final file descriptors.

## Native document links

Native clicks use the existing Zig link resolver.
Local Markdown and text destinations open in the same window.
Encoded heading fragments are applied after the destination document has been accepted.
In-document fragments use the same decoded anchor handling.
Web and mail links use `posix_spawnp` with a literal argument vector for `xdg-open`.
The viewer reaps completed helpers without blocking the GUI and leaves opened applications running when it closes.

Tests cover missing and failed handlers, child cleanup, encoded filenames and heading fragments.
The isolated GUI test uses a fake helper and confirms that quotes, semicolons, and shell-like URL text remain one literal argument.

## Layout and worker timing checkpoint

A comparison against the parser-stage binary completed 144 balanced launches: twelve pairs per sample in each cache mode.
Both executables use ReleaseFast, one pathname, isolated Weston, and unchanged CPU affinity, governor, and power limits.
Cold runs flush caches and verify zero resident executable, document, and asset pages.

| Sample | Cold paired change, ms | Warm paired change, ms |
|---|---:|---:|
| SMALL | +0.49 ± 9.78 | +1.06 ± 6.34 |
| SAMPLE | +0.30 ± 11.33 | +3.55 ± 5.32 |
| HUGE | +5.69 ± 15.44 | −2.30 ± 3.01 |

Changes are after minus before with approximate paired Student-t 95% margins.
Every interval includes zero, so this checkpoint establishes no clear first-viewport speed change.
The worker migration is retained for ownership and reuse by the later Zig drawing backend.
Full runs, native call graphs, individual averages, and runtime conditions are retained under `build/zig-migration-20261022T031026Z/workers-comparison.html`.

## System-text maps

Zig owns private Pango maps, descriptions, layouts, style changes, fallback references, metric caches, and document-glyph scanning.
Prepared font sets use reference counting so maps retain their anonymous backing files independently of worker replacement.
The frontend adapter supplies the existing Cairo drawing context for this compatibility stage.
Pango, Fontconfig, and Cairo remain their existing implementations; moving the owning code does not replace those libraries.

Native tests cover all code styles, mixed-script fallback, Latin preservation, replaced font sets, malformed UTF-8, and variation selectors.
The complete optimized suite and 44 GUI profiles pass.
The optimized executable is 5,747,088 bytes, 28,640 bytes larger than the preceding build.
All twelve complete reader captures are pixel-identical.

## Bundled-font resources

Zig owns the private bundled-font configuration, anonymous font files, Latin coverage, loaded-style mask, and retained fallback resources.
The backend adapter keeps FLTK font-slot registration and publishes the private configuration before opening the display.
Required italic faces still load independently and only when requested.
Zig's nested resource spans retain the caller's profiling depth.

The full optimized suite and 44 GUI profiles pass, including the injected font-memory allocation failure and its existing diagnostic.
The optimized executable remains 5,747,088 bytes.
All twelve reader captures are pixel-identical.

## Rendered text and positions

The document worker builds the immutable plain-text projection, block byte offsets, required italic styles, and code/diagram requirements.
Two passes calculate exact storage and fill it once, including list prefixes, table tabs, explicit code newlines, and block separators.
The projection belongs to the document arena and crosses the GUI boundary as borrowed typed views until the next document replacement.
The GUI borrows the text buffer instead of concatenating another copy during document acceptance.

New tests check UTF-8 byte positions, tables with empty cells, every block kind, required styles, empty documents, and allocation failures.
All 175 core tests pass in Debug, ReleaseSafe, and ReleaseFast, plus 766 parser cases, native suites, and 44 GUI profiles.
The optimized executable is 5,751,216 bytes, 4,128 bytes larger than the preceding build.
All twelve reader captures match; two full-window captures have the known three-pixel scrollbar variation.

## Viewport geometry and scroll state

Zig owns block-height and offset arrays, indexing, width and margin state, scroll positions, horizontal extents, and geometry revisions.
The current painter borrows the arrays and references scalar state through a small C boundary.
Resize preserves existing geometry if allocation fails, and indexing retains scroll-anchor behavior while a document is replaced.
Block-height estimates also use the shared Zig implementation.

Tests cover empty documents, collapsed blocks, exact boundaries, document replacement, borrowed-array updates, width modes, scroll limits, estimates, and allocation failure.
All 183 core tests pass in the three modes, plus the parser/native suites and 44 GUI profiles.
The optimized executable is 5,749,984 bytes, 1,232 bytes smaller than the preceding build.
All twelve complete captures are pixel-identical.
