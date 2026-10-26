# Markdown FAST

A fast, minimal Markdown viewer for Linux with Wayland, including Fedora 44 and Ubuntu 26.04.
The default UI uses FLTK 1.4.5 with Cairo/Pango drawing and standard FLTK menus and controls.
Zigmark/Mecha parse Markdown, Zignal handles images, and Zig owns the document core, JSON, decompression, and diagram renderers.
FLTK and its C++ frontend are bundled into the single executable. Rust is not required.
The [migration guide](docs/zig-migration.md) records the implementation and regression checks.
The [text stack](docs/text-stack.md) and [Cairo](docs/cairo.md) guides describe the production FLTK frontend.
The experimental Zig/z2d UI remains available with `make native`; it is not used by normal builds, profiling, or release packages.
It requires a Wayland compositor. If Wayland is unavailable, the viewer exits with a clear error.
It opens local documents, reloads after saves, and ships as a single `mdf` executable.
Mermaid and local vector/text SVG rendering use separate compressed modules inside that executable.
Their ELF sections are not mapped at startup. A worker loads only the required module into anonymous memory after the first Markdown viewport.
SVG-only documents skip Mermaid. Mermaid uses the SVG module to render its generated vector output.
Ordinary PNG/JPEG images use a third, independent Zignal module and do not load either renderer.
Text-only documents load none of these modules. Explicit screenshot export loads the image codec only when saving the PNG.
Optional modules use independent zlib payloads by default, favoring small and mid-sized text-only documents.
They inflate only when needed, using Zig's existing decoder. Set `MDF_OPTIONAL_MODULE_COMPRESSION=raw` when building to compare uncompressed lazy payloads.
The [module guide](docs/compressed-diagrams.md) describes the ABI, build, limits, and regression checks.
The GUI includes window controls, light/dark mode, font controls, and optional auto-reload.
The first toolbar icon shows or hides the table of contents. The right minimap supports click-and-drag navigation.
The toolbar also has a light/dark toggle and one width button that cycles between 80% and 100%.
The Preview button on the right shows or hides the minimap.
The −, reset, and + buttons decrease the font size, reset it to the theme default, and increase it.
Font controls also appear in the Font menu.
Wrapping is on by default, with the toolbar button unselected. Selecting the button turns it blue and enables no-wrap mode.
With wrapping off, a horizontal scrollbar appears below the document, outside the TOC and minimap.
Use the scrollbar, Shift + wheel, a horizontal trackpad gesture, or the left/right arrow keys to pan the document.
Document text uses the normal arrow cursor and supports drag selection and Ctrl+C.
Links and diagram controls use a hand cursor.
Block quotations group their paragraphs and lists, with consistent spacing and indentation for nested content.
The UI and ordinary text use bundled Latin Open Sans. Missing document characters use system fonts prepared in the background.
Fenced code blocks trigger deferred monospace loading; inline code uses it too when available.
The Theme menu contains Classic (12), Paper (14), Terminal (11), Nord (13), Solarized (14), Gruvbox (12), and Catppuccin (13).
Theme selection preserves light/dark mode. The sun/moon toolbar button switches that mode.
The new styles range from cool blue Nord to cream-and-teal Solarized, warm retro Gruvbox, and lavender Catppuccin.
Reader surfaces, menus, controls, selections, highlights, and alerts follow the selected palette.
All themes reuse the bundled fonts and load no theme files at startup. See [theme notes and references](docs/themes.md).
The defaults are light mode, Open Sans, font size 12, and 80% text width.
Enable **Settings > Save settings across sessions** to keep your preferences in
`~/.config/mdf/settings.json`. This saves the theme, light/dark mode, font size, text width, line wrapping, sidebar visibility, and auto-reload.
It also saves the window size and maximized state. The viewer ignores legacy `font_family` values and preserves other preferences.
The Wayland compositor controls window placement.
**Settings > Reset settings** restores the defaults and turns saving off.

