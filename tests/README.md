# Running tests

Run `make tests` for the full non-GUI suite. `make test` is an alias.
The suite builds the ReleaseFast executable and checks the core in Debug, ReleaseSafe, and ReleaseFast modes.
The launcher checks apply the strict production startup requirements to that optimized executable.
It also runs native JSON, image, asynchronous keyboard, and system-font checks, renderer checks, and Python and shell regression tests.
GUI and visual comparisons remain separate: use `make test-gui` or `make test-render`.
The GUI suite also checks word-metric reuse against real FLTK fonts, bounded cache size,
font invalidation, and retained painting metrics in `text-layout.hpp`.
`make test-cairo OPTIMIZE=ReleaseFast` checks the minimal Cairo backend contract and image compositing.

Every `make build` first runs the unit tests in the selected build mode.
For example, `make build OPTIMIZE=ReleaseFast` tests ReleaseFast before building it.
Failed tests stop the build before it replaces the executable.
Test binaries can remain cached. Test execution is never skipped because of a cached result.

Use `make test-unit` for a focused run. Add `OPTIMIZE=ReleaseSafe` or `OPTIMIZE=ReleaseFast` to select another mode.
The test runner prints the number of passed and failed tests.

`unit.zig` loads the additional suites under `unit/` through the tested core's public test API.
The original source tests run in a separate test binary, so neither suite hides the other.
Add new cases to the relevant file and import new suites in `unit.zig`.
Use fixed inputs and test observable behavior. Keep filesystem tests in temporary directories.
Use the testing allocator so allocation leaks fail the test.

The unit cases cover Markdown structures, malformed UTF-8, URL validation, preference bounds, table sizing,
viewport lookup, wrapping, cancellation, filesystem limits, JSON ownership and conversion, and profiler accounting.
Workflow tests also inject a unit failure and verify that the build stops.
They check setup's dependency-cache selection, pinned checksums, and offline behavior.

These commands use cached dependencies and perform no downloads or global disk-cache flushes.
Run `make setup` first if dependencies are missing.
