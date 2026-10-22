const std = @import("std");
const layout = @import("mdf").layout;
const document = @import("mdf").document;
const a = std.testing.allocator;

test "layout: native styles preserve heading sizes weight emphasis and small text" {
    const expected = [_]i32{ 17, 36, 28, 22, 20, 17, 17 };
    for (expected, 0..) |size, heading| {
        const style = layout.nativeStyle(.heading, @intCast(heading), 2, false, 1);
        try std.testing.expectEqual(size, style.size);
        try std.testing.expectEqual(@as(u32, 3), style.face);
    }
    for (0..4) |flags| {
        const style = layout.nativeStyle(.paragraph, 0, @intCast(flags), false, 1);
        try std.testing.expectEqual(@as(u32, @intCast(flags)), style.face);
        try std.testing.expectEqual(@as(i32, 17), style.size);
    }
    try std.testing.expectEqual(@as(i32, 13), layout.nativeStyle(.paragraph, 0, 64, false, 1).size);
    try std.testing.expectEqual(@as(i32, 15), layout.nativeStyle(.code, 0, 0, false, 1).size);
    try std.testing.expectEqual(@as(u32, 3), layout.nativeStyle(.paragraph, 0, 2, true, 1).face);
    try std.testing.expectEqual(@as(i32, 17), layout.nativeStyle(.heading, 999, 0, false, 1).size);
}

test "layout: native styles retain zoom rounding and minimum pixel size" {
    try std.testing.expectEqual(@as(i32, 18), layout.nativeStyle(.heading, 1, 0, false, 0.5).size);
    try std.testing.expectEqual(@as(i32, 34), layout.nativeStyle(.paragraph, 0, 0, false, 2).size);
    try std.testing.expectEqual(@as(i32, 1), layout.nativeStyle(.paragraph, 0, 0, false, 0).size);
}

test "layout: intrinsic fitting protects compact cells and caps long tokens" {
    var fitted: [2]f32 = undefined;
    try layout.intrinsicColumns(&.{ 60, 400 }, &.{ 60, 800 }, 300, 16, true, &fitted);
    try std.testing.expectEqual(@as(f32, 60), fitted[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 240), fitted[1], 0.001);
    try layout.intrinsicColumns(&.{ 60, 400 }, &.{ 60, 800 }, 300, 16, false, &fitted);
    try std.testing.expectEqualSlices(f32, &.{ 60, 800 }, &fitted);
    var one: [1]f32 = undefined;
    try layout.intrinsicColumns(&.{1000}, &.{1000}, 100, 16, true, &one);
    try std.testing.expectApproxEqAbs(@as(f32, 100), one[0], 0.001);
}

test "layout: intrinsic fitting interpolates and expands to the available width" {
    var fitted: [2]f32 = undefined;
    try layout.intrinsicColumns(&.{ 30, 70 }, &.{ 60, 140 }, 150, 16, true, &fitted);
    try std.testing.expectEqualSlices(f32, &.{ 45, 105 }, &fitted);
    try layout.intrinsicColumns(&.{ 30, 70 }, &.{ 60, 140 }, 400, 16, true, &fitted);
    try std.testing.expectEqualSlices(f32, &.{ 120, 280 }, &fitted);
}

test "layout: many intrinsic columns preserve readable widths and overflow" {
    var minimum: [40]f32 = undefined;
    var preferred: [40]f32 = undefined;
    var output: [40]f32 = undefined;
    for (&minimum, &preferred, 0..) |*min, *pref, i| {
        min.* = @floatFromInt(17 + i);
        pref.* = min.* * 2;
    }
    for ([_]f32{ 40, 320, 1800, 6000 }) |width| {
        try layout.intrinsicColumns(&minimum, &preferred, width, 16, true, &output);
        var sum: f32 = 0;
        for (output) |value| {
            try std.testing.expect(std.math.isFinite(value) and value > 0);
            sum += value;
        }
        try std.testing.expect(sum >= width - 0.02);
        for (output, minimum) |value, min| {
            // Extreme tokens may wrap, but ordinary words do not become
            // single-letter columns just to fit the entire table on screen.
            try std.testing.expect(value >= @min(min, @max(17, width * 0.5)) - 0.01);
        }
    }
    try std.testing.expectError(error.InvalidColumns, layout.intrinsicColumns(&minimum, &preferred, 100, 16, true, output[0..1]));
    try std.testing.expectError(error.InvalidColumns, layout.intrinsicColumns(&.{std.math.nan(f32)}, &.{1}, 100, 16, true, output[0..1]));
}

test "layout: narrow eight-column tables retain whole labels" {
    const minimum = [_]f32{ 80, 65, 80, 110, 140, 60, 95, 100 };
    const preferred = [_]f32{ 100, 120, 150, 500, 700, 80, 95, 100 };
    var fitted: [8]f32 = undefined;
    try layout.intrinsicColumns(&minimum, &preferred, 368, 16, true, &fitted);
    try std.testing.expectEqualSlices(f32, &minimum, &fitted);
}

