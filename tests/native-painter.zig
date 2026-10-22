const std = @import("std");
const paint = @import("native_canvas");
const a = std.testing.allocator;

test "native canvas: ARGB storage matches Wayland channel order and clips rectangles" {
    var canvas = try paint.Canvas.init(a, 5, 4, .{});
    defer canvas.deinit();
    canvas.clear();
    canvas.rectangle(-2, -1, 4, 3, 0xff0000);
    const pixels = canvas.surface.image_surface_argb.buf;
    for (pixels, 0..) |pixel, index| {
        const red = index % 5 < 2 and index / 5 < 2;
        try std.testing.expectEqual(@as(u8, 255), pixel.r);
        try std.testing.expectEqual(@as(u8, if (red) 0 else 255), pixel.g);
        try std.testing.expectEqual(@as(u8, if (red) 0 else 255), pixel.b);
        try std.testing.expectEqual(@as(u8, 255), pixel.a);
    }
    try std.testing.expectEqual(@as(u32, 0xffff0000), @as(u32, @bitCast(pixels[0])));
}
test "native canvas: proportional metrics scale and optional italic faces stay unloaded" {
    var canvas = try paint.Canvas.init(a, 200, 80, .{});
    defer canvas.deinit();
    const regular: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 0 };
    const narrow = try canvas.measure(regular, "iiii");
    const wide = try canvas.measure(regular, "WWWW");
    try std.testing.expect(wide.width > narrow.width and narrow.height > 0);
    const doubled = try canvas.measure(.{ .face = 0, .size = 34, .flags = 0 }, "iiii");
    try std.testing.expectApproxEqAbs(narrow.width * 2, doubled.width, 0.001);
    _ = try canvas.measure(.{ .face = 1, .size = 17, .flags = 0 }, "Bold");
    try std.testing.expectEqual(@as(u32, 3), canvas.loaded_styles);
}
test "native canvas: glyph drawing respects color and leaves the background intact" {
    var canvas = try paint.Canvas.init(a, 160, 70, .{});
    defer canvas.deinit();
    canvas.clear();
    try canvas.text(.{ .face = 0, .size = 24, .flags = 0 }, "Hello", 15, 40, 0x3276b0);
    var ink: usize = 0;
    for (canvas.surface.image_surface_argb.buf) |pixel| {
        if (pixel.r != 255 or pixel.g != 255 or pixel.b != 255) {
            ink += 1;
            try std.testing.expect(pixel.b >= pixel.g and pixel.g >= pixel.r);
        }
        try std.testing.expectEqual(@as(u8, 255), pixel.a);
    }
    try std.testing.expect(ink > 50 and ink < 2500);
    try std.testing.expectEqual(@as(u32, 0xffffffff), @as(u32, @bitCast(canvas.surface.image_surface_argb.buf[0])));
}
test "native canvas: invalid sizes fail without retaining partial surface storage" {
    try std.testing.expectError(error.InvalidWidth, paint.Canvas.init(a, 0, 10, .{}));
}
test "native canvas: resize preserves font measurements and survives invalid dimensions" {
    var canvas = try paint.Canvas.init(a, 100, 50, .{});
    defer canvas.deinit();
    const style: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 0 };
    const before = try canvas.measure(style, "Retained");
    const calls = canvas.measurement_calls;
    try std.testing.expect(try canvas.resize(70, 80));
    try std.testing.expect(!(try canvas.resize(70, 80)));
    try std.testing.expectError(error.InvalidWidth, canvas.resize(0, 80));
    try std.testing.expectEqual(@as(i32, 70), canvas.surface.getWidth());
    try std.testing.expectEqual(@as(i32, 80), canvas.surface.getHeight());
    const after = try canvas.measure(style, "Retained");
    try std.testing.expectEqual(before.width, after.width);
    try std.testing.expectEqual(calls, canvas.measurement_calls);
    canvas.clear();
    canvas.rectangle(68, 78, 20, 20, 0x3276b0);
    try std.testing.expectEqual(@as(u32, 0xff3276b0), @as(u32, @bitCast(canvas.surface.image_surface_argb.buf[70 * 80 - 1])));
}
test "native canvas: scaled RGBA interpolates premultiplied colors without transparent halos" {
    var canvas = try paint.Canvas.init(a, 4, 1, .{});
    defer canvas.deinit();
    canvas.clear();
    var rgba: [8]u8 = .{ 255, 0, 0, 255, 0, 0, 255, 0 };
    canvas.image(.{ .data = &rgba, .width = 2, .height = 1, .channels = 4 }, 0, 0, 4, 1);
    const expected: [4]u32 = .{ 0xffff0000, 0xffff4040, 0xffffbfbf, 0xffffffff };
    for (canvas.surface.image_surface_argb.buf, expected) |value, color| try std.testing.expectEqual(color, @as(u32, @bitCast(value)));
}
test "native canvas: image clipping and grayscale alpha preserve opaque destinations" {
    var canvas = try paint.Canvas.init(a, 2, 2, .{});
    defer canvas.deinit();
    canvas.clear();
    var rgb: [3]u8 = .{ 0, 255, 0 };
    canvas.image(.{ .data = &rgb, .width = 1, .height = 1, .channels = 3 }, -1, -1, 3, 3);
    for (canvas.surface.image_surface_argb.buf) |value| try std.testing.expectEqual(@as(u32, 0xff00ff00), @as(u32, @bitCast(value)));
    canvas.clear();
    var gray: [2]u8 = .{ 32, 128 };
    canvas.image(.{ .data = &gray, .width = 1, .height = 1, .channels = 2 }, 0, 0, 1, 1);
    try std.testing.expectEqual(@as(u32, 0xff8f8f8f), @as(u32, @bitCast(canvas.surface.image_surface_argb.buf[0])));
    try std.testing.expectEqual(@as(u32, 0xffffffff), @as(u32, @bitCast(canvas.surface.image_surface_argb.buf[1])));
    canvas.palette = paint.Palette.init(true);
    canvas.clear();
    var transparent: [4]u8 = .{ 255, 0, 0, 0 };
    canvas.image(.{ .data = &transparent, .width = 1, .height = 1, .channels = 4 }, 0, 0, 2, 2);
    for (canvas.surface.image_surface_argb.buf) |value| try std.testing.expectEqual(@as(u32, 0xff202124), @as(u32, @bitCast(value)));
}
test "native canvas: glyph masks clip safely and composite coverage over the existing color" {
    var canvas = try paint.Canvas.init(a, 2, 2, .{});
    defer canvas.deinit();
    canvas.clear();
    canvas.mask(&.{ 0, 255, 128, 0 }, -1, 0, 2, 2, 0xff0000);
    const pixels = canvas.surface.image_surface_argb.buf;
    try std.testing.expectEqual(@as(u32, 0xffff0000), @as(u32, @bitCast(pixels[0])));
    try std.testing.expectEqual(@as(u32, 0xffffffff), @as(u32, @bitCast(pixels[2])));
    canvas.mask(&.{128}, 1, 1, 1, 1, 0x0000ff);
    try std.testing.expectEqual(@as(u32, 0xff7f7fff), @as(u32, @bitCast(pixels[3])));
}
test "native canvas: bundled coverage distinguishes supported Latin from deferred scripts" {
    var canvas = try paint.Canvas.init(a, 20, 20, .{});
    defer canvas.deinit();
    const font = try canvas.font(0);
    try std.testing.expect(paint.coverage.has(font, 'A') and paint.coverage.has(font, 'é'));
    try std.testing.expect(!paint.coverage.has(font, 'Ж') and !paint.coverage.has(font, '中'));
    const missing = try paint.coverage.missing(a, font, "Latin ação café µ — Привет 中文\u{200d}\u{fe0f}");
    defer a.free(missing);
    try std.testing.expectEqualSlices(u32, &.{ 0x41f, 0x432, 0x435, 0x438, 0x440, 0x442, 0x4e2d, 0x6587 }, missing);
    const chunks = try paint.coverage.missingMany(a, font, &.{ "Привет 中文", "Привет", "Latin ação café" });
    defer a.free(chunks);
    try std.testing.expectEqualSlices(u32, missing, chunks);
    try std.testing.expectEqual(@as(usize, 0), paint.coverage.missingCount(font, "Latin ação café µ —"));
    try std.testing.expectEqual(@as(usize, 2), paint.coverage.missingCount(font, "ЖЖ\u{200d}"));
}
test "native canvas: adopting fonts invalidates measurements without changing Latin output" {
    var canvas = try paint.Canvas.init(a, 120, 40, .{});
    defer canvas.deinit();
    var fonts: paint.DrawingFonts = .{};
    canvas.system_fonts = &fonts;
    const style: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 0 };
    const before = try canvas.measure(style, "Latin");
    const calls = canvas.measurement_calls;
    fonts.version += 1;
    const after = try canvas.measure(style, "Latin");
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqual(calls + 1, canvas.measurement_calls);
    try std.testing.expectEqual(@as(usize, 1), canvas.cached_words);
}
test "native canvas: full Unicode cmap groups and absent glyph zero are checked" {
    var canvas = try paint.Canvas.init(a, 20, 20, .{});
    defer canvas.deinit();
    var font = (try canvas.font(0)).*;
    var data: [64]u8 = @splat(0);
    std.mem.writeInt(u32, data[12..16], 1, .big);
    std.mem.writeInt(u32, data[16..20], 0x1f600, .big);
    std.mem.writeInt(u32, data[20..24], 0x1f601, .big);
    std.mem.writeInt(u32, data[24..28], 7, .big);
    font.file = .fixed(&data);
    font.meta.cmap_subtable_offset = .{ .full = 0 };
    try std.testing.expect(paint.coverage.has(&font, 0x1f600) and paint.coverage.has(&font, 0x1f601));
    try std.testing.expect(!paint.coverage.has(&font, 0x1f5ff) and !paint.coverage.has(&font, 0x1f602));
    std.mem.writeInt(u32, data[24..28], 0, .big);
    try std.testing.expect(!paint.coverage.has(&font, 0x1f600));
}

