# Markdown FAST implementation

Markdown FAST is a read-only Markdown viewer for Linux x86_64 with Wayland.
The current version is 0.2.0.

## GUI and document processing

- FLTK 1.4.5 provides native menus, buttons, window controls, TOC, minimap, and scrollbars over Wayland shared memory.
- The production C++ frontend draws through Cairo and Pango. It uses neither X11 nor OpenGL.
- Deferred workers prepare system Sans fallback and monospace fonts after the first viewport.
- Zig 0.17.0 owns Markdown parsing, loading, settings, file watching, navigation, and the embedded Open Sans resources.
- Zigmark parses CommonMark/GFM; Zig converts its AST into MDF blocks and spans.
- The private FLTK frontend borrows the launcher's Zig document core through a checked C ABI. Worker inputs remain valid until their workers stop.
- Typed block and span views keep bulk document data out of JSON. Repeated headings reuse their last anchor suffix to keep parsing linear.
- Zig's `std.json` handles messages, settings, and profiler JSON.
- The FLTK document widget measures visible blocks with Pango and retains text runs and bounded word measurements.
- Width changes retain word measurements. Font and display-scale changes clear those measurements. Painting resolves colors from the current palette.
- Words span adjacent styles and links. Pango supplies grapheme boundaries for long-token wrapping and pointer selection through the private layout interface.
- TOC jumps retain layout through open ancestors. Details changes invalidate their subtree and preserve the reader's scroll anchor.
- The minimap caches a small image surface and moves its viewport marker during scrolling.

The toolbar contains TOC, light/dark, and one width button that cycles between 80% and 100%.
The −, reset, and + buttons decrease, reset, and increase the font size. Reset uses the current theme's default size.
The Preview toggle sits on the right. Its visibility is included in saved settings.
Size controls remain in the Font menu. The initial width is 80%.
Classic, Paper, and Terminal use Open Sans at sizes 12, 14, and 11.
Theme selection preserves light/dark mode. The toolbar button switches that mode.
Native FLTK drawings provide the TOC, reset, sun/moon, and disclosure icons.
Generated footnote return links use readable “Back” text.
The reader supports GFM tables, tasks, alerts, nested details, images, links, text selection, and copying.
TOC links reveal collapsed ancestors. The minimap supports clicking, dragging, and wheel scrolling.

## Startup sequence

1. Start reading and parsing the requested file on the document worker.
2. Prepare the private Fontconfig configuration and four anonymous Open Sans memory files.
3. Publish the configuration before Pango font maps and FLTK font names. Then finalize the scaffold geometry.
4. Accept ready Markdown before showing the window and start navigation preparation immediately.
5. Measure and draw the visible Markdown blocks with the bundled Latin fonts in the first useful frame.
6. Decode local PNG/JPEG images with Zig/Zignal and render Mermaid diagrams on the image worker while the GUI processes window events.
7. Apply TOC labels, minimap lines, image pixels, and diagram pixels. Already prepared results can share the first window frame.
8. After the first frame, prepare system Sans fallback only for missing document glyphs and system monospace only for code blocks, using separate workers. Reflow affected text when ready.

The compositor controls window placement. Saved normal size and maximized state use the existing settings schema.
Settings remain opt-in at `~/.config/mdf/settings.json`.
The viewer ignores legacy `font_family` values and preserves the other saved preferences.
The viewer ships as one executable with its fonts and bundled code embedded.
The private Fontconfig configuration contains Latin subsets of Open Sans regular, bold, italic, and bold italic.
Code starts in Open Sans. Code blocks trigger a deferred system monospace worker; inline code uses the result when available but does not trigger discovery.
Missing document glyphs trigger a separate system Sans worker. It loads the required families and leaves Latin text in Open Sans.
Native headings, the TOC, minimap and code receive the same selected fallback faces. Characters without an installed font remain explicit missing glyphs.
Remaining layout defect: Arabic and Hebrew words are still positioned in left-to-right source order. Paragraph-level bidirectional layout must also preserve wrapping, selection, and hit testing.
Mermaid fences render through pinned Pozeiden and zig-svg/z2d libraries, all written in Zig, using embedded Open Sans.
SVG labels lack automatic glyph fallback and complex-script shaping. Explicit RTL or vertical SVG text and some system font formats produce readable errors.
Rendering failures keep readable source and an error. Advanced Mermaid syntax can differ from the official renderer. Tables share measured word-based column widths across rows.
The first Markdown frame reads no system fonts, Fontconfig files, or font caches. Deferred font discovery reads those resources on its workers, without extracting fonts or writing persistent caches.

