# Markdown test vectors

`commonmark-spec-0.31.2.json` is the published CommonMark 0.31.2 example set:
<https://spec.commonmark.org/0.31.2/spec.json>.
Its license is retained in `LICENSE-commonmark.txt`.

`gfm-extensions.json` contains the 24 extension examples from
`github/cmark-gfm` commit `587a12bb54d95ac37241377e6ddc93ea0e45439b`, `test/spec.txt`.
Its license is retained in `LICENSE-gfm.txt`.
The extraction replaces the specification's visible tab arrows with actual tabs.

`markdown-compatibility.json` adds generated cases for container tabs, literal fenced-code content, empty/code line endings, NUL, and all 2,125 named references.
Expected HTML was checked with the official CommonMark reference at commit `65d96448bb4261977dd87f3f4b4d003e76606a36`.
One numeric-reference case deliberately retains MDF's existing HTML5 C1 mapping (`&#128;` becomes the euro sign).
The additional vectors are project regression data; the official specification licenses apply to the first two files.
