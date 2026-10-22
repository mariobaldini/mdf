//! Private system text maps. Pango retains complex-script shaping and the
//! existing Cairo reference painter while Zig owns map and cache lifetimes.
const std = @import("std");
const c = @import("ui_native");
const Prepared = @import("font-worker.zig").Prepared;
const a = std.heap.c_allocator;
const Metrics = c.struct_MdfSystemTextMetrics;
const ft2 = @import("system_text_options").ft2;
const Text = struct {
    prepared: *Prepared,
    fallbacks: std.ArrayList(*Prepared) = .empty,
    coverage: ?*c.FcCharSet = null,
    map: ?*c.PangoFontMap = null,
    context: ?*c.PangoContext = null,
    layout: ?*c.PangoLayout = null,
    description: ?*c.PangoFontDescription = null,
    last_size: c_int = -1,
    last_style: c_int = -1,
    metrics: std.AutoHashMapUnmanaged(u32, Metrics) = .empty,

    fn create(prepared: *Prepared) !*Text {
        if (prepared.config == null or prepared.fds.items.len == 0 or prepared.family.len == 0) return error.SystemFontUnavailable;
        const self = try a.create(Text);
        self.* = .{ .prepared = prepared };
        prepared.retain();
        errdefer self.destroy();
        self.coverage = c.FcCharSetCreate() orelse return error.FontCharsetFailed;
        if (c.FcConfigGetFonts(prepared.config, c.FcSetApplication)) |pointer| {
            const fonts: *c.FcFontSet = pointer;
            var index: usize = 0;
            while (index < fonts.nfont) : (index += 1) {
                var chars: ?*c.FcCharSet = null;
                if (c.FcPatternGetCharSet(fonts.fonts[index], c.FC_CHARSET, 0, &chars) == c.FcResultMatch)
                    _ = c.FcCharSetMerge(self.coverage, chars, null);
            }
        }
        self.map = (if (ft2) c.pango_ft2_font_map_new() else c.pango_cairo_font_map_new()) orelse return error.SystemFontMapUnavailable;
        if (c.g_type_check_instance_is_a(@ptrCast(self.map), c.pango_fc_font_map_get_type()) == 0) return error.SystemFontMapUnavailable;
        c.pango_fc_font_map_set_config(@ptrCast(self.map), prepared.config);
        if (ft2) c.pango_ft2_font_map_set_resolution(@ptrCast(self.map), 96, 96)
        else c.pango_cairo_font_map_set_resolution(@ptrCast(self.map), 96);
        self.context = c.pango_font_map_create_context(self.map) orelse return error.SystemFontContextUnavailable;
        self.layout = c.pango_layout_new(self.context) orelse return error.SystemFontLayoutUnavailable;
        c.pango_layout_set_single_paragraph_mode(self.layout, 1);
        c.pango_layout_set_auto_dir(self.layout, @intFromBool(!prepared.mono));
        const attributes = c.pango_attr_list_new() orelse return error.SystemFontAttributesUnavailable;
        defer c.pango_attr_list_unref(attributes);
        const fallback = c.pango_attr_fallback_new(1) orelse return error.SystemFontAttributesUnavailable;
        c.pango_attr_list_insert(attributes, fallback);
        if (prepared.mono) {
            const features = c.pango_attr_font_features_new("liga=0,clig=0,calt=0,kern=0") orelse return error.SystemFontAttributesUnavailable;
            c.pango_attr_list_insert(attributes, features);
        }
        c.pango_layout_set_attributes(self.layout, attributes);
        self.description = c.pango_font_description_new() orelse return error.SystemFontDescriptionUnavailable;
        const family = if (prepared.mono) try a.dupeSentinel(u8, prepared.family, 0) else
            try std.fmt.allocPrintSentinel(a, "Open Sans, {s}", .{prepared.family}, 0);
        defer a.free(family);
        c.pango_font_description_set_family(self.description, family);
        if (prepared.mono) for (0..4) |style| {
            self.configure(16, @intCast(style));
            c.pango_layout_set_text(self.layout, "iiii", 4);
            const narrow = self.extents().width;
            c.pango_layout_set_text(self.layout, "WWWW", 4);
            const wide = self.extents().width;
            c.pango_layout_set_text(self.layout, "    ", 4);
            const spaces = self.extents().width;
            if (narrow <= 0 or @abs(narrow - wide) > 0.1 or @abs(narrow - spaces) > 0.1) return error.NotMonospace;
        };
        return self;
    }
    fn destroy(self: *Text) void {
        if (self.layout) |value| c.g_object_unref(value);
        if (self.context) |value| c.g_object_unref(value);
        if (self.map) |value| c.g_object_unref(value);
        if (self.description) |value| c.pango_font_description_free(value);
        if (self.coverage) |value| c.FcCharSetDestroy(value);
        self.metrics.deinit(a);
        for (self.fallbacks.items) |value| value.destroy();
        self.fallbacks.deinit(a);
        self.prepared.destroy();
        a.destroy(self);
    }
    fn addFallback(self: *Text, other: *Text) !void {
        if (self.prepared == other.prepared or std.mem.indexOfScalar(*Prepared, self.fallbacks.items, other.prepared) != null) return;
        const from: *c.FcFontSet = c.FcConfigGetFonts(other.prepared.config, c.FcSetApplication) orelse return error.PrivateCodeFontMapUnavailable;
        const to: *c.FcFontSet = c.FcConfigGetFonts(self.prepared.config, c.FcSetApplication) orelse return error.PrivateCodeFontMapUnavailable;
        // Retain backing descriptors before adding any pattern references.
        try self.fallbacks.append(a, other.prepared);
        other.prepared.retain();
        var index: usize = 0;
        while (index < from.nfont) : (index += 1) {
            c.FcPatternReference(from.fonts[index]);
            if (c.FcFontSetAdd(to, from.fonts[index]) == 0) {
                c.FcPatternDestroy(from.fonts[index]);
                return error.CodeFallbackMetadataFailed;
            }
        }
        _ = c.FcCharSetMerge(self.coverage, other.coverage, null);
        c.pango_fc_font_map_config_changed(@ptrCast(self.map));
        c.pango_layout_context_changed(self.layout);
        self.metrics.clearRetainingCapacity();
    }
    fn configure(self: *Text, size: c_int, style: c_int) void {
        if (self.last_size == size and self.last_style == style) return;
        c.pango_font_description_set_absolute_size(self.description, @as(f64, @floatFromInt(size)) * c.PANGO_SCALE);
        c.pango_font_description_set_weight(self.description, if (style & 1 != 0) c.PANGO_WEIGHT_BOLD else c.PANGO_WEIGHT_NORMAL);
        c.pango_font_description_set_style(self.description, if (style & 2 != 0) c.PANGO_STYLE_ITALIC else c.PANGO_STYLE_NORMAL);
        c.pango_layout_set_font_description(self.layout, self.description);
        self.last_size = size;
        self.last_style = style;
    }
    fn extents(self: *Text) Metrics {
        var width: c_int = 0;
        var height: c_int = 0;
        c.pango_layout_get_size(self.layout, &width, &height);
        return .{ .width = @as(f32, @floatFromInt(width)) / c.PANGO_SCALE,
            .height = @as(f32, @floatFromInt(height)) / c.PANGO_SCALE,
            .descent = @as(f32, @floatFromInt(height - c.pango_layout_get_baseline(self.layout))) / c.PANGO_SCALE };
    }
    fn measure(self: *Text, text: []const u8, size: c_int, style: c_int) !Metrics {
        self.configure(size, style);
        if (!self.prepared.mono) {
            c.pango_layout_set_text(self.layout, text.ptr, @intCast(text.len));
            return self.extents();
        }
        const key = @as(u32, @intCast(size)) * 4 + @as(u32, @intCast(style & 3));
        const entry = try self.metrics.getOrPut(a, key);
        if (!entry.found_existing) {
            c.pango_layout_set_text(self.layout, "M", 1);
            entry.value_ptr.* = self.extents();
        }
        var metrics = entry.value_ptr.*;
        var ascii = true;
        for (text) |byte| if (byte < 32 or byte >= 127) {
            ascii = false;
            break;
        };
        if (ascii) {
            metrics.width *= @floatFromInt(text.len);
            return metrics;
        }
        c.pango_layout_set_text(self.layout, text.ptr, @intCast(text.len));
        return self.extents();
    }
};
fn failure(buffer: ?[*]u8, length: usize, err: anyerror) void {
    const output = buffer orelse return;
    if (length == 0) return;
    const message = if (err == error.NotMonospace) "Selected system font does not provide fixed-width code text" else @errorName(err);
    const count = @min(message.len, length - 1);
    @memcpy(output[0..count], message[0..count]);
    output[count] = 0;
}
export fn mdf_system_text_create(prepared: *Prepared, error_buffer: ?[*]u8, error_length: usize) ?*Text {
    return Text.create(prepared) catch |err| {
        failure(error_buffer, error_length, err);
        return null;
    };
}
export fn mdf_system_text_destroy(self: ?*Text) void {
    if (self) |text| text.destroy();
}
export fn mdf_system_text_add_fallback(self: *Text, other: *Text, error_buffer: ?[*]u8, error_length: usize) c_int {
    self.addFallback(other) catch |err| {
        failure(error_buffer, error_length, err);
        return 0;
    };
    return 1;
}
export fn mdf_system_text_has_character(self: *Text, ch: u32) c_int {
    return c.FcCharSetHasChar(self.coverage, ch);
}
export fn mdf_system_text_unknown_glyphs(self: *Text, text: [*]const u8, len: usize, style: c_int) c_int {
    if (len > std.math.maxInt(c_int)) return -1;
    self.configure(16, style);
    c.pango_layout_set_text(self.layout, text, @intCast(len));
    return c.pango_layout_get_unknown_glyphs_count(self.layout);
}
export fn mdf_system_text_measure(self: *Text, text: [*]const u8, len: usize, size: c_int, style: c_int, out: *Metrics) c_int {
    if (len > std.math.maxInt(c_int) or size <= 0) return 0;
    out.* = self.measure(text[0..len], size, style) catch return 0;
    return 1;
}
export fn mdf_system_text_draw(self: *Text, text: [*]const u8, len: usize, size: c_int, style: c_int, cr: *c.cairo_t, x: f32, baseline: f32) void {
    if (ft2) return;
    if (len == 0 or (len == 1 and text[0] == '\t') or len > std.math.maxInt(c_int)) return;
    self.configure(size, style);
    c.pango_layout_set_text(self.layout, text, @intCast(len));
    c.cairo_save(cr);
    c.cairo_translate(cr, x - @as(f32, 0.5), baseline - @as(f32, @floatFromInt(c.pango_layout_get_baseline(self.layout))) / c.PANGO_SCALE - @as(f32, 0.5));
    c.pango_cairo_show_layout(cr, self.layout);
    c.cairo_restore(cr);
}
export fn mdf_system_text_bitmap(self: *Text, text: [*]const u8, len: usize, size: c_int, style: c_int,
    x: f32, baseline: f32, width: c_int, height: c_int, output: *c.struct_MdfTextMask) c_int
{
    output.* = std.mem.zeroes(c.struct_MdfTextMask);
    if (!ft2 or len == 0 or len > std.math.maxInt(c_int) or size <= 0 or width <= 0 or height <= 0 or
        !std.math.isFinite(x) or !std.math.isFinite(baseline)) return 0;
    self.configure(size, style);
    c.pango_layout_set_text(self.layout, text, @intCast(len));
    var ink: c.PangoRectangle = undefined;
    c.pango_layout_get_pixel_extents(self.layout, &ink, null);
    const origin_y = baseline - @as(f32, @floatFromInt(c.pango_layout_get_baseline(self.layout))) / c.PANGO_SCALE;
    const left: i32 = @intFromFloat(std.math.clamp(@floor(x + @as(f32, @floatFromInt(ink.x))) - 1, 0, @as(f32, @floatFromInt(width))));
    const top: i32 = @intFromFloat(std.math.clamp(@floor(origin_y + @as(f32, @floatFromInt(ink.y))) - 1, 0, @as(f32, @floatFromInt(height))));
    const right: i32 = @intFromFloat(std.math.clamp(@ceil(x + @as(f32, @floatFromInt(ink.x + ink.width))) + 1, 0, @as(f32, @floatFromInt(width))));
    const bottom: i32 = @intFromFloat(std.math.clamp(@ceil(origin_y + @as(f32, @floatFromInt(ink.y + ink.height))) + 1, 0, @as(f32, @floatFromInt(height))));
    if (right <= left or bottom <= top) return 1;
    const count = std.math.mul(usize, @intCast(right - left), @intCast(bottom - top)) catch return 0;
    if (count > 64 * 1024 * 1024) return 0;
    const data = a.alloc(u8, count) catch return 0;
    @memset(data, 0);
    var bitmap = std.mem.zeroes(c.FT_Bitmap);
    bitmap.width = @intCast(right - left); bitmap.rows = @intCast(bottom - top);
    bitmap.pitch = right - left; bitmap.buffer = data.ptr;
    bitmap.num_grays = 256; bitmap.pixel_mode = c.FT_PIXEL_MODE_GRAY;
    c.pango_ft2_render_layout_subpixel(&bitmap, self.layout,
        @intFromFloat(@round((x - @as(f32, @floatFromInt(left))) * c.PANGO_SCALE)),
        @intFromFloat(@round((origin_y - @as(f32, @floatFromInt(top))) * c.PANGO_SCALE)));
    output.* = .{ .data = data.ptr, .width = right - left, .height = bottom - top, .left = left, .top = top };
    return 1;
}

