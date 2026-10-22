# PNG, JPEG, GIF and BMP codecs

MDF uses Zignal 0.11.0 at commit `1719dae43146b836f8382571300dcd84b3950072`.
The source is the `modules/zignal` submodule from `https://github.com/bfactory-ai/zignal.git`.
The parent repository pins the commit. The embedded notices include its MIT license.

`frontend/image-pixels.zig` provides the existing `mdf_decode_pixels` C interface.
The Zig build creates `libmdf-image.a`. A private codec module links this archive; the UI engine does not.
The checked `.mdf_image` section embeds that module in the single distributable executable.
It loads into sealed anonymous memory on the first raster decode or explicit PNG screenshot export.
Text-only and SVG-only documents do not load the raster codec for document rendering.
Mermaid and SVG keep their own independent modules; loading one never inflates the others.
The image codec has no font or UI dependency. Its only exported symbol is the ABI 1 `mdf_image_api` table.
Successful loading is cached for the process lifetime, with the existing loader's cancellation and corruption checks.
The default `MDF_OPTIONAL_MODULE_COMPRESSION=zlib` compresses all three optional modules independently.
Use `raw` to store each module unchanged for a controlled comparison.
Fonts and the mandatory UI engine retain their existing storage policies.

Only PNG/JPEG/GIF/BMP decoding and PNG encoding are used.
Other Zignal codecs and image-processing features are not requested.
Decoding stays on the existing image worker.
`std.Io.failing` runs asynchronous tasks inline and rejects actual I/O.
The codecs read the supplied bytes; they do not create threads or load system codec libraries.

Successful pixel allocations use the C allocator. The caller owns the pixels and releases them with `free()`.
Native eight-bit PNG scanlines transfer directly after removal of their filter bytes.
A failure clears the output. PNG preserves one, two, three or four channels.
JPEG produces RGB, including grayscale JPEG input.
GIF displays the first composed frame and preserves transparency.
BMP supports indexed and true-color data, top-down rows, channel masks and RLE.
GIF and BMP pixels remain owned after the decoder's temporary state is destroyed.

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
The independent generator adds 37 GIF/BMP files with exact expected RGBA pixels.
These cover global/local palettes, transparency, interlacing, animated first-frame selection, BMP row order, bitfields and RLE.
The codec unit suite also runs 1,024 deterministic GIF/BMP mutations with a fixed output-memory limit.

PNG capture encoding also uses Zignal through `mdf_encode_png`.
The adapter accepts grayscale, RGB, and RGBA byte views, including unaligned C buffers.
It checks dimensions and storage length, borrows the source pixels, and returns an independently owned encoded allocation.
The UI writes those encoded bytes only after encoding succeeds and checks write/close errors.
Startup profiles snapshot codec status before optional screenshot export, so capture work does not appear as a document requirement.
The production UI no longer calls the bundled C PNG encoder.
GIF/BMP decoding runs on the Zig worker in both frontends.
The application no longer links FLTK's image archive.
The bundled C PNG/JPEG decoders remain only in reference tests.
The profiler identifies Zignal for both image decoding and screenshot encoding.
