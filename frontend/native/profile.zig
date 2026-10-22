//! Native wait observations. Syscall timestamps exclude descriptor inspection.
const std = @import("std");
const c = @import("native");
const trace = @import("ui_profile");
pub const Wait = struct {
    start: u64,
    result: c_int,
    err: c_int,
    watched: [3]c_int,
    ready: [3]c_int,
    watched_count: usize,
    ready_count: usize,
    compositor_readable: bool,
    compositor_writable: bool,
    worker: bool,
};
pub const Waits = struct {
    values: [256]Wait = undefined,
    count: usize = 0,
    dropped: usize = 0,
    pub fn poll(self: *Waits, enabled: bool, fds: []c.struct_pollfd) c_int {
        const start = if (enabled) c.mdf_now_ns() else 0;
        const result = c.poll(fds.ptr, fds.len, 1000);
        const saved = c.__errno_location().*;
        if (start != 0) {
            const finish = c.mdf_now_ns();
            const readable = fds[0].revents & c.POLLIN != 0;
            const writable = fds[0].revents & c.POLLOUT != 0;
            const worker = fds[1].revents & c.POLLIN != 0;
            const name = if (result == 0) "Wait for native events — timeout" else if (result < 0) "Wait for native events — interrupted or failed" else if (worker) "Wait for native workers — wake descriptor readable" else if (readable) "Wait for Wayland events — compositor readable" else if (writable) "Wait for Wayland events — compositor writable" else "Wait for native events — transfer or descriptor status";
            c.mdf_profile_event(0, name.ptr, name.len, @src().file.ptr, @src().file.len, @src().line, start, finish - start, trace.nestingDepth(), true);
            if (self.count < self.values.len) {
                var value: Wait = .{ .start = start, .result = result, .err = if (result < 0) saved else 0, .watched = @splat(-1), .ready = @splat(-1), .watched_count = 0, .ready_count = 0, .compositor_readable = readable, .compositor_writable = writable, .worker = worker };
                for (fds) |fd| if (fd.fd >= 0) {
                    value.watched[value.watched_count] = fd.fd;
                    value.watched_count += 1;
                    if (fd.revents != 0) {
                        value.ready[value.ready_count] = fd.fd;
                        value.ready_count += 1;
                    }
                };
                self.values[self.count] = value;
                self.count += 1;
            } else self.dropped += 1;
        }
        c.__errno_location().* = saved;
        return result;
    }
    pub fn annotate(self: *const Waits, events: *std.json.Value, allocator: std.mem.Allocator, origin: u64) !void {
        for (self.values[0..self.count]) |wait| {
            for (events.array.items) |*event| {
                const start = event.object.get("start_ns") orelse continue;
                if (start != .integer or start.integer != wait.start - origin or event.object.get("kind").? != .string or
                    !std.mem.eql(u8, event.object.get("kind").?.string, "wait")) continue;
                const reason = if (wait.result == 0) "timeout" else if (wait.result < 0) "error or interruption" else if (wait.worker and
                    !wait.compositor_readable and !wait.compositor_writable) "other descriptor" else if (wait.compositor_readable or wait.compositor_writable) "compositor" else "clipboard transfer";
                var info: std.json.Value = .{ .object = .empty };
                try info.object.put(allocator, "api", .{ .string = "poll" });
                try info.object.put(allocator, "result", .{ .integer = wait.result });
                try info.object.put(allocator, "errno", .{ .integer = wait.err });
                try info.object.put(allocator, "timeout_ms", .{ .integer = 1000 });
                try info.object.put(allocator, "reason", .{ .string = reason });
                try info.object.put(allocator, "compositor_readable", .{ .bool = wait.compositor_readable });
                try info.object.put(allocator, "compositor_writable", .{ .bool = wait.compositor_writable });
                try info.object.put(allocator, "worker_wake", .{ .bool = wait.worker });
                for ([_]struct { name: []const u8, fds: []const c_int }{ .{ .name = "watched_fds", .fds = wait.watched[0..wait.watched_count] }, .{ .name = "ready_fds", .fds = wait.ready[0..wait.ready_count] } }) |entry| {
                    var values: std.array_list.Managed(std.json.Value) = .init(allocator);
                    for (entry.fds) |fd| try values.append(.{ .integer = fd });
                    try info.object.put(allocator, entry.name, .{ .array = values });
                }
                try event.object.put(allocator, "wait", info);
                try event.object.put(allocator, "description", .{ .string = try std.fmt.allocPrint(allocator, "Measured Linux poll wait: {s}; result {d}, errno {d}, timeout 1000 ms. A worker wake uses the shared notification descriptor; recorded worker handoffs identify the result adopted afterward.", .{ reason, wait.result, wait.err }) });
                break;
            }
        }
    }
};

