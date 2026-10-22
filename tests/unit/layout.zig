const std = @import("std");
const layout = @import("mdf").layout;
const document = @import("mdf").document;
const a = std.testing.allocator;

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