## Build and delivery

| Command | Behavior |
| --- | --- |
| `make setup` | Install missing Fedora 44 or Ubuntu 26.04 tools and fetch checksum-pinned sources. |
| `make build` | Build the Zig core and FLTK frontend in Debug mode, offline. |
| `make release` | Build optimized runtime files, RPM/DEB packages, checksums, and build metadata. |
| `make install` | Copy the built executable into the user's bin folder without sudo. Remove the retired companion library on upgrade. |
| `make uninstall` | Remove the user-local executable, any retired companion, and the application configuration folder. |
| `make run-sample` | Rebuild and open `SAMPLE.md`; this is also the default Make target. |
| `make test` | Run workflow, installation, report, and Zig core tests. |
| `make test-gui` | Run native GUI checks in a private headless Weston compositor. |
| `make profile` | Run five cold launches per sample and create one timestamped HTML report with document tabs. |
| `make clean` | Remove all build output, temporary files, profiles, and compiler caches. |

All generated files stay under `build/`. Downloaded sources stay in ignored `zig-pkg/` and survive `make clean`.
FLTK, the frontend, and the Zig core have separate Debug and ReleaseFast build directories.
Release mode uses Zig ReleaseFast, GCC `-O3`, full LTO within each compiler toolchain, baseline x86_64 instructions, and dead-section removal.
C++ exception unwinding remains enabled. System Cairo/Pango libraries use distribution build options.
Source installation copies `mdf` into the selected bin folder. RPM and DEB packages install it directly at `/usr/bin/mdf`.

## Validation and performance

Core checks cover parsing, allocation failures, layout estimates, settings, links, file watching, and worker ownership.
GUI checks cover sample rendering, startup ordering, width and theme controls, selection, details, images, fonts, resizing, and minimap navigation.
They also run the executable alone from another working directory and reject non-Wayland backends.
GUI tests reject system font access before the first viewport and allow later font reads only on the Sans and monospace workers. They reject font-cache writes and companion-library loads.
Pango checks verify all four real embedded styles and their proportional metrics.
The private compositor provides a virtual input seat; tests do not control the user's desktop input.
Native title-bar gestures and perceived scrolling quality still benefit from a desktop check.