The executable embeds Latin subsets of Open Sans regular, bold, italic, and bold italic.
Each face is compressed separately. Regular and bold inflate in a startup worker while the UI libraries load.
Each italic face inflates once, only when its style is required.
Markdown emphasis uses its final font before measurement and the first render. SVG text requests its own resolved styles on demand.
The subsets preserve Latin accents, existing punctuation and symbols, kerning, and hinting.
The FLTK renderer uses the bundled fonts through private Fontconfig/Pango maps.
Deferred font workers register anonymous memory files in private Fontconfig/PangoFT2 maps.
Before the first Markdown frame, it reads no system fonts, Fontconfig files, or font caches.
After parsing, MDF checks the rendered text against the bundled font's character coverage.
If characters are missing, a worker selects system Sans fonts covering those characters and loads only the required families into anonymous memory.
A document with a code block also starts a separate worker to prepare the preferred system monospace family.
Both workers start after the first Markdown frame. Latin documents without code blocks start neither worker, including documents containing only inline code.
Existing font caches are read only. Missing caches trigger an uncached scan; the viewer creates no extracted font files or persistent font caches.
The GUI adopts private Pango maps and reflows affected text while preserving the scroll position.
Latin text retains Open Sans. Selected fallback faces also supply missing characters in headings, the TOC, minimap, and code.
System fonts remain optional. If no installed font covers a character, it keeps an explicit missing-glyph marker. If no monospace is available, code keeps Open Sans.
Reading and parsing overlap window initialization. Ready Markdown can appear in the first window frame, without a mandatory empty scaffold frame.
Startup uses a libc-only Zig launcher. Separate workers prepare the embedded UI engine and its system libraries while the core parses the document.
Image-file reads and heading preparation start before the UI handoff. Preview reflow retains those image bytes.
The UI engine is uncompressed and loads from anonymous memory. The distribution remains one executable.
During window configuration, the GUI prepares visible Markdown layout, then FLTK submits a Wayland shared-memory frame.
See [parallel startup](docs/parallel-bootstrap.md) for the ABI, ownership, profiling, and upgrade rules.
Navigation preparation starts when the document is adopted, before waiting for that frame.
A separate worker decodes PNG/JPEG pixels with Zig/Zignal while the GUI handles window events and draws navigation.
That worker also renders fenced `mermaid` diagrams through Pozeiden and zig-svg/z2d, all written in Zig.
Mermaid diagrams open at natural size to keep labels readable in narrow windows.
Use the diagram's minus/plus buttons to zoom, its percentage button to reset to 100%, and **Fit** for an overview.
Drag the diagram horizontally, or use the body scrollbar and arrow keys to pan. The zoom controls stay visible while panning.
After clicking a diagram, `+`/`-` zoom, `0` resets, and Escape returns focus to the document.
Each diagram keeps its own zoom. Zooming reuses decoded pixels and reflows only that block; it does not rerun Mermaid or SVG rendering.
Diagrams use embedded Open Sans and adapt to light/dark mode. SVG text has limited font fallback and no complex-script shaping.
Explicit RTL or vertical SVG text produces a readable error. Prepared system Sans fonts can supply missing SVG label characters. Arabic joining remains unsupported there.
Some system font collections are unsupported. These limits affect SVG and diagram labels; Markdown body text keeps its separate Pango font support.
The 17 supported families are flowchart, sequence, class, state, ER, pie, Gantt, Git graph, timeline,
XY chart, quadrant, mindmap, Sankey, C4, block, requirement, and Kanban.
Journey, packet, architecture, treemap, radar, and ZenUML show their source with an unsupported-type message.
If diagram rendering fails, MDF keeps its source text and shows the error. Advanced syntax can differ from official Mermaid.
Pozeiden estimates label widths. SVG rasterization uses the actual font data, so complex labels can need manual line breaks.
Embedded images, Markdown labels, and newer `@{shape: ...}` syntax are unsupported.
Diagram source is limited to 256 KiB, and generated SVG is limited to 16 MiB.
Pozeiden also limits graph layout to 10,000 nodes and 20,000 edges, flowcharts to 500 subgraphs, and mindmaps to 100 nesting levels.
Rendered canvases are limited to 16384 pixels per side and 64 MiB of RGBA pixels.
Tables measure word and line widths across all rows before allocating columns, keeping short labels and numbers intact where space permits.
The first Markdown frame precedes deferred image/diagram decoding and system-font discovery.
Sidebar spaces stay fixed during this work.

