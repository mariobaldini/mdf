//! Pure Zig painting in the compositor's native ARGB pixel format.
const std = @import("std");
const z2d = @import("z2d");
const c = @import("native");
const profile=@import("ui_profile");
pub const coverage = @import("font-coverage.zig");
pub const DrawingFonts = @import("font-runtime.zig").Drawing;
pub const FontSpec = c.MdfLayoutFont;
pub const Palette = struct {
    bg: u32 = 0xffffff,
    fg: u32 = 0x42464b,
    panel: u32 = 0xf5f6f7,
    border: u32 = 0xd8dce1,
    link: u32 = 0x3276b0,
    muted: u32 = 0x6b6f75,
    selection: u32 = 0xc5ddf5,
    highlight: u32 = 0xebd77f,
    note: u32 = 0x0969da,
    tip: u32 = 0x1a7f37,
    important: u32 = 0x8250df,
    warning: u32 = 0x9a6700,
    caution: u32 = 0xcf222e,
    dark: bool = false,

    pub fn init(dark: bool) Palette {
        return preset(dark, 0);
    }
    pub fn preset(dark: bool, theme: u32) Palette {
        const p = c.mdf_theme_palette(theme, dark);
        return .{ .bg = p.bg, .fg = p.fg, .panel = p.panel, .border = p.border,
            .link = p.link, .muted = p.muted, .selection = p.selection, .highlight = p.highlight,
            .note = p.note, .tip = p.tip, .important = p.important, .warning = p.warning, .caution = p.caution, .dark = dark };
    }
    pub fn role(self: Palette, value: u32) u32 {
        return switch (value) {
            1 => self.border,
            2 => self.panel,
            3 => self.link,
            4 => if (self.dark) self.bg else 0xffffff,
            5 => self.note,
            6 => self.tip,
            7 => self.important,
            8 => self.warning,
            9 => self.caution,
            10 => self.fg,
            else => self.bg,
        };
    }
};
pub fn pixel(color: u32) z2d.Pixel {
    return .{ .argb = .{ .r = @truncate(color >> 16), .g = @truncate(color >> 8), .b = @truncate(color), .a = 255 } };
}
pub const Canvas = struct {
    const FontMeasurements = struct {
        widths: std.StringHashMapUnmanaged(c.MdfFlowMetrics) = .empty,
    };
    allocator: std.mem.Allocator,
    profiling: bool = false,
    surface: z2d.Surface,
    logical_width: i32,
    logical_height: i32,
    scale: f32 = 1,
    palette: Palette,
    fonts: [4]?z2d.font.Font = @splat(null),
    loaded_styles: u32 = 0,
    failure: ?anyerror = null,
    measurements: std.AutoHashMapUnmanaged(u32, FontMeasurements) = .empty,
    cached_words: usize = 0,
    measurement_calls: usize = 0,
    system_fonts: ?*const DrawingFonts = null,
    system_version: u64 = 0,

    pub fn init(a: std.mem.Allocator, width: i32, height: i32, palette: Palette) !Canvas {
        return initScaled(a, width, height, palette, 1);
    }
    pub fn physicalSize(width: i32, height: i32, scale: f32) ![2]i32 {
        if (width <= 0) return error.InvalidWidth;
        if (height <= 0) return error.InvalidHeight;
        if (!std.math.isFinite(scale) or scale <= 0 or scale > 8) return error.InvalidPixelScale;
        // Wayland scales use 120ths. Multiply their integer numerator first
        // so a float approximation of 4/3 cannot add a spurious buffer pixel.
        const units = @round(@as(f64, scale) * 120);
        const protocol_scale = @abs(units / 120 - scale) < 0.000001;
        const w = @ceil(if (protocol_scale) @as(f64, @floatFromInt(width)) * units / 120 else @as(f64, @floatFromInt(width)) * scale);
        const h = @ceil(if (protocol_scale) @as(f64, @floatFromInt(height)) * units / 120 else @as(f64, @floatFromInt(height)) * scale);
        if (w > 32768 or h > 32768 or w * h > 32 * 1024 * 1024) return error.CanvasMemoryLimit;
        return .{ @intFromFloat(w), @intFromFloat(h) };
    }
    pub fn initScaled(a: std.mem.Allocator, width: i32, height: i32, palette: Palette, scale: f32) !Canvas {
        const size = try physicalSize(width, height, scale);
        return .{ .allocator = a, .surface = try z2d.Surface.init(.image_surface_argb, a, size[0], size[1]),
            .logical_width = width, .logical_height = height, .scale = scale, .palette = palette };
    }
    pub fn resize(self: *Canvas, width: i32, height: i32) !bool {
        return self.resizeScaled(width, height, self.scale);
    }
    pub fn resizeScaled(self: *Canvas, width: i32, height: i32, scale: f32) !bool {
        const size = try physicalSize(width, height, scale);
        if (width == self.logical_width and height == self.logical_height and scale == self.scale) return false;
        // Keep fonts and measured words across resizes. Allocate before releasing
        // the old surface so allocation failure leaves the canvas usable.
        const replacement = try z2d.Surface.init(.image_surface_argb, self.allocator, size[0], size[1]);
        self.surface.deinit(self.allocator);
        self.surface = replacement;
        if (self.scale != scale) self.clearMeasurements();
        self.logical_width = width; self.logical_height = height; self.scale = scale;
        return true;
    }
    fn fontPixels(self: *const Canvas, size: i32) i32 {
        return @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(size)) * self.scale)));
    }
    fn clearMeasurements(self: *Canvas) void {
        var fonts = self.measurements.valueIterator();
        while (fonts.next()) |value| {
            var keys = value.widths.keyIterator();
            while (keys.next()) |key| self.allocator.free(key.*);
            value.widths.deinit(self.allocator);
        }
        self.measurements.deinit(self.allocator);
        self.measurements = .empty;
        self.cached_words = 0;
    }
    pub fn deinit(self: *Canvas) void {
        self.clearMeasurements();
        self.surface.deinit(self.allocator);
    }
    fn refreshSystem(self: *Canvas) void {
        const version = if (self.system_fonts) |fonts| fonts.version else 0;
        if (version != self.system_version) {
            self.clearMeasurements();
            self.system_version = version;
        }
    }
    pub fn monoReady(self: *const Canvas) bool {
        return if (self.system_fonts) |fonts| fonts.mono != null else false;
    }
    fn systemChoice(self: *Canvas, style: FontSpec, bytes: []const u8) !u32 {
        const fonts = self.system_fonts orelse return 0;
        if (style.flags & 1 != 0 and style.flags & 2 == 0 and fonts.mono != null) return 1;
        if (fonts.sans == null) return 0;
        const selected = try self.font(style.face);
        var at: usize = 0;
        while (at < bytes.len) {
            const begin = at;
            at += 1;
            if (bytes[begin] < 128) continue;
            const length = std.unicode.utf8ByteSequenceLength(bytes[begin]) catch continue;
            if (length > bytes.len - begin) continue;
            const ch = std.unicode.utf8Decode(bytes[begin..][0..length]) catch continue;
            at = begin + length;
            if (!coverage.ignorable(ch) and !coverage.has(selected, ch)) return 2;
        }
        return 0;
    }
    pub fn clear(self: *Canvas) void {
        self.surface.paintPixel(pixel(self.palette.bg));
    }
    pub fn font(self: *Canvas, face: u32) !*z2d.font.Font {
        if (face >= self.fonts.len) return error.InvalidFontStyle;
        if (self.fonts[face] == null) {
            const timing=profile.begin(self.profiling,@src(),"Prepare bundled font for native drawing",0);
            defer timing.end();
            const bytes = c.mdf_font_resource(0, face);
            if (bytes.ptr == null or bytes.len == 0) return error.MissingBuiltinFont;
            const file = try z2d.font.File.loadBuffer(bytes.ptr[0..bytes.len]);
            self.fonts[face] = try file.loadFontIndex(0);
            self.loaded_styles |= @as(u32, 1) << @as(u5, @intCast(face));
        }
        return &self.fonts[face].?;
    }
    pub fn measure(self: *Canvas, style: c.MdfLayoutFont, bytes: []const u8) !c.MdfFlowMetrics {
        self.refreshSystem();
        const mode = try self.systemChoice(style, bytes);
        const key = @as(u32, @intCast(style.size)) * 16 + mode * 4 + style.face;
        const entry = try self.measurements.getOrPut(self.allocator, key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const cache = entry.value_ptr;
        if (bytes.len <= 128) if (cache.widths.get(bytes)) |value| return value;
        const result: c.MdfFlowMetrics = if (mode != 0) system: {
            const fonts = self.system_fonts.?;
            var metrics: c.struct_MdfSystemTextMetrics = undefined;
            if (fonts.api.?.measure.?(if (mode == 1) fonts.mono else fonts.sans, bytes.ptr, bytes.len, self.fontPixels(style.size), @intCast(style.face), &metrics) == 0)
                return error.SystemTextMeasurementFailed;
            break :system .{ .width = metrics.width / self.scale, .height = metrics.height / self.scale, .descent = metrics.descent / self.scale };
        } else latin: {
            const selected = try self.font(style.face);
            const size: f64 = @floatFromInt(style.size);
            const descent = -@as(f64, @floatFromInt(selected.meta.descender)) / @as(f64, @floatFromInt(selected.meta.units_per_em)) * size;
            break :latin .{ .width = @floatCast(try z2d.text.measure(self.allocator, selected, bytes, .{ .size = size })), .height = @floatCast(@ceil(selected.lineHeight(size))), .descent = @floatCast(@ceil(@max(0, descent))) };
        };
        self.measurement_calls += 1;
        if (bytes.len <= 128 and self.cached_words < 2048) {
            const owned = try self.allocator.dupe(u8, bytes);
            errdefer self.allocator.free(owned);
            try cache.widths.put(self.allocator, owned, result);
            self.cached_words += 1;
        }
        return result;
    }
    pub fn rectangle(self: *Canvas, x: f32, y: f32, width: f32, height: f32, color: u32) void {
        const left: i32 = @intFromFloat(@round(x * self.scale));
        const top: i32 = @intFromFloat(@round(y * self.scale));
        const right = @min(self.surface.getWidth(), left + @as(i32, @intFromFloat(@ceil(@max(0, width * self.scale)))));
        const bottom = @min(self.surface.getHeight(), top + @as(i32, @intFromFloat(@ceil(@max(0, height * self.scale)))));
        const begin = @max(0, left);
        if (right <= begin) return;
        var row = @max(0, top);
        while (row < bottom) : (row += 1)
            self.surface.paintStride(begin, row, @intCast(right - begin), pixel(color));
    }
    pub fn blit(self: *Canvas, source: *const Canvas, x: i32, y: i32) void {
        std.debug.assert(self.scale == source.scale);
        const px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * self.scale));
        const py: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * self.scale));
        const left = @max(0, px);
        const top = @max(0, py);
        const right = @min(self.surface.getWidth(), px + source.surface.getWidth());
        const bottom = @min(self.surface.getHeight(), py + source.surface.getHeight());
        if (right <= left or bottom <= top) return;
        const destination = self.surface.image_surface_argb.buf;
        const pixels = source.surface.image_surface_argb.buf;
        const dw: usize = @intCast(self.surface.getWidth());
        const sw: usize = @intCast(source.surface.getWidth());
        var row = top;
        while (row < bottom) : (row += 1) {
            const dst: usize = @as(usize, @intCast(row)) * dw + @as(usize, @intCast(left));
            const src: usize = @as(usize, @intCast(row - py)) * sw + @as(usize, @intCast(left - px));
            const count: usize = @intCast(right - left);
            @memcpy(destination[dst..][0..count], pixels[src..][0..count]);
        }
    }
    pub fn overlay(self: *Canvas, x: i32, y: i32, width: i32, height: i32, color: u32, alpha: u8) void {
        const px: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * self.scale));
        const py: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * self.scale));
        const pw: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(width)) * self.scale));
        const ph: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) * self.scale));
        const pixels = self.surface.image_surface_argb.buf;
        const stride: usize = @intCast(self.surface.getWidth());
        var row = @max(0, py);
        const red: u32 = (color >> 16) & 255;
        const green: u32 = (color >> 8) & 255;
        const blue: u32 = color & 255;
        const opacity: u32 = alpha;
        while (row < @min(self.surface.getHeight(), py + ph)) : (row += 1) {
            var col = @max(0, px);
            while (col < @min(self.surface.getWidth(), px + pw)) : (col += 1) {
                const pixel_value = &pixels[@as(usize, @intCast(row)) * stride + @as(usize, @intCast(col))];
                pixel_value.r = @intCast((red * opacity + @as(u32, pixel_value.r) * (255 - opacity) + 127) / 255);
                pixel_value.g = @intCast((green * opacity + @as(u32, pixel_value.g) * (255 - opacity) + 127) / 255);
                pixel_value.b = @intCast((blue * opacity + @as(u32, pixel_value.b) * (255 - opacity) + 127) / 255);
            }
        }
    }
    pub fn mask(self: *Canvas, data: []const u8, x: i32, y: i32, width: i32, height: i32, color: u32) void {
        if (width <= 0 or height <= 0 or data.len < @as(usize, @intCast(width)) * @as(usize, @intCast(height))) return;
        const pixels = self.surface.image_surface_argb.buf;
        const stride: usize = @intCast(self.surface.getWidth());
        const red = (color >> 16) & 255;
        const green = (color >> 8) & 255;
        const blue = color & 255;
        var row = @max(0, y);
        while (row < @min(self.surface.getHeight(), y + height)) : (row += 1) {
            var col = @max(0, x);
            while (col < @min(self.surface.getWidth(), x + width)) : (col += 1) {
                const alpha: u32 = data[@as(usize, @intCast(row - y)) * @as(usize, @intCast(width)) + @as(usize, @intCast(col - x))];
                if (alpha == 0) continue;
                const current = &pixels[@as(usize, @intCast(row)) * stride + @as(usize, @intCast(col))];
                current.r = @intCast((red * alpha + @as(u32, current.r) * (255 - alpha) + 127) / 255);
                current.g = @intCast((green * alpha + @as(u32, current.g) * (255 - alpha) + 127) / 255);
                current.b = @intCast((blue * alpha + @as(u32, current.b) * (255 - alpha) + 127) / 255);
                current.a = 255;
            }
        }
    }
    pub fn image(self: *Canvas, source: c.struct_MdfPixels, x: f32, y: f32, width: f32, height: f32) void {
        if (source.data == null or source.width <= 0 or source.height <= 0 or width <= 0 or height <= 0 or
            !std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(width) or !std.math.isFinite(height)) return;
        inline for (.{ 1, 2, 3, 4 }) |channels| if (source.channels == channels) {
            self.paintImage(channels, source, x * self.scale, y * self.scale, width * self.scale, height * self.scale);
            return;
        };
    }
    fn sample(comptime channels: usize, data: [*c]const u8, index: usize) @Vector(4, f32) {
        const at = index * channels;
        const alpha: f32 = @floatFromInt(if (channels == 2) data[at + 1] else if (channels == 4) data[at + 3] else @as(u8, 255));
        const red: f32 = @floatFromInt(data[at]);
        const green: f32 = if (channels <= 2) red else @floatFromInt(data[at + 1]);
        const blue: f32 = if (channels <= 2) red else @floatFromInt(data[at + 2]);
        return .{ red * alpha, green * alpha, blue * alpha, alpha };
    }
    fn paintImage(self: *Canvas, comptime channels: usize, source: c.struct_MdfPixels, x: f32, y: f32, width: f32, height: f32) void {
        const surface_w = self.surface.getWidth();
        const surface_h = self.surface.getHeight();
        if (x >= @as(f32, @floatFromInt(surface_w)) or y >= @as(f32, @floatFromInt(surface_h)) or x + width <= 0 or y + height <= 0) return;
        const left: i32 = @intFromFloat(@max(0, @floor(x)));
        const top: i32 = @intFromFloat(@max(0, @floor(y)));
        const right: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(surface_w)), @ceil(x + width)));
        const bottom: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(surface_h)), @ceil(y + height)));
        const pixels = self.surface.image_surface_argb.buf;
        const stride: usize = @intCast(surface_w);
        const source_w: usize = @intCast(source.width);
        const scale_x = @as(f32, @floatFromInt(source.width)) / width;
        const scale_y = @as(f32, @floatFromInt(source.height)) / height;
        var row = top;
        while (row < bottom) : (row += 1) {
            const sy = (@as(f32, @floatFromInt(row)) + 0.5 - y) * scale_y - 0.5;
            const floor_y: i32 = @intFromFloat(@floor(sy));
            const y0: usize = @intCast(std.math.clamp(floor_y, 0, source.height - 1));
            const y1: usize = @intCast(std.math.clamp(floor_y + 1, 0, source.height - 1));
            const fy = sy - @floor(sy);
            var col = left;
            while (col < right) : (col += 1) {
                const sx = (@as(f32, @floatFromInt(col)) + 0.5 - x) * scale_x - 0.5;
                const floor_x: i32 = @intFromFloat(@floor(sx));
                const x0: usize = @intCast(std.math.clamp(floor_x, 0, source.width - 1));
                const x1: usize = @intCast(std.math.clamp(floor_x + 1, 0, source.width - 1));
                const fx = sx - @floor(sx);
                // Interpolate premultiplied colors, then composite over the
                // opaque reader. Transparent RGB cannot create edge halos.
                const mixed = sample(channels, source.data, y0 * source_w + x0) * @as(@Vector(4, f32), @splat((1 - fx) * (1 - fy))) +
                    sample(channels, source.data, y0 * source_w + x1) * @as(@Vector(4, f32), @splat(fx * (1 - fy))) +
                    sample(channels, source.data, y1 * source_w + x0) * @as(@Vector(4, f32), @splat((1 - fx) * fy)) +
                    sample(channels, source.data, y1 * source_w + x1) * @as(@Vector(4, f32), @splat(fx * fy));
                const current = &pixels[@as(usize, @intCast(row)) * stride + @as(usize, @intCast(col))];
                const background: @Vector(4, f32) = .{ @floatFromInt(current.r), @floatFromInt(current.g), @floatFromInt(current.b), 255 };
                const result = (mixed + background * @as(@Vector(4, f32), @splat(255 - mixed[3]))) / @as(@Vector(4, f32), @splat(255));
                current.r = @intFromFloat(std.math.clamp(@round(result[0]), 0, 255));
                current.g = @intFromFloat(std.math.clamp(@round(result[1]), 0, 255));
                current.b = @intFromFloat(std.math.clamp(@round(result[2]), 0, 255));
                current.a = 255;
            }
        }
    }
    pub fn text(self: *Canvas, style: c.MdfLayoutFont, bytes: []const u8, x: f32, baseline: f32, color: u32) !void {
        if (bytes.len == 0 or (bytes.len == 1 and bytes[0] == '\t')) return;
        self.refreshSystem();
        const mode = try self.systemChoice(style, bytes);
        if (mode != 0) {
            const fonts = self.system_fonts.?;
            var output = std.mem.zeroes(c.struct_MdfTextMask);
            if (fonts.api.?.bitmap.?(if (mode == 1) fonts.mono else fonts.sans, bytes.ptr, bytes.len, self.fontPixels(style.size), @intCast(style.face), x * self.scale, baseline * self.scale, self.surface.getWidth(), self.surface.getHeight(), &output) == 0) return error.SystemTextBitmapFailed;
            defer c.free(output.data);
            if (output.data != null and output.width > 0 and output.height > 0) self.mask(output.data[0 .. @as(usize, @intCast(output.width)) * @as(usize, @intCast(output.height))], output.left, output.top, output.width, output.height, color);
            return;
        }
        const selected = try self.font(style.face);
        const size: f64 = @as(f64, @floatFromInt(style.size)) * self.scale;
        const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = pixel(color) } };
        try z2d.text.show(self.allocator, &self.surface, &pattern, selected, bytes, @as(f64, x) * self.scale, @as(f64, baseline) * self.scale - selected.baselineOffset(size), .{ .size = size });
    }
    pub fn triangle(self: *Canvas, points: [3][2]f32, color: u32) !void {
        var path: z2d.Path = .empty;
        defer path.deinit(self.allocator);
        try path.moveTo(self.allocator, points[0][0] * self.scale, points[0][1] * self.scale);
        try path.lineTo(self.allocator, points[1][0] * self.scale, points[1][1] * self.scale);
        try path.lineTo(self.allocator, points[2][0] * self.scale, points[2][1] * self.scale);
        try path.close(self.allocator);
        const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = pixel(color) } };
        try z2d.painter.fill(self.allocator, &self.surface, &pattern, path.nodes.items, .default);
    }
    pub fn png(self: *Canvas, filename: [*:0]const u8) !void {
        const pixels = self.surface.image_surface_argb.buf;
        const rgba = try self.allocator.alloc(u8, pixels.len * 4);
        defer self.allocator.free(rgba);
        for (pixels, 0..) |value, index| {
            rgba[index * 4] = value.r;
            rgba[index * 4 + 1] = value.g;
            rgba[index * 4 + 2] = value.b;
            rgba[index * 4 + 3] = value.a;
        }
        var source = c.struct_MdfPixels{ .data = rgba.ptr, .width = self.surface.getWidth(), .height = self.surface.getHeight(), .channels = 4 };
        var encoded: c.struct_MdfEncodedImage = std.mem.zeroes(c.struct_MdfEncodedImage);
        if (c.mdf_encode_png(&source, rgba.len, &encoded) == 0) return error.PngEncodingFailed;
        defer c.free(encoded.data);
        const file = c.fopen(filename, "wb") orelse return error.CannotOpenCapture;
        const wrote = c.fwrite(encoded.data, 1, encoded.length, file);
        const closed = c.fclose(file);
        if (wrote != encoded.length or closed != 0) return error.CannotWriteCapture;
    }
};