const Missing = struct {
    text: []const u8,
    at: usize = 0,
    coverage: ?*const c.FcCharSet,
    fn next(self: *Missing) ?u32 {
        while (self.at < self.text.len) {
            const start = self.at;
            self.at += 1;
            if (self.text[start] < 128) continue;
            const len = std.unicode.utf8ByteSequenceLength(self.text[start]) catch continue;
            if (len > self.text.len - start) continue;
            const ch = std.unicode.utf8Decode(self.text[start..][0..len]) catch continue;
            self.at = start + len;
            const kind = c.g_unichar_type(ch);
            if (kind == c.G_UNICODE_CONTROL or kind == c.G_UNICODE_FORMAT or
                (ch >= 0xfe00 and ch <= 0xfe0f) or (ch >= 0xe0100 and ch <= 0xe01ef)) continue;
            if (self.coverage == null or c.FcCharSetHasChar(self.coverage, ch) == 0) return ch;
        }
        return null;
    }
};
export fn mdf_needs_fallback(text: [*]const u8, len: usize, coverage: ?*const c.FcCharSet) c_int {
    var missing = Missing{ .text = text[0..len], .coverage = coverage };
    return @intFromBool(missing.next() != null);
}
export fn mdf_missing_glyphs(text: [*]const u8, len: usize, coverage: ?*const c.FcCharSet) c.struct_MdfMissingGlyphs {
    var missing = Missing{ .text = text[0..len], .coverage = coverage };
    var unique: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unique.deinit(a);
    while (missing.next()) |ch| unique.put(a, ch, {}) catch return .{ .data = null, .count = 0, .failed = 1 };
    const result = a.alloc(u32, unique.count()) catch return .{ .data = null, .count = 0, .failed = 1 };
    var keys = unique.keyIterator();
    var index: usize = 0;
    while (keys.next()) |ch| : (index += 1) result[index] = ch.*;
    std.mem.sort(u32, result, {}, std.sort.asc(u32));
    return .{ .data = if (result.len > 0) result.ptr else null, .count = result.len, .failed = 0 };
}