test "native canvas: device scale changes pixels while preserving Latin layout and loaded faces" {
    try std.testing.expectEqual([2]i32{1360,800}, try paint.Canvas.physicalSize(1020,600,@as(f32,4.0/3.0)));
    try std.testing.expectEqual([2]i32{12,6}, try paint.Canvas.physicalSize(10,5,1.2));
    var canvas = try paint.Canvas.initScaled(a, 120, 40, .{}, 1.25);
    defer canvas.deinit();
    try std.testing.expectEqual(@as(i32, 120), canvas.logical_width);
    try std.testing.expectEqual(@as(i32, 150), canvas.surface.getWidth());
    try std.testing.expectEqual(@as(i32, 50), canvas.surface.getHeight());
    const style: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 0 };
    const before = try canvas.measure(style, "Latin café");
    try std.testing.expect(try canvas.resizeScaled(120, 40, 2));
    try std.testing.expectEqual(@as(usize, 0), canvas.cached_words);
    try std.testing.expectEqual(@as(u32, 1), canvas.loaded_styles);
    try std.testing.expectEqual(@as(i32, 240), canvas.surface.getWidth());
    try std.testing.expectEqual(before, try canvas.measure(style, "Latin café"));
    try std.testing.expect(!(try canvas.resizeScaled(120, 40, 2)));
    try std.testing.expectError(error.InvalidPixelScale, canvas.resizeScaled(120, 40, 0));
    try std.testing.expectError(error.InvalidPixelScale, canvas.resizeScaled(120, 40, std.math.nan(f32)));
    try std.testing.expectError(error.CanvasMemoryLimit, canvas.resizeScaled(16384, 16384, 8));
    try std.testing.expectEqual(@as(i32, 240), canvas.surface.getWidth());
    try std.testing.expectEqual(@as(f32, 2), canvas.scale);
}
test "native canvas: scaled rectangles overlays images and blits use logical coordinates" {
    var source = try paint.Canvas.initScaled(a, 2, 2, .{}, 2);
    defer source.deinit();
    source.clear();
    source.rectangle(0, 0, 1, 1, 0xff0000);
    const pixels = source.surface.image_surface_argb.buf;
    for (pixels, 0..) |value, i| try std.testing.expectEqual(@as(u32, if (i % 4 < 2 and i / 4 < 2) 0xffff0000 else 0xffffffff), @as(u32, @bitCast(value)));
    source.overlay(0, 0, 1, 1, 0x0000ff, 255);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), @as(u32, @bitCast(pixels[5])));
    var green: [3]u8 = .{ 0, 255, 0 };
    source.image(.{ .data = &green, .width = 1, .height = 1, .channels = 3 }, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), @as(u32, @bitCast(pixels[15])));
    var destination = try paint.Canvas.initScaled(a, 3, 3, .{}, 2);
    defer destination.deinit();
    destination.clear();
    destination.blit(&source, 1, 1);
    const output = destination.surface.image_surface_argb.buf;
    try std.testing.expectEqual(@as(u32, 0xffffffff), @as(u32, @bitCast(output[0])));
    try std.testing.expectEqual(@as(u32, 0xff0000ff), @as(u32, @bitCast(output[2 * 6 + 2])));
    try std.testing.expectEqual(@as(u32, 0xff00ff00), @as(u32, @bitCast(output[5 * 6 + 5])));
}

