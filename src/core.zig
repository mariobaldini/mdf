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
const fonts = @import("fonts.zig");
const layout = @import("layout.zig");
const flow = @import("flow.zig");
const measurement = @import("measurement.zig");
const block_layout = @import("block_layout.zig");
comptime {
    _ = @import("json.zig");
    _ = @import("diagrams.zig");
    _ = @import("viewport.zig");
}
const a = std.heap.c_allocator;
const themes = @import("themes.zig");

pub const Buffer = extern struct { ptr: ?[*]const u8 = null, len: usize = 0 };
pub const ThemeInfo = extern struct { id: Buffer = .{}, name: Buffer = .{}, font_size: u32 = 12 };
export fn mdf_theme_count() usize {
    return std.meta.tags(themes.Preset).len;
}
export fn mdf_theme_info(index: usize) ThemeInfo {
    const all = std.meta.tags(themes.Preset);
    if (index >= all.len) return .{};
    const theme = all[index];
    return .{ .id = borrowed(@tagName(theme)), .name = borrowed(theme.name()), .font_size = theme.fontSize() };
}
export fn mdf_theme_index(name: ?[*]const u8, len: usize) u32 {
    return @backingInt(themes.fromName(if (name) |ptr| ptr[0..len] else ""));
}
export fn mdf_theme_palette(index: u32, dark: bool) themes.Palette {
    const theme: themes.Preset = std.enums.fromInt(themes.Preset, index) orelse .classic;
    return theme.palette(dark);
}
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
pub const DocumentText = extern struct { text: Buffer = .{}, starts: ?[*]const usize = null, count: usize = 0, styles: u32 = 0, flags: u32 = 0 };
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

