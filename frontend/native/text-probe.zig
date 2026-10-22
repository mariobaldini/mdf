//! Exercise the same packed optional API without needing a compositor.
const std = @import("std");
const c = @import("native");
const paint = @import("canvas.zig");
const a = std.heap.c_allocator;
pub const callbacks: c.struct_MdfTextHost = .{ .font = c.mdf_font_resource, .now = c.mdf_now_ns,
    .event = c.mdf_profile_event, .signal = c.mdf_profile_signal };
fn notify() callconv(.c) void {}
fn finish(api: [*c]const c.struct_MdfTextApi, worker: ?*anyopaque) !*anyopaque {
    const job = worker orelse return error.FontWorkerCreationFailed;
    const deadline = c.mdf_now_ns() + 15 * std.time.ns_per_s;
    while (api.*.complete.?(job) == 0) {
        if (c.mdf_now_ns() > deadline) return error.FontWorkerTimeout;
        var descriptor = c.struct_pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(&descriptor, 1, 1);
    }
    return api.*.take.?(job) orelse error.FontWorkerFailed;
}
fn available(api: [*c]const c.struct_MdfTextApi, value: *anyopaque) !bool {
    const message = api.*.@"error".?(value);
    if (message.length == 0) return true;
    const text = message.data[0..message.length];
    if (std.mem.eql(u8, text, "NoMonospaceFonts") or std.mem.eql(u8, text, "NoMatchingMonospaceFont") or
        std.mem.startsWith(u8, text, "No installed font covers")) return false;
    _ = c.fwrite(text.ptr, 1, text.len, c.stderr);
    return error.SystemTextPreparationFailed;
}
fn draw(api: [*c]const c.struct_MdfTextApi, value: *anyopaque, canvas: *paint.Canvas, text: []const u8, y: f32) !void {
    var mask = std.mem.zeroes(c.struct_MdfTextMask);
    if (api.*.bitmap.?(value, text.ptr, text.len, 24, 0, 16, y, canvas.surface.getWidth(), canvas.surface.getHeight(), &mask) == 0)
        return error.TextBitmapFailed;
    defer c.free(mask.data);
    if (mask.data == null or mask.width <= 0 or mask.height <= 0) return error.EmptyTextBitmap;
    const length = @as(usize, @intCast(mask.width)) * @as(usize, @intCast(mask.height));
    var ink: usize = 0;
    for (mask.data[0..length]) |byte| if (byte != 0) { ink += 1; };
    if (ink < 20) return error.EmptyTextBitmap;
    canvas.mask(mask.data[0..length], mask.left, mask.top, mask.width, mask.height, 0x3276b0);
}
pub fn run(filename: [*:0]const u8) !void {
    var error_buffer: [512]u8 = @splat(0);
    const api = c.mdf_text_renderer(&callbacks, 2, null, null, 0, &error_buffer, error_buffer.len);
    if (api == null) { _ = c.fwrite(&error_buffer, 1, std.mem.sliceTo(&error_buffer, 0).len, c.stderr); return error.TextModuleUnavailable; }
    const text = "Привет 中文 مرحبا שלום Ελληνικά";
    var characters: std.ArrayList(u32) = .empty;
    defer characters.deinit(a);
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |ch| if (ch >= 128 and std.mem.indexOfScalar(u32, characters.items, ch) == null) try characters.append(a, ch);
    const mono_job = api.*.start.?(1, null, 0, 3, notify, 0) orelse return error.FontWorkerCreationFailed;
    defer api.*.stop.?(mono_job);
    const sans_job = api.*.start.?(0, characters.items.ptr, characters.items.len, 3, notify, 0) orelse return error.FontWorkerCreationFailed;
    defer api.*.stop.?(sans_job);
    const mono = try finish(api, mono_job);
    var mono_owned = true;
    defer if (mono_owned) api.*.destroy.?(mono);
    const sans = try finish(api, sans_job);
    var sans_owned = true;
    defer if (sans_owned) api.*.destroy.?(sans);
    const mono_available = try available(api, mono);
    const sans_available = try available(api, sans);
    const mono_family = try a.dupe(u8, bytes(api.*.family.?(mono)));
    defer a.free(mono_family);
    const sans_family = try a.dupe(u8, bytes(api.*.family.?(sans)));
    defer a.free(sans_family);
    var canvas = try paint.Canvas.init(a, 900, 230, .{});
    defer canvas.deinit();
    canvas.clear();
    try canvas.text(.{ .face = 1, .size = 22, .flags = 0 }, "Deferred system text without Cairo", 16, 32, 0x42464b);
    var unknown: c_int = -1;
    if (mono_available) {
        var narrow: c.struct_MdfSystemTextMetrics = undefined;
        var wide: c.struct_MdfSystemTextMetrics = undefined;
        if (api.*.measure.?(mono, "iiii", 4, 20, 0, &narrow) == 0 or api.*.measure.?(mono, "WWWW", 4, 20, 0, &wide) == 0 or
            @abs(narrow.width - wide.width) > 0.01 or narrow.width <= 0) return error.NotMonospace;
        try draw(api, mono, &canvas, "iiii WWWW 0123456789 { code(); }", 80);
    }
    if (sans_available) {
        unknown = api.*.unknown_glyphs.?(sans, text, text.len, 0);
        var all = true;
        for (characters.items) |ch| if (api.*.has_character.?(sans, ch) == 0) { all = false; };
        if (all and unknown != 0) return error.UnknownSystemGlyphs;
        try draw(api, sans, &canvas, text, 132);
        if (mono_available) {
            if (api.*.add_fallback.?(mono, sans) == 0) return error.CannotAddFallback;
            try draw(api, mono, &canvas, "code: 中文 + Привет", 184);
        }
        const retained = api.*.retain_resources.?(sans) orelse return error.FontResourceRetainFailed;
        var held = true;
        defer if (held) api.*.release_resources.?(retained);
        const view = api.*.resources.?(retained);
        if (view.source_count == 0 or view.fd_count < view.source_count) return error.FontResourceViewFailed;
        const fd = view.fds[0];
        api.*.destroy.?(sans); sans_owned = false;
        api.*.destroy.?(mono); mono_owned = false;
        var info: c.struct_stat = undefined;
        if (c.fstat(fd, &info) != 0 or info.st_size <= 0) return error.FontResourceLifetimeFailed;
        const cloned = api.*.from_resources.?(retained) orelse return error.FontMapCloneFailed;
        var cloned_owned = true;
        defer if(cloned_owned) api.*.destroy.?(cloned);
        if (!try available(api,cloned)) return error.FontMapCloneUnavailable;
        api.*.release_resources.?(retained); held = false;
        if (c.fstat(fd,&info) != 0 or info.st_size <= 0) return error.ClonedFontResourceLifetimeFailed;
        if (api.*.unknown_glyphs.?(cloned,text,text.len,0) != unknown) return error.ClonedGlyphCoverageChanged;
        try draw(api,cloned,&canvas,text,218);
        api.*.destroy.?(cloned); cloned_owned=false;
        if (c.fcntl(fd, c.F_GETFD) != -1 or c.__errno_location().* != c.EBADF) return error.FontResourceNotReleased;
    }
    for (0..3) |_| { const job = api.*.start.?(1, null, 0, 3, notify, 0) orelse return error.FontWorkerCreationFailed; api.*.stop.?(job); }
    try canvas.png(filename);
    const report = try std.json.Stringify.valueAlloc(a, .{ .mono = mono_available, .sans = sans_available, .unknown = unknown,
        .mono_family = mono_family, .sans_family = sans_family }, .{});
    defer a.free(report);
    _ = c.fwrite(report.ptr, 1, report.len, c.stdout);
}
fn bytes(value: c.struct_MdfFontBytes) []const u8 { return if (value.length > 0) value.data[0..value.length] else ""; }
