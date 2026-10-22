# MDF patches for FLTK

These patches target FLTK **1.4.5**, including its bundled libdecor Cairo plugin.
`frontend/dependencies.json` pins the upstream archive and SHA-256.
`series.json` pins the order and the before/after SHA-256 of every managed file.
The upstream archive remains unchanged.

## Patch series

| Patch | Purpose | Upgrade checks |
| --- | --- | --- |
| `0001-title-height.patch` | Increase the Cairo title bar from 24 to 48 logical pixels. | Drawing, button hit areas, borders, normal and maximized windows. |
| `0002-startup-tracing.patch` | Add optional native timing hooks for registry/output callbacks, cursor loading, XKB compilation, libdecor, and buffer creation/submission. | Nested timings, GUI ownership, buffer commit timestamps, hooks absent in other executables. |
| `0003-parallel-startup.patch` | Prepare XKB resources on a worker, defer cursor loading, prepare frame buffers, and fix the first-configure redraw gate. | The input, buffer, protocol, and performance checks below. |
| `0004-cursor-shapes.patch` | Use compositor-provided standard cursor shapes when available. | Protocol version 1, hidden/custom cursors, pointer removal, and theme fallback. |
| `0005-shared-drawing.patch` | Draw into client-owned shared pixels until a busy buffer requires a private drawing surface. | Pixel ownership, pending frames, resize, scaling, offscreen images, and destruction. |
| `0006-viewport-pool.patch` | Reserve only the page-rounded first viewport for shared drawing. | Allocation guarantees, signed protocol bounds, pool retirement, resize, and scaling. |

`scripts/prepare-fltk.py` applies the series during setup and before every native build.
It accepts pristine sources and exact intermediate states, including the former inline title-height adjustment.
It validates all files before replacement and leaves already prepared files untouched.
An unknown managed-file change stops the build instead of guessing patch context.
Only the managed files have these checks. Preserve other local dependency edits separately.

The patch identity includes the manifest and patch contents.
The build invalidates cached FLTK objects when this identity changes.
Native profile output records the identity as `fltk_patch_id`.

## Ownership and readiness

The optional `fl_mdf_*` hooks are private integration interfaces, not upstream FLTK APIs.
Applications without the hooks keep synchronous initialization.
The patched driver remains responsible for protocol objects and callbacks.
No worker creates windows, draws, dispatches Wayland events, or changes FLTK widgets.

The keyboard worker owns its XKB contexts and source copies.
Each completed keymap/state transfers to the GUI once.
The initial Compose state transfers with the first adopted result and survives later keymap replacement.
Discarding an unadopted keymap must preserve its initial Compose state.
The worker never accesses an adopted object.
Shutdown joins the worker before releasing its remaining objects.

The GUI retains keyboard callbacks while preparation is pending.
Enter events copy their variable-length key arrays.
Keymaps, focus, modifiers, and keys share one ordered GUI stream.
At the 1024-event limit, it retains the incoming event before completing preparation synchronously.
Zero-delay continuations deliver queued releases even inside a shortcut's nested modal event loop.
A keymap replacement drains earlier queued input before changing generations.
Retained focus events check that their surface still exists before replay.
A failed worker preparation uses the existing synchronous compilation path.

Cursor loading stays on the GUI thread because it creates Wayland buffer objects.
The driver first tries `wp_cursor_shape_manager_v1`, binding protocol version 1.
Standard cursor requests then use the compositor's images and avoid loading a cursor theme.
The driver keeps the selected shape until it receives a valid pointer-enter serial.
Hidden cursors use a null cursor surface. Custom image cursors retain the existing surface path.
Pointer removal destroys the shape device. Manager removal restores the theme path.
If the compositor or build SDK lacks the protocol, the existing theme path remains active.
Generated tablet protocol metadata supplies the cursor protocol's type reference; MDF does not bind tablet devices.
MDF defers theme loading until after its first Markdown viewport callback.
Ready navigation/image jobs start before cursor loading, so cursor I/O cannot delay decoder kickoff.
Pending standard cursor requests retain their latest value; custom cursors remain intact.
Fully-ready timing includes deferred input and cursor preparation.
Adopting nonvisual resources can reuse an already submitted document frame.
Readiness does not force a duplicate document repaint when the visible state is already current.

Frame preparation sends the initial configure request before allocating local buffers.
It checks the Wayland queue/socket between preparation units.
Worker wakeups do not falsely indicate that window configuration is ready.
Only this window's drawing and shared-buffer pages receive early allocation/touches.
Preparation never attaches or commits a content buffer before configure acknowledgement.
FLTK's existing resize/scale invalidation discards mismatched prepared buffers and layout.

The first shared drawing buffer reserves its page-rounded size instead of the default 10 MB pool.
Anonymous-file allocation still reserves backing storage before mapping, preserving allocation failure behavior.
Private and offscreen drawing retain the upstream pool policy.
Existing pool retirement keeps compositor-owned buffers alive when a new viewport needs another pool.
Sizes must fit Wayland's signed 32-bit pool and offset fields before any protocol request.

