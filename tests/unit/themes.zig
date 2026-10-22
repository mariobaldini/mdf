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
    try std.testing.expectEqual(@as(u32, 0), @backingInt(themes.Preset.classic));
    try std.testing.expectEqual(@as(u32, 1), @backingInt(themes.Preset.paper));
    try std.testing.expectEqual(@as(u32, 2), @backingInt(themes.Preset.terminal));
    try std.testing.expectEqual(@as(usize, 7), std.meta.tags(themes.Preset).len);
    for (std.meta.tags(themes.Preset)) |theme| {
        try std.testing.expect(theme.name().len > 0);
        try std.testing.expect(theme.fontSize() >= 11 and theme.fontSize() <= 14);
        try std.testing.expectEqual(theme, themes.fromName(@tagName(theme)));
        try std.testing.expect(theme.palette(false).bg != theme.palette(true).bg);
    }
    try std.testing.expectEqual(themes.Preset.classic, themes.fromName("unknown"));
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
    try std.testing.expectEqual(themes.Preset.classic.palette(false).bg, c.mdf_theme_palette(999, false).bg);
}
test "themes: text links labels highlights and selected text retain readable contrast" {
    for (std.meta.tags(themes.Preset)) |theme| for ([_]bool{ false, true }) |dark| {
        const p = theme.palette(dark);
        for ([_]u32{ p.bg, p.panel }) |background| {
            for ([_]u32{ p.fg, p.link, p.muted, p.note, p.tip, p.important, p.warning, p.caution }) |foreground|
                try std.testing.expect(contrast(foreground, background) >= 4.5);
        }
        try std.testing.expect(contrast(p.fg, p.selection) >= 4.5);
        try std.testing.expect(contrast(p.fg, p.highlight) >= 4.5);
        try std.testing.expect(contrast(if (dark) p.bg else 0xffffff, p.link) >= 4.5);
    };
}
