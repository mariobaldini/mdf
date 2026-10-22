//! Deferred FreeType text support. Only the table crosses the module boundary.
const std = @import("std");
const c = @import("ui_native");
const fonts = @import("font-worker.zig");
const profile = @import("ui-profile.zig");
const a = std.heap.c_allocator;
comptime { _ = @import("system-text.zig"); _ = @import("body-fonts.zig"); }
var host: c.struct_MdfTextHost = std.mem.zeroes(c.struct_MdfTextHost);
fn initialize(value: [*c]const c.struct_MdfTextHost) callconv(.c) c_int {
    if (value == null or value.*.font == null or value.*.now == null) return 0;
    if (host.font != null and (host.font != value.*.font or host.now != value.*.now)) return 0;
    host = value.*;
    return 1;
}
// The library owns no second recorder or font cache.
pub export fn mdf_now_ns() callconv(.c) u64 { return if (host.now) |now| now() else 0; }
pub export fn mdf_profile_event(track: u8, name: [*]const u8, name_len: usize, source: [*]const u8, source_len: usize,
    line: u32, started: u64, duration: u64, depth: usize, waiting: bool) callconv(.c) void
{
    if (host.event) |event| event(track, name, name_len, source, source_len, line, started, duration, depth, waiting);
}
pub export fn mdf_profile_signal(track: u8, name: [*]const u8, name_len: usize, source: [*]const u8, source_len: usize,
    line: u32, at: u64) callconv(.c) void
{
    if (host.signal) |signal| signal(track, name, name_len, source, source_len, line, at);
}
const Result = struct {
    prepared: ?*fonts.Prepared = null,
    text: ?*anyopaque = null,
    failure: []u8 = &.{},
    fn destroy(self: *Result) void {
        if (self.text) |text| c.mdf_system_text_destroy(text);
        if (self.prepared) |prepared| prepared.destroy();
        a.free(self.failure); a.destroy(self);
    }
};
const Worker = struct {
    mono: bool,
    characters: []u32,
    styles: u32,
    notify: ?*const fn () callconv(.c) void,
    tracing: bool,
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?*Result = null,

    fn prepare(self: *Worker) !*Result {
        const track: u8 = if (self.mono) 2 else 5;
        const body = c.mdf_body_fonts_create() orelse return error.PrivateFontConfigurationFailed;
        defer c.mdf_body_fonts_destroy(body);
        {
            const timing = profile.begin(self.tracing, @src(), "Register bundled faces for deferred text", track);
            defer timing.end();
            for (0..4) |style| if ((self.styles | 3) & (@as(u32, 1) << @as(u5, @intCast(style))) != 0) {
                if (self.canceled.load(.monotonic)) return error.Canceled;
                const font = host.font.?(0, @intCast(style));
                if (font.ptr == null or font.len == 0) return error.BundledFontUnavailable;
                // The outer span identifies the actual worker; the legacy
                // bundled-font adapter's GUI-only nested spans stay disabled.
                if (c.mdf_body_fonts_add(body, @intCast(style), font.ptr, font.len, 0, 0, null, 0) == 0) return error.BundledFontRegistrationFailed;
            };
        }
        const bundled = c.mdf_body_fonts_view(body);
        const prepared = try fonts.prepareInline(self.mono, self.characters,
            if (bundled.count > 0) bundled.fds[0..bundled.count] else &.{}, self.tracing, &self.canceled);
        errdefer prepared.destroy();
        if (self.canceled.load(.monotonic)) return error.Canceled;
        const result = try a.create(Result);
        result.* = .{ .prepared = prepared };
        errdefer { a.free(result.failure); a.destroy(result); }
        var error_buffer: [512]u8 = @splat(0);
        {
            const timing = profile.begin(self.tracing, @src(), "Create deferred FreeType text map", track);
            defer timing.end();
            result.text = c.mdf_system_text_create(prepared, &error_buffer, error_buffer.len);
        }
        if (result.text == null) result.failure = try a.dupe(u8, if (prepared.failure.len > 0) prepared.failure else std.mem.sliceTo(&error_buffer, 0));
        return result;
    }
    fn run(self: *Worker) void {
        const name: [:0]const u8 = if (self.mono) "mdf-monospace" else "mdf-fallback";
        _ = c.prctl(c.PR_SET_NAME, name.ptr, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        {
            const timing = if (self.mono) profile.begin(self.tracing, @src(), "Prepare deferred system monospace", 2)
                else profile.begin(self.tracing, @src(), "Prepare deferred system Sans fallback", 5);
            defer timing.end();
            self.result = self.prepare() catch |err| failed: {
                if (err == error.Canceled) return;
                const value = a.create(Result) catch break :failed null;
                value.* = .{};
                value.failure = a.dupe(u8, @errorName(err)) catch &.{};
                break :failed value;
            };
        }
        if (self.canceled.load(.monotonic)) return;
        if (self.mono) profile.signal(self.tracing, @src(), "System monospace prepared", 2)
        else profile.signal(self.tracing, @src(), "System Sans fallback prepared", 5);
        self.done.store(true, .release);
        if (self.notify) |notify| notify();
    }
    fn join(self: *Worker) void { if (self.thread) |thread| thread.join(); self.thread = null; }
};
fn start(mono: c_int, characters: [*c]const u32, count: usize, styles: u32,
    notify: ?*const fn () callconv(.c) void, tracing: c_int) callconv(.c) ?*anyopaque
{
    if (host.font == null or (count > 0 and characters == null) or count > 1_000_000) return null;
    const self = a.create(Worker) catch return null;
    const copy = a.dupe(u32, if (count > 0) characters[0..count] else &.{}) catch { a.destroy(self); return null; };
    self.* = .{ .mono = mono != 0, .characters = copy, .styles = styles & 15, .notify = notify, .tracing = tracing != 0 };
    self.thread = std.Thread.spawn(.{}, Worker.run, .{self}) catch { a.free(copy); a.destroy(self); return null; };
    return self;
}
fn complete(value: ?*anyopaque) callconv(.c) c_int {
    const self: *Worker = @ptrCast(@alignCast(value orelse return 1));
    return @intFromBool(self.done.load(.acquire));
}
fn take(value: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Worker = @ptrCast(@alignCast(value orelse return null));
    if (!self.done.load(.acquire)) return null;
    self.join();
    const result = self.result; self.result = null;
    return result;
}
fn stop(value: ?*anyopaque) callconv(.c) void {
    const self: *Worker = @ptrCast(@alignCast(value orelse return));
    self.canceled.store(true, .monotonic); self.join();
    if (self.result) |result| result.destroy();
    a.free(self.characters); a.destroy(self);
}
fn destroy(value: ?*anyopaque) callconv(.c) void { const self: *Result = @ptrCast(@alignCast(value orelse return)); self.destroy(); }
fn family(value: ?*anyopaque) callconv(.c) c.struct_MdfFontBytes {
    const self: *Result = @ptrCast(@alignCast(value orelse return .{ .data = null, .length = 0 }));
    const text = if (self.prepared) |prepared| prepared.family else "";
    return .{ .data = text.ptr, .length = text.len };
}
fn failure(value: ?*anyopaque) callconv(.c) c.struct_MdfFontBytes {
    const self: *Result = @ptrCast(@alignCast(value orelse return .{ .data = null, .length = 0 }));
    return .{ .data = self.failure.ptr, .length = self.failure.len };
}
fn measure(value: ?*anyopaque, text: [*c]const u8, len: usize, size: c_int, style: c_int, out: [*c]c.struct_MdfSystemTextMetrics) callconv(.c) c_int {
    const self: *Result = @ptrCast(@alignCast(value orelse return 0));
    return if (self.text) |map| c.mdf_system_text_measure(map, text, len, size, style, out) else 0;
}
fn bitmap(value: ?*anyopaque, text: [*c]const u8, len: usize, size: c_int, style: c_int,
    x: f32, baseline: f32, width: c_int, height: c_int, out: [*c]c.struct_MdfTextMask) callconv(.c) c_int
{
    const self: *Result = @ptrCast(@alignCast(value orelse return 0));
    return if (self.text) |map| c.mdf_system_text_bitmap(map, text, len, size, style, x, baseline, width, height, out) else 0;
}
fn hasCharacter(value: ?*anyopaque, ch: u32) callconv(.c) c_int {
    const self: *Result = @ptrCast(@alignCast(value orelse return 0));
    return if (self.text) |map| c.mdf_system_text_has_character(map, ch) else 0;
}
fn unknown(value: ?*anyopaque, text: [*c]const u8, len: usize, style: c_int) callconv(.c) c_int {
    const self: *Result = @ptrCast(@alignCast(value orelse return -1));
    return if (self.text) |map| c.mdf_system_text_unknown_glyphs(map, text, len, style) else -1;
}
fn addFallback(value: ?*anyopaque, other_value: ?*anyopaque) callconv(.c) c_int {
    const self: *Result = @ptrCast(@alignCast(value orelse return 0));
    const other: *Result = @ptrCast(@alignCast(other_value orelse return 0));
    if (self.text == null or other.text == null) return 0;
    return c.mdf_system_text_add_fallback(self.text, other.text, null, 0);
}
fn retainResources(value: ?*anyopaque) callconv(.c) ?*anyopaque {
    const self: *Result = @ptrCast(@alignCast(value orelse return null));
    const prepared = self.prepared orelse return null;
    prepared.retain(); return prepared;
}
fn releaseResources(value: ?*anyopaque) callconv(.c) void {
    const prepared: *fonts.Prepared = @ptrCast(@alignCast(value orelse return)); prepared.destroy();
}
fn resources(value: ?*anyopaque) callconv(.c) c.struct_MdfPreparedFontView {
    return if (value != null) c.mdf_font_prepared_view(value) else std.mem.zeroes(c.struct_MdfPreparedFontView);
}
fn fromResources(value: ?*anyopaque) callconv(.c) ?*anyopaque {
    const prepared: *fonts.Prepared = @ptrCast(@alignCast(value orelse return null));
    const result = a.create(Result) catch return null;
    prepared.retain();
    result.* = .{ .prepared = prepared };
    var error_buffer: [512]u8 = @splat(0);
    result.text = c.mdf_system_text_create(prepared, &error_buffer, error_buffer.len);
    if (result.text == null) {
        const reason = std.mem.sliceTo(&error_buffer,0);
        result.failure = a.dupe(u8,if(reason.len>0) reason else "Cannot clone prepared font map") catch { result.destroy(); return null; };
    }
    return result;
}
const api: c.struct_MdfTextApi = .{ .abi = c.MDF_TEXT_ABI, .size = @sizeOf(c.struct_MdfTextApi), .kind = c.MDF_MODULE_TEXT, .reserved = 0,
    .initialize = initialize, .start = start, .complete = complete, .take = take, .stop = stop, .destroy = destroy,
    .family = family, .@"error" = failure, .measure = measure, .bitmap = bitmap, .has_character = hasCharacter,
    .unknown_glyphs = unknown, .add_fallback = addFallback, .retain_resources = retainResources,
    .release_resources = releaseResources, .resources = resources, .from_resources = fromResources };
pub export fn mdf_text_api(abi: u32) callconv(.c) ?*const c.struct_MdfTextApi { return if (abi == c.MDF_TEXT_ABI) &api else null; }
