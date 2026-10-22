const std = @import("std");
const Block = @import("document.zig").Block;
const TableColumn = @import("document.zig").TableColumn;

pub const default_font_size: u16 = 12;
pub const min_font_size: u16 = 8;
pub const max_font_size: u16 = 72;
pub const document_margin: f32 = 24;
pub const NativeStyle = extern struct { face: u32, size: i32 };
pub const StyleKind = enum(u32) { paragraph, heading, code };

pub fn faceOffset(bold: bool, italic: bool, emphasized_block: bool) u32 {
    return @as(u32, @intFromBool(bold or emphasized_block)) + 2 * @as(u32, @intFromBool(italic));
}

pub fn nativeStyle(kind: StyleKind, heading: u32, span_flags: u32, table_header: bool, zoom: f32) NativeStyle {
    const sizes = [_]f32{ 12, 26, 20, 16, 14, 12, 12 };
    const points = switch (kind) {
        .heading => sizes[@min(6, heading)],
        .code => @as(f32, 11),
        .paragraph => @as(f32, 12),
    };
    const scale: f32 = if (span_flags & 64 != 0) 0.8 else 1;
    return .{
        .face = faceOffset(span_flags & 1 != 0, span_flags & 2 != 0, kind == .heading or table_header),
        .size = @max(1, @as(i32, @intFromFloat(@round(points * 1.4 * zoom * scale)))),
    };
}

/// Fit intrinsic columns while protecting readable words. A table may overflow
/// when several ordinary columns cannot fit; only oversized tokens may shrink.
/// The caller supplies output storage; no allocation or font calls occur here.
pub fn intrinsicColumns(minimum: []const f32, preferred: []const f32, width: f32, padding: f32, wrap: bool, output: []f32) !void {
    if (minimum.len != preferred.len or minimum.len != output.len) return error.InvalidColumns;
    var min_sum: f32 = 0;
    var preferred_sum: f32 = 0;
    for (minimum, preferred, output) |min, pref, *out| {
        if (!std.math.isFinite(min) or !std.math.isFinite(pref) or min < 0 or pref < 0) return error.InvalidColumns;
        min_sum += min;
        preferred_sum += @max(min, pref);
        out.* = min;
    }
    if (!std.math.isFinite(width) or !std.math.isFinite(padding) or width < 0 or padding < 0) return error.InvalidColumns;
    if (!wrap and preferred_sum > width) {
        for (minimum, preferred, output) |min, pref, *out| out.* = @max(min, pref);
    } else if (min_sum > width) {
        if (minimum.len > 1) {
            const word_cap = @max(padding + 1, width * 0.5);
            var readable_sum: f32 = 0;
            for (minimum) |min| readable_sum += @min(min, word_cap);
            if (readable_sum > width) {
                for (minimum, output) |min, *out| out.* = @min(min, word_cap);
                return;
            }
        }
        var compact: f32 = 0;
        var flexible: usize = 0;
        for (minimum, preferred) |min, pref| {
            if (@max(min, pref) <= min + 0.01 and min <= width * 0.5) compact += min else flexible += 1;
        }
        const protect = flexible != 0 and compact + @as(f32, @floatFromInt(flexible)) * (padding + 1) <= width;
        var low: f32 = 0;
        var high = min_sum;
        for (0..24) |_| {
            const cap = (low + high) / 2;
            var used: f32 = 0;
            for (minimum, preferred) |min, pref|
                used += if (protect and @max(min, pref) <= min + 0.01 and min <= width * 0.5) min else @min(min, cap);
            if (used > width) high = cap else low = cap;
        }
        for (minimum, preferred, output) |min, pref, *out|
            if (!protect or !(@max(min, pref) <= min + 0.01 and min <= width * 0.5)) {
                out.* = @min(min, low);
            };
    } else {
        for (minimum, preferred, output) |min, raw_pref, *out| {
            const pref = @max(min, raw_pref);
            if (preferred_sum > width) out.* += (width - min_sum) * (pref - min) / (preferred_sum - min_sum) else out.* = pref + (width - preferred_sum) * pref / @max(1, preferred_sum);
        }
    }
}

pub const MaxWidth = enum {
    characters_100,
    percent_80,
    percent_100,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !MaxWidth {
        const name = try std.json.innerParse([]const u8, allocator, source, options);
        // Keep preferences saved before the character-width option was increased.
        if (std.mem.eql(u8, name, "characters_80")) return .characters_100;
        return std.meta.stringToEnum(MaxWidth, name) orelse error.InvalidEnumTag;
    }
};

pub fn documentWidth(viewport_width: f32, mode: MaxWidth, character_width: f32) f32 {
    const available = @max(40, viewport_width - 2 * document_margin);
    const limit = switch (mode) {
        .characters_100 => 100 * character_width,
        .percent_80 => viewport_width * 0.8,
        .percent_100 => available,
    };
    return @min(available, @max(40, limit));
}

