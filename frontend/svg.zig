//! Bounded SVG rasterization through the pinned Zig SVG/z2d backend.
const std = @import("std");
const svg = @import("svg");
const z2d = @import("z2d");
const Font = extern struct { data: ?[*]const u8, length: usize };
const Pixels = extern struct { data: ?[*]u8, width: c_int, height: c_int, channels: c_int };
extern fn mdf_builtin_font(family: u32, style: u32) Font;
const Fonts = struct {
    extra: []const Font,
    fn resolve(ctx: ?*anyopaque, req: svg.raster.FontRequest) ?[]const u8 {
        const self: *const Fonts = @ptrCast(@alignCast(ctx.?));
        // The upstream callback has no text/character-coverage argument.
        // Explicit non-Open-Sans families can use an already prepared face.
        // Per-character fallback and complex-script shaping remain limitations
        // of this backend; body text retains its separate Pango font maps.
        if (self.extra.len > 0 and req.family.len > 0 and !std.ascii.eqlIgnoreCase(req.family, "Open Sans")) {
            const face = self.extra[0];
            if (face.data) |bytes| return bytes[0..face.length];
        }
        const style: u32 = (if (req.italic) @as(u32, 2) else 0) + (if (req.weight > 550) @as(u32, 1) else 0);
        const face = mdf_builtin_font(0, style);
        if (face.data) |bytes| return bytes[0..face.length];
        return null;
    }
};

fn render(source: []const u8, extra: []const Font, limit: usize, out: *Pixels, lw: *f32, lh: *f32) !void {
    if (source.len == 0) return error.EmptySvg;
    if (source.len > 16 * 1024 * 1024) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    const allocator = std.heap.smp_allocator;
    var doc = try svg.read(allocator, source);
    defer doc.deinit();
    try validateResources(&doc);
    if (!std.math.isFinite(doc.width) or !std.math.isFinite(doc.height) or
        doc.width <= 0 or doc.height <= 0 or doc.width > 16384 or doc.height > 16384) return error.BadCanvas;
    const logical_width: f32 = @floatCast(doc.width);
    const logical_height: f32 = @floatCast(doc.height);
    const cap: f32 = @floatFromInt(@min(limit / 4, 16 * 1024 * 1024));
    const scale = @min(@sqrt(cap / (logical_width * logical_height)), 2.0);
    if (scale < 1) return error.ImageMemoryLimit;
    const width: u32 = @intFromFloat(@max(1, @floor(logical_width * scale)));
    const height: u32 = @intFromFloat(@max(1, @floor(logical_height * scale)));
    var fonts = Fonts{ .extra = extra };
    const options: svg.Options = .{
        .width = width, .height = height,
        .fonts = .{ .ctx = &fonts, .resolve = Fonts.resolve },
        .limits = .{ .max_width = 32768, .max_height = 32768,
            .max_pixels = @min(limit / 4, 16 * 1024 * 1024), .max_shapes = 100_000 },
    };
    // 0.2 exposes drawing from a parsed tree. Preserve the full renderer's
    // media-query behavior while avoiding a second parse for ordinary SVGs.
    var surface = if (doc.media_dependent) try svg.render(allocator, source, options) else block: {
        if (doc.shape_count > options.limits.max_shapes) return error.TooManyShapes;
        try options.limits.check(width, height);
        var destination = try z2d.Surface.init(.image_surface_rgba, allocator, @intCast(width), @intCast(height));
        errdefer destination.deinit(allocator);
        try svg.raster.drawFrom(allocator, &destination, &doc, doc.paths(),
            doc.transformFor(0, 0, @floatFromInt(width), @floatFromInt(height)), options);
        break :block destination;
    };
    defer surface.deinit(allocator);
    const bytes = try std.heap.c_allocator.alloc(u8, @as(usize, width) * height * 4);
    errdefer std.heap.c_allocator.free(bytes);
    const pixels = surface.image_surface_rgba.buf;
    for (pixels, 0..) |pixel, i| {
        const at = i * 4;
        const alpha: u32 = pixel.a;
        bytes[at + 3] = pixel.a;
        const channels = [_]u8{ pixel.r, pixel.g, pixel.b };
        for (channels, 0..) |value, ch| bytes[at + ch] = if (alpha > 0 and alpha < 255)
            @intCast(@min(255, (@as(u32, value) * 255 + alpha / 2) / alpha)) else value;
    }
    out.* = .{ .data = bytes.ptr, .width = @intCast(width), .height = @intCast(height), .channels = 4 };
    lw.* = logical_width;
    lh.* = logical_height;
}

