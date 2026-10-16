const std = @import("std");
const c = @import("native");
const layout = @import("layout.zig");
const Allocator = std.mem.Allocator;

pub const Preset = enum {
    classic,
    paper,
    terminal,

    pub fn name(self: Preset) []const u8 {
        return switch (self) {
            .classic => "Classic",
            .paper => "Paper",
            .terminal => "Terminal",
        };
    }

    pub fn fontSize(self: Preset) u16 {
        return switch (self) {
            .classic => layout.default_font_size,
            .paper => 14,
            .terminal => 11,
        };
    }
};

// Dimensions use logical window units, independent of framebuffer pixels.
// Keep the normal rectangle when the window is maximized or minimized.
pub const Window = struct {
    width: i32 = 1040,
    height: i32 = 780,
    maximized: bool = false,
};

pub const Values = struct {
    save_settings_across_sessions: bool = false,
    theme: Preset = .classic,
    dark_mode: bool = false,
    font_size: u16 = layout.default_font_size,
    max_width: layout.MaxWidth = .percent_80,
    line_wrap: bool = true,
    show_toc: bool = true,
    show_preview: bool = true,
    auto_reload: bool = true,
    window: Window = .{},
};

pub fn decode(allocator: Allocator, json: []const u8) !Values {
    const parsed = try std.json.parseFromSlice(Values, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var values = parsed.value;
    if (!values.save_settings_across_sessions) return .{};
    values.font_size = std.math.clamp(values.font_size, layout.min_font_size, layout.max_font_size);
    if (values.window.width < 420 or values.window.width > 16384) values.window.width = 1040;
    if (values.window.height < 240 or values.window.height > 16384) values.window.height = 780;
    return values;
}

pub const Store = struct {
    allocator: Allocator,
    path: [:0]u8,

    pub fn init(allocator: Allocator, home: []const u8) !Store {
        if (!std.fs.path.isAbsolute(home)) return error.HomeDirectoryUnavailable;
        return .{ .allocator = allocator, .path = try std.fs.path.joinZ(allocator, &.{ home, ".config", "mdf", "settings.json" }) };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
    }

    pub fn load(self: *const Store) !Values {
        const fd = c.open(self.path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
        if (fd < 0) {
            if (c.__errno_location().* == c.ENOENT) return .{};
            return error.CannotReadSettings;
        }
        defer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG) return error.InvalidSettingsFile;
        var buffer: [16384]u8 = undefined;
        if (stat.st_size < 0 or stat.st_size >= buffer.len) return error.SettingsFileTooLarge;
        var length: usize = 0;
        while (length < buffer.len) {
            const n = c.read(fd, buffer[length..].ptr, buffer.len - length);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n < 0) return error.CannotReadSettings;
            if (n == 0) return decode(self.allocator, buffer[0..length]);
            length += @intCast(n);
        }
        return error.SettingsFileTooLarge;
    }

    pub fn save(self: *const Store, values: Values) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, values, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        const directory = try self.allocator.dupeZ(u8, std.fs.path.dirname(self.path).?);
        defer self.allocator.free(directory);
        for (directory, 0..) |ch, i| {
            if (ch != '/' or i == 0) continue;
            directory[i] = 0;
            const result = c.mkdir(directory.ptr, 0o700);
            directory[i] = '/';
            if (result != 0 and c.__errno_location().* != c.EEXIST) return error.CannotCreateSettingsDirectory;
        }
        if (c.mkdir(directory.ptr, 0o700) != 0 and c.__errno_location().* != c.EEXIST) return error.CannotCreateSettingsDirectory;

        // Write beside the destination and replace it atomically. mkstemp uses mode 0600.
        const temporary = try std.fmt.allocPrintSentinel(self.allocator, "{s}.tmp-XXXXXX", .{self.path}, 0);
        defer self.allocator.free(temporary);
        const fd = c.mkstemp(temporary.ptr);
        if (fd < 0) return error.CannotWriteSettings;
        defer _ = c.close(fd);
        defer _ = c.unlink(temporary.ptr);
        var offset: usize = 0;
        while (offset < json.len) {
            const n = c.write(fd, json[offset..].ptr, json.len - offset);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.CannotWriteSettings;
            offset += @intCast(n);
        }
        if (c.fsync(fd) != 0 or c.rename(temporary.ptr, self.path.ptr) != 0) return error.CannotWriteSettings;
    }

    pub fn clear(self: *const Store) !void {
        if (c.unlink(self.path.ptr) != 0 and c.__errno_location().* != c.ENOENT) return error.CannotRemoveSettings;
    }
};

