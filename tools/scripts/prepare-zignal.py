#!/usr/bin/env python3
"""Apply reviewed PNG compatibility fixes to a build-cache copy of Zignal 0.11."""
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
changes = [
    (
        ".grayscale, .grayscale_alpha => {\n                if (png_state.transparency != null) {",
        ".grayscale, .grayscale_alpha => {\n                if (png_state.header.color_type == .grayscale_alpha or png_state.transparency != null) {",
    ),
    (
        """            const trans_r: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[0..2], .big) >> 8)
            else
                trans_data[1]; // Use lower byte for 8-bit
            const trans_g: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[2..4], .big) >> 8)
            else
                trans_data[3];
            const trans_b: u8 = if (header.is16Bit())
                @intCast(std.mem.readInt(u16, trans_data[4..6], .big) >> 8)
            else
                trans_data[5];
            break :blk r == trans_r and g == trans_g and b == trans_b;""",
        """            // Compare tRNS before stripping 16-bit samples to eight bits.
            for (0..3) |channel| {
                const at = offset + channel * channel_stride;
                const sample: u16 = if (header.is16Bit())
                    std.mem.readInt(u16, src_row[at..][0..2], .big)
                else
                    src_row[at];
                if (sample != std.mem.readInt(u16, trans_data[channel * 2 ..][0..2], .big))
                    break :blk false;
            }
            break :blk true;""",
    ),
]
for old, new in changes:
    if source.count(old) != 1:
        raise SystemExit("Zignal PNG source changed; review docs/architecture.md#images-and-diagrams before updating the adapter")
    source = source.replace(old, new)
Path(sys.argv[2]).write_text(source)
