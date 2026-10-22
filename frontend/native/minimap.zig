//! Bounded tiny-text atlas, prepared after the first document flush.
const std = @import("std");
const profile=@import("ui_profile");
const c = @import("native");
const paint = @import("canvas.zig");
const fonts = @import("font-runtime.zig");
const a = std.heap.c_allocator;
const Notify = *const fn () callconv(.c) void;
pub const Config = struct {
    tracing: bool = false,
    revision: u64,
    width: i32,
    height: i32,
    content_width: f32,
    zoom: f32,
    advance: f32,
    font_size: i32,
    slot_height: i32,
    baseline: f32,
    scale: f32,
    background: u32,
    foreground: u32,
    font_version: u64 = 0,
    fn sameNavigation(self: Config, other: Config) bool {
        return self.revision == other.revision and @abs(self.content_width - other.content_width) < 1 and
            self.zoom == other.zoom and @abs(self.advance - other.advance) < 0.01;
    }
    pub fn eql(self: Config, other: Config) bool {
        return self.sameNavigation(other) and self.width == other.width and self.height == other.height and
            self.font_size == other.font_size and self.slot_height == other.slot_height and
            self.scale == other.scale and self.background == other.background and self.foreground == other.foreground and self.font_version == other.font_version;
    }
};
const Line = struct { block: usize, row: usize, count: usize, text: []u8 };
fn freeLines(lines: []Line) void {
    for (lines) |line| a.free(line.text);
    a.free(lines);
}
pub fn sampleStride(total: usize, limit: usize) usize {
    return if (total == 0) 1 else (total - 1) / @max(1, limit) + 1;
}
pub fn lineBaseline(top: f32, height: f32, total: f32, map_height: f32, row: usize, count: usize, size: f32) ?f32 {
    if (height <= 0 or total <= 0 or map_height <= 0 or count == 0 or row >= count) return null;
    const ratio = map_height / total;
    const first = top * ratio;
    const available = height * ratio;
    const spacing = @min(size * 1.4, available / @as(f32, @floatFromInt(count)));
    const y = first + @as(f32, @floatFromInt(row + 1)) * @max(1, spacing);
    return if (y > first + available + size or y > map_height) null else @round(y);
}
pub const Atlas = struct {
    canvas: paint.Canvas,
    lines: []Line,
    config: Config,
    pub fn deinit(self: *Atlas) void {
        self.canvas.deinit();
        freeLines(self.lines);
    }
    pub fn draw(self: *const Atlas, destination: *paint.Canvas, x: i32, y: i32, width: i32, height: i32, offsets: []const f32, heights: []const f32, total: f32) bool {
        if (self.config.width != width or self.config.height != height or self.config.scale != destination.scale or
            self.config.background != destination.palette.panel or self.config.foreground != destination.palette.muted) return false;
        const scale = destination.scale;
        const dx: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) * scale));
        const dy: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) * scale));
        const dw: usize = @intCast(destination.surface.getWidth());
        const sw: usize = @intCast(self.canvas.surface.getWidth());
        const clip_right = @min(destination.surface.getWidth(), dx + @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(width)) * scale))));
        const clip_bottom = @min(destination.surface.getHeight(), dy + @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(height)) * scale))));
        const background: u32 = @bitCast(paint.pixel(self.config.background).argb);
        const source = self.canvas.surface.image_surface_argb.buf;
        const target = destination.surface.image_surface_argb.buf;
        const slot_pixels: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(self.config.slot_height)) * scale));
        for (self.lines, 0..) |line, slot| {
            if (line.block >= heights.len or line.block >= offsets.len) continue;
            const baseline = lineBaseline(offsets[line.block], heights[line.block], total, @floatFromInt(height), line.row, line.count, @floatFromInt(self.config.font_size)) orelse continue;
            const target_y: i32 = @intFromFloat(@round((@as(f32, @floatFromInt(y)) + baseline - self.config.baseline) * scale));
            const source_y: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(slot * @as(usize, @intCast(self.config.slot_height)))) * scale));
            var row: i32 = 0;
            while (row < slot_pixels and source_y + row < self.canvas.surface.getHeight()) : (row += 1) {
                const ty = target_y + row;
                if (ty < @max(0, dy) or ty >= clip_bottom) continue;
                var col: i32 = @max(0, -dx);
                while (col < @as(i32, @intCast(sw)) and dx + col < clip_right) : (col += 1) {
                    const value = source[@as(usize, @intCast(source_y + row)) * sw + @as(usize, @intCast(col))];
                    if (@as(u32, @bitCast(value)) != background)
                        target[@as(usize, @intCast(ty)) * dw + @as(usize, @intCast(dx + col))] = value;
                }
            }
        }
        return true;
    }
};
const Job = struct {
    config: Config,
    lines: []Line,
    notify: Notify,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    result: ?Atlas = null,
    failure: ?anyerror = null,
    font_snapshot: ?fonts.Snapshot = null,
    fn create(core: *c.MdfCore, config: Config, drawing: fonts.Drawing, notify: Notify) !*Job {
        var lines: std.ArrayList(Line) = .empty;
        errdefer {
            for (lines.items) |line| a.free(line.text);
            lines.deinit(a);
        }
        const count = c.mdf_core_preview_count(core);
        var total: usize = 0;
        for (0..count) |block| total = try std.math.add(usize, total, c.mdf_core_preview_lines(core, block));
        const physical_limit: usize = @intFromFloat(@floor(32000 / (@as(f32, @floatFromInt(config.slot_height)) * config.scale)));
        const limit = @max(1, @min(@as(usize, @intCast(@max(256, config.height * 2))), physical_limit));
        const stride = sampleStride(total, limit);
        var n: usize = 0;
        for (0..count) |block| {
            const rows = c.mdf_core_preview_lines(core, block);
            for (0..rows) |row| {
                defer n += 1;
                if (n % stride != 0) continue;
                const source = c.mdf_core_preview_line(core, block, row);
                const bytes = if (source.ptr != null) source.ptr[0..source.len] else "";
                var end = @min(bytes.len, 1024);
                while (end < bytes.len and end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
                const owned = try a.dupe(u8, bytes[0..end]);
                lines.append(a, .{ .block = block, .row = row, .count = rows, .text = owned }) catch |err| {
                    a.free(owned);
                    return err;
                };
            }
        }
        const self = try a.create(Job);
        errdefer a.destroy(self);
        self.* = .{ .config = config, .lines = try lines.toOwnedSlice(a), .notify = notify };
        errdefer freeLines(self.lines);
        if (drawing.sans != null) self.font_snapshot=drawing.snapshot() orelse return error.FontResourcesUnavailable;
        errdefer if(self.font_snapshot) |snapshot| snapshot.deinit();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn render(self: *Job) !Atlas {
        const config = self.config;
        var canvas = try paint.Canvas.initScaled(a, config.width, @intCast(@max(1, self.lines.len) * @as(usize, @intCast(config.slot_height))), .{ .bg = config.background }, config.scale);
        errdefer canvas.deinit();
        var drawing: fonts.Drawing = .{};
        var system_map: ?*anyopaque = null;
        if (self.font_snapshot) |snapshot| {
            system_map=snapshot.api.from_resources.?(snapshot.value) orelse return error.MinimapFontMapFailed;
            const reason=snapshot.api.@"error".?(system_map);
            if(reason.length>0) { snapshot.api.destroy.?(system_map); return error.MinimapFontMapFailed; }
            drawing=.{ .api=snapshot.api,.sans=system_map,.version=config.font_version };
            canvas.system_fonts=&drawing;
        }
        defer if(self.font_snapshot) |snapshot| if(system_map) |map| snapshot.api.destroy.?(map);
        canvas.clear();
        for (self.lines, 0..) |line, slot| {
            if (self.stop.load(.monotonic)) return error.Canceled;
            try canvas.text(.{ .face = 0, .size = config.font_size, .flags = 0 }, line.text, 3, @as(f32, @floatFromInt(slot * @as(usize, @intCast(config.slot_height)))) + config.baseline, config.foreground);
        }
        // Atlas pixels outlive this worker's private shaping context.
        canvas.system_fonts=null;
        const result: Atlas = .{ .canvas = canvas, .lines = self.lines, .config = config };
        self.lines = &.{};
        return result;
    }
    fn run(self: *Job) void {
        const timing=profile.begin(self.config.tracing,@src(),"Rasterize native minimap text",10);
        self.result = self.render() catch |err| failed: {
            self.failure = err;
            break :failed null;
        };
        timing.end();
        profile.signal(self.config.tracing,@src(),"Minimap raster ready",10);
        self.done.store(true, .release);
        self.notify();
    }
    fn destroy(self: *Job) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |thread| thread.join();
        if(self.font_snapshot) |snapshot| snapshot.deinit();
        if (self.result) |*atlas| atlas.deinit();
        freeLines(self.lines);
        a.destroy(self);
    }
};
pub const Manager = struct {
    job: ?*Job = null,
    atlas: ?Atlas = null,
    navigation: ?Config = null,
    requested: ?Config = null,
    finished: bool = true,
    version: u64 = 0,
    jobs: usize = 0,
    started_ns: u64 = 0,
    error_buffer: [128]u8 = @splat(0),
    pub fn stop(self: *Manager) void {
        if (self.job) |job| job.destroy();
        self.job = null;
    }
    pub fn deinit(self: *Manager) void {
        self.stop();
        if (self.atlas) |*atlas| atlas.deinit();
        self.atlas = null;
    }
    pub fn reset(self: *Manager) void {
        self.deinit();
        self.navigation = null;
        self.requested = null;
        self.finished = true;
        self.version +%= 1;
        self.jobs = 0;
        self.started_ns = 0;
        @memset(&self.error_buffer, 0);
    }
    pub fn message(self: *const Manager) []const u8 {
        return std.mem.sliceTo(&self.error_buffer, 0);
    }
    fn fail(self: *Manager, text: []const u8) void {
        self.finished = true;
        @memset(&self.error_buffer, 0);
        @memcpy(self.error_buffer[0..@min(text.len, self.error_buffer.len - 1)], text[0..@min(text.len, self.error_buffer.len - 1)]);
    }
    pub fn update(self: *Manager, core: *c.MdfCore, config: ?Config, drawing: fonts.Drawing, notify: Notify) !bool {
        const desired = config orelse {
            self.stop();
            self.requested = null;
            self.finished = true;
            return false;
        };
        if (self.requested == null or !self.requested.?.eql(desired)) {
            self.stop();
            self.requested = desired;
            self.finished = false;
            @memset(&self.error_buffer, 0);
            if (self.navigation == null or !self.navigation.?.sameNavigation(desired)) {
                if (!c.mdf_core_navigation_start(core, desired.content_width, desired.zoom, desired.advance)) {
                    self.fail("Cannot prepare minimap text");
                    return false;
                }
                self.navigation = desired;
            }
            if (self.atlas) |atlas| if (atlas.config.eql(desired)) {
                self.finished = true;
                return false;
            };
            if (self.started_ns == 0) self.started_ns = c.mdf_now_ns();
        }
        if (self.finished) return false;
        if (c.mdf_core_navigation_state(core) == 3) {
            self.fail("Minimap text is unavailable");
            return false;
        }
        if (!c.mdf_core_navigation_ready(core)) return false;
        if (self.job == null) {
            const timing=profile.begin(desired.tracing,@src(),"Prepare native minimap inputs",0);
            defer timing.end();
            profile.signal(desired.tracing,@src(),"Accept navigation",0);
            profile.signal(desired.tracing,@src(),"Request minimap raster",0);
            self.job = Job.create(core, desired, drawing, notify) catch |err| {
                self.fail(@errorName(err));
                return false;
            };
            self.jobs += 1;
        }
        const job = self.job.?;
        if (!job.done.load(.acquire)) return false;
        const timing=profile.begin(desired.tracing,@src(),"Adopt native minimap raster",0);
        defer timing.end();
        profile.signal(desired.tracing,@src(),"Minimap raster adopted",0);
        defer {
            job.destroy();
            self.job = null;
            self.finished = true;
        }
        if (job.result) |atlas| {
            if (self.atlas) |*old| old.deinit();
            self.atlas = atlas;
            job.result = null;
            self.version +%= 1;
            return true;
        }
        self.fail(if (job.failure) |err| @errorName(err) else "Minimap rasterization failed");
        return false;
    }
};
