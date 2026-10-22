# PNG and JPEG decoding

MDF uses Zignal 0.11.0 at commit `1719dae43146b836f8382571300dcd84b3950072`.
The source is the `modules/zignal` submodule from `https://github.com/bfactory-ai/zignal.git`.
The parent repository pins the commit. The embedded notices include its MIT license.

`frontend/image-pixels.zig` provides the existing `mdf_decode_pixels` C interface.
The Zig build creates `libmdf-image.a`. The UI engine links this archive.
Installation still requires one executable. The launcher does not load a separate codec module.

Only PNG and JPEG entry points are used. Other Zignal codecs and image-processing features are not requested.
Decoding stays on the existing image worker.
`std.Io.failing` runs asynchronous tasks inline and rejects actual I/O.
The codecs read the supplied bytes; they do not create threads or load system codec libraries.

Successful pixel allocations use the C allocator. The caller owns the pixels and releases them with `free()`.
Native eight-bit PNG scanlines transfer directly after removal of their filter bytes.
A failure clears the output. PNG preserves one, two, three or four channels.
JPEG produces RGB, including grayscale JPEG input.

The adapter checks the caller's byte limit before pixel allocation.
Dimensions are limited to 32,768 per axis and 67,108,864 pixels.
Zignal also limits chunks, scans, blocks and decompressed data.
Incomplete PNG data returns an error instead of partial pixels.

## Compatibility fixes

`scripts/prepare-zignal.py` corrects two PNG branches in a generated build-cache copy.
The upstream submodule stays unchanged.

1. Interlaced grayscale-alpha PNGs must retain their alpha channel without a `tRNS` chunk.
2. RGB `tRNS` comparisons must use the full sample before conversion from 16 bits to eight bits.

The script requires exact source text and stops after an unexpected upstream change.
When updating Zignal, check whether upstream includes these corrections before porting the adapter.

## Checks

Run `make test-images OPTIMIZE=ReleaseFast` and `make test-gui OPTIMIZE=ReleaseFast`.
The independent PNG generator covers all color types and bit depths, Adam7, row filters and transparency.
PNG pixels must match the original libpng path exactly.
JPEG checks cover baseline, progressive, grayscale, chroma subsampling and restart markers.
JPEG inverse transforms and interpolation can differ between implementations.
The reference comparison requires mean channel error at most 1/255 and PSNR at least 40 dB.
The checks also cover byte limits, corrupt input, cancellation and ownership after worker replacement.

FLTK's bundled libpng remains for PNG capture encoding. The bundled C JPEG decoder remains only in reference tests.
The profiler identifies Zignal as the document decoder and retains archive-size labels for the reference libraries.