Each startup report is one offline HTML file with library versions, file sizes, build identity, and launch measurements.
Document tabs switch between separate `SAMPLE.md` and `SAMPLE-HUGE.md` results. The shared binary size inventory is stored once.
Both fixtures contain only characters covered by the bundled Latin faces, including their code blocks. `SAMPLE-EXTENDED.md` owns the unsupported-script and symbol workload and is used by the fallback and rendering checks.
The flame chart groups calls and subcalls by thread, uses a shared time axis, and highlights parallel groups.
Call and group selection supports zooming. Unused worker tracks stay hidden.
Ctrl + wheel zooms around the pointer up to 256×. A large horizontal scrollbar supports panning.
GUI event waits are timed at the actual `select` and `poll` calls, separately from callback work.
Each lane accounts for its full interval with work, waits, idle states, and explicitly untraced time.
The vertical dependency graph expands startup stages into nested calls and uses one color per thread.
Its independent zoom controls offer fit width, native 100% size, +/−, and a 5–800% slider. Ctrl + wheel preserves the point under the cursor. Click-and-drag pans from the background or call blocks; a simple click inspects the call. Both scrollbars also pan the graph.
Measured waits, synchronous Wayland wait/callback intervals, and untraced gaps have explicit blocks with durations.
The red path defaults to first viewport; the endpoint selector also supports full readiness.
Outer red block durations sum exactly to the selected launch's endpoint. Nested durations already belong to their parent.
Blocks show start time since t0 and elapsed milliseconds. Parallel work enters the red sum only with evidence that it blocked adoption.
Readiness signals connect document requests, worker completion, and GUI acceptance in a separate dependency graph.
The graph identifies the last prerequisite for Markdown acceptance and separates worker time from GUI pickup time.
It shows readiness dependencies rather than OS lock contention.
Before each measured launch, profiling fsyncs its executable, document and local images, drops Linux reclaimable caches, and creates an empty application cache.
The profiler checks input page residency with `PROT_NONE` mappings and `mincore`, and rejects a launch if executable/document/image pages remain cached.
The running desktop, active shared libraries, storage-controller caches, and compositor state are not reset.
The report clock starts in the parent before process creation and ends after FLTK flushes the document frame.
Matching monotonic timestamps identify the pre-main interval; application spans retain their original durations on that shared axis.
The launch interval includes executable loading, dynamic linking, static initialization, and scheduling. Demand paging after `main` remains inside application elapsed time.
The pre-main interval is named Pre-load and remains in startup totals; it is not presented as isolated disk-I/O time.
Exact terminal input and compositor scanout require terminal/shell hooks and Wayland presentation feedback; neither is inferred from frame submission.
Profiler finish and process exit are measured separately from startup readiness.
Separate spans record configuration creation, font data, each face, Pango adoption, FLTK registration, and Wayland initialization.
The selected implementation prepares fonts synchronously. The GUI thread adopts Pango and registers FLTK names.

The reviewed FLTK startup series lives in `frontend/patches/fltk/` with exact source checksums and upgrade instructions.
Keyboard preparation uses a separate input track. Pending input retains its order across preparation and keymap changes.
Cursor loading stays on the GUI after the first viewport. Full readiness includes deferred input resources.
The first valid configure clears the expose gate while a separate flag preserves second-configure workarounds.
Buffer preparation can run while the compositor configures the window. The benchmark selection determines the production policy.
First content-buffer commit has a separate timestamp; moving a reporting callback alone is not a speedup.

The 2026-10-20 cold comparison retained asynchronous keyboard preparation and deferred cursor loading.
It used two batches of ten pairs per document, with identical release flags and a fixed runtime path.
The table shows launch-to-viewport means. Margins are approximate paired 95% confidence intervals for the savings.

| Document | Synchronous input mean (ms) | Deferred input mean (ms) | Saving ± margin (ms) |
| --- | ---: | ---: | ---: |
| SAMPLE.md | 180.57 | 127.20 | 53.37 ± 8.87 |
| SAMPLE-HUGE.md | 197.72 | 140.86 | 56.87 ± 20.96 |

Both documents passed scaffold, viewport median/p95, and full-readiness guards.
Image decoding starts before deferred cursor loading to avoid delaying decoder kickoff.
An independent 80-launch comparison rejected early buffer/layout preparation; it remains disabled by default.
The rejected runs and timestamped reports remain under `build/startup-20261020T121240Z/`.
All five rendering cases matched the reference pixels, including actual early-buffer preparation with a delayed test compositor.
The production binary matches the accepted benchmark executable byte for byte.

Before external launch timing was added on 2026-10-18, each candidate ran two batches of five cold launches with identical optimized build settings and a fixed sample.
The historical comparison below uses time from `main`, excluding pre-main launch costs.
The sample copy, binary hashes, source snapshots, and timestamped standalone reports remain under `build/profile/`.

