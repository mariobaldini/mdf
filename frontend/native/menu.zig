//! Allocation-free menu state. Drawing and commands belong to the shell/window.
const std = @import("std");
pub const Theme = @import("settings").Preset;
const theme_order = @import("settings").theme_menu_order;
pub const Command = union(enum) {
    open, reload, quit, toc, preview, wrap, width80, width100, copy, select_all,
    larger, smaller, reset_size, size: i32, theme: Theme,
    auto_reload, save_settings, reset_settings, about, licenses,
};
pub const Title = enum { file, view, font, theme, settings, help };
pub const names = [_][]const u8{ "File", "View", "Font", "Theme", "Settings", "Help" };
pub const positions = [_]i32{ 12, 56, 106, 152, 217, 292 };
pub const Item = struct { name: []const u8, command: Command, shortcut: []const u8 = "" };
const file = [_]Item{
    .{ .name = "Open...", .command = .open, .shortcut = "Ctrl+O" },
    .{ .name = "Reload", .command = .reload, .shortcut = "Ctrl+R" },
    .{ .name = "Quit", .command = .quit, .shortcut = "Ctrl+Q" },
};
const view = [_]Item{
    .{ .name = "Table of contents", .command = .toc },
    .{ .name = "Preview", .command = .preview },
    .{ .name = "Line wrap", .command = .wrap },
    .{ .name = "80% width", .command = .width80 },
    .{ .name = "100% width", .command = .width100 },
    .{ .name = "Copy selection", .command = .copy, .shortcut = "Ctrl+C" },
    .{ .name = "Select all", .command = .select_all, .shortcut = "Ctrl+A" },
};
const font = makeFonts();
fn makeFonts() [20]Item {
    var result: [20]Item = undefined;
    result[0] = .{ .name = "Larger", .command = .larger, .shortcut = "Ctrl++" };
    result[1] = .{ .name = "Smaller", .command = .smaller, .shortcut = "Ctrl+-" };
    result[2] = .{ .name = "Default size", .command = .reset_size, .shortcut = "Ctrl+0" };
    for ([_]i32{ 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 56, 64, 72 }, 3..) |size, index|
        result[index] = .{ .name = std.fmt.comptimePrint("{d} pt", .{size}), .command = .{ .size = size } };
    return result;
}
const theme = makeThemes();
fn makeThemes() [theme_order.len]Item {
    var result: [theme_order.len]Item = undefined;
    for (theme_order, 0..) |value, index|
        result[index] = .{ .name = value.name(), .command = .{ .theme = value } };
    return result;
}
const settings = [_]Item{
    .{ .name = "Automatic reload", .command = .auto_reload },
    .{ .name = "Save settings across sessions", .command = .save_settings },
    .{ .name = "Reset settings", .command = .reset_settings },
};
const help = [_]Item{
    .{ .name = "About Markdown FAST", .command = .about },
    .{ .name = "Third-party licenses", .command = .licenses },
};
pub fn items(title: Title) []const Item {
    return switch (title) { .file => &file, .view => &view, .font => &font, .theme => &theme, .settings => &settings, .help => &help };
}
pub const Bounds = struct { x: i32, y: i32 = 28, width: i32, rows: usize };
pub const Result = struct { handled: bool = false, command: ?Command = null };
pub const Menu = struct {
    opened: ?Title = null,
    selected: usize = 0,
    first: usize = 0,

    pub fn bounds(self: Menu, width: i32, height: i32) Bounds {
        const title = self.opened orelse .file;
        const w = @max(1, @min(320, width - 16));
        return .{ .x = std.math.clamp(positions[@intFromEnum(title)] - 8, 0, @max(0, width - w)), .width = w,
            .rows = @min(items(title).len, @as(usize, @intCast(@max(1, @divTrunc(height - 36, 26))))) };
    }
    fn titleAt(x: f32, y: f32) ?Title {
        if (y < 0 or y >= 28) return null;
        for (positions, 0..) |position, index| {
            const right = if (index + 1 < positions.len) positions[index + 1] - 6 else position + 42;
            if (x >= @as(f32, @floatFromInt(position - 8)) and x < @as(f32, @floatFromInt(right))) return @enumFromInt(index);
        }
        return null;
    }
    fn rowAt(self: Menu, x: f32, y: f32, width: i32, height: i32) ?usize {
        if (self.opened == null) return null;
        const box = self.bounds(width, height);
        if (x < @as(f32, @floatFromInt(box.x)) or x >= @as(f32, @floatFromInt(box.x + box.width)) or y < 32) return null;
        const row: usize = @intFromFloat((y - 32) / 26);
        return if (row < box.rows) self.first + row else null;
    }
    pub fn press(self: *Menu, x: f32, y: f32, width: i32, height: i32) Result {
        self.fit(width, height);
        if (titleAt(x, y)) |title| {
            self.opened = if (self.opened == title) null else title;
            self.selected = 0; self.first = 0;
            return .{ .handled = true };
        }
        if (self.opened) |title| {
            const row = self.rowAt(x, y, width, height);
            self.opened = null;
            return .{ .handled = true, .command = if (row) |index| items(title)[index].command else null };
        }
        return .{};
    }
    pub fn hover(self: *Menu, x: f32, y: f32, width: i32, height: i32) bool {
        if (self.opened == null) return false;
        self.fit(width, height);
        const before = self.*;
        if (titleAt(x, y)) |title| {
            if (self.opened != title) { self.opened = title; self.first = 0; self.selected = 0; }
        } else if (self.rowAt(x, y, width, height)) |row| self.selected = row;
        return before.opened != self.opened or before.selected != self.selected;
    }
    pub fn move(self: *Menu, delta: i32, width: i32, height: i32) void {
        const count = items(self.opened orelse return).len;
        self.selected = @intCast(@mod(@as(i32, @intCast(self.selected)) + delta, @as(i32, @intCast(count))));
        const rows = self.bounds(width, height).rows;
        if (self.selected < self.first) self.first = self.selected;
        if (self.selected >= self.first + rows) self.first = self.selected + 1 - rows;
    }
    pub fn fit(self: *Menu, width: i32, height: i32) void {
        const count = items(self.opened orelse return).len;
        self.selected = @min(self.selected, count - 1);
        const rows = self.bounds(width, height).rows;
        self.first = @min(self.first, count - rows);
        if (self.selected < self.first) self.first = self.selected;
        if (self.selected >= self.first + rows) self.first = self.selected + 1 - rows;
    }
    pub fn accept(self: *Menu) ?Command {
        const title = self.opened orelse return null;
        self.opened = null;
        return items(title)[self.selected].command;
    }
};
