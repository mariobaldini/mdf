//! GUI-owned decoded pixels. Workers transfer each allocation once.
const std = @import("std");
const c = @import("native");
pub const Image = struct {
    pixels: c.struct_MdfPixels,
    diagram: bool = false,
    svg: bool = false,
    logical_width: f32 = 0,
    logical_height: f32 = 0,
    failure: [512]u8 = @splat(0),

    fn release(self: Image) void { c.free(self.pixels.data); }
    pub fn message(self: *const Image) []const u8 { return std.mem.sliceTo(&self.failure, 0); }
};
pub const Store = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    values: std.AutoHashMapUnmanaged(usize, Image) = .empty,
    version: u64 = 0,

    pub fn put(self: *Store, index: usize, image: Image) !void {
        errdefer image.release();
        const entry = try self.values.getOrPut(self.allocator, index);
        if (entry.found_existing) entry.value_ptr.release();
        entry.value_ptr.* = image;
    }
    pub fn reset(self: *Store) void {
        var images = self.values.valueIterator();
        while (images.next()) |image| image.release();
        self.values.clearRetainingCapacity();
        self.version +%= 1;
    }
    pub fn deinit(self: *Store) void { self.reset(); self.values.deinit(self.allocator); }
};
