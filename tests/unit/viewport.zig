const std = @import("std");
const viewport = @import("mdf").viewport;
const a = std.testing.allocator;

test "viewport: untouched and empty geometry preserves the reader margins" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), state.offsets.len);
    try std.testing.expectEqual(@as(f32, 48), state.total());
    try std.testing.expectEqual(@as(usize, 0), state.indexAt(500, 0));
    try state.resize(0);
    try std.testing.expectEqualSlices(f32, &.{24}, state.offsets);
    try std.testing.expectEqual(@as(f32, 48), state.total());
    try state.reindex();
    try std.testing.expectEqual(@as(u64, 1), state.fields.geometry_revision);
}
test "viewport: collapsed blocks and exact boundaries choose the following block" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    try state.resize(3);
    @memcpy(state.heights, &[_]f32{ 10, 0, 20 });
    try state.reindex();
    try std.testing.expectEqualSlices(f32, &.{ 24, 34, 34, 54 }, state.offsets);
    try std.testing.expectEqual(@as(usize, 0), state.indexAt(-100, 3));
    try std.testing.expectEqual(@as(usize, 0), state.indexAt(33.9, 3));
    try std.testing.expectEqual(@as(usize, 2), state.indexAt(34, 3));
    try std.testing.expectEqual(@as(usize, 2), state.indexAt(500, 3));
    try std.testing.expectEqual(@as(f32, 78), state.total());
}
test "viewport: document replacement clamps against the current model count" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    try state.resize(3);
    @memset(state.heights, 10);
    try state.reindex();
    try std.testing.expectEqual(@as(usize, 0), state.indexAt(500, 1));
    try std.testing.expectEqual(@as(usize, 3), state.indexAt(500, 5));
    try state.resize(5);
    try std.testing.expectEqualSlices(f32, &.{ 10, 10, 10, 0, 0 }, state.heights);
    try state.resize(1);
    try std.testing.expectEqualSlices(f32, &.{ 24, 34 }, state.offsets);
}
test "viewport: borrowed heights remain the source of indexed offsets" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    try state.resize(2);
    const borrowed = state.view();
    borrowed.heights.?[0] = 100;
    borrowed.heights.?[1] = 200;
    try state.reindex();
    try std.testing.expectEqual(state.heights.ptr, borrowed.heights.?);
    try std.testing.expectEqualSlices(f32, &.{ 24, 124, 324 }, state.offsets);
}
test "viewport: width modes preserve horizontal position until wrapping is restored" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    state.fields.horizontal_scroll = 50;
    state.configure(500, 0, 7, false);
    try std.testing.expectEqual(@as(f32, 452), state.fields.content_width);
    try std.testing.expectEqual(@as(f32, 24), state.fields.margin);
    try std.testing.expectEqual(@as(f32, 50), state.fields.horizontal_scroll);
    state.configure(500, 1, 7, false);
    try std.testing.expectEqual(@as(f32, 400), state.fields.content_width);
    try std.testing.expectEqual(@as(f32, 50), state.fields.margin);
    state.configure(500, 2, 7, true);
    try std.testing.expectEqual(@as(f32, 452), state.fields.content_width);
    try std.testing.expectEqual(@as(f32, 0), state.fields.horizontal_scroll);
    try std.testing.expect(state.fields.horizontal_dirty);
}
test "viewport: scroll positions clamp to measured content and available width" {
    var state = viewport.State{ .allocator = a };
    defer state.deinit();
    try state.resize(3);
    @memset(state.heights, 100);
    try state.reindex();
    state.move(999, 100);
    try std.testing.expectEqual(@as(f32, 248), state.fields.scroll);
    state.move(-20, 100);
    try std.testing.expectEqual(@as(f32, 0), state.fields.scroll);
    state.move(50, 1000);
    try std.testing.expectEqual(@as(f32, 0), state.fields.scroll);
    state.moveHorizontal(999, 60, false);
    try std.testing.expectEqual(@as(f32, 60), state.fields.horizontal_scroll);
    state.moveHorizontal(50, 60, true);
    try std.testing.expectEqual(@as(f32, 0), state.fields.horizontal_scroll);
    state.horizontal(100, 135.001);
    try std.testing.expectEqual(@as(f32, 135), state.fields.horizontal_extent);
    try std.testing.expect(!state.fields.horizontal_dirty);
}
test "viewport: estimates retain zoom indentation rules and explicit no-wrap lines" {
    try std.testing.expectEqual(@as(f32, 174), viewport.estimate(0, 100, 1, 0, 0, 20, 1, 200, true));
    try std.testing.expectEqual(@as(f32, 54), viewport.estimate(0, 100, 1, 0, 0, 20, 1, 200, false));
    try std.testing.expectEqual(@as(f32, 198), viewport.estimate(1, 100, 1, 0, 0, 20, 1, 200, true));
    try std.testing.expectEqual(@as(f32, 24), viewport.estimate(3, 100, 1, 0, 0, 20, 1, 200, true));
    try std.testing.expectEqual(@as(f32, 774), viewport.estimate(0, 100, 1, 100, 100, 20, 1, 1, true));
}
fn allocationCheck(allocator: std.mem.Allocator) !void {
    var state = viewport.State{ .allocator = allocator };
    defer state.deinit();
    try state.resize(2);
    @memcpy(state.heights, &[_]f32{ 10, 20 });
    try state.reindex();
    const previous = state.heights.ptr;
    state.resize(8) catch |err| {
        try std.testing.expectEqual(previous, state.heights.ptr);
        try std.testing.expectEqualSlices(f32, &.{ 10, 20 }, state.heights);
        try std.testing.expectEqualSlices(f32, &.{ 24, 34, 54 }, state.offsets);
        return err;
    };
}
test "viewport: failed resize retains previous geometry and frees partial allocations" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
}
