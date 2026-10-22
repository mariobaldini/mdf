const std = @import("std");
const flow = @import("mdf").flow;
const a = std.testing.allocator;

fn span(text: []const u8) flow.Span {
    return .{ .text = text.ptr, .len = text.len };
}
fn spec(width: f32) flow.Spec {
    return .{ .left = 0, .top = 0, .width = width, .size = 10 };
}
fn measure(_: ?*anyopaque, _: usize, ptr: [*]const u8, len: usize) callconv(.c) flow.Metrics {
    var count: usize = 0;
    for (ptr[0..len]) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return .{ .width = @as(f32, @floatFromInt(count)) * 5, .height = 10, .descent = 2 };
}

test "flow: wrapping retains byte positions including skipped leading spaces" {
    const output = try flow.layout(a, &.{span(" one two three")}, spec(40), measure, null);
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), output.runs.len);
    try std.testing.expectEqual(@as(usize, 1), output.runs[0].position);
    try std.testing.expectEqual(@as(usize, 9), output.runs[4].position);
    try std.testing.expectEqual(@as(f32, 0), output.runs[4].x);
    try std.testing.expectEqual(@as(f32, 25.5), output.runs[4].y);
    try std.testing.expectEqual(@as(f32, 30), output.height);
    try std.testing.expectEqual(@as(f32, 40), output.right);
}

test "flow: no-wrap retains long words and explicit newlines" {
    var options = spec(10);
    options.flags = 4;
    options.start = 100;
    options.left = 20;
    options.top = 30;
    const output = try flow.layout(a, &.{span("abcde\nxy")}, options, measure, null);
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), output.runs.len);
    try std.testing.expectEqual(@as(usize, 106), output.runs[1].position);
    try std.testing.expectEqual(@as(f32, 45), output.right);
    try std.testing.expectEqual(@as(f32, 30), output.height);
}

test "flow: long UTF-8 words split on codepoint boundaries" {
    const output = try flow.layout(a, &.{span("ééé")}, spec(10), measure, null);
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), output.runs.len);
    for (output.runs, 0..) |run, index| {
        try std.testing.expectEqual(index * 2, run.offset);
        try std.testing.expectEqual(index * 2, run.position);
        try std.testing.expectEqual(@as(usize, 2), run.len);
    }
    try std.testing.expectEqual(@as(f32, 30), output.height);
    try std.testing.expectEqual(@as(f32, 10), output.right);
}

test "flow: code retains indentation and advances tabs to four-space stops" {
    var options = spec(100);
    options.flags |= 2;
    var code = span(" \tX\tY");
    code.flags = 1;
    const output = try flow.layout(a, &.{code}, options, measure, null);
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 5), output.runs.len);
    try std.testing.expectEqual(@as(f32, 15), output.runs[1].width);
    try std.testing.expectEqual(@as(f32, 20), output.runs[2].x);
    try std.testing.expectEqual(@as(f32, 15), output.runs[3].width);
    try std.testing.expectEqual(@as(f32, 40), output.runs[4].x);
    try std.testing.expectEqual(@as(f32, 45), output.right);
}

test "flow: alignment shifts each line including styled spans" {
    var options = spec(40);
    options.alignment = 1;
    const centered = try flow.layout(a, &.{ span("ab"), span("cd\nx") }, options, measure, null);
    defer centered.deinit(a);
    try std.testing.expectEqual(@as(f32, 10), centered.runs[0].x);
    try std.testing.expectEqual(@as(f32, 20), centered.runs[1].x);
    try std.testing.expectEqual(@as(f32, 17.5), centered.runs[2].x);
    try std.testing.expectEqual(@as(usize, 1), centered.runs[1].span);
    options.alignment = 2;
    const right = try flow.layout(a, &.{span("ab\nx")}, options, measure, null);
    defer right.deinit(a);
    try std.testing.expectEqual(@as(f32, 30), right.runs[0].x);
    try std.testing.expectEqual(@as(f32, 35), right.runs[1].x);
    try std.testing.expectEqual(@as(f32, 40), right.right);
}

test "flow: measuring without collecting runs performs no allocations" {
    var options = spec(20);
    options.flags = 1;
    const output = try flow.layout(std.testing.failing_allocator, &.{span("one two three")}, options, measure, null);
    defer output.deinit(std.testing.failing_allocator);
    try std.testing.expectEqual(@as(usize, 0), output.runs.len);
    try std.testing.expectEqual(@as(f32, 60), output.height);
}

fn allocationCheck(allocator: std.mem.Allocator) !void {
    const output = try flow.layout(allocator, &.{span("one two three four five six seven")}, spec(20), measure, null);
    defer output.deinit(allocator);
}
test "flow: allocation failures release all partially built runs" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
}

test "flow: invalid geometry text and callback metrics are rejected" {
    var options = spec(0);
    try std.testing.expectError(error.InvalidGeometry, flow.layout(a, &.{}, options, measure, null));
    options.width = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGeometry, flow.layout(a, &.{}, options, measure, null));
    try std.testing.expectError(error.InvalidText, flow.layout(a, &.{.{ .text = null, .len = 1 }}, spec(10), measure, null));
    options = spec(10);
    options.start = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidText, flow.layout(a, &.{span("a")}, options, measure, null));
    const bad = struct {
        fn measure(_: ?*anyopaque, _: usize, _: [*]const u8, _: usize) callconv(.c) flow.Metrics {
            return .{ .width = std.math.nan(f32), .height = 1, .descent = 0 };
        }
    };
    try std.testing.expectError(error.InvalidMetrics, flow.layout(a, &.{span("a")}, spec(10), bad.measure, null));
    const truncated = try flow.layout(a, &.{span("\xf0\x9f")}, spec(1), measure, null);
    defer truncated.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), truncated.runs[0].len);
}