pub const Minimap = struct {
    height: f32,
    thumb_height: f32,
    max_scroll: f32,

    pub fn init(height: f32, document_height: f32, viewport_height: f32) Minimap {
        const h = @max(0, height);
        const total = @max(1, document_height);
        return .{
            .height = h,
            .thumb_height = @min(h, @max(12, h * @max(0, viewport_height) / total)),
            .max_scroll = @max(0, document_height - viewport_height),
        };
    }

    pub fn thumbTop(self: Minimap, offset: f32) f32 {
        if (self.max_scroll == 0) return 0;
        return (self.height - self.thumb_height) * std.math.clamp(offset / self.max_scroll, 0, 1);
    }

    pub fn scrollAt(self: Minimap, pointer_y: f32, grab_offset: f32) f32 {
        const travel = self.height - self.thumb_height;
        if (travel <= 0) return 0;
        return std.math.clamp((pointer_y - grab_offset) / travel, 0, 1) * self.max_scroll;
    }
};

pub fn fontSize(block: Block, zoom: f32) f32 {
    const sizes = [_]f32{ 12, 26, 20, 16, 14, 12, 12 };
    return (if (block.kind == .heading) sizes[@min(6, block.heading)] else if (block.kind == .code) @as(f32, 11) else @as(f32, default_font_size)) * zoom;
}

pub fn lineHeight(block: Block) f32 {
    return switch (block.kind) {
        .heading => 1.25,
        .code => 1.35,
        else => 1.35,
    };
}

pub fn headingRule(block: Block) bool {
    return block.kind == .heading and block.heading <= 2;
}

pub fn blockSpacing(block: Block, previous: ?Block, zoom: f32) struct { before: f32, after: f32, padding: f32 } {
    return .{
        .before = if (block.kind == .heading and previous != null) 16 * zoom else if (block.indent == 0 and previous != null and previous.?.indent > 0) 8 * zoom else 0,
        .after = (if (block.kind == .table_row and !block.table_last) @as(f32, 0) else if (headingRule(block)) @as(f32, 18) else if (block.kind == .heading) @as(f32, 10) else if (block.indent > 0) @as(f32, 6) else @as(f32, 12)) * zoom,
        .padding = (if (block.kind == .code) @as(f32, 12) else if (block.quote > 0) @as(f32, 8) else @as(f32, 0)) * zoom,
    };
}

pub fn columnWidth(columns: []const TableColumn, index: usize, width: f32, zoom: f32) f32 {
    var total: f32 = 0;
    for (columns) |column| total += @floatFromInt(@min(48, @max(8, column.characters)));
    const minimum = @min(64 * zoom, width / @as(f32, @floatFromInt(columns.len)));
    const remaining = @max(0, width - minimum * @as(f32, @floatFromInt(columns.len)));
    return minimum + remaining * @as(f32, @floatFromInt(@min(48, @max(8, columns[index].characters)))) / total;
}

pub const Layout = struct {
    allocator: std.mem.Allocator,
    heights: []f32,
    offsets: []f32,
    width: f32 = 0,
    zoom: f32 = 0,

    pub fn init(a: std.mem.Allocator, count: usize) !Layout {
        const heights = try a.alloc(f32, count);
        errdefer a.free(heights);
        const offsets = try a.alloc(f32, count + 1);
        @memset(heights, 0);
        @memset(offsets, 0);
        return .{ .allocator = a, .heights = heights, .offsets = offsets };
    }

    pub fn deinit(self: *Layout) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.offsets);
    }

    pub fn invalidate(self: *Layout) void {
        // Retain the current offsets for the reading-position anchor, but
        // discard measurements when the font size changes.
        self.zoom = 0;
    }

    pub fn prepare(self: *Layout, blocks: []const Block, width: f32, zoom: f32) bool {
        const profile_span = @import("profiling.zig").begin(@src(), "Estimate block heights and offsets", .gui);
        defer profile_span.end();
        if (@abs(self.width - width) < 1 and self.zoom == zoom) return false;
        self.width = width;
        self.zoom = zoom;
        for (blocks, self.heights, 0..) |block, *height, i| {
            const size = fontSize(block, zoom);
            const spacing = blockSpacing(block, if (i > 0) blocks[i - 1] else null, zoom);
            const indent = @as(f32, @floatFromInt(@min(20, block.indent + block.quote))) * 22 * zoom;
            const available = @max(40, width - indent - 2 * spacing.padding);
            const columns = @max(1, available / (size * 0.7));
            const wraps = @ceil(@as(f32, @floatFromInt(block.bytes)) / columns);
            const lines = @max(@as(f32, @floatFromInt(block.lines)), wraps);
            height.* = if (block.kind == .rule) 24 * zoom else @max(1, lines) * size * 1.4 * lineHeight(block) + 2 * spacing.padding + spacing.before + spacing.after;
            if (block.kind == .table_row) {
                var row_lines: f32 = 1;
                for (block.cells, 0..) |cell, col| {
                    var bytes: usize = 0;
                    for (cell.spans) |span| bytes += span.text.len;
                    const cell_width = @max(1, columnWidth(block.columns, col, available, zoom) - 16 * zoom);
                    row_lines = @max(row_lines, @ceil(@as(f32, @floatFromInt(bytes)) * size * 0.7 / cell_width));
                }
                height.* = row_lines * size * 1.4 * lineHeight(block) + 16 * zoom + spacing.after;
            }
            if (block.alert_start) height.* += size * 2;
            if (block.kind == .code and block.language.len > 0) height.* += size * 2;
        }
        self.reindex();
        return true;
    }

    pub fn reindex(self: *Layout) void {
        self.offsets[0] = 32;
        for (self.heights, 0..) |h, i| self.offsets[i + 1] = self.offsets[i] + h;
    }

    pub fn indexAt(self: Layout, y: f32) usize {
        if (self.heights.len == 0) return 0;
        var low: usize = 0;
        var high: usize = self.heights.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.offsets[middle + 1] <= y) low = middle + 1 else high = middle;
        }
        return @min(low, self.heights.len - 1);
    }

    pub fn totalHeight(self: Layout) f32 {
        return self.offsets[self.offsets.len - 1] + 32;
    }
};