| Candidate | Batch | Scaffold median (ms) | First viewport median (ms) | First viewport p95 (ms) |
| --- | --- | ---: | ---: | ---: |
| Existing baseline | 1 | 175.81 | 223.57 | 236.97 |
| Existing baseline | 2 | 175.95 | 223.35 | 254.18 |
| Private synchronous | 1 | 117.72 | 164.39 | 169.07 |
| Private synchronous | 2 | 120.20 | 168.19 | 173.02 |
| Private worker | 1 | 119.15 | 160.15 | 219.17 |
| Private worker | 2 | 113.26 | 163.67 | 180.10 |

The worker improved viewport medians, but worsened viewport p95 in both batches and the scaffold median in batch 1.
The synchronous implementation passed the selection rule and remains the production path.
The trial recorded font preparation on the font-worker track. It joined the worker before adoption or release of its resources.
The previous font phase included Wayland initialization. Separate baseline medians were 39.98/37.58 ms for system Fontconfig and 66.92/70.49 ms for Wayland.
Private font preparation took 1.89/2.06 ms. Wayland remained separate at 70.77/70.24 ms.

`mdf --profile-scroll SAMPLE.md` separately records native draw times for 80 scroll positions.
Every sample must paint the reader widget. This measures synchronous layout and drawing, excluding compositor latency.
The original `scroll_draw_ms` and `scroll_frames` fields retain this series.
The additive `interaction_profile` field contains repeated scroll, resize, and TOC series.
Each series records handler and flush times, word-cache hits and misses, layout builds, and minimap builds.
These timings start at programmatic handler calls and end after synchronous FLTK flush. They exclude event arrival and compositor scanout.
`scripts/benchmark-interactions.py` compares alternating baseline and candidate launches on the same Wayland compositor, with two warmups per document.
Its report includes executable hashes, raw samples, and guards for startup, scroll p95, resize, and TOC timings.
For startup tails, `--startup-runs 60` adds a separate paired `--benchmark` series.
The report also preserves startup samples from the interaction launches.
Use `scripts/benchmark.py` for warm launches of generated document sizes.
Do not use startup measurements alone to judge interaction speed or rendering quality.

The 2026-10-26 ReleaseFast comparison used 24 interaction pairs and 60 separate warm startup pairs per text fixture.
Each series included two warmups. Clients used CPU 2. The private headless Weston compositor used CPU 0.
Both builds used identical FLTK patches, Pango 1.57.1, and Cairo 1.18.6.
All fixtures passed the 5% startup median/p95 and scroll p95 guards.
The table records medians from handler entry through synchronous FLTK flush.

| Text fixture | Resize before/after (ms) | TOC before/after (ms) | Scroll p95 before/after (ms) |
| --- | ---: | ---: | ---: |
| Small | 6.030 / 5.695 | 1.419 / 0.821 | 1.554 / 1.524 |
| Mid-sized | 12.157 / 11.974 | 1.777 / 0.787 | 4.075 / 4.088 |
| Huge | 27.909 / 27.898 | 3.155 / 1.751 | 4.336 / 4.413 |

Huge-text resize remained effectively unchanged. Core tests passed in Debug, ReleaseSafe, and ReleaseFast (226 each).
The GUI suite and display-scale checks at 125% and 200% also passed.
The local evidence remains in `build/latin-reflow/acceptance.json`, including raw samples, executable hashes, library versions, cache counters, and every guard result.

The following milestone targets progressive image delivery and decoded-image memory.
The prior huge-image probe used approximately 266 MiB at readiness. Decoded results currently wait for the entire batch.

## Upstream sources

- [FLTK 1.4 documentation](https://www.fltk.org/doc-1.4/)
- [FLTK Wayland implementation](https://www.fltk.org/doc-1.4/wayland-devel.html)
- [Zigmark](https://github.com/sc2in/zigmark)
- [Zig](https://ziglang.org/)
