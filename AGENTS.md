# Markdown FAST agent instructions

Read `README.md` before changing the project.

## Version rule

- `VERSION` is the source of the application version. Its format is `MAJOR.MINOR`, such as `0.3`.
- For every completed change, run `make version-bump` once. This includes code, interface, tests, build files, and documentation changes.
- Increase the second integer: `0.3` becomes `0.4`, and `0.9` becomes `0.10`. Keep related edits under one increase.
- Builds and test runs that change no tracked files do not need a version increase.
- `make version-bump` also updates `build.zig.zon`. Zig and package tools use `MAJOR.MINOR.0`.
- Read the application version from `VERSION` in build code. Do not copy it into source labels or test expectations.
- Before completing a change, run `make version-check` and the tests affected by the change.