const InkBounds = struct { left: usize, top: usize, right: usize = 0, bottom: usize = 0, count: usize = 0 };
fn inkBounds(canvas: *paint.Canvas) InkBounds {
    const stride: usize = @intCast(canvas.surface.getWidth());
    var bounds: InkBounds = .{ .left = stride, .top = @intCast(canvas.surface.getHeight()) };
    for (canvas.surface.image_surface_argb.buf, 0..) |value, i| if (value.r != 255 or value.g != 255 or value.b != 255) {
        bounds.left = @min(bounds.left, i % stride); bounds.right = @max(bounds.right, i % stride);
        bounds.top = @min(bounds.top, i / stride); bounds.bottom = @max(bounds.bottom, i / stride);
        bounds.count += 1;
    };
    return bounds;
}
test "native canvas: doubled text and vector glyphs occupy doubled device coordinates" {
    var base = try paint.Canvas.init(a, 160, 80, .{});
    defer base.deinit();
    var scaled = try paint.Canvas.initScaled(a, 160, 80, .{}, 2);
    defer scaled.deinit();
    base.clear(); scaled.clear();
    const style: paint.FontSpec = .{ .face = 0, .size = 24, .flags = 0 };
    try base.text(style, "Scale", 10, 40, 0x3276b0);
    try scaled.text(style, "Scale", 10, 40, 0x3276b0);
    const first = inkBounds(&base); const second = inkBounds(&scaled);
    try std.testing.expect(first.count > 50 and second.count > first.count * 3 and second.count < first.count * 6);
    try std.testing.expect(@abs(@as(i64, @intCast(second.left)) - @as(i64, @intCast(first.left * 2))) <= 2);
    try std.testing.expect(@abs(@as(i64, @intCast(second.top)) - @as(i64, @intCast(first.top * 2))) <= 2);
    try std.testing.expect(@abs(@as(i64, @intCast(second.right)) - @as(i64, @intCast(first.right * 2))) <= 2);
    try scaled.triangle(.{ .{70,10}, .{80,10}, .{75,20} }, 0xff0000);
    try std.testing.expectEqual(@as(u32, 0xffff0000), @as(u32, @bitCast(scaled.surface.image_surface_argb.buf[30 * 320 + 150])));
}
test "native canvas: repeated widths are reused and word storage is bounded" {
    var canvas = try paint.Canvas.init(a, 100, 50, .{});
    defer canvas.deinit();
    const style: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 0 };
    const first = try canvas.measure(style, "AV café");
    const calls = canvas.measurement_calls;
    const again = try canvas.measure(style, "AV café");
    try std.testing.expectEqual(first.width, again.width);
    try std.testing.expectEqual(calls, canvas.measurement_calls);
    var buffer: [64]u8 = undefined;
    for (0..2100) |i| {
        const word = try std.fmt.bufPrint(&buffer, "distinct{d}", .{i});
        _ = try canvas.measure(style, word);
    }
    try std.testing.expectEqual(@as(usize, 2048), canvas.cached_words);
    const count = canvas.cached_words;
    const long: [256]u8 = @splat('W');
    _ = try canvas.measure(style, &long);
    try std.testing.expectEqual(count, canvas.cached_words);
}