## First-configure redraw correction

Upstream `handle_configure()` clears `wait_for_expose_value` on the second configure.
`Fl::flush()` skips windows while that flag remains set.
Mutter can send a valid initial configure, then delay the activation configure.
A captured MDF run submitted its first content buffer but suppressed later redraws for about three seconds.
The Wayland frame callback arrived during that interval, so a pending frame callback was not the blocker.

The patch clears the expose gate after the first valid configured width and height.
A separate private flag retains upstream's second-configure workarounds for geometry and compositor differences.
It preserves configure acknowledgement and buffer-commit ordering.
Retain this correction unless a later upstream release resolves the same gate.

## Validation and upgrade procedure

1. Save the old patch series, pinned manifest, build identity, and measurement reports.
2. Extract the new verified upstream archive into a separate directory.
3. Port each patch in order. Preserve the original upstream copyright notices.
4. Record each file's SHA-256 before and after each patch in `series.json`.
5. Update the upstream version and archive SHA-256 in both manifests.
6. Apply the new series to pristine sources. Apply it again to verify idempotence.
7. Run `make test-patches`, `make test`, and `make test-gui OPTIMIZE=ReleaseFast`.
8. Exercise normal/maximized windows, fractional scale, early input, shortcuts, dead keys, and keymap changes on the target desktop.
9. Compare optimized cold launches for all three samples before enabling an optimization.

Patch files use plain unified diffs with `a/` and `b/` paths.
New files use `/dev/null` as their source and `null` as the manifest's before checksum.
The application tool requires exact context and rejects fuzzy or unknown source states.

The private CMake switches `MDF_ASYNC_INPUT`, `MDF_PREPARE_FRAME`, and `MDF_SHARED_DRAWING` isolate benchmark candidates.
All three production defaults are `ON`.
Historical experiment results remain in their timestamped reports. Recheck the current binary when changing these defaults.
They do not add saved preferences or command-line options.
Both variants must include identical timing hooks and the redraw correction.
Report actual first-buffer-commit time separately from the deferred viewport callback.
Never import durations from strace or a different launch into an optimized report.

## Presentation boundary

Drawing into Cairo does not prove that FLTK submitted a buffer.
A pending Wayland frame callback can defer buffer submission after the draw callback returns.
MDF snapshots the reader revision, navigation, and font state at the actual buffer-commit hook.
Viewport and full readiness use that submitted snapshot after the socket flush succeeds.
The socket write watch handles backpressure without blocking the GUI.
Only actual reader paints update the pending reader snapshot.
This prevents a speculative timer from starting cursor or system-font work before the first Markdown submission.

The profiler rejects a viewport timestamp earlier than its first commit or socket flush.
The isolated GUI checks exercise these invariants on small, huge, Unicode, and unavailable-font cases.
A server-only delayed compositor test exercises early buffer preparation without changing the client binary.
Prepared measurements also track window scale; a scale change invalidates those measurements before drawing.
No-wrap width scans remain outside speculative layout preparation.

## Shared drawing ownership

MDF's main window can create its Cairo surface directly on a Wayland shared-memory buffer.
The buffer is cleared before drawing. Its first submission needs no separate drawing allocation or pixel copy.
The compositor owns submitted pixels until `wl_buffer.release`.
Before drawing while that buffer is busy, `make_current()` creates a private Cairo surface and copies the previous pixels.
The normal FLTK copy path then handles later submissions for that buffer.
This avoids writing through the direct Cairo alias while the compositor owns it.
Resize and scale changes discard the old buffer through FLTK's existing release path.
Destruction frees private arrays and preserves mapped storage until the compositor releases it.
Offscreen surfaces and custom cursor images retain private drawing storage.
`MDF_SHARED_DRAWING=OFF` selects the previous drawing path for comparisons.

`make test-buffers OPTIMIZE=ReleaseFast` checks initialization, pixel preservation, detachment, and offscreen lifetime without a compositor.
`make test-gui OPTIMIZE=ReleaseFast` checks both cursor backends when the protocol SDK is available.
The test compositor can advertise the cursor protocol; production timing uses the ordinary desktop.

To exercise early buffers with a delayed server, use the experimental build:

```sh
MDF_PREPARE_FRAME=ON make build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/early-frame-test
cc -shared -fPIC tests/slow-compositor.c -o build/fltk-tests/slow-compositor.so -ldl
MDF_TEST_COMPOSITOR_PRELOAD="$PWD/build/fltk-tests/slow-compositor.so" \
  sh scripts/fltk-gui.sh build/early-frame-test/bin/mdf
```

The preload affects only the isolated Weston server. The client executable stays unchanged.
The test requires actual early-buffer preparation and committed/flushed viewport ordering.
Use ordinary desktop launches for performance measurements.