Keyboard resources prepare on a worker, with early input preserved until adoption.
FLTK uses compositor cursor shapes when supported and its cursor-theme fallback otherwise.
Window handling, drawing, and Wayland buffer submission stay on the GUI thread.
The [FLTK patch guide](frontend/patches/fltk/README.md) documents local backend changes and future upgrade checks.

## Install

For a Wayland desktop on Linux x86_64 with glibc 2.38 or later.
Packages declare the required Wayland, XKB, Pixman, GLib/GIO, HarfBuzz, Fontconfig, and FreeType system libraries.

```sh
curl -fsSL https://raw.githubusercontent.com/mariobaldini/mdf/main/tools/installer.sh | bash
```

The script checks the OS and architecture, then installs the matching RPM or DEB through the system package manager.
The installer requires curl and Python 3 and verifies the package against GitHub's SHA-256 asset digest.
It accepts `GH_TOKEN` for access to private releases.
Packages install `/usr/bin/mdf` and a Markdown desktop entry for the **Open With** menu.
Installation preserves the current default Markdown application.
Package installation requires administrator access.

### From source

The build requires Git LFS, GNU Make, Zig 0.17.0, GCC/G++, CMake, Ninja, Python, binutils, pkg-config, and the graphics development dependencies.
`make setup` prepares the FLTK frontend and pinned Zig modules. Builds then run offline.
`make reference` is an isolated FLTK build in `build/reference`; `make setup-reference` remains an alias for the same dependencies.
`make setup-native` prepares the minimal dependencies for the optional experimental Zig UI.

On Fedora 44 and Ubuntu 26.04, `make setup` installs missing requirements and downloads the pinned sources.
If the default compiler has another version, setup caches the exact official compiler in `zig-pkg/zig-0.17.0/`.
Make uses that cached compiler automatically. An explicit `ZIG=/path/to/zig` overrides this choice.
Setup extracts dependency archives at their package root. It also repairs source caches from earlier setup runs.

```sh
git clone --recurse-submodules https://github.com/mariobaldini/mdf.git
cd mdf
git lfs pull
make setup
make build
make install
```

`make install` copies `mdf` into `~/.local/bin` without sudo and removes the retired companion library on upgrade.
The `~/.local/bin` folder must be in your `PATH`.
For an existing checkout, run `git submodule update --init --recursive` before building.
Pozeiden 0.4.1 is pinned in `modules/pozeiden`. Its public license is PolyForm Noncommercial 1.0.0.
Commercial use requires separate permission from its author. The [upstream licensing guide](modules/pozeiden/LICENSING.md) explains these terms.
`mdf --licenses` includes the complete license and required notice.
zig-svg 0.2.0 is pinned in `modules/zig-svg`. It uses MIT, and its z2d dependency uses MPL 2.0.
Zignal 0.11.0 is pinned in `modules/zignal` under MIT. The [decoder guide](docs/image-decoding.md) covers ownership, limits, and source fixes.

