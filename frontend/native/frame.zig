//! Client window controls share the existing menu band, preserving body bounds.
const std = @import("std");
const paint = @import("canvas.zig");
pub const cursors = @import("cursor-pixels.zig");
// xdg_toplevel.resize edge values from the stable xdg-shell protocol.
pub const Edge = enum(u32) { top = 1, bottom = 2, left = 4, top_left = 5, bottom_left = 6, right = 8, top_right = 9, bottom_right = 10 };
pub const Hit = union(enum) { none, move, minimize, maximize, close, resize: Edge };
pub const Clicks = struct {
    last: ?u32 = null,
    pub fn press(self: *Clicks, time: u32) bool {
        if (time == 0) {
            self.last = null;
            return false;
        }
        const double = if (self.last) |at| time -% at < 400 else false;
        self.last = if (double) null else time;
        return double;
    }
};

pub fn hit(x: f32, y: f32, width: i32, height: i32, constrained: bool) Hit {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or x >= w or y >= h) return .none;
    if (!constrained) {
        const left = x < 4;
        const right = x >= w - 4;
        const top = y < 4;
        const bottom = y >= h - 4;
        if (top and left) return .{ .resize = .top_left };
        if (top and right) return .{ .resize = .top_right };
        if (bottom and left) return .{ .resize = .bottom_left };
        if (bottom and right) return .{ .resize = .bottom_right };
        if (left) return .{ .resize = .left };
        if (right) return .{ .resize = .right };
        if (top) return .{ .resize = .top };
        if (bottom) return .{ .resize = .bottom };
    }
    if (y >= 28) return .none;
    if (x >= w - 32 and x < w - 4) return .close;
    if (x >= w - 60 and x < w - 32) return .maximize;
    if (x >= w - 88 and x < w - 60) return .minimize;
    if (x >= 340 and x < w - 92) return .move;
    return .none;
}
pub fn cursor(value: Hit) cursors.Kind {
    return switch (value) {
        .resize => |edge| switch (edge) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
            .top_left, .bottom_right => .nwse,
            .top_right, .bottom_left => .nesw,
        },
        else => .arrow,
    };
}
pub fn control(value:Hit) std.meta.Tag(Hit) {
    return switch(value) {.minimize=>.minimize,.maximize=>.maximize,.close=>.close,else=>.none};
}
pub fn draw(canvas: *paint.Canvas, title: []const u8, constrained: bool, hover: Hit) !void {
    const w = canvas.logical_width;
    const h = canvas.logical_height;
    const p = canvas.palette;
    if (!constrained) {
        canvas.rectangle(0, 0, @floatFromInt(w), 1, p.border);
        canvas.rectangle(0, @floatFromInt(h - 1), @floatFromInt(w), 1, p.border);
        canvas.rectangle(0, 0, 1, @floatFromInt(h), p.border);
        canvas.rectangle(@floatFromInt(w - 1), 0, 1, @floatFromInt(h), p.border);
    }
    const hovered = control(hover);
    for ([_]std.meta.Tag(Hit){ .minimize, .maximize, .close }, 0..) |button, index| {
        const x: f32 = @floatFromInt(w - 88 + @as(i32, @intCast(index)) * 28);
        if (hovered == button) canvas.rectangle(x, 2, 28, 24, if (button == .close) 0xc84444 else p.border);
        const color = if (hovered == .close and button == .close) 0xffffff else p.fg;
        switch (button) {
            .minimize => canvas.rectangle(x + 9, 17, 10, 1, color),
            .maximize => {
                if (constrained) {
                    canvas.rectangle(x + 11, 7, 10, 9, color);
                    canvas.rectangle(x + 12, 8, 8, 7, p.panel);
                }
                canvas.rectangle(x + 8, 10, 10, 9, color);
                canvas.rectangle(x + 9, 11, 8, 7, p.panel);
            },
            .close => for (0..10) |i| {
                const step: f32 = @floatFromInt(i);
                canvas.rectangle(x + 9 + step, 9 + step, 1, 1, color);
                canvas.rectangle(x + 18 - step, 9 + step, 1, 1, color);
            },
            else => unreachable,
        }
    }
    if (w > 480 and title.len > 0) {
        const style: paint.FontSpec = .{ .face = 0, .size = 12, .flags = 0 };
        const available: f32 = @floatFromInt(w - 440);
        var end = title.len;
        while (end > 0 and (try canvas.measure(style, title[0..end])).width > available) {
            end -= 1;
            while (end > 0 and title[end] & 0xc0 == 0x80) end -= 1;
        }
        try canvas.text(style, title[0..end], 350, 19, p.muted);
    }
}