/// Promote native diagnostics into the report format used by make profile.
/// Conversion and serialization run after the ready-frame timestamp.
pub fn report(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const root = &parsed.value.object;
    const recorded = root.get("profile").?.object;
    try root.put(arena, "events", recorded.get("events").?);
    try root.put(arena, "dropped_events", recorded.get("dropped_events").?);
    _ = root.swapRemove("profile");
    var metrics: std.json.ObjectMap = .empty;
    var usage = root.get("startup_usage").?.object.iterator();
    while (usage.next()) |entry| try metrics.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    for ([_][2][]const u8{
        .{ "first_frame_ms", "ready_ms" },            .{ "full_ready_ms", "ready_ms" },                  .{ "first_document_ms", "flush_ms" },
        .{ "first_document_commit_ms", "commit_ms" }, .{ "first_document_flush_ms", "flush_ms" },        .{ "scaffold_ms", "flush_ms" },
        .{ "window_present_ms", "flush_ms" },         .{ "backend_ms", "backend_ms" },                   .{ "read_ms", "read_ms" },
        .{ "parse_ms", "parse_ms" },                  .{ "source_bytes", "source_bytes" },               .{ "blocks", "blocks" },
        .{ "total_frames", "startup_paints" },                .{ "document_frames", "startup_paints" },                  .{ "ui_module_ready_ms", "ui_module_ready_ms" },
        .{ "ui_module_bytes", "ui_module_bytes" },    .{ "bundled_font_styles", "startup_font_styles" },
    }) |entry| try metrics.put(arena, entry[0], root.get(entry[1]).?);
    var layout_ns: i64 = 0;
    for (root.get("events").?.array.items) |event| if (std.mem.eql(u8, event.object.get("name").?.string, "Measure visible Markdown blocks")) {
        layout_ns += event.object.get("duration_ns").?.integer;
    };
    try metrics.put(arena, "layout_ms", .{ .float = @as(f64, @floatFromInt(layout_ns)) / std.time.ns_per_ms });
    const fonts = root.get("fonts").?.object;
    for ([_][2][]const u8{ .{ "first_viewport_monospace", "first_viewport_mono" }, .{ "first_viewport_fallback", "first_viewport_fallback" }, .{ "monospace_family", "mono_family" }, .{ "fallback_families", "sans_family" }, .{ "fallback_missing_glyph_count", "unresolved" }, .{ "fallback_requested_glyph_count", "requested_characters" } }) |entry| try metrics.put(arena, entry[0], fonts.get(entry[1]).?);
    for ([_]struct { name: []const u8, ready: []const u8, requested: []const u8 }{ .{ .name = "monospace_status", .ready = "mono_ready", .requested = "mono_requested" }, .{ .name = "fallback_status", .ready = "sans_ready", .requested = "sans_requested" } }) |entry|
        try metrics.put(arena, entry.name, .{ .string = if (fonts.get(entry.ready).?.bool) "ready" else if (fonts.get(entry.requested).?.bool) "unavailable" else "not-needed" });
    const counts = root.get("assets").?.object.get("counts").?.object;
    for ([_][2][]const u8{ .{ "decoded_images", "raster" }, .{ "rendered_diagrams", "mermaid" }, .{ "rendered_svgs", "svg" }, .{ "diagram_errors", "failures" } }) |entry|
        try metrics.put(arena, entry[0], counts.get(entry[1]).?);
    for ([_][2][]const u8{ .{ "mermaid_engine", "pozeiden" }, .{ "svg_engine", "zig-svg" }, .{ "image_decoder", "zignal" }, .{ "png_encoder", "zignal" }, .{ "compression_engine", "std.compress.flate" }, .{ "markdown_parser", "zigmark" }, .{ "markdown_parser_version", "0.11.1" }, .{ "image_decoder_version", "0.11.0" }, .{ "json_engine", "std.json" }, .{ "drawing_library", "z2d" }, .{ "drawing_library_version", "0.13.0" }, .{ "text_library", "deferred-pangoft2" }, .{ "cursor_backend", "native-memory" }, .{ "drawing_buffers", "shared-memory-copy" } }) |entry| try metrics.put(arena, entry[0], .{ .string = entry[1] });
    try metrics.put(arena, "input_ready", root.get("keyboard_ready").?);
    try metrics.put(arena, "library_read_ahead", .{ .bool = true });
    try root.put(arena, "metrics", .{ .object = metrics });
    try root.put(arena, "profile_version", .{ .integer = 1 });
    try root.put(arena, "file", root.get("document_path").?);
    for ([_][2][]const u8{ .{ "version", "0.2.0" }, .{ "gui", "native Zig / Wayland" }, .{ "renderer", "z2d" }, .{ "video_driver", "wayland" }, .{ "startup_policy", "native-parallel-bootstrap" }, .{ "navigation_status", "ready" }, .{ "font_initialization", "private-bundled" }, .{ "keyboard_preparation", "worker" }, .{ "frame_preparation", "markdown-first" } }) |entry| try root.put(arena, entry[0], .{ .string = entry[1] });
    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}