fn validateResources(doc: *svg.document.Document) !void {
    // Keep the pre-existing document policy even for unused definitions.
    // The SVG backend is sans-I/O; host resolvers only return font bytes.
    var count: usize = 0;
    for (doc.tree.nodes.items) |node| {
        if (node.kind == .attribute or node.kind == .namespace) continue;
        count += 1;
        if (count > 100_000) return error.TooManyXmlNodes;
        if (node.kind != .element) continue;
        const name = node.name.local;
        for ([_][]const u8{ "image", "feImage", "script", "foreignObject" }) |blocked| {
            if (std.mem.eql(u8, name, blocked)) return error.UnsupportedSvgResource;
        }
        if (!std.mem.eql(u8, name, "a")) for (node.attributes.items) |id| {
            const attribute = doc.tree.node(id);
            if ((std.mem.eql(u8, attribute.name.local, "href") or std.mem.eql(u8, attribute.name.local, "src")) and
                !std.mem.startsWith(u8, attribute.value, "#")) return error.ExternalSvgResource;
        };
        if (std.mem.eql(u8, name, "style")) for (node.children.items) |id| {
            const child = doc.tree.node(id);
            if (child.kind == .text and (std.mem.indexOf(u8, child.value, "@import") != null or
                std.mem.indexOf(u8, child.value, "@font-face") != null)) return error.ExternalSvgStyle;
        };
    }
}

fn failure(buffer: ?[*]u8, length: usize, message: []const u8) c_int {
    if (buffer) |b| if (length > 0) {
        const count = @min(length - 1, message.len);
        @memcpy(b[0..count], message[0..count]); b[count] = 0;
    };
    return 0;
}

export fn mdf_render_svg(source: ?[*]const u8, length: usize, dark: c_int,
    extra: ?[*]const Font, count: usize, limit: usize, output: ?*Pixels,
    lw: ?*f32, lh: ?*f32, error_buffer: ?[*]u8, error_length: usize) c_int {
    _ = dark;
    const out = output orelse return 0;
    const width = lw orelse return 0;
    const height = lh orelse return 0;
    out.* = .{ .data = null, .width = 0, .height = 0, .channels = 0 };
    width.* = 0; height.* = 0;
    if (count > 256 or (count > 0 and extra == null)) return failure(error_buffer, error_length, "Invalid prepared SVG fonts");
    const input = source orelse return failure(error_buffer, error_length, "Empty SVG");
    if (length > 16 * 1024 * 1024) return failure(error_buffer, error_length, "SVG exceeds 16 MiB");
    if (extra) |faces| for (faces[0..count]) |face| {
        if (face.data == null or face.length == 0 or face.length > 128 * 1024 * 1024)
            return failure(error_buffer, error_length, "Invalid prepared SVG font");
    };
    render(input[0..length], if (extra) |faces| faces[0..count] else &.{}, limit, out, width, height) catch |err|
        return failure(error_buffer, error_length, switch (err) {
            error.UnsupportedTextDirection => "SVG right-to-left and vertical text are not supported by zig-svg yet",
            error.UnsupportedSvgResource => "SVG embedded images, scripts and foreign objects are unsupported",
            error.ExternalSvgResource, error.ExternalSvgStyle => "SVG external resources and font loading are unsupported",
            error.BadFont => "SVG font format is not supported by zig-svg",
            else => @errorName(err),
        });
    if (error_buffer) |buffer| if (error_length > 0) { buffer[0] = 0; };
    return 1;
}