JSON uses Zig's `std.json`; no external JSON library is required.
The [C++ ownership binding](docs/json-boundary.md) connects FLTK to the Zig core.
The build requires no Rust compiler or Cargo.
`make reference OPTIMIZE=ReleaseFast` builds the FLTK frontend in the isolated `build/reference/bin/mdf` location.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/mariobaldini/mdf/main/tools/installer.sh | bash -s -- --uninstall
```

The script removes the system package and `~/.config/mdf`.
For a source installation, `make uninstall` removes the executable, any retired companion, and `~/.config/mdf`.

## Development

```sh
make run-sample
make tests
make test-gui
```

- `make setup` installs missing dependencies and downloads pinned libraries.
- `make check-requirements` reports missing dependencies and Fedora installation commands.
- `make build` runs the unit tests in the selected build mode, then compiles offline into `build/bin/`. The default mode is Debug. Failed tests stop the build before it replaces the executable.
- `make tests` checks the optimized executable and runs unit tests in Debug, ReleaseSafe, and ReleaseFast. It needs no compositor. `make test` remains an alias.
- `make test-unit` runs just the unit tests in the selected mode. Compiled test binaries are cached, but the tests execute on every invocation.
- New unit cases live under `tests/unit/`. They cover Markdown, links, settings, layout, navigation, files, the JSON ABI, and profiling. Existing source tests remain enabled.
- `make test-gui` checks the FLTK GUI in an isolated headless Wayland compositor. Intermediate files and compiler caches stay under `build/`.
- `make test-images` compares PNG pixels exactly and bounds JPEG differences against the original decoder. It also checks cancellation and pixel ownership.
- `make test-codecs` checks the pinned Zignal module and PNG compatibility fixes in Debug mode. It is included in `make test`.
- `make test-json` checks the native JSON boundary and validates its output with Python. It is included in `make test`.
- `make test-buffers` checks first-frame shared drawing and detachment before repainting compositor-owned pixels. It is included in `make tests`.
- `make test-monospace` checks system font matching, fixed-width styles, uncached discovery without cache writes, missing-font fallback, cancellation, and resource ownership. It needs an installed monospace font and is included in `make test-gui`.
- `make test-mermaid` checks all 17 Pozeiden families in light/dark mode, unsupported types, malformed input, limits, and dependency notices.
- `make test-svg` checks SVG rasterization, font styles, malformed input, and allocation limits. Both targets are included in `make test`.
- `make test-samples` checks the compact syntax sample and the large handbook's distinct PNG/JPEG assets.
- `make test-render` captures MDF and Typora at wide and narrow widths for visual review. Requirements and limits are below.
- `make release` uses Zig ReleaseFast, GCC `-O3`, full link-time optimization, and dead-section removal for the app and bundled dependencies.
  It strips debug symbols and omits frame pointers. C++ exception unwinding remains enabled.
- `make release` also builds RPM and DEB packages. It requires `rpmbuild` and `dpkg-deb` (`rpm-build` and `dpkg` on Fedora).
- The release files, packages, checksums, and build metadata appear in `build/`.
- `make clean` removes `build/`, including binaries, packages, profiles, and compiler caches. It also removes legacy output directories.
  It keeps downloaded dependencies in `zig-pkg/` and submodules in `modules/`.

### Startup profile

```sh
make profile
```

This builds ReleaseFast and opens six samples 12 times each, for 72 cold launches.
`SAMPLE-SMALL`, `SAMPLE-MID`, and `SAMPLE-HUGE` each have `-TEXT.md` and `-IMAGES.md` editions.
Each pair shares the same prose. The image editions add PNG, JPEG, SVG, and Mermaid content.
Each round opens every edition once. A shuffled cycle balances the six launch positions in forward and reversed orders.
The report starts with each sample's average pre-load, scaffold, first viewport, and full readiness time, plus its 95% margin of error.
These Student-t estimates include every run. They describe uncertainty in the mean; background load can correlate runs.
The report records the order seed and every round's order. Use `scripts/profile.py --seed NUMBER` to repeat an order.
Tabs below the summary switch the detailed measurements and call graphs between documents.
Each launch records the scaffold, first Markdown viewport in Open Sans, and full readiness after optional font adoption.
The app and all compiled dependencies use the release optimizations above. Profiling binaries have their own directory: `build/profile/runtime/bin/`.
Debug builds in `build/bin/` cannot replace these files. Zig can reuse cached objects only when their build inputs and optimization settings match.
Profiling creates one HTML file with a UTC datetime, such as `build/profile/profile-20261017T183045.123456Z.html`.
The file works offline and contains the measurements for every launch.
Startup timing begins in the parent before process creation. A matching `CLOCK_MONOTONIC` timestamp at `main` identifies the pre-main interval.
The **Pre-load** interval includes process creation, executable loading, dynamic linking, scheduling, and static initialization. It is included in every startup total.
It measures the complete pre-main interval, not disk I/O alone. ELF pages load on demand; a larger file does not imply that every byte is read before `main`.
Disk page faults after `main` remain part of the application timings. The report separates pre-main time, in-app viewport time, and profiler finish/exit time.
Frame timers end after FLTK flushes the frame. They exclude terminal input delivery, shell command parsing, and compositor scanout.
For an Enter-to-screen measurement, capture command acceptance in the terminal or [Zsh's `accept-line` widget](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html).
Then pair that timestamp with [Wayland presentation feedback](https://wayland.app/protocols/presentation-time) for the first Markdown surface commit.
Both endpoints must use the same clock domain, or their clocks must be correlated explicitly.
The current automated launcher measures process launch to frame submission; it does not install shell or terminal hooks.

Use `make benchmark-launch` to measure the launch baseline without graphics or linked libraries.
It builds two small ReleaseFast Zig programs: normal `main()` and a bare Linux entry point that skips Zig startup.
Each program records a monotonic timestamp before printing Hello World.
The default measures 50 cold and 200 warm launches per program, with balanced executable order and no discarded outliers.
Cold launches use the same cache reset and zero-resident-page checks as MDF profiling. Warm launches verify that the executable is fully cached.
The results include averages, 95% margins, medians, minima, and p95. Exact sources, executables, and JSON stay under `build/launch-baseline/`.
This baseline requires Linux x86_64 and no desktop. Use `LAUNCH_RUNS=100` for twice the samples.

The flame chart groups nested calls by thread on a shared time axis. Each thread has its own color.
Select a parallel group or double-click a call to inspect its subcalls. **Fit all** restores the complete interval.
Ctrl + wheel zooms around the pointer, up to 256×. The large horizontal scrollbar supports panning.
Each thread lane includes measured event waits, idle states, and untraced intervals. Child gaps show the caller's self time.
The complete window flush has its own paint/buffer scope around the draw callback.
Short shaded blocks use W (wait), U (untraced), I (idle/deferred), or S (caller self time). Selection shows surrounding calls and explains the interval.
An untraced interval can contain real work; it does not prove that the CPU was idle or identify an OS wait.
The profiler measures the GUI's event waits directly through `select` and `poll`. Untraced time remains labeled as untraced.
Each native wait records the requested timeout, result, watched descriptors, and ready descriptors from that same launch.
The report distinguishes compositor readability, another descriptor, an expired timeout, an interrupt, and an error.
Compositor readability does not identify the exact protocol message or measure compositor CPU time.
Synchronous Wayland dispatch and roundtrip calls have separate elapsed intervals, labeled **wait + callbacks** because they include event handling.
The dependency graph shows recorded calls, waits, and worker handoffs in a vertical layout.
Each thread has its own color. Blocks contain their recorded calls and subcalls.
Use **Fit width**, **100%**, the +/− buttons, or the 5–800% slider to zoom this graph.
Ctrl + wheel zooms around the pointer. Click and drag anywhere in the diagram to pan, including over call blocks.
A simple click still inspects a call. Horizontal and vertical scrollbars also support panning.
Each block shows its start in milliseconds since t0 and its total elapsed duration in milliseconds.
Nested rows show their start times and inclusive elapsed durations. Their durations are already included in the outer block.
A block marked **part** is split at a handoff or endpoint. Its tooltip retains the original call duration.

The red path defaults to **First viewport**. The **Fully ready** selector includes the deferred work through final readiness.
The sum of the outer red block durations equals the selected endpoint time, with pre-load counted once.
Both graphs use the selected launch. The summary cards show batch statistics, which can differ from that launch.
Parallel work stays visible in its thread color.

A worker enters the red path only with evidence that its result blocked the GUI during a measured wait.
Work that finishes while the GUI remains busy does not enter the red path.
Waits and untraced intervals have separate blocks. Untraced intervals retain their unknown cause.
The eager startup graph connects document adoption to navigation preparation, then navigation readiness to image decoding.
Optional results that are already ready can share the first useful frame. Work that is still pending does not delay the Markdown viewport.
Milestones from one submitted frame share a graph node, rather than appearing as fictitious serial paints.
The image/diagram worker owns its source buffers and rendered pixels. It uses Zig/Zignal codecs and native Mermaid/SVG libraries, then sends a GUI wakeup.
Pozeiden calculates Mermaid layout in Zig with estimated label widths. It does not measure the actual font metrics.
SVG uses in-memory font callbacks. The image worker receives anonymous font data and does no system font discovery.
The host rejects embedded images and external resources, including unused definitions. The SVG renderer performs no file or network I/O.
FLTK image objects, widget changes and drawing stay on the GUI thread. GIF/BMP decoding retains the existing GUI path.
Workers are joined on cancellation and shutdown; adopted pixel buffers outlive their GUI image wrappers.
The report also lists library versions and file sizes, executable sizes, launch timings, CPU time, and memory use.
The main library table shows attributed bytes retained in `mdf`, separately from external shared-library file sizes.
Archive and header sizes appear under **Build inputs**. Archives include unused objects and compiler/LTO metadata, so an archive can exceed the final executable's size.
The size treemap divides the executable into fonts, application code, bundled libraries, language runtimes, shared data, and ELF structure.
Click a group to inspect its parts. Sizes use the final file and matching build symbols; LTO inlined code stays with its caller.
Symbol metadata stays in the build directory and is not installed or included in release packages.
Font timings separate configuration creation, anonymous font data, each face, Pango adoption, FLTK registration, and Wayland initialization.
Deferred monospace and Sans fallback have distinct worker tracks after the first viewport, with catalogue lookup, selected-file loading, GUI adoption, and upgraded frames.
The report lists the selected system family and its font-file bytes separately from embedded executable data. Full readiness includes deferred font preparation; the first-viewport timer does not.
Before every launch, the profiler fsyncs its executable, document, and local images, then clears Linux page, dentry, and inode caches through `sudo`.
It then uses `PROT_NONE` mappings and `mincore` to verify zero resident executable, document, and image pages without reading their contents.
If executable pages remain cached, profiling stops before launching. Each report displays the measured resident/total page count.
It also uses an empty application cache and disables Mesa/NVIDIA shader disk caches.
If sudo needs authentication, run `sudo -v` in the terminal first. Cache resets affect the whole system.
These tests keep the running desktop session. Shared active libraries, storage-controller caches, and other device state can remain warm.
Each launch records the CPU governor, allowed CPU count, and system load average before its cache reset.
The report shows these conditions beside the selected launch so power modes and background load remain visible when comparing timings.
The profile requires a running Wayland session and uses default settings. Saved preferences remain untouched.
If the display socket is missing, profiling stops before cache resets.
`make setup` installs Python 3 and missing cache-reset tools. No sampling profiler is required.
Use `make profile PROFILE_RUNS=24` for more samples, or `PROFILE_RUNS=1` for a smoke check without an error estimate.
`make clean` removes all profile artifacts.
Each document tab records its text size, local image references, distinct files, PNG/JPEG counts, and compressed asset bytes.
The small sample contains regular and bold text, headings, lists, a quotation, links, and a table.
It has no images, diagrams, italics, or code blocks, so it needs no deferred rendering or font workers.
The regular sample covers Markdown syntax, code, and wide tables. The large sample is a fictional 100-station handbook with different data and images.
The six profiling editions use only characters covered by the bundled Open Sans faces.
Code in the mid and huge editions still triggers deferred monospace loading.
The original `SAMPLE-SMALL.md`, `SAMPLE.md`, and `SAMPLE-HUGE.md` remain compatibility fixtures for existing rendering checks.
`SAMPLE-EXTENDED.md` contains Greek, Cyrillic, Arabic, Hebrew, CJK, emoji, and additional symbols for the system Sans fallback checks.
See [the fixture notes](assets/SAMPLES.md) for provenance and regeneration instructions.
For a separate scrolling check, run `build/profile/runtime/bin/mdf --profile-scroll SAMPLE.md`.
Its `scroll_draw_ms` values measure synchronous native drawing, excluding compositor display latency.

### Separate syscall diagnostic

```sh
make profile-trace
```

This builds the same optimized application and traces one fresh launch of each sample with `strace -ff -ttt -T -yy -vvv`.
The result is a separate timestamped HTML report under `build/profile-trace/`, with per-thread text logs in an adjacent directory.
It never changes regular `make profile` results or copies syscall durations between launches.
**Tracing adds overhead. Its timings are diagnostic, not performance measurements of an ordinary launch.**
Both graphs within a report use events from that same launch. The regular report uses the untraced optimized launch.

Native thread IDs connect syscalls to the GUI and document/navigation workers. Other runtime threads get their own colors.
The diagnostic shows timed file opens, mappings, reads, descriptor readiness, and futex operations beneath native calls.
Select a syscall for arguments, its result, and the descriptor identity. Successful futex wakes at the same address are candidate wakers.
They do not prove lock ownership. `EAGAIN` futex calls are work checks, not sleeping waits.
The parser tracks descriptor reuse and reports which descriptors became ready, rather than labeling every watched descriptor as the waker.
Syscall duration includes kernel work, waiting, scheduling, and observer overhead. Mapping a file is not a measurement of all its disk I/O.
Page faults, user code, and scheduler delays outside observed syscalls can remain untraced.
The launcher correlates realtime syscall timestamps with monotonic native timestamps and records the clock uncertainty.
It stops if the clock offset changes too much. Incomplete syscall records are counted.

Read/write/socket payloads use raw pointers, and exec environment expansion is excluded.
Use `python3 scripts/profile-trace.py --stacks` after the build for optional `-k` caller stacks, which add much more overhead.
Matching build symbols stay in the diagnostic directory. Stack frames identify callers; they are not individually timed subcalls.
Use `--warm` to inspect calls without a cache reset. That option explicitly disables the cold-start claim.
For exact Wayland message context, prefix the separate diagnostic with `WAYLAND_DEBUG=client`.
Its adjacent text log then includes window configuration, frame callbacks and buffer messages. These diagnostic timings remain separate from regular profiles.

To compare two optimized executables with balanced cold pairs:

```sh
python3 scripts/benchmark-startup.py --before /path/to/saved/mdf --after build/profile/runtime/bin/mdf
```

The default comparison runs two batches of ten pairs per document: 80 cold launches.
It reports means, medians, p95, maxima, approximate paired 95% confidence margins, and both native call graphs.
The report separates first buffer commit, the deferred viewport callback, scaffold, and full readiness.
It also records the first socket flush. Viewport readiness requires a committed, flushed Markdown frame.
Selection requires better viewport medians in both batches without worse scaffold medians, viewport p95, or fully-ready median/p95.
If only confidence remains inconclusive, the comparison collects two additional batches.
It preserves all observations, checks unchanged CPU affinity/governors, and uses the normal cache policy. It does not change the machine's power settings.
The reset flushes the executable, document, and local images, then clears Linux reclaimable caches with `drop_caches=3`.
`mincore` verifies zero resident pages for those inputs before timing. A warm input aborts the launch.
File-specific flushing avoids a stalled global `sync()` on unrelated dirty filesystems.

### Visual rendering comparison

```sh
make test-render
```

This optional test needs Python Pillow, Weston 15 with its development headers, GCC, and the installed Typora Flatpak (`io.typora.Typora`).
Flatpak launches the reference application only. MDF runs as the native release executable.
The test uses private Wayland desktops, disposable Typora profiles, and read-only copies of the sample.
It captures 29 sections at 1040 and 480 pixels wide, producing 58 section pairs and a local HTML gallery under `build/render-comparison/`.
Script and symbol captures use `SAMPLE-EXTENDED.md`; the other cases use `SAMPLE.md`. Both applications receive identical frozen bytes for each case.
Current support work targets Latin text. Use `python3 scripts/render-compare.py --latin-only` to omit the extended-script fixture.
`--capture-reader` hides MDF navigation for these captures. `--capture-anchor ID` positions a requested heading in the viewport.
Both options require `--capture PNG` and `--profile` or `--benchmark`.

Review the gallery for missing content, overlap, clipping, malformed tables, and failed local images.
Capture checks reject blank frames and verify MDF's requested heading is visible. Passing capture checks does not prove rendering equivalence.
The Typora driver waits for its focused Find field before typing a query. If the expected field does not appear, it stops without typing into the document.
Pixel equality is not expected: fonts, spacing, code styling, UI chrome, and enabled Markdown extensions differ.
MDF keeps math source as text and renders supported Mermaid diagrams. Unsupported characters use installed system fonts when available; otherwise they show missing-glyph markers.
Arabic and Hebrew glyphs shape within each word, but paragraph-level bidirectional word ordering remains a layout limitation.
This comparison checks rendering correctness, not application speed. Ordinary tests and CI do not require Typora.

After reviewing a capture directory, create a focused standalone A/B findings file:

```sh
python3 scripts/render-findings.py build/render-comparison/render-UTC --reviewed
```

Pass `--latin-only` to the findings script when reviewing a Latin-only capture set.

The report embeds its cropped details and original screenshots, with 1×–3× zoom and finding filters. No image sidecars are needed to share it.
Its curated notes show remaining font limits, intentional code styling and reference-editor differences first. Verified table and Mermaid fixes follow in a separate section.
Use `--images-captures DIRECTORY` to include the separate image check. Without `--reviewed`, the file is labeled as a draft.
Review the images again before applying these annotations to another renderer version.

To compare the shipped Latin subset with the original full fonts on this computer:

```sh
make build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/profile/runtime
python3 scripts/benchmark-fonts.py --prepare --full-fonts /path/to/original-open-sans
python3 scripts/benchmark-fonts.py
```

Preparation requires Python `fontTools` and the four full upstream TTF files from the package recorded in `assets/fonts/README.md`.
It keeps source assets unchanged and verifies that the subset rebuild matches the production executable.
The comparison runs 100 cold launches per build for each sample, plus 100 identical-binary control launches.
It also runs isolated font preparation and Pango/Cairo checks. Results include averages and approximate 95% confidence margins across ten batches.
The diagnostic requires this computer's performance governor and CPU cores 0–3. It does not change the governor.
For a short check under the current powersave mode and ordinary CPU scheduling, use `--startup-only --startup-pairs 10 --governor powersave --cpu-set all`.
It checks unchanged preferences, matching workloads, empty executable page caches, and identical pixels for covered Latin text.
Greek/Cyrillic rendering is measured separately because subsetting removes those glyphs.

One GitHub Actions workflow starts independent Fedora 44 and Ubuntu 26.04 build jobs for pushes, pull requests, and manual runs.
Both jobs run the Debug build, full test suite, and ReleaseFast GUI checks.
A final publishing job requires both builds to pass and a qualifying push to `main` or a version tag.
The `dev`, pull-request, and manual runs retain no build artifacts and create no release packages.
Each branch uses its own workflow file. The `dev` branch must include this workflow change.

The publishing job verifies both build manifests and uploads only Fedora's RPM and Ubuntu's DEB.
Checksums and build information remain internal CI inputs. GitHub also displays its automatically generated source archive links.

For example, workflow run 123 for version `0.2.0` creates tag `v0.2.0-123` at the exact source commit.
Its RPM release is `123`, and its DEB version is `0.2.0-123`. Package managers can update between builds of the same application version.
Each main build publishes its own release. The publishing job rechecks completed versions to keep Latest on the newest successful build.

Version-tag pushes such as `v0.2.1` retain the existing release behavior and must match the application version.
Local `make release` keeps the original package names. Set `MDF_PACKAGE_RELEASE=123` to create packages with a numbered revision.

FLTK is built with Wayland enabled, X11 and OpenGL disabled, and its bundled Cairo title-bar plugin.
The Markdown pane draws visible blocks directly through FLTK. It caches text layouts and the small minimap image.
See [the roadmap](docs/mdf-todo.md) for implementation details.
