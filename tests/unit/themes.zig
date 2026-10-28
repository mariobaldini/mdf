const std = @import("std");
const themes = @import("mdf").themes;
const c = @import("mdf").native;

fn luminance(color: u32) f64 {
    var result: f64 = 0;
    for ([_]u5{ 16, 8, 0 }, [_]f64{ 0.2126, 0.7152, 0.0722 }) |shift, weight| {
        const channel = @as(f64, @floatFromInt((color >> shift) & 255)) / 255;
        const linear = if (channel <= 0.04045) channel / 12.92 else std.math.pow(f64, (channel + 0.055) / 1.055, 2.4);
        result += linear * weight;
    }
    return result;
}
fn contrast(a: u32, b: u32) f64 {
    const x = luminance(a);
    const y = luminance(b);
    return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
}
test "themes: legacy IDs remain stable and every preset has distinct light and dark palettes" {
    const existing = [_]themes.Preset{ .classic, .paper, .terminal, .nord, .solarized, .gruvbox, .catppuccin };
    for (existing, 0..) |theme, index|
        try std.testing.expectEqual(@as(u32, @intCast(index)), @backingInt(theme));
    try std.testing.expectEqual(@as(usize, 10), std.meta.tags(themes.Preset).len);
    try std.testing.expectEqual(themes.Preset.classic, themes.menu_order[0]);
    try std.testing.expectEqual(themes.Preset.ink, themes.menu_order[1]);
    for (std.meta.tags(themes.Preset)) |theme| {
        try std.testing.expect(theme.name().len > 0);
        try std.testing.expect(theme.fontSize() >= 11 and theme.fontSize() <= 14);
        try std.testing.expectEqual(theme, themes.fromName(@tagName(theme)));
        try std.testing.expect(theme.palette(false).bg != theme.palette(true).bg);
    }
    try std.testing.expectEqual(themes.Preset.ink, themes.fromName("unknown"));
}
test "themes: catalog and RGB records cross the C boundary without conversion drift" {
    const all = std.meta.tags(themes.Preset);
    try std.testing.expectEqual(all.len, c.mdf_theme_count());
    for (all, 0..) |theme, index| {
        const info = c.mdf_theme_info(index);
        try std.testing.expectEqualStrings(@tagName(theme), info.id.ptr[0..info.id.len]);
        try std.testing.expectEqualStrings(theme.name(), info.name.ptr[0..info.name.len]);
        try std.testing.expectEqual(@as(u32, theme.fontSize()), info.font_size);
        try std.testing.expectEqual(@as(u32, @intCast(index)), c.mdf_theme_index(info.id.ptr, info.id.len));
        for ([_]bool{ false, true }) |dark| {
            const actual = c.mdf_theme_palette(@intCast(index), dark);
            const expected = theme.palette(dark);
            inline for (@typeInfo(themes.Palette).@"struct".field_names) |field|
                try std.testing.expectEqual(@field(expected, field), @field(actual, field));
        }
    }
    try std.testing.expectEqual(@as(usize, 0), c.mdf_theme_info(999).id.len);
    try std.testing.expectEqual(all.len, themes.menu_order.len);
    var seen: [all.len]bool = @splat(false);
    for (themes.menu_order, 0..) |theme, position| {
        const index = @backingInt(theme);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
        const info = c.mdf_theme_menu_info(position);
        try std.testing.expectEqualStrings(@tagName(theme), info.id.ptr[0..info.id.len]);
        try std.testing.expectEqualStrings(theme.name(), info.name.ptr[0..info.name.len]);
    }
    try std.testing.expectEqual(@as(usize, 0), c.mdf_theme_menu_info(999).id.len);
    try std.testing.expectEqual(themes.Preset.ink.palette(false).fg, c.mdf_theme_palette(999, false).fg);
}
test "themes: text links labels highlights and selected text retain readable contrast" {
    for (std.meta.tags(themes.Preset)) |theme| for ([_]bool{ false, true }) |dark| {
        errdefer std.debug.print("Contrast check failed for {s}, dark={any}\n", .{ @tagName(theme), dark });
        const p = theme.palette(dark);
        // Body copy, code, and table text use the same foreground on these surfaces.
        try std.testing.expect(contrast(p.fg, p.bg) >= 7);
        try std.testing.expect(contrast(p.fg, p.panel) >= 7);
        for ([_]u32{ p.bg, p.panel }) |background| {
            for ([_]u32{ p.fg, p.link, p.muted, p.note, p.tip, p.important, p.warning, p.caution }) |foreground|
                try std.testing.expect(contrast(foreground, background) >= 4.5);
        }
        try std.testing.expect(contrast(p.fg, p.selection) >= 4.5);
        try std.testing.expect(contrast(p.link, p.selection) >= 4.5);
        try std.testing.expect(contrast(p.fg, p.highlight) >= 4.5);
        try std.testing.expect(contrast(if (dark) p.bg else 0xffffff, p.link) >= 4.5);
    };
}