const TestFonts = struct {
    var requested: u32 = 0;
    fn provide(family: u32, style: u32) callconv(.c) Font {
        if (family != 0 or style > 3) return .{ .data = null, .length = 0 };
        requested |= @as(u32, 1) << @intCast(style);
        const data = switch (style) {
            0 => @embedFile("svg-font-Regular"),
            1 => @embedFile("svg-font-Bold"),
            2 => @embedFile("svg-font-Italic"),
            else => @embedFile("svg-font-BoldItalic"),
        };
        return .{ .data = data.ptr, .length = data.len };
    }
};
comptime {
    if (@import("builtin").is_test) @export(&TestFonts.provide, .{ .name = "mdf_builtin_font" });
}

test "SVG vectors and bundled text use bounded C-owned RGBA output" {
    var out: Pixels = undefined;
    var width: f32 = 0;
    var height: f32 = 0;
    const source = "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><rect width='120' height='60' fill='#c03020'/><text x='5' y='30' font-family='Open Sans' font-size='18' fill='white'>MDF SVG</text></svg>";
    try render(source, &.{}, 64 * 1024 * 1024, &out, &width, &height);
    defer std.heap.c_allocator.free(out.data.?[0..@as(usize, @intCast(out.width * out.height * 4))]);
    try std.testing.expectEqual(@as(f32, 120), width);
    try std.testing.expectEqual(@as(f32, 60), height);
    try std.testing.expectEqual(@as(c_int, 240), out.width);
    try std.testing.expectEqualSlices(u8, &.{192,48,32,255}, out.data.?[0..4]);
    try std.testing.expectError(error.ImageMemoryLimit, render(source, &.{}, 4, &out, &width, &height));
}

test "SVG inherited text styles request only the actual italic face" {
    for ([_][]const u8{ "", "font-style='italic'", "style='font-style:italic;font-weight:bold'",
        "style='font-style:italic;font-weight:600'", "style='font-style:italic;font-weight:550'" }, [_]u32{1,4,8,8,4}) |attributes, expected| {
        TestFonts.requested = 0;
        const source = try std.fmt.allocPrint(std.testing.allocator,
            "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='80'><g {s}><text x='5' y='40'>Styled text</text></g></svg>", .{attributes});
        defer std.testing.allocator.free(source);
        var out: Pixels = undefined;
        var width: f32 = 0; var height: f32 = 0;
        try render(source, &.{}, 64 * 1024 * 1024, &out, &width, &height);
        defer std.heap.c_allocator.free(out.data.?[0..@as(usize, @intCast(out.width * out.height * 4))]);
        try std.testing.expectEqual(expected, TestFonts.requested);
    }
}

test "SVG resource policy rejects unused definitions and external styles" {
    for ([_][]const u8{
        "<defs><image href='data:image/png;base64,AA=='/></defs>",
        "<script>alert(1)</script>", "<foreignObject/>", "<defs><feImage href='file:///not-loaded'/></defs>",
        "<style>@font-face { src: url(font.ttf) }</style>", "<use href='https://example.invalid/x.svg#x'/>",
    }) |body| {
        const source = try std.fmt.allocPrint(std.testing.allocator,
            "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20'>{s}</svg>", .{body});
        defer std.testing.allocator.free(source);
        var out: Pixels = undefined;
        var width: f32 = 0; var height: f32 = 0;
        if (render(source, &.{}, 4096, &out, &width, &height)) |_| {
            std.heap.c_allocator.free(out.data.?[0..@as(usize, @intCast(out.width * out.height * 4))]);
            return error.ExpectedSvgRejection;
        } else |_| {}
    }
}

test "SVG FFI errors clear outputs and return a readable error" {
    var out: Pixels = .{ .data = null, .width = 1, .height = 1, .channels = 4 };
    var width: f32 = 1; var height: f32 = 1;
    var message: [128]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 0), mdf_render_svg(null, 0, 0, null, 0, 4096, &out, &width, &height, &message, message.len));
    try std.testing.expect(out.data == null and out.width == 0 and width == 0 and height == 0 and message[0] != 0);
    const rtl = "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><text x='100' y='30' direction='rtl'>RTL</text></svg>";
    try std.testing.expectEqual(@as(c_int, 0), mdf_render_svg(rtl.ptr, rtl.len, 0, null, 0, 4096*16, &out, &width, &height, &message, message.len));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&message, 0), "right-to-left") != null);
}
