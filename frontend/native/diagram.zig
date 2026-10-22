//! Per-diagram zoom and inline controls. Pixels stay owned by the image worker;
//! changing view scale only reuses those pixels and updates one block's layout.
const std = @import("std");
const paint = @import("canvas.zig");
pub const Action = enum { smaller, reset, larger, fit };
pub const State = struct {
    zoom: f32 = 1,
    fit: bool = false,

    pub fn factor(self: State, available: f32, natural: f32) f32 {
        return if (self.fit) @min(1, @max(1, available) / @max(1, natural)) else self.zoom;
    }
    pub fn enabled(action: Action, current: f32) bool {
        return switch (action) { .smaller => current > 0.25, .larger => current < 2, else => true };
    }
    pub fn apply(self: *State, action: Action, current: f32) void {
        if (!enabled(action, current)) return;
        self.* = switch (action) {
            .reset => .{},
            .fit => .{ .fit = true },
            .smaller => .{ .zoom = std.math.clamp(current / 1.25, 0.25, 2) },
            .larger => .{ .zoom = std.math.clamp(current * 1.25, 0.25, 2) },
        };
    }
};
pub const Box = struct {
    x: f32, y: f32, width: f32, height: f32 = 28,
    pub fn contains(self: Box, x: f32, y: f32) bool {
        return x >= self.x and x < self.x + self.width and y >= self.y and y < self.y + self.height;
    }
};
pub const Controls = struct {
    boxes: [4]Box,
    height: f32,
    pub fn init(left: f32, top: f32, available: f32) Controls {
        const width = @max(28, available);
        var result: Controls = undefined;
        var x = left;
        var y = top + 2;
        for (&result.boxes, [_]f32{ 28, 62, 28, 44 }) |*box, preferred| {
            const w = @min(preferred, width);
            if (x > left and x + w > left + width) { x = left; y += 32; }
            box.* = .{ .x = x, .y = y, .width = w };
            x += w + 4;
        }
        result.height = y - top + 30;
        return result;
    }
    pub fn hit(self: Controls, x: f32, y: f32) ?Action {
        for (self.boxes, 0..) |box, index| if (box.contains(x, y)) return @enumFromInt(index);
        return null;
    }
    pub fn draw(self: Controls, canvas: *paint.Canvas, state: State, factor: f32, focused: bool) !void {
        const palette = canvas.palette;
        for (self.boxes, 0..) |box, index| {
            const action: Action = @enumFromInt(index);
            const selected = if (action == .fit) state.fit else action == .reset and !state.fit and @abs(factor - 1) < 0.001;
            const color: u32 = if (!State.enabled(action, factor)) palette.muted else if (selected) 0xffffff else palette.fg;
            canvas.rectangle(box.x, box.y, box.width, box.height, if (focused) palette.link else palette.border);
            canvas.rectangle(box.x + 1, box.y + 1, box.width - 2, box.height - 2, if (selected) 0x3276b0 else palette.panel);
            if (action == .smaller or action == .larger) {
                canvas.rectangle(box.x + box.width / 2 - 5, box.y + 13, 10, 2, color);
                if (action == .larger) canvas.rectangle(box.x + box.width / 2 - 1, box.y + 9, 2, 10, color);
            } else {
                var buffer: [24]u8 = undefined;
                const label = if (action == .fit) "Fit" else if (factor < 0.01) "<1%" else
                    try std.fmt.bufPrint(&buffer, "{d}%", .{@as(u32, @intFromFloat(@round(factor * 100)))});
                const style: paint.FontSpec = .{ .face = 0, .size = if (box.width < 40) 11 else 13 };
                const metrics = try canvas.measure(style, label);
                try canvas.text(style, label, box.x + (box.width - metrics.width) / 2,
                    box.y + (box.height + metrics.height) / 2 - metrics.descent, color);
            }
        }
    }
};
