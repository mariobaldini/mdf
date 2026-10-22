//! Standalone offscreen probe for the native reader. It uses the production
//! core/layout/fonts/PNG encoder and leaves the shipping backend unchanged.
const std = @import("std");
const c = @import("native");
const paint = @import("canvas.zig");
const reader = @import("reader.zig");
const a = std.heap.c_allocator;
fn wake() callconv(.c) void {}
fn render(path: [*:0]const u8, output: [*:0]const u8, anchor: []const u8, width: i32, height: i32) !void {
    const began = c.mdf_now_ns();
    const core = c.mdf_core_create("", 0, false, 0, wake) orelse return error.CoreCreationFailed;
    defer c.mdf_core_destroy(core);
    const requested = c.mdf_core_open(core, path, std.mem.len(path));
    defer c.mdf_buffer_free(requested);
    while (true) {
        const value = c.mdf_core_poll(core);
        if (value.ptr != null) {
            defer c.mdf_buffer_free(value);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, reader.bytes(value), .{});
            defer parsed.deinit();
            if (parsed.value.object.contains("err")) return error.DocumentLoadFailed;
            break;
        }
        if (c.mdf_now_ns() - began > 30 * std.time.ns_per_s) return error.DocumentLoadTimeout;
        var delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = std.time.ns_per_ms };
        _ = c.nanosleep(&delay, null);
    }
    const loaded = c.mdf_now_ns();
    if (width <= 0 or height <= 0 or width > 16384 or height > 16384) return error.InvalidCanvas;
    var canvas = try paint.Canvas.init(a, width, height, .{});
    defer canvas.deinit();
    var view = try reader.Reader.init(a, core, &canvas);
    defer view.deinit();
    if (anchor.len > 0) view.jump(anchor);
    const ready = c.mdf_now_ns();
    try view.draw();
    const painted = c.mdf_now_ns();
    try canvas.png(output);
    const report = try std.json.Stringify.valueAlloc(a, .{
        .renderer = "z2d offscreen initial viewport", .width = canvas.surface.getWidth(), .height = canvas.surface.getHeight(),
        .blocks = view.layouts.len, .font_styles = canvas.loaded_styles,
        .document_ms = @as(f64, @floatFromInt(loaded - began)) / std.time.ns_per_ms,
        .prepare_ms = @as(f64, @floatFromInt(ready - loaded)) / std.time.ns_per_ms,
        .layout_and_paint_ms = @as(f64, @floatFromInt(painted - ready)) / std.time.ns_per_ms,
        .total_ms = @as(f64, @floatFromInt(painted - began)) / std.time.ns_per_ms,
    }, .{});
    defer a.free(report);
    if (c.fwrite(report.ptr, 1, report.len, c.stdout) != report.len) return error.CannotWriteReport;
}
pub export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc < 3) {
        const usage = "Usage: mdf-native-render FILE.md OUTPUT.png [ANCHOR] [WIDTH] [HEIGHT]\n";
        _ = c.fwrite(usage.ptr, 1, usage.len, c.stderr);
        return 2;
    }
    const width = if (argc > 4) std.fmt.parseInt(i32, std.mem.span(argv[4]), 10) catch return 2 else 1020;
    const height = if (argc > 5) std.fmt.parseInt(i32, std.mem.span(argv[5]), 10) catch return 2 else 682;
    render(argv[1], argv[2], if (argc > 3) std.mem.span(argv[3]) else "", width, height) catch |err| {
        const message = @errorName(err);
        _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
        return 1;
    };
    return 0;
}
