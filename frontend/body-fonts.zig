//! Private bundled-font resources shared by the current backend and deferred
//! system-text maps. FLTK font-slot registration remains a backend adapter.
const std = @import("std");
const c = @import("ui_native");
const Prepared = @import("font-worker.zig").Prepared;
const profile = @import("ui-profile.zig");
const a = std.heap.c_allocator;
const ft2=@import("system_text_options").ft2;
const Store = struct {
    config: *c.FcConfig,
    coverage: ?*c.FcCharSet = null,
    fds: std.ArrayList(c_int) = .empty,
    fallbacks: std.ArrayList(*Prepared) = .empty,
    styles: u32 = 0,

    fn create() !*Store {
        const self = try a.create(Store);
        errdefer a.destroy(self);
        const config = c.FcConfigCreate() orelse return error.PrivateFontConfigurationFailed;
        errdefer c.FcConfigDestroy(config);
        self.* = .{ .config = config };
        try self.fds.ensureTotalCapacity(a, 4);
        _ = c.FcConfigSetRescanInterval(config, 0);
        return self;
    }
    fn destroy(self: *Store) void {
        if (self.coverage) |chars| c.FcCharSetDestroy(chars);
        c.FcConfigDestroy(self.config);
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.deinit(a);
        for (self.fallbacks.items) |font| font.destroy();
        self.fallbacks.deinit(a);
        a.destroy(self);
    }
    fn add(self: *Store, style: u32, bytes: []const u8, tracing: bool) !void {
        if (style >= 4 or bytes.len == 0) return error.BundledFontUnavailable;
        const bit = @as(u32, 1) << @as(u5, @intCast(style));
        if (self.styles & bit != 0) return;
        const fd = block: {
            const phase = profile.begin(tracing, @src(), "Prepare anonymous font data", 0);
            defer phase.end();
            const fd = c.memfd_create("mdf-font", c.MFD_CLOEXEC);
            if (fd < 0) return error.FontMemoryFileFailed;
            self.fds.append(a, fd) catch |err| {
                _ = c.close(fd);
                return err;
            };
            var at: usize = 0;
            while (at < bytes.len) {
                const count = c.write(fd, bytes.ptr + at, bytes.len - at);
                if (count < 0 and c.__errno_location().* == c.EINTR) continue;
                if (count <= 0) return error.FontWriteFailed;
                at += @intCast(count);
            }
            break :block fd;
        };
        {
            const phase = switch (style) {
                0 => profile.begin(tracing, @src(), "Register Open Sans regular", 0),
                1 => profile.begin(tracing, @src(), "Register Open Sans bold", 0),
                2 => profile.begin(tracing, @src(), "Register Open Sans italic", 0),
                else => profile.begin(tracing, @src(), "Register Open Sans bold italic", 0),
            };
            defer phase.end();
            var path: [64]u8 = undefined;
            const file = try std.fmt.bufPrint(&path, "/proc/self/fd/{d}\x00", .{fd});
            if (c.FcConfigAppFontAddFile(self.config, file.ptr) == 0) return error.BundledFontRegistrationFailed;
        }
        self.styles |= bit;
        if (self.styles & 3 == 3 and self.coverage == null) {
            const fonts: *c.FcFontSet = c.FcConfigGetFonts(self.config, c.FcSetApplication) orelse return error.BundledFontCoverageUnavailable;
            var chars: ?*c.FcCharSet = null;
            if (fonts.nfont == 0 or c.FcPatternGetCharSet(fonts.fonts[0], c.FC_CHARSET, 0, &chars) != c.FcResultMatch)
                return error.BundledFontCoverageUnavailable;
            self.coverage = c.FcCharSetCopy(chars) orelse return error.BundledFontCoverageUnavailable;
        }
    }
    fn addFallback(self: *Store, prepared: *Prepared) !void {
        const from: *c.FcFontSet = c.FcConfigGetFonts(prepared.config, c.FcSetApplication) orelse return error.FallbackFontsUnavailable;
        const to: *c.FcFontSet = c.FcConfigGetFonts(self.config, c.FcSetApplication) orelse return error.BundledFontsUnavailable;
        try self.fallbacks.append(a, prepared);
        prepared.retain();
        var index: usize = 0;
        while (index < from.nfont) : (index += 1) {
            var family: [*c]c.FcChar8 = null;
            if (c.FcPatternGetString(from.fonts[index], c.FC_FAMILY, 0, &family) == c.FcResultMatch and
                std.mem.eql(u8, std.mem.span(family), "Open Sans")) continue;
            c.FcPatternReference(from.fonts[index]);
            if (c.FcFontSetAdd(to, from.fonts[index]) == 0) {
                c.FcPatternDestroy(from.fonts[index]);
                return error.FallbackFontPublicationFailed;
            }
        }
    }
};
fn failure(buffer: ?[*]u8, length: usize, err: anyerror) c_int {
    if (buffer) |output| if (length > 0) {
        const name = switch (err) {
            error.FontMemoryFileFailed => "Cannot create font memory file",
            error.FontWriteFailed => "Cannot prepare embedded Open Sans data",
            error.BundledFontUnavailable => "Embedded Open Sans face unavailable",
            error.BundledFontRegistrationFailed => "Fontconfig rejected embedded Open Sans face",
            error.BundledFontCoverageUnavailable => "Embedded Open Sans coverage unavailable",
            error.FallbackFontPublicationFailed => "Cannot publish document fallback font",
            else => @errorName(err),
        };
        const count = @min(length - 1, name.len);
        @memcpy(output[0..count], name[0..count]);
        output[count] = 0;
    };
    return 0;
}
export fn mdf_body_fonts_create() ?*Store {
    return Store.create() catch null;
}
export fn mdf_body_fonts_destroy(self: ?*Store) void {
    if (self) |store| store.destroy();
}
export fn mdf_body_fonts_add(self: *Store, style: u32, bytes: [*]const u8, len: usize, tracing: c_int, caller_depth: usize, error_buffer: ?[*]u8, error_length: usize) c_int {
    const nesting = profile.enter(caller_depth);
    defer nesting.end();
    self.add(style, bytes[0..len], tracing != 0) catch |err| return failure(error_buffer, error_length, err);
    return 1;
}
export fn mdf_body_fonts_view(self: *Store) c.struct_MdfBodyFontsView {
    return .{ .config = self.config, .coverage = self.coverage, .fds = self.fds.items.ptr, .count = self.fds.items.len, .styles = self.styles };
}
export fn mdf_body_fonts_activate(self: *Store) c_int {
    return c.FcConfigSetCurrent(self.config);
}
export fn mdf_body_fonts_adopt_default(self: *Store) c_int {
    if(ft2) return 0;
    const map = c.pango_cairo_font_map_get_default() orelse return 0;
    if (c.g_type_check_instance_is_a(@ptrCast(map), c.pango_fc_font_map_get_type()) == 0) return 0;
    c.pango_fc_font_map_set_config(@ptrCast(map), self.config);
    return 1;
}
export fn mdf_body_fonts_refresh_default() void {
    if(ft2) return;
    c.pango_fc_font_map_config_changed(@ptrCast(c.pango_cairo_font_map_get_default()));
}
export fn mdf_body_fonts_add_fallback(self: *Store, prepared: *Prepared, error_buffer: ?[*]u8, error_length: usize) c_int {
    self.addFallback(prepared) catch |err| return failure(error_buffer, error_length, err);
    return 1;
}