test "layout: an empty document has a safe viewport lookup and finite height" {
    var model = try layout.Layout.init(a, 0);
    defer model.deinit();
    _ = model.prepare(&.{}, 600, 1);
    try std.testing.expectEqual(@as(usize, 0), model.indexAt(-100));
    try std.testing.expectEqual(@as(usize, 0), model.indexAt(10000));
    try std.testing.expectEqual(@as(f32, 64), model.totalHeight());
}
test "layout: exact block boundaries choose the following visible block" {
    var model = try layout.Layout.init(a, 3);
    defer model.deinit();
    @memcpy(model.heights, &[_]f32{ 10, 0, 20 });
    model.reindex();
    try std.testing.expectEqual(@as(usize, 0), model.indexAt(-10));
    try std.testing.expectEqual(@as(usize, 0), model.indexAt(41));
    try std.testing.expectEqual(@as(usize, 2), model.indexAt(42));
    try std.testing.expectEqual(@as(usize, 2), model.indexAt(10000));
}
test "layout: invalidation preserves scroll anchors until the next measurement" {
    const blocks = [_]document.Block{ .{ .bytes = 100 }, .{ .bytes = 300 } };
    var model = try layout.Layout.init(a, blocks.len);
    defer model.deinit();
    _ = model.prepare(&blocks, 600, 1);
    const anchor = model.offsets[1];
    try std.testing.expect(!model.prepare(&blocks, 600, 1));
    model.invalidate();
    try std.testing.expectEqual(anchor, model.offsets[1]);
    try std.testing.expect(model.prepare(&blocks, 600, 1));
}
test "layout: narrow deeply indented content still has finite positive heights" {
    const blocks = [_]document.Block{ .{ .bytes = 900, .indent = 500, .quote = 500 }, .{ .kind = .code, .bytes = 500, .lines = 20 } };
    var model = try layout.Layout.init(a, blocks.len);
    defer model.deinit();
    _ = model.prepare(&blocks, 40, 2);
    for (model.heights) |height| try std.testing.expect(std.math.isFinite(height) and height > 0);
}
test "layout: wide tables distribute all available width at every zoom" {
    var columns: [40]document.TableColumn = undefined;
    for (&columns, 0..) |*column, i| column.* = .{ .characters = 1 + i * 5 };
    for ([_]usize{ 1, 2, 12, 40 }) |count| for ([_]f32{ 120, 600, 1440 }) |width| for ([_]f32{ 0.75, 1, 2 }) |zoom| {
        var total: f32 = 0;
        for (0..count) |i| {
            const w = layout.columnWidth(columns[0..count], i, width, zoom);
            try std.testing.expect(std.math.isFinite(w) and w > 0);
            total += w;
        }
        try std.testing.expectApproxEqAbs(width, total, 0.02);
    };
}
test "layout: empty and enormous table cell lengths still produce bounded widths" {
    const columns = [_]document.TableColumn{ .{ .characters = 0 }, .{ .characters = std.math.maxInt(usize) } };
    const left = layout.columnWidth(&columns, 0, 500, 1);
    const right = layout.columnWidth(&columns, 1, 500, 1);
    try std.testing.expect(left > 0 and right > left);
    try std.testing.expectApproxEqAbs(@as(f32, 500), left + right, 0.01);
}
test "layout: only the first two heading levels receive separator rules" {
    for (1..7) |level| try std.testing.expectEqual(level <= 2, layout.headingRule(.{ .kind = .heading, .heading = @intCast(level) }));
    try std.testing.expect(!layout.headingRule(.{}));
}
test "layout: minimap coordinates round-trip without losing the grab offset" {
    const map = layout.Minimap.init(600, 10000, 500);
    for (0..101) |i| {
        const scroll = map.max_scroll * @as(f32, @floatFromInt(i)) / 100;
        const top = map.thumbTop(scroll);
        try std.testing.expectApproxEqAbs(scroll, map.scrollAt(top + 9, 9), 0.01);
    }
}
test "layout: minimap offsets clamp outside the document" {
    const map = layout.Minimap.init(500, 10000, 500);
    try std.testing.expectEqual(@as(f32, 0), map.thumbTop(-100));
    try std.testing.expectEqual(map.height - map.thumb_height, map.thumbTop(1000000));
}
test "layout: a zero-height minimap is safe even with a long document" {
    const map = layout.Minimap.init(0, 10000, 500);
    try std.testing.expectEqual(@as(f32, 0), map.thumb_height);
    try std.testing.expectEqual(@as(f32, 0), map.scrollAt(100, 5));
}
