const std = @import("std");
const measure = @import("mdf").measurement;
const document = @import("mdf").document;
const flow = @import("mdf").flow;
const a = std.testing.allocator;
fn metrics(_: ?*anyopaque, font: measure.Font, _: [*]const u8, len: usize) callconv(.c) flow.Metrics {
    return .{ .width = @as(f32, @floatFromInt(len)) * @as(f32, @floatFromInt(font.size)),
        .height = @floatFromInt(font.size), .descent = 2 };
}
test "measurement: small text truncates the rounded base size and preserves face selection" {
    const small = measure.font(.{ .kind = .heading, .heading = 1 }, 64 | 2, 1, false);
    try std.testing.expectEqual(@as(i32, 28), small.size);
    try std.testing.expectEqual(@as(u32, 3), small.face);
    try std.testing.expectEqual(@as(u32, 1), measure.font(.{}, 4, 1, true).flags);
    try std.testing.expectEqual(@as(u32, 0), measure.font(.{}, 4, 1, false).flags);
}
const rows = [_]document.Block{
    .{ .kind = .table_row, .table_header = true, .cells = &.{
        .{ .spans = &.{ .{ .text = "ab", .bold = true }, .{ .text = "cd" } } },
        .{ .spans = &.{.{ .text = "x y\nzz" }} },
    } },
    .{ .kind = .table_row, .cells = &.{
        .{ .spans = &.{.{ .text = "a" }} },
        .{ .spans = &.{.{ .text = "z" }} },
    } },
};
test "measurement: styled fragments remain one word and explicit newlines reset preferred width" {
    const widths = try measure.tableColumns(a, &rows, 1, 1, 1, false, false, metrics, null);
    defer a.free(widths);
    try std.testing.expectEqualSlices(f32, &.{ 85, 68 }, widths);
}
test "measurement: wrapping preserves readable cells when many columns overflow" {
    var cells: [40]document.TableCell = undefined;
    for (&cells) |*cell| cell.* = .{ .spans = &.{.{ .text = "x" }} };
    const blocks = [_]document.Block{.{ .kind = .table_row, .table_header = true, .cells = &cells }};
    const widths = try measure.tableColumns(a, &blocks, 0, 320, 1, true, false, metrics, null);
    defer a.free(widths);
    var total: f32 = 0;
    for (widths) |width| {
        try std.testing.expectEqual(@as(f32, 34), width);
        total += width;
    }
    try std.testing.expectEqual(@as(f32, 1360), total);
}
test "measurement: invalid rows and nonfinite metrics fail before column allocation escapes" {
    try std.testing.expectError(error.InvalidTable, measure.tableColumns(a, &rows, 10, 300, 1, true, false, metrics, null));
    const bad_rows = [_]document.Block{
        .{ .kind = .table_row, .table_header = true },
        .{ .kind = .table_row, .cells = &.{.{ .spans = &.{} }} },
    };
    try std.testing.expectError(error.InconsistentTable, measure.tableColumns(a, &bad_rows, 0, 300, 1, true, false, metrics, null));
    const bad = struct {
        fn metrics(_: ?*anyopaque, _: measure.Font, _: [*]const u8, _: usize) callconv(.c) flow.Metrics {
            return .{ .width = std.math.nan(f32), .height = 17, .descent = 2 };
        }
    };
    try std.testing.expectError(error.InvalidMetrics, measure.tableColumns(a, &rows, 0, 300, 1, true, false, bad.metrics, null));
}
fn allocationCheck(allocator: std.mem.Allocator) !void {
    const widths = try measure.tableColumns(allocator, &rows, 0, 300, 1, true, false, metrics, null);
    defer allocator.free(widths);
}
test "measurement: allocation failures release intrinsic measurement temporaries" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
}
