//! Backend-independent geometry and scroll ownership. A renderer may borrow
//! the arrays until resize; only the UI thread mutates this state.
const std = @import("std");
const layout = @import("layout.zig");
pub const Fields = extern struct {
    scroll: f32 = 0,
    horizontal_scroll: f32 = 0,
    content_width: f32 = 0,
    margin: f32 = 24,
    horizontal_extent: f32 = 0,
    horizontal_dirty: bool = true,
    geometry_revision: u64 = 0,
};
pub const View = extern struct {
    heights: ?[*]f32,
    offsets: ?[*]const f32,
    count: usize,
    offset_count: usize,
};
pub const State = struct {
    allocator: std.mem.Allocator,
    fields: Fields = .{},
    heights: []f32 = &.{},
    offsets: []f32 = &.{},

    pub fn deinit(self: *State) void {
        self.allocator.free(self.heights);
        self.allocator.free(self.offsets);
    }
    pub fn resize(self: *State, count: usize) !void {
        const offset_count = try std.math.add(usize, count, 1);
        if (self.heights.len == count and self.offsets.len == offset_count) return;
        const heights = try self.allocator.alloc(f32, count);
        errdefer self.allocator.free(heights);
        const offsets = try self.allocator.alloc(f32, offset_count);
        @memset(heights, 0);
        const keep = @min(count, self.heights.len);
        @memcpy(heights[0..keep], self.heights[0..keep]);
        self.allocator.free(self.heights);
        self.allocator.free(self.offsets);
        self.heights = heights;
        self.offsets = offsets;
        self.reindexValues();
    }
    fn reindexValues(self: *State) void {
        self.offsets[0] = 24;
        for (self.heights, 0..) |height, index| self.offsets[index + 1] = self.offsets[index] + height;
    }
    pub fn reindex(self: *State) !void {
        try self.resize(self.heights.len);
        self.reindexValues();
        self.fields.geometry_revision +%= 1;
    }
    /// During document replacement the model count can change before reflow.
    /// Use its current count to preserve the reader's anchor clamp.
    pub fn indexAt(self: State, y: f32, block_count: usize) usize {
        if (block_count == 0) return 0;
        var low: usize = 0;
        var high = self.offsets.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (y < self.offsets[middle]) high = middle else low = middle + 1;
        }
        return @min(low -| 1, block_count - 1);
    }
    pub fn total(self: State) f32 {
        return if (self.offsets.len == 0) 48 else self.offsets[self.offsets.len - 1] + 24;
    }
    pub fn configure(self: *State, width: f32, mode: u32, character_width: f32, wrap: bool) void {
        const max_width: layout.MaxWidth = switch (mode) { 0 => .characters_100, 2 => .percent_100, else => .percent_80 };
        self.fields.content_width = layout.documentWidth(width, max_width, character_width);
        self.fields.margin = @max(0, (width - self.fields.content_width) / 2);
        self.fields.horizontal_dirty = true;
        if (wrap) self.fields.horizontal_scroll = 0;
    }
    pub fn move(self: *State, value: f32, height: f32) void {
        self.fields.scroll = std.math.clamp(value, 0, @max(0, self.total() - height));
    }
    pub fn moveHorizontal(self: *State, value: f32, maximum: f32, wrap: bool) void {
        self.fields.horizontal_scroll = if (wrap) 0 else std.math.clamp(value, 0, @max(0, maximum));
    }
    pub fn horizontal(self: *State, width: f32, right: f32) void {
        self.fields.horizontal_extent = @max(width, @ceil(right - 0.01));
        self.fields.horizontal_dirty = false;
    }
    pub fn view(self: *State) View {
        return .{ .heights = if (self.heights.len > 0) self.heights.ptr else null,
            .offsets = if (self.offsets.len > 0) self.offsets.ptr else null,
            .count = self.heights.len, .offset_count = self.offsets.len };
    }
};
pub fn estimate(kind: u32, bytes: usize, lines: usize, indent: usize, quote: usize, size: f32, zoom: f32, width: f32, wrap: bool) f32 {
    if (kind == 3) return 24 * zoom;
    const available = @max(40, width - @as(f32, @floatFromInt(@min(20, indent +| quote))) * 22 * zoom);
    const count: f32 = @floatFromInt(@max(1, lines));
    const measured = if (wrap) @max(count, @ceil(@as(f32, @floatFromInt(bytes)) * size * 0.5 / available)) else count;
    return measured * size * 1.5 + 24 * zoom + (if (kind == 1) @as(f32, 24) * zoom else 0);
}
const a = std.heap.c_allocator;
pub export fn mdf_viewport_create() ?*State {
    const self = a.create(State) catch return null;
    self.* = .{ .allocator = a };
    return self;
}
pub export fn mdf_viewport_destroy(self: *State) void {
    self.deinit();
    a.destroy(self);
}
pub export fn mdf_viewport_fields(self: *State) *Fields {
    return &self.fields;
}
pub export fn mdf_viewport_resize(self: *State, count: usize) bool {
    self.resize(count) catch return false;
    return true;
}
pub export fn mdf_viewport_view(self: *State) View {
    return self.view();
}
pub export fn mdf_viewport_reindex(self: *State) bool {
    self.reindex() catch return false;
    return true;
}
pub export fn mdf_viewport_index_at(self: *State, y: f32, count: usize) usize {
    return self.indexAt(y, count);
}
pub export fn mdf_viewport_total(self: *State) f32 {
    return self.total();
}
pub export fn mdf_viewport_configure(self: *State, width: f32, mode: u32, character_width: f32, wrap: bool) void {
    self.configure(width, mode, character_width, wrap);
}
pub export fn mdf_viewport_move(self: *State, value: f32, height: f32) void {
    self.move(value, height);
}
pub export fn mdf_viewport_move_horizontal(self: *State, value: f32, maximum: f32, wrap: bool) void {
    self.moveHorizontal(value, maximum, wrap);
}
pub export fn mdf_viewport_horizontal(self: *State, width: f32, right: f32) void {
    self.horizontal(width, right);
}
pub export fn mdf_estimate_block(kind: u32, bytes: usize, lines: usize, indent: usize, quote: usize, size: f32, zoom: f32, width: f32, wrap: bool) f32 {
    return estimate(kind, bytes, lines, indent, quote, size, zoom, width, wrap);
}
