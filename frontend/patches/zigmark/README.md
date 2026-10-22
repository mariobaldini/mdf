# Zigmark build adapters

The parent repository pins Zigmark 0.11.1 and Mecha 0.11.0 as submodules.
Both source trees stay unmodified.
`scripts/prepare-zigmark.py` copies the parser into the build cache, applies checked Zig 0.17 syntax changes, and applies these patches without fuzz.
`scripts/prepare-mecha.py` adapts tuple and field reflection in a generated copy.
The build tracks the scripts, source directories, and every patch as inputs.

1. `0001` corrects physical line endings, indented-code whitespace, soft-break trimming, and container tab columns.
   Code blocks retain their complete line endings in the AST.
   It also propagates GFM options into nested blocks and replaces NUL with the standard replacement character.
2. `0002` distinguishes container prefixes from literal fenced-code content.
   It preserves tabs after code indentation and tracks nested fences while collecting quotes and list continuations.
3. `0003` allocates temporary table-cell arrays through the supplied allocator, releases them, and propagates allocation errors.
   The upstream page-allocator temporaries otherwise survive document destruction.
4. `0004` makes flattened image labels semantic text: entities decode once, code/escaped punctuation stays literal, and visible autolinks and hard breaks are retained.
   MDF consumes the flattened label directly rather than parsing it a second time.
5. `0005` skips definition collection when the required `]:` signature is absent and skips label normalization when the reference map is empty.
   Reference definitions and deferred resolution retain the same behavior.

The generated parser disables nonstandard frontmatter recognition for ordinary Markdown.
The MDF module also disables HTML blocks, preserving the viewer's existing inline-HTML handling for details, emphasis, and other supported tags.
The specification renderer retains standard HTML blocks.
Both modules use the complete standard entity map from `assets/html-entities.tsv` through the Zig decoder.
The replacement entity-decoder body has a checked source hash so an upstream change cannot be silently discarded.
The entity data retains its MD4C MIT attribution; no MD4C parser or C entity implementation is compiled.

For an upstream update:

1. Update the submodule pin and `frontend/dependencies.json` together.
2. Check which fixes landed upstream before porting the remaining changes.
3. Keep each generated-source replacement exact. Regenerate patch context when required; do not enable fuzz.
4. Run `make test-markdown`, `make tests`, and the native GUI/render comparisons.
5. Compare all four sample document models and startup measurements against the previous complete executable.

The parser gates cover all 652 CommonMark 0.31.2 cases, 24 GFM extension cases, additional container/code/entity cases, and MDF's own unit tests.
These gates run during ordinary builds as well as `make tests`.

Zig 0.17 currently crashes when the compact entity reader is compiled with per-module `-fstrip`.
The build retains debug metadata for that one module during compilation, with ReleaseFast optimization unchanged.
The normal release packer strips the final ELF and saves matching debug sidecars.
Recheck this workaround when updating Zig.
