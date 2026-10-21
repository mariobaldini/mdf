//! The GUI boundary contains only C scalars, byte slices and an opaque handle.
//! The Zig side owns workers and their borrowed document/font storage. The frontend
//! copies typed document views and font/image bytes before requesting replacement.
const std = @import("std");
const c = @import("native");
const document = @import("document.zig");
const loading = @import("loader.zig");
const navigation = @import("navigation.zig");
const settings = @import("settings.zig");
const profiling = @import("profiling.zig");
const a = std.heap.c_allocator;

pub const Buffer = extern struct { ptr: ?[*]const u8 = null, len: usize = 0 };
pub const BlockView = extern struct {
    kind: Buffer = .{},
    prefix: Buffer = .{},
    language: Buffer = .{},
    anchor: Buffer = .{},
    alert: Buffer = .{},
    image_src: Buffer = .{},
    spans: usize = 0,
    cells: usize = 0,
    columns: usize = 0,
    bytes: usize = 0,
    lines: usize = 1,
    indent: usize = 0,
    quote: usize = 0,
    parent: isize = -1,
    heading: u32 = 0,
    flags: u32 = 0,
    task: i32 = -1,
};
pub const SpanView = extern struct { text: Buffer = .{}, link: Buffer = .{}, flags: u32 = 0 };
pub const CellView = extern struct { spans: usize = 0, alignment: u32 = 0 };
fn borrowed(bytes: []const u8) Buffer {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
const Wake = *const fn () callconv(.c) void;
var wake_callback: std.atomic.Value(?Wake) = .init(null);
fn notify() void {
    if (wake_callback.load(.acquire)) |wake| wake();
}

const Core = struct {
    loader: *loading.Loader,
    nav: *navigation.Worker,
    doc: ?document.Document = null,
    generation: u64 = 0,
    revision: u64 = 0,
    read_ns: u64 = 0,
    parse_ns: u64 = 0,
    watch_available: bool = true,
    store: ?settings.Store = null,
    values: settings.Values = .{},
    recorder: ?*profiling.Recorder = null,
};

fn json(value: anytype) Buffer {
    const bytes = std.json.Stringify.valueAlloc(a, value, .{}) catch return .{};
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
fn failure(err: anyerror) Buffer {
    return json(.{ .err = @errorName(err) });
}
fn slice(ptr: [*]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

export fn mdf_buffer_free(buffer: Buffer) void {
    if (buffer.ptr) |ptr| a.free(ptr[0..buffer.len]);
}
export fn mdf_now_ns() u64 {
    return profiling.nowNs();
}
export fn mdf_core_mode() [*:0]const u8 {
    const mode = @tagName(@import("builtin").mode);
    return if (std.mem.eql(u8, mode, "fast")) "ReleaseFast" else if (std.mem.eql(u8, mode, "safe")) "ReleaseSafe" else if (std.mem.eql(u8, mode, "small")) "ReleaseSmall" else if (std.mem.eql(u8, mode, "debug")) "Debug" else mode;
}
export fn mdf_core_create(home: [*]const u8, home_len: usize, profile: bool, origin: u64, wake: Wake) ?*Core {
    const self = a.create(Core) catch return null;
    wake_callback.store(wake, .release);
    self.* = .{
        .loader = undefined,
        .nav = undefined,
    };
    if (profile) {
        const recorder = a.create(profiling.Recorder) catch {
            a.destroy(self);
            return null;
        };
        recorder.init(origin) catch {
            a.destroy(recorder);
            a.destroy(self);
            return null;
        };
        recorder.enable();
        self.recorder = recorder;
    }
    self.loader = loading.Loader.create(a, notify) catch {
        if (self.recorder) |r| {
            r.deinit();
            a.destroy(r);
        }
        a.destroy(self);
        return null;
    };
    self.nav = navigation.Worker.create(a, notify) catch {
        self.loader.destroy();
        if (self.recorder) |r| {
            r.deinit();
            a.destroy(r);
        }
        a.destroy(self);
        return null;
    };
    self.store = settings.Store.init(a, slice(home, home_len)) catch null;
    if (!profile) if (self.store) |*store| {
        self.values = store.load() catch .{};
    };
    self.loader.setAutoReload(self.values.auto_reload);
    return self;
}
export fn mdf_core_destroy(self: *Core) void {
    self.loader.destroy();
    self.nav.destroy();
    wake_callback.store(null, .release);
    if (self.doc) |*doc| doc.deinit();
    if (self.store) |*store| store.deinit();
    if (self.recorder) |r| {
        r.deinit();
        a.destroy(r);
    }
    a.destroy(self);
}
export fn mdf_core_set_wake(self: *Core, wake: ?Wake) void {
    _ = self;
    wake_callback.store(wake, .release);
    // Results can become ready during the bootstrap-to-GUI handoff.
    // Notify the new consumer even if the previous callback is in flight.
    notify();
}
export fn mdf_core_open(self: *Core, ptr: [*]const u8, len: usize) Buffer {
    profiling.signal(@src(), "Request document", .gui);
    self.generation = self.loader.request(slice(ptr, len)) catch |err| return failure(err);
    return json(.{ .generation = self.generation });
}
export fn mdf_core_poll(self: *Core) Buffer {
    var result = self.loader.take() orelse return .{};
    defer result.deinit();
    if (result.generation != self.generation) return .{};
    if (result.failure) |err| return failure(err);
    profiling.signal(@src(), "Accept document", .gui);
    self.nav.reset(); // Join before replacing the document borrowed by this worker.
    if (self.doc) |*doc| doc.deinit();
    self.doc = result.document;
    result.document = null;
    self.read_ns = result.read_ns;
    self.parse_ns = result.parse_ns;
    self.watch_available = result.watch_available;
    self.revision += 1;
    const doc = &self.doc.?;
    // File reads and outline preparation do not need GUI/font metrics. Start
    // them while the bootstrap's other worker loads the UI dependency graph.
    profiling.signal(@src(), "Request early document assets", .gui);
    self.nav.start(doc.blocks, doc.path, .{ .width = 0, .zoom = 1, .character_width = 1 }) catch {};
    // Bulk text uses borrowed typed views, avoiding a second giant JSON tree.
    return json(.{
        .revision = self.revision,
        .path = @as([]const u8, doc.path),
        .source_bytes = doc.source.len,
        .block_count = doc.blocks.len,
        .automatic = result.automatic,
        .watch_available = self.watch_available,
        .read_ns = self.read_ns,
        .parse_ns = self.parse_ns,
    });
}
// These views borrow immutable document storage until the next successful poll
// or destruction. The frontend copies it synchronously on the GUI thread.
export fn mdf_core_block(self: *Core, index: usize) BlockView {
    const doc = self.doc orelse return .{};
    if (index >= doc.blocks.len) return .{};
    const b = doc.blocks[index];
    return .{
        .kind = borrowed(@tagName(b.kind)),
        .prefix = borrowed(b.prefix),
        .language = borrowed(b.language),
        .anchor = borrowed(b.anchor),
        .alert = borrowed(if (b.alert) |alert| @tagName(alert) else ""),
        .image_src = borrowed(b.image_src orelse ""),
        .spans = b.spans.len,
        .cells = b.cells.len,
        .columns = b.columns.len,
        .bytes = b.bytes,
        .lines = b.lines,
        .indent = b.indent,
        .quote = b.quote,
        .parent = if (b.details_parent) |p| @intCast(p) else -1,
        .heading = b.heading,
        .flags = @as(u32, @intFromBool(b.details_open)) |
            (@as(u32, @intFromBool(b.alert_start)) << 1) |
            (@as(u32, @intFromBool(b.table_header)) << 2) |
            (@as(u32, @intFromBool(b.table_last)) << 3) |
            (@as(u32, @intFromBool(b.table_stripe)) << 4),
        .task = if (b.task) |v| @as(i32, @intFromBool(v)) else -1,
    };
}
export fn mdf_core_span(self: *Core, index: usize, cell: isize, span: usize) SpanView {
    const doc = self.doc orelse return .{};
    if (index >= doc.blocks.len) return .{};
    const b = doc.blocks[index];
    const values = if (cell < 0) b.spans else if (cell < b.cells.len) b.cells[@intCast(cell)].spans else return .{};
    if (span >= values.len) return .{};
    const s = values[span];
    return .{
        .text = borrowed(s.text),
        .link = borrowed(s.link orelse ""),
        .flags = @as(u32, @intFromBool(s.bold)) |
            (@as(u32, @intFromBool(s.italic)) << 1) |
            (@as(u32, @intFromBool(s.code)) << 2) |
            (@as(u32, @intFromBool(s.strike)) << 3) |
            (@as(u32, @intFromBool(s.underline)) << 4) |
            (@as(u32, @intFromBool(s.highlight)) << 5) |
            (@as(u32, @intFromBool(s.small)) << 6),
    };
}
export fn mdf_core_cell(self: *Core, index: usize, cell: usize) CellView {
    const doc = self.doc orelse return .{};
    if (index >= doc.blocks.len or cell >= doc.blocks[index].cells.len) return .{};
    const value = doc.blocks[index].cells[cell];
    return .{ .spans = value.spans.len, .alignment = @backingInt(value.alignment) };
}
export fn mdf_core_column(self: *Core, index: usize, column: usize) usize {
    const doc = self.doc orelse return 0;
    if (index >= doc.blocks.len or column >= doc.blocks[index].columns.len) return 0;
    return doc.blocks[index].columns[column].characters;
}
export fn mdf_core_navigation_start(self: *Core, width: f32, zoom: f32, advance: f32) bool {
    const doc = self.doc orelse return false;
    profiling.signal(@src(), "Request navigation", .gui);
    self.nav.start(doc.blocks, doc.path, .{ .width = width, .zoom = zoom, .character_width = advance }) catch return false;
    return true;
}
export fn mdf_core_navigation_ready(self: *Core) bool {
    return self.nav.status() == .ready;
}
export fn mdf_core_navigation(self: *Core) Buffer {
    if (self.nav.status() != .ready) return json(.{ .status = @tagName(self.nav.status()) });
    profiling.signal(@src(), "Accept navigation", .gui);
    const model = &self.nav.model.?;
    const indices = a.alloc(usize, model.images.len) catch return .{};
    defer a.free(indices);
    for (model.images, indices) |img, *index| index.* = img.index;
    return json(.{ .status = "ready", .revision = self.revision, .headings = model.headings, .preview = model.preview, .images = indices });
}
// Borrowed bytes remain valid until the next open/poll/navigation_start/destroy.
export fn mdf_core_image(self: *Core, index: usize) Buffer {
    if (self.nav.status() == .ready) for (self.nav.model.?.images) |img| {
        if (img.index == index) return .{ .ptr = img.bytes.ptr, .len = img.bytes.len };
    };
    return .{};
}
export fn mdf_core_settings(self: *Core) Buffer {
    return json(self.values);
}
export fn mdf_core_settings_update(self: *Core, ptr: [*]const u8, len: usize) Buffer {
    const parsed = std.json.parseFromSlice(settings.Values, a, slice(ptr, len), .{ .ignore_unknown_fields = true }) catch |err| return failure(err);
    defer parsed.deinit();
    self.values = parsed.value;
    self.values.font_size = std.math.clamp(self.values.font_size, 8, 72);
    self.loader.setAutoReload(self.values.auto_reload);
    if (self.recorder == null) if (self.store) |*store| {
        if (self.values.save_settings_across_sessions) store.save(self.values) catch |err| return failure(err) else store.clear() catch |err| return failure(err);
    };
    return json(self.values);
}
export fn mdf_core_link(self: *Core, ptr: [*]const u8, len: usize) Buffer {
    const resolved = @import("links.zig").resolve(a, if (self.doc) |doc| doc.path else "", slice(ptr, len)) catch |err| return failure(err);
    return switch (resolved) {
        inline else => |url, tag| blk: {
            defer a.free(url);
            break :blk json(.{ .kind = @tagName(tag), .url = url });
        },
    };
}
export fn mdf_profile_event(track: u8, name: [*]const u8, name_len: usize, source: [*]const u8, source_len: usize, line: u32, start: u64, duration: u64, depth: usize, waiting: bool) void {
    profiling.external(std.enums.fromInt(profiling.Track, track) orelse .gui, if (waiting) .wait else .work, slice(name, name_len), slice(source, source_len), line, start, duration, depth);
}
export fn mdf_profile_signal(track: u8, name: [*]const u8, name_len: usize, source: [*]const u8, source_len: usize, line: u32, at: u64) void {
    profiling.external(std.enums.fromInt(profiling.Track, track) orelse .gui, .signal, slice(name, name_len), slice(source, source_len), line, at, 0, 0);
}
export fn mdf_core_profile(self: *Core) Buffer {
    const r = self.recorder orelse return .{};
    const snapshot = r.snapshot(a) catch return .{};
    defer a.free(snapshot.events);
    return json(.{ .events = snapshot.events, .dropped_events = snapshot.dropped, .usage = c.mdf_get_profile_usage() });
}

test "C boundary preserves settings and rejects unsafe links" {
    const self = mdf_core_create("", 0, false, 0, struct {
        fn wake() callconv(.c) void {}
    }.wake).?;
    defer mdf_core_destroy(self);
    const value = "{\"font_size\":18,\"dark_mode\":true}";
    const updated = mdf_core_settings_update(self, value, value.len);
    defer mdf_buffer_free(updated);
    try std.testing.expectEqual(@as(u16, 18), self.values.font_size);
    try std.testing.expect(self.values.dark_mode and !self.values.save_settings_across_sessions);
    const legacy = "{\"font_family\":\"unknown-legacy-family\",\"font_size\":19,\"theme\":\"terminal\",\"dark_mode\":true,\"show_preview\":false}";
    const migrated = mdf_core_settings_update(self, legacy, legacy.len);
    defer mdf_buffer_free(migrated);
    try std.testing.expectEqual(@as(u16, 19), self.values.font_size);
    try std.testing.expect(self.values.dark_mode and !self.values.show_preview);
    try std.testing.expectEqual(settings.Preset.terminal, self.values.theme);
    try std.testing.expect(std.mem.indexOf(u8, migrated.ptr.?[0..migrated.len], "font_family") == null);
    const link = "javascript:alert(1)";
    const rejected = mdf_core_link(self, link, link.len);
    defer mdf_buffer_free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected.ptr.?[0..rejected.len], "UnsupportedLink") != null);
}

test "typed document views preserve styles tasks tables and bounds" {
    const self = mdf_core_create("", 0, false, 0, struct {
        fn wake() callconv(.c) void {}
    }.wake).?;
    defer mdf_core_destroy(self);
    self.doc = try document.Document.parseDeferred(a, "# T **bold**\n\n- [x] Done\n\n| A | B |\n| :--- | ---: |\n| ~~gone~~ | `code` |\n", "sample.md");
    const heading = mdf_core_block(self, 0);
    try std.testing.expectEqual(@as(u32, 1), heading.heading);
    const bold = mdf_core_span(self, 0, -1, heading.spans - 1);
    try std.testing.expect(bold.flags & 1 != 0);
    try std.testing.expectEqualStrings("bold", bold.text.ptr.?[0..bold.text.len]);
    try std.testing.expectEqual(@as(i32, 1), mdf_core_block(self, 1).task);
    try std.testing.expect(mdf_core_block(self, 2).flags & 4 != 0);
    try std.testing.expectEqual(@as(u32, 2), mdf_core_cell(self, 3, 1).alignment);
    try std.testing.expect(mdf_core_span(self, 3, 0, 0).flags & 8 != 0);
    try std.testing.expect(mdf_core_span(self, 3, 1, 0).flags & 4 != 0);
    try std.testing.expect(mdf_core_block(self, 100).kind.ptr == null);
    try std.testing.expect(mdf_core_span(self, 3, 100, 0).text.ptr == null);
}

// Regular/bold are raw font data. Each italic face is a separate compressed
// resource; the host inflates it only when that actual style is requested.
export fn mdf_font_resource(family: u32, style: u32) Buffer {
    const bytes: []const u8 = switch (family) {
        0 => switch (style) {
            0 => @embedFile("open-sans-regular"),
            1 => @embedFile("open-sans-bold"),
            2 => @embedFile("open-sans-italic"),
            3 => @embedFile("open-sans-bold-italic"),
            else => return .{},
        },
        else => return .{},
    };
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

export fn mdf_notices() Buffer {
    const bytes = @embedFile("notices") ++ "\n\n" ++ @embedFile("mermaid-notices");
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
