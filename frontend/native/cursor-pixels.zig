//! Small immutable cursor masks, with no theme files or cursor library.
pub const size = 24;
pub const Kind = enum { arrow, text, hand, horizontal, vertical, nwse, nesw };
pub const count = @typeInfo(Kind).@"enum".field_names.len;
pub fn hotspot(kind: Kind) [2]i32 {
    return switch (kind) {
        .arrow => .{ 3, 3 },
        .hand => .{ 10, 3 },
        else => .{ 12, 12 },
    };
}
fn line(x: i32, y: i32, ax: i32, ay: i32, bx: i32, by: i32) bool {
    const dx = bx - ax;
    const dy = by - ay;
    const dot = (x - ax) * dx + (y - ay) * dy;
    const length = dx * dx + dy * dy;
    const cross = (x - ax) * dy - (y - ay) * dx;
    return dot >= 0 and dot <= length and cross * cross <= @divTrunc(length, 2);
}
fn polygon(points: []const [2]i32, x: i32, y: i32) bool {
    var inside = false;
    var j = points.len - 1;
    for (points, 0..) |p, i| {
        const q = points[j];
        if ((p[1] > y) != (q[1] > y)) {
            const crossing = @as(f32, @floatFromInt(q[0] - p[0])) * @as(f32, @floatFromInt(y - p[1])) /
                @as(f32, @floatFromInt(q[1] - p[1])) + @as(f32, @floatFromInt(p[0]));
            if (@as(f32, @floatFromInt(x)) < crossing) inside = !inside;
        }
        j = i;
    }
    return inside;
}
fn shape(kind: Kind, x: i32, y: i32) bool {
    return switch (kind) {
        .arrow => polygon(&.{ .{ 3, 2 }, .{ 3, 20 }, .{ 8, 15 }, .{ 12, 23 }, .{ 15, 21 }, .{ 11, 13 }, .{ 20, 13 } }, x, y),
        .hand => polygon(&.{ .{ 9, 2 }, .{ 12, 2 }, .{ 12, 10 }, .{ 19, 10 }, .{ 20, 14 }, .{ 17, 22 }, .{ 9, 22 }, .{ 4, 14 }, .{ 6, 12 }, .{ 9, 15 } }, x, y),
        .text => line(x, y, 12, 3, 12, 21) or line(x, y, 8, 3, 16, 3) or line(x, y, 8, 21, 16, 21),
        .horizontal => line(x, y, 4, 12, 20, 12) or line(x, y, 4, 12, 8, 8) or line(x, y, 4, 12, 8, 16) or
            line(x, y, 20, 12, 16, 8) or line(x, y, 20, 12, 16, 16),
        .vertical => shape(.horizontal, y, x),
        .nwse => line(x, y, 5, 5, 19, 19) or line(x, y, 5, 5, 5, 11) or line(x, y, 5, 5, 11, 5) or
            line(x, y, 19, 19, 19, 13) or line(x, y, 19, 19, 13, 19),
        .nesw => shape(.nwse, 23 - x, y),
    };
}
pub fn render(kind: Kind, output: *[size * size]u32) void {
    for (output, 0..) |*pixel, index| {
        const x: i32 = @intCast(index % size);
        const y: i32 = @intCast(index / size);
        pixel.* = if (shape(kind, x, y)) 0xff101010 else if (shape(kind, x - 1, y) or shape(kind, x + 1, y) or shape(kind, x, y - 1) or shape(kind, x, y + 1)) 0xffffffff else 0;
    }
}
