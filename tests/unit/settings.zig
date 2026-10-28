const std = @import("std");
const settings = @import("mdf").settings;
const a = std.testing.allocator;

fn opted(extra: []const u8) !settings.Values {
    const text = try std.fmt.allocPrint(a, "{{\"save_settings_across_sessions\":true,{s}}}", .{extra});
    defer a.free(text);
    return settings.decode(a, text);
}
fn invalid(text: []const u8) !void {
    if (settings.decode(a, text)) |_| return error.ExpectedInvalidSettings else |_| {}
}

test "settings: disabling persistence discards otherwise valid custom preferences" {
    const values = try settings.decode(a, "{\"save_settings_across_sessions\":false,\"font_size\":55,\"theme\":\"terminal\",\"line_wrap\":false}");
    try std.testing.expectEqualDeep(settings.Values{ .save_settings_across_sessions = false }, values);
}
test "settings: the minimum font size is accepted and smaller values clamp" {
    try std.testing.expectEqual(@as(u16, 8), (try opted("\"font_size\":0")).font_size);
    try std.testing.expectEqual(@as(u16, 8), (try opted("\"font_size\":8")).font_size);
}
test "settings: the maximum font size is accepted and larger values clamp" {
    try std.testing.expectEqual(@as(u16, 72), (try opted("\"font_size\":72")).font_size);
    try std.testing.expectEqual(@as(u16, 72), (try opted("\"font_size\":65535")).font_size);
}
test "settings: valid window dimension endpoints survive loading" {
    const low = try opted("\"window\":{\"width\":420,\"height\":240}");
    const high = try opted("\"window\":{\"width\":16384,\"height\":16384}");
    try std.testing.expectEqual(@as(i32, 420), low.window.width);
    try std.testing.expectEqual(@as(i32, 240), low.window.height);
    try std.testing.expectEqual(@as(i32, 16384), high.window.width);
    try std.testing.expectEqual(@as(i32, 16384), high.window.height);
}
test "settings: invalid dimensions reset independently" {
    const wide = try opted("\"window\":{\"width\":16385,\"height\":700}");
    const short = try opted("\"window\":{\"width\":900,\"height\":239}");
    try std.testing.expectEqual(@as(i32, 1040), wide.window.width);
    try std.testing.expectEqual(@as(i32, 700), wide.window.height);
    try std.testing.expectEqual(@as(i32, 900), short.window.width);
    try std.testing.expectEqual(@as(i32, 780), short.window.height);
}
test "settings: every built-in theme survives the stored preference format" {
    for (std.meta.tags(settings.Preset)) |theme| {
        const values = settings.Values{ .save_settings_across_sessions = true, .theme = theme };
        const text = try std.json.Stringify.valueAlloc(a, values, .{});
        defer a.free(text);
        try std.testing.expectEqual(theme, (try settings.decode(a, text)).theme);
    }
}
test "settings: all current width modes survive serialization" {
    for (std.meta.tags(@import("mdf").layout.MaxWidth)) |mode| {
        const values = settings.Values{ .save_settings_across_sessions = true, .max_width = mode };
        const text = try std.json.Stringify.valueAlloc(a, values, .{});
        defer a.free(text);
        try std.testing.expectEqual(mode, (try settings.decode(a, text)).max_width);
    }
}
test "settings: hidden panels no-wrap and disabled reload are preserved together" {
    const values = try opted("\"show_toc\":false,\"show_preview\":false,\"line_wrap\":false,\"auto_reload\":false");
    try std.testing.expect(!values.show_toc and !values.show_preview and !values.line_wrap and !values.auto_reload);
}
test "settings: wrong scalar types and overflowing integers are rejected" {
    for ([_][]const u8{ "{\"font_size\":-1}", "{\"font_size\":65536}", "{\"font_size\":null}", "{\"dark_mode\":1}", "{\"window\":[]}", "[]", "null" }) |text| try invalid(text);
}
test "settings: unknown enum values and incomplete JSON are rejected" {
    for ([_][]const u8{ "{\"theme\":\"missing\"}", "{\"max_width\":\"missing\"}", "{", "{\"window\":" }) |text| try invalid(text);
}
test "settings: future nested fields do not change known preferences" {
    const values = try opted("\"font_size\":18,\"future\":{\"array\":[1,null,true]},\"window\":{\"width\":900,\"future\":{\"x\":1}}");
    try std.testing.expectEqual(@as(u16, 18), values.font_size);
    try std.testing.expectEqual(@as(i32, 900), values.window.width);
}
test "settings: a relative home directory is never used for persistence" {
    try std.testing.expectError(error.HomeDirectoryUnavailable, settings.Store.init(a, "relative/home"));
    try std.testing.expectError(error.HomeDirectoryUnavailable, settings.Store.init(a, ""));
}