export fn mdf_text_style(kind: u32, heading: u32, span_flags: u32, table_header: bool, zoom: f32) layout.NativeStyle {
    return layout.nativeStyle(std.enums.fromInt(layout.StyleKind, kind) orelse .paragraph, heading, span_flags, table_header, zoom);
}
export fn mdf_document_width(viewport: f32, mode: u32, character_width: f32) f32 {
    const width: layout.MaxWidth = switch (mode) {
        0 => .characters_100,
        2 => .percent_100,
        else => .percent_80,
    };
    return layout.documentWidth(viewport, width, character_width);
}
export fn mdf_table_widths(minimum: ?[*]const f32, preferred: ?[*]const f32, count: usize, width: f32, padding: f32, wrap: bool, output: ?[*]f32) bool {
    if (count == 0) return true;
    if (count > 65536) return false;
    const min = minimum orelse return false;
    const pref = preferred orelse return false;
    const out = output orelse return false;
    layout.intrinsicColumns(min[0..count], pref[0..count], width, padding, wrap, out[0..count]) catch return false;
    return true;
}
const FlowResult = extern struct { runs: ?[*]flow.Run = null, count: usize = 0, height: f32 = 0, right: f32 = 0 };
export fn mdf_text_flow(spans: ?[*]const flow.Span, count: usize, spec: flow.Spec, measure: flow.Measure, context: ?*anyopaque, output: *FlowResult) bool {
    output.* = .{};
    if (count > 1_000_000 or (count != 0 and spans == null)) return false;
    const result = flow.layout(a, if (spans) |ptr| ptr[0..count] else &.{}, spec, measure, context) catch return false;
    output.* = .{ .runs = if (result.runs.len != 0) result.runs.ptr else null, .count = result.runs.len, .height = result.height, .right = result.right };
    return true;
}
export fn mdf_text_flow_free(result: FlowResult) void {
    if (result.runs) |ptr| a.free(ptr[0..result.count]);
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
    self.nav.prepare_fonts = prepareRequiredFontData;
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
export fn mdf_core_document_text(self: *Core) DocumentText {
    const doc = self.doc orelse return .{};
    return .{ .text = borrowed(doc.rendered.text), .starts = doc.rendered.starts.ptr,
        .count = doc.rendered.starts.len, .styles = doc.rendered.styles, .flags = doc.rendered.flags };
}
const FloatBuffer = extern struct { data: ?[*]f32 = null, count: usize = 0 };
export fn mdf_core_table_columns(self: *Core, index: usize, width: f32, zoom: f32, wrap: bool, mono_ready: bool, callback: measurement.Measure, context: ?*anyopaque, depth: usize, output: *FloatBuffer) bool {
    output.* = .{};
    const doc = self.doc orelse return false;
    const timing = profiling.beginExternal(@src(), "Measure intrinsic table column widths", .gui, depth);
    defer timing.end();
    const columns = measurement.tableColumns(a, doc.blocks, index, width, zoom, wrap, mono_ready, callback, context) catch return false;
    output.* = .{ .data = if (columns.len > 0) columns.ptr else null, .count = columns.len };
    return true;
}
export fn mdf_float_buffer_free(buffer: FloatBuffer) void {
    if (buffer.data) |ptr| a.free(ptr[0..buffer.count]);
}
export fn mdf_core_layout_block(self: *Core, index: usize, options: *const block_layout.Options, callback: measurement.Measure, columns: block_layout.Columns, context: ?*anyopaque) ?*block_layout.Result {
    const doc = self.doc orelse return null;
    if (index >= doc.blocks.len or index >= doc.rendered.starts.len) return null;
    const result = a.create(block_layout.Result) catch return null;
    result.* = block_layout.measure(a, doc.blocks[index], index, doc.rendered.starts[index], options.*, callback, columns, context) catch {
        a.destroy(result);
        return null;
    };
    return result;
}
export fn mdf_layout_result_view(result: *block_layout.Result) block_layout.View {
    return result.view();
}
export fn mdf_layout_result_free(result: *block_layout.Result) void {
    result.deinit();
    a.destroy(result);
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
export fn mdf_core_navigation_state(self: *Core) u32 {
    return @intFromEnum(self.nav.status());
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
export fn mdf_core_preview_count(self: *Core) usize {
    return if (self.nav.status() == .ready) self.nav.model.?.preview.len else 0;
}
export fn mdf_core_preview_lines(self: *Core, index: usize) usize {
    if (index >= mdf_core_preview_count(self)) return 0;
    return self.nav.model.?.preview[index].lines.len;
}
export fn mdf_core_preview_line(self: *Core, index: usize, line: usize) Buffer {
    if (line >= mdf_core_preview_lines(self, index)) return .{};
    return borrowed(self.nav.model.?.preview[index].lines[line]);
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
        .local => |url| blk: {
            defer a.free(url);
            const raw=slice(ptr,len);
            const raw_anchor=if(std.mem.indexOfScalar(u8,raw,'#')) |at| raw[at+1..] else "";
            const anchor=@import("links.zig").decode(a,raw_anchor) catch |err| return failure(err);
            defer a.free(anchor);
            break :blk json(.{ .kind="local",.url=url,.anchor=anchor });
        },
        inline else => |url, tag| blk: {
            defer a.free(url);
            break :blk json(.{ .kind = @tagName(tag), .url = url });
        },
    };
}
export fn mdf_drop_path(ptr: [*]const u8, len: usize) Buffer {
    const path=@import("links.zig").droppedPath(a,slice(ptr,len)) catch |err| return failure(err);
    defer a.free(path);
    return json(.{ .path=path });
}
test "local link replies preserve decoded destination fragments" {
    const self=mdf_core_create("",0,false,0,struct { fn wake() callconv(.c) void {} }.wake).?;
    defer mdf_core_destroy(self);
    self.doc=try document.Document.parseDeferred(a,"# Start\n","/tmp/docs/start.md");
    const url="next%20page.md#caf%C3%A9";
    const reply=mdf_core_link(self,url,url.len);
    defer mdf_buffer_free(reply);
    const parsed=try std.json.parseFromSlice(std.json.Value,std.testing.allocator,reply.ptr.?[0..reply.len],.{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("local",parsed.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("/tmp/docs/next page.md",parsed.value.object.get("url").?.string);
    try std.testing.expectEqualStrings("café",parsed.value.object.get("anchor").?.string);
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
test "typed preview views preserve wrapped Unicode and reject stale or out-of-range access" {
    const self = mdf_core_create("", 0, false, 0, struct {
        fn wake() callconv(.c) void {}
    }.wake).?;
    defer mdf_core_destroy(self);
    try std.testing.expectEqual(@as(usize, 0), mdf_core_preview_count(self));
    self.doc = try document.Document.parseDeferred(a, "# Preview\n\nLatin café and Ελληνικά\n", "sample.md");
    {
        _ = c.pthread_mutex_lock(&self.nav.mutex);
        defer _ = c.pthread_mutex_unlock(&self.nav.mutex);
        self.nav.model = try navigation.Model.prepare(a, self.doc.?.blocks, "sample.md", .{ .width = 240, .zoom = 1, .character_width = 7 }, null);
        self.nav.state.store(.ready, .release);
    }
    try std.testing.expectEqual(@as(u32, 2), mdf_core_navigation_state(self));
    try std.testing.expectEqual(self.doc.?.blocks.len, mdf_core_preview_count(self));
    for (self.nav.model.?.preview, 0..) |block, index| {
        try std.testing.expectEqual(block.lines.len, mdf_core_preview_lines(self, index));
        for (block.lines, 0..) |text, row| {
            const line = mdf_core_preview_line(self, index, row);
            try std.testing.expectEqualStrings(text, line.ptr.?[0..line.len]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(line.ptr.?[0..line.len]));
        }
    }
    try std.testing.expect(mdf_core_preview_line(self, 999, 0).ptr == null);
    try std.testing.expect(mdf_core_preview_line(self, 0, 999).ptr == null);
    self.nav.state.store(.working, .release);
    try std.testing.expectEqual(@as(u32, 1), mdf_core_navigation_state(self));
    try std.testing.expectEqual(@as(usize, 0), mdf_core_preview_count(self));
    try std.testing.expect(mdf_core_preview_line(self, 0, 0).ptr == null);
}
test "shared C ABI matches Zig record sizes alignment and field offsets" {
    const viewport = @import("viewport.zig");
    inline for (.{
        .{ Buffer, c.Buffer }, .{ BlockView, c.MdfBlockView }, .{ SpanView, c.MdfSpanView },
        .{ ThemeInfo, c.MdfThemeInfo }, .{ themes.Palette, c.MdfThemePalette },
        .{ CellView, c.MdfCellView }, .{ DocumentText, c.MdfDocumentText }, .{ layout.NativeStyle, c.MdfTextStyle },
        .{ flow.Span, c.MdfFlowSpan }, .{ flow.Spec, c.MdfFlowSpec }, .{ flow.Metrics, c.MdfFlowMetrics },
        .{ flow.Run, c.MdfFlowRun }, .{ FlowResult, c.MdfFlowResult }, .{ measurement.Font, c.MdfLayoutFont },
        .{ FloatBuffer, c.MdfFloatBuffer }, .{ block_layout.Options, c.MdfLayoutOptions },
        .{ block_layout.Run, c.MdfLayoutRun }, .{ block_layout.Rect, c.MdfLayoutRect }, .{ block_layout.View, c.MdfLayoutView },
        .{ viewport.Fields, c.MdfViewportFields }, .{ viewport.View, c.MdfViewportView },
    }) |pair| {
        const Zig = pair[0];
        const C = pair[1];
        try std.testing.expectEqual(@sizeOf(Zig), @sizeOf(C));
        try std.testing.expectEqual(@alignOf(Zig), @alignOf(C));
        inline for (@typeInfo(Zig).@"struct".field_names) |name| if (@hasField(C, name)) {
            try std.testing.expectEqual(@offsetOf(Zig, name), @offsetOf(C, name));
        };
    }
}

// Every face returns immutable raw bytes from the same checked Zig cache.
// Startup inflates regular/bold; each italic face stays lazy and independent.
var startup_fonts: fonts.Startup = .{
    .allocator = a,
    .resources = &.{ @embedFile("open-sans-regular"), @embedFile("open-sans-bold"), @embedFile("open-sans-italic"), @embedFile("open-sans-bold-italic") },
};
fn prepareRequiredFontData(blocks: []const document.Block) void {
    const styles = fonts.requiredStyles(blocks);
    if (styles == 0) return;
    const phase = profiling.begin(@src(), "Prepare required bundled italic data", .navigation);
    defer phase.end();
    inline for (2..4) |style| if (styles & (@as(u32, 1) << style) != 0) {
        _ = startup_fonts.get(style) catch {};
    };
}
export fn mdf_startup_fonts_begin() void {
    startup_fonts.start();
}
export fn mdf_startup_fonts_end() void {
    startup_fonts.finish();
}
export fn mdf_font_resource(family: u32, style: u32) Buffer {
    if (family != 0) return .{};
    return borrowed(startup_fonts.get(style) catch return .{});
}

export fn mdf_notices() Buffer {
    const bytes = @embedFile("notices") ++ "\n\n" ++ @embedFile("mermaid-notices");
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}
