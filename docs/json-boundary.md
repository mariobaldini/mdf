# JSON boundary

MDF uses Zig's `std.json` for all application JSON parsing, storage, and serialization.
The frontend has no external JSON dependency.

`src/json.zig` exposes a C ABI. `frontend/json.hpp` provides the C++ ownership binding.
Each JSON tree has an arena. Parsing copies strings, so the input buffer can be released immediately.
Read views retain the arena. A builder clones a shared tree before mutation.
This keeps existing views valid when an object or array grows.
Inserted values are copied into the destination arena.
Tree copies allow up to 256 nested containers.

The binding preserves signed and unsigned 64-bit integers. It rejects invalid types, integer overflow, and nonfinite numbers.
Serialization uses `std.json.Stringify`. The caller frees its output with `mdf_buffer_free`.

Settings files and profiler JSON retain their existing fields and value types.
Bulk document blocks and spans still use typed views.
The launcher and embedded UI module come from the same build.
Rollback requires replacing the single executable; settings need no conversion.

Run `make test-json OPTIMIZE=ReleaseFast` for ownership, mutation, input lifetime, bounds, and error checks.
The test also validates the encoded result with Python's JSON reader.
`make test-gui` checks settings, document loading, navigation, and actual profiler output.