test "viewport lookup honors measured heights and width changes" {
    const blocks = [_]Block{ .{ .bytes = 100 }, .{ .bytes = 100 }, .{ .bytes = 100 } };
    var layout = try Layout.init(std.testing.allocator, blocks.len);
    defer layout.deinit();
    try std.testing.expect(layout.prepare(&blocks, 600, 1));
    const wide_height = layout.totalHeight();
    layout.heights[0] = 100;
    layout.reindex();
    try std.testing.expectEqual(@as(usize, 0), layout.indexAt(layout.offsets[1] - 1));
    try std.testing.expectEqual(@as(usize, 1), layout.indexAt(layout.offsets[1]));
    try std.testing.expect(!layout.prepare(&blocks, 600, 1));
    try std.testing.expect(layout.prepare(&blocks, 120, 1));
    try std.testing.expect(layout.totalHeight() > wide_height);
}

test "maximizing uses the full width and font changes reflow text" {
    const blocks = [_]Block{ .{ .bytes = 8_000 }, .{ .kind = .heading, .heading = 2, .bytes = 60 } };
    var layout = try Layout.init(std.testing.allocator, blocks.len);
    defer layout.deinit();
    _ = layout.prepare(&blocks, documentWidth(1040, .percent_100, 7), 1);
    const normal_height = layout.totalHeight();
    _ = layout.prepare(&blocks, documentWidth(1920, .percent_100, 7), 1);
    try std.testing.expectEqual(@as(f32, 1872), layout.width);
    try std.testing.expect(layout.totalHeight() < normal_height);
    const maximized_height = layout.totalHeight();
    _ = layout.prepare(&blocks, documentWidth(1920, .percent_100, 14), 2);
    try std.testing.expect(layout.totalHeight() > maximized_height);
}

test "document max widths follow character metrics and fit the window" {
    try std.testing.expectEqual(@as(f32, 700), documentWidth(1040, .characters_100, 7));
    try std.testing.expectEqual(@as(f32, 832), documentWidth(1040, .percent_80, 7));
    try std.testing.expectEqual(@as(f32, 992), documentWidth(1040, .percent_100, 7));
    try std.testing.expectEqual(@as(f32, 1400), documentWidth(1920, .characters_100, 14));
    inline for (std.meta.tags(MaxWidth)) |mode| {
        const width = documentWidth(420, mode, 14);
        try std.testing.expect(width > 0 and width <= 372);
        try std.testing.expectEqual(@as(f32, 40), documentWidth(0, mode, 0));
    }
}

test "minimap click and drag positions clamp and preserve the grabbed position" {
    const map = Minimap.init(600, 12000, 600);
    try std.testing.expectEqual(@as(f32, 30), map.thumb_height);
    try std.testing.expectEqual(@as(f32, 0), map.scrollAt(-50, 15));
    try std.testing.expectEqual(map.max_scroll, map.scrollAt(700, 15));
    const top = map.thumbTop(4500);
    try std.testing.expectApproxEqAbs(@as(f32, 4500), map.scrollAt(top + 7, 7), 0.01);
    const short = Minimap.init(600, 100, 600);
    try std.testing.expectEqual(@as(f32, 600), short.thumb_height);
    try std.testing.expectEqual(@as(f32, 0), short.scrollAt(300, 0));
    const empty = Minimap.init(0, 0, 0);
    try std.testing.expectEqual(@as(f32, 0), empty.scrollAt(100, 0));
}

test "table column widths agree across rows and fit narrow viewports" {
    const columns = [_]TableColumn{ .{ .characters = 6 }, .{ .characters = 80 }, .{ .characters = 3 } };
    for ([_]f32{ 120, 400, 1600 }) |width| {
        var total: f32 = 0;
        for (columns, 0..) |_, i| {
            const cell_width = columnWidth(&columns, i, width, 1);
            try std.testing.expect(cell_width > 0);
            total += cell_width;
        }
        try std.testing.expectApproxEqAbs(width, total, 0.01);
    }
}
