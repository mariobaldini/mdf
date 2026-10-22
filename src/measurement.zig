//! Font measurement contract and intrinsic table layout shared by renderers.
const std = @import("std");
const document = @import("document.zig");
const layout = @import("layout.zig");
const flow = @import("flow.zig");
pub const Font = extern struct { face: u32, size: i32, flags: u32 = 0 }; // 1: monospace, 2: native prefix metrics
pub const Measure = *const fn (?*anyopaque, Font, [*]const u8, usize) callconv(.c) flow.Metrics;
pub fn spanFlags(span: document.Span) u32 {
    return @as(u32, @intFromBool(span.bold)) | @as(u32, @intFromBool(span.italic)) << 1 |
        @as(u32, @intFromBool(span.code)) << 2 | @as(u32, @intFromBool(span.strike)) << 3 |
        @as(u32, @intFromBool(span.underline)) << 4 | @as(u32, @intFromBool(span.highlight)) << 5 |
        @as(u32, @intFromBool(span.small)) << 6;
}
pub fn font(block: document.Block, flags: u32, zoom: f32, mono_ready: bool) Font {
    const kind: layout.StyleKind = if (block.kind == .heading) .heading else if (block.kind == .code) .code else .paragraph;
    const base = layout.nativeStyle(kind, block.heading, 0, block.table_header, zoom);
    return .{ .face = layout.faceOffset(flags & 1 != 0, flags & 2 != 0, block.kind == .heading or block.table_header),
        .size = @max(1, @as(i32, @intFromFloat(@as(f32, @floatFromInt(base.size)) * (if (flags & 64 != 0) @as(f32, 0.8) else 1)))),
        .flags = @intFromBool(mono_ready and (block.kind == .code or flags & 4 != 0)) };
}
pub fn text(callback: Measure, context: ?*anyopaque, face: Font, bytes: []const u8) !flow.Metrics {
    const result = callback(context, face, bytes.ptr, bytes.len);
    if (!std.math.isFinite(result.width) or !std.math.isFinite(result.height) or
        !std.math.isFinite(result.descent) or result.width < 0 or result.height < 0) return error.InvalidMetrics;
    return result;
}
pub fn tableColumns(a: std.mem.Allocator, blocks: []const document.Block, row_index: usize, width: f32, zoom: f32, wrap: bool, mono_ready: bool, callback: Measure, context: ?*anyopaque) ![]f32 {
    if (row_index >= blocks.len or blocks[row_index].kind != .table_row) return error.InvalidTable;
    var index = row_index;
    while (index > 0 and !blocks[index].table_header and blocks[index - 1].kind == .table_row) index -= 1;
    const count = blocks[index].cells.len;
    const temporary = try a.alloc(f32, try std.math.mul(usize, count, 2));
    defer a.free(temporary);
    const minimum = temporary[0..count];
    const preferred = temporary[count..];
    const padding = 16 * zoom;
    @memset(minimum, padding + 1);
    @memset(preferred, padding + 1);
    var row = index;
    while (row < blocks.len and blocks[row].kind == .table_row and (row == index or !blocks[row].table_header)) : (row += 1) {
        const block = blocks[row];
        for (block.cells, 0..) |cell, col| {
            if (col >= count) return error.InconsistentTable;
            var word: f32 = 0;
            var line: f32 = 0;
            var longest_word: f32 = 0;
            var longest_line: f32 = 0;
            for (cell.spans) |span| {
                const face = font(block, spanFlags(span), zoom, mono_ready);
                var at: usize = 0;
                while (at < span.text.len) {
                    const space = std.ascii.isWhitespace(span.text[at]);
                    var end = at + 1;
                    if (span.text[at] != '\n') while (end < span.text.len and span.text[end] != '\n' and std.ascii.isWhitespace(span.text[end]) == space) : (end += 1) {};
                    const part = (try text(callback, context, face, span.text[at..end])).width;
                    if (space) {
                        longest_word = @max(longest_word, word);
                        word = 0;
                    } else word += part;
                    if (span.text[at] == '\n') {
                        longest_line = @max(longest_line, line);
                        line = 0;
                    } else line += part;
                    at = end;
                }
            }
            minimum[col] = @max(minimum[col], @max(longest_word, word) + padding + 1);
            preferred[col] = @max(preferred[col], @max(longest_line, line) + padding + 1);
        }
    }
    const result = try a.alloc(f32, count);
    errdefer a.free(result);
    try layout.intrinsicColumns(minimum, preferred, width, padding, wrap, result);
    return result;
}
