# Optional module storage evaluation

The default now uses independently compressed, lazy modules to prioritize small and mid-sized text-only documents.
The measurements below informed that choice; raw payloads remain available for comparison.
Zignal loads only for raster decoding or explicit PNG export.
Mermaid and SVG stay independent. Text-only documents load none of these three modules.
`make profile` measures the six SMALL/MID/HUGE `-TEXT.md` and `-IMAGES.md` editions.
The original sample filenames remain available for existing rendering checks.

## Compared versions

The evaluation ran on the local machine on 2026-10-23 with optimized production binaries and the FLTK UI.

| Version | Executable bytes | MiB | Mandatory UI bytes |
| --- | ---: | ---: | ---: |
| Previous: raw diagrams, raster codecs in UI | 7,649,656 | 7.30 | 3,431,440 |
| New: raw lazy modules | 7,671,296 | 7.32 | 3,206,160 |
| New: compressed lazy modules | 5,699,704 | 5.44 | 3,206,160 |

Compression reduces the new executable by **25.7%**. Moving Zignal out removes **220 KiB** from the mandatory UI.
The raw and compressed lazy variants share identical allocated host code, UI bytes, and decoded module ELF images.
The repacker verifies these identities before publishing its output.
The existing Zig standard-library inflater handles zlib payloads; no external unzip library is needed.

## First viewport without images

This table isolates compression from lazy loading. Positive saving means faster.
Margins are paired Student-t 95% estimates. The small case uses the independent confirmation; the others use the exploratory comparison.

| TEXT edition, cold cache | Raw mean, ms | Compressed mean, ms | Paired saving, ms | Pairs |
| --- | ---: | ---: | ---: | ---: |
| Small | 42.37 | 40.79 | 1.57 ± 1.52 | 60 |
| Mid | 50.05 | 49.79 | 0.26 ± 2.65 | 20 |
| Huge | 49.54 | 50.83 | -1.29 ± 11.27 | 20 |

Small-text pre-load saved **1.45 ± 0.24 ms** cold. Its viewport gain is modest, with a wide interval.
Warm small-text viewport savings were **0.78 ± 0.95 ms**; that interval includes zero.
An earlier 20-pair small-text estimate was larger. The confirmation reduced that estimate.

The previous binary versus compressed lazy comparison used 40 pairs for every edition and cache state.
Its cold first-viewport savings for small, mid, and huge TEXT were **0.29 ± 1.72**, **1.49 ± 1.85**, and **-5.62 ± 8.26 ms**.
These intervals all include zero. They measure the combined codec extraction and compression change.

## When the modules are used

The IMAGES editions contain PNG, JPEG, a local SVG, and Mermaid.
Compression delayed the previous binary's first diagram pixels by **6–9 ms cold** and **9–10 ms warm**.
Some later waits absorb that delay, so it does not always increase full readiness by the same amount.

| IMAGES edition, warm cache | Previous ready mean, ms | Compressed ready mean, ms | Paired added time, ms |
| --- | ---: | ---: | ---: |
| Small | 46.67 | 52.99 | 6.33 ± 1.72 |
| Mid | 62.59 | 64.85 | 2.27 ± 1.93 |
| Huge | 261.88 | 275.21 | 13.33 ± 2.92 |

Raw lazy modules preserve the faster diagram path. Compression offers a clear file-size reduction and a small cold pre-load gain.
It does not establish a broad text-only first-render improvement. The report includes a text/image share model for each document size.
That model states its workload assumptions and uncertainty instead of assuming one image frequency for every user.

## Method and reproduction

The main analysis contains **1,680 launches** at matching recorded power settings: performance governor, 12 logical CPUs,
and a 20 W MMIO long-term power limit. Binary order is balanced, and document order is shuffled.
Cold and warm results remain separate. Cold runs flush Linux filesystem caches and verify zero resident executable, document,
and asset pages before every launch. Shared desktop libraries and storage-controller caches can remain warm.
No tracing or competing builds ran during timing, and no outliers were removed.
Power, affinity, and workload checks run before and after each launch. An incomplete power-change attempt was discarded in full.

A separate 240-launch confirmation used a stable 64 W limit for both variants. It is reported separately and never pooled with the 20 W data.
Background and compositor activity can correlate observations; the margins do not guarantee future latency.

The unified local report is `build/module-comparison/summary.html` with machine-readable statistics in `summary.json`.
Detailed reports preserve individual runs, native graphs, exact binaries, symbol files, and source snapshots.
The fixtures are commit `4f79d11`; lazy codecs and storage controls are commit `49fdbdb`.

```sh
make profile
MDF_OPTIONAL_MODULE_COMPRESSION=raw make profile
```

For an exact-code storage comparison, build once and repack the optional payloads:

```sh
MDF_OPTIONAL_MODULE_COMPRESSION=raw make build OPTIMIZE=ReleaseFast BUILD_PREFIX=build/raw
python3 scripts/repack-optional-modules.py --input build/raw/bin/mdf \
  --output build/compressed/mdf --compression zlib
python3 scripts/benchmark-startup.py --before build/raw/bin/mdf \
  --after build/compressed/mdf --batches 2 --pairs-per-batch 20
```

These benchmark commands require the existing Wayland and cache-reset tools.
Full unit, codec, module, Debug/Release GUI, private ABI, and single-file package checks passed before measurement.
