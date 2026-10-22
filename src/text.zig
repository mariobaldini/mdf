//! The immutable rendered-text projection shared by selection, glyph checks,
//! and backend layout. Construct it on the document worker, not during paint.
const std = @import("std");
const document = @import("document.zig");
const layout = @import("layout.zig");

pub const Projection = struct {
    text: []const u8 = "",
    starts: []const usize = &.{},
    styles: u32 = 0,
    flags: u32 = 0, // 1: ordinary code block, 2: Mermaid block

    pub fn init(a: std.mem.Allocator, blocks: []const document.Block) !Projection {
        var total: usize = 0;
        var styles: u32 = 0;
        var flags: u32 = 0;
        for (blocks) |block| {
            total = try std.math.add(usize, total, block.prefix.len);
            total = try std.math.add(usize, total, 2);
            const bold = block.kind == .heading or block.table_header;
            for (block.spans) |span| {
                total = try std.math.add(usize, total, span.text.len);
                if (span.italic and span.text.len != 0)
                    styles |= @as(u32, 1) << @as(u5, @intCast(layout.faceOffset(span.bold, span.italic, bold)));
            }
            for (block.cells, 0..) |cell, column| {
                if (column != 0) total = try std.math.add(usize, total, 1);
                for (cell.spans) |span| {
                    total = try std.math.add(usize, total, span.text.len);
                    if (span.italic and span.text.len != 0)
                        styles |= @as(u32, 1) << @as(u5, @intCast(layout.faceOffset(span.bold, span.italic, bold)));
                }
            }
            if (block.kind == .code) flags |= if (std.mem.eql(u8, block.language, "mermaid")) @as(u32, 2) else 1;
        }
        const bytes = try a.alloc(u8, total);
        errdefer a.free(bytes);
        const starts = try a.alloc(usize, blocks.len);
        var at: usize = 0;
        for (blocks, starts) |block, *start| {
            start.* = at;
            append(bytes, &at, block.prefix);
            for (block.spans) |span| append(bytes, &at, span.text);
            for (block.cells, 0..) |cell, column| {
                if (column != 0) append(bytes, &at, "\t");
                for (cell.spans) |span| append(bytes, &at, span.text);
            }
            append(bytes, &at, "\n\n");
        }
        std.debug.assert(at == bytes.len);
        return .{ .text = bytes, .starts = starts, .styles = styles, .flags = flags };
    }
    pub fn deinit(self: Projection, a: std.mem.Allocator) void {
        a.free(self.text);
        a.free(self.starts);
    }
};
fn append(output: []u8, at: *usize, value: []const u8) void {
    @memcpy(output[at.*..][0..value.len], value);
    at.* += value.len;
}