test "settings decode defaults, partial files, invalid data, and bounds" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqualDeep(Values{}, try decode(allocator, "{}"));
    try std.testing.expectEqualDeep(Values{}, try decode(allocator, "{\"dark_mode\":true}"));
    const partial = try decode(allocator, "{\"save_settings_across_sessions\":true,\"font_family\":\"ubuntu_mono\",\"future_option\":1}");
    try std.testing.expect(partial.save_settings_across_sessions and partial.auto_reload);
    try std.testing.expectEqual(@as(u16, 12), partial.font_size);
    try std.testing.expectEqual(layout.MaxWidth.percent_80, partial.max_width);
    try std.testing.expect(partial.show_toc);
    try std.testing.expect(partial.show_preview);
    try std.testing.expect(partial.line_wrap);
    try std.testing.expect(!(try decode(allocator, "{\"save_settings_across_sessions\":true,\"line_wrap\":false}")).line_wrap);
    try std.testing.expect((try decode(allocator, "{\"line_wrap\":false}")).line_wrap);
    const legacy_width = try decode(allocator, "{\"save_settings_across_sessions\":true,\"max_width\":\"characters_80\",\"font_size\":18}");
    try std.testing.expectEqual(layout.MaxWidth.characters_100, legacy_width.max_width);
    try std.testing.expectEqual(@as(u16, 18), legacy_width.font_size);
    const bounded = try decode(allocator, "{\"save_settings_across_sessions\":true,\"font_size\":200,\"window\":{\"x\":2147483647,\"y\":0,\"width\":-1,\"height\":0}}");
    try std.testing.expectEqual(@as(u16, 72), bounded.font_size);
    try std.testing.expectEqualDeep(Window{}, bounded.window);
    const legacy_window = try decode(allocator, "{\"save_settings_across_sessions\":true,\"window\":{\"x\":150,\"y\":110,\"width\":900,\"height\":640,\"maximized\":true}}");
    try std.testing.expectEqualDeep(Window{ .width = 900, .height = 640, .maximized = true }, legacy_window.window);
    try std.testing.expectError(error.UnexpectedEndOfInput, decode(allocator, "{\"font_size\":"));
    // Legacy family values, including unknown/invalid types, are ignored.
    for ([_][]const u8{ "\"adwaita_sans\"", "\"ubuntu_mono\"", "\"missing\"", "null", "42" }) |family| {
        const legacy = try std.fmt.allocPrint(allocator, "{{\"save_settings_across_sessions\":true,\"font_family\":{s},\"theme\":\"paper\",\"dark_mode\":true,\"font_size\":19,\"show_toc\":false,\"show_preview\":false,\"auto_reload\":false,\"max_width\":\"percent_100\",\"window\":{{\"width\":900,\"height\":640,\"maximized\":true}}}}", .{family});
        defer allocator.free(legacy);
        try std.testing.expectEqualDeep(Values{
            .save_settings_across_sessions = true,
            .theme = .paper,
            .dark_mode = true,
            .font_size = 19,
            .show_toc = false,
            .show_preview = false,
            .auto_reload = false,
            .max_width = .percent_100,
            .window = .{ .width = 900, .height = 640, .maximized = true },
        }, try decode(allocator, legacy));
    }
}

test "settings store round trips, replaces complete JSON, and clears opt-in" {
    var template = "/tmp/mdf-settings-XXXXXX".*;
    const home = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, std.mem.span(home)) catch {};
    var store = try Store.init(std.testing.allocator, std.mem.span(home));
    defer store.deinit();
    try std.testing.expect(std.mem.endsWith(u8, store.path, "/.config/mdf/settings.json"));
    try std.testing.expectEqualDeep(Values{}, try store.load());
    var values = Values{
        .save_settings_across_sessions = true,
        .theme = .paper,
        .dark_mode = true,
        .font_size = 23,
        .max_width = .characters_100,
        .line_wrap = false,
        .show_toc = false,
        .show_preview = false,
        .auto_reload = false,
        .window = .{ .width = 900, .height = 640, .maximized = true },
    };
    try store.save(values);
    try std.testing.expectEqualDeep(values, try store.load());
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(store.path.ptr, &stat));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), stat.st_mode & 0o777);
    values.dark_mode = false;
    values.font_size = 9;
    values.line_wrap = true;
    try store.save(values);
    try std.testing.expectEqualDeep(values, try store.load());
    // A failed replacement must leave the previous complete file readable.
    var blocked = try Store.init(std.testing.allocator, store.path);
    defer blocked.deinit();
    try std.testing.expectError(error.CannotCreateSettingsDirectory, blocked.save(values));
    try std.testing.expectEqualDeep(values, try store.load());
    const fd = c.open(store.path.ptr, c.O_WRONLY | c.O_TRUNC);
    try std.testing.expect(fd >= 0);
    try std.testing.expectEqual(@as(isize, 1), c.write(fd, "{", 1));
    _ = c.close(fd);
    try std.testing.expectError(error.UnexpectedEndOfInput, store.load());
    try store.clear();
    try store.clear();
    try std.testing.expectEqualDeep(Values{}, try store.load());
}
