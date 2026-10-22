//! Deferred image work and transferable pixel ownership. Input storage remains
//! borrowed until the joined worker releases its descriptors.
const std = @import("std");
const c = @import("ui_native");
const profile = @import("ui-profile.zig");
const a = std.heap.c_allocator;
extern fn mdf_now_ns() u64;
const Notify = ?*const fn () callconv(.c) void;
const Input = c.struct_MdfImageInput;
const Output = c.struct_MdfPreparedImage;
const Prepared = struct {
    index: c_int,
    pixels: c.struct_MdfPixels = std.mem.zeroes(c.struct_MdfPixels),
    diagram: bool = false,
    svg: bool = false,
    width: f32 = 0,
    height: f32 = 0,
    failure: ?[]u8 = null,
    missing_glyphs: c.struct_MdfSvgText = .{ .data = null, .length = 0 },

    fn deinit(self: *Prepared) void {
        c.free(self.pixels.data);
        c.free(@constCast(self.missing_glyphs.data));
        self.missing_glyphs = .{ .data = null, .length = 0 };
        if (self.failure) |message| a.free(message);
        self.pixels.data = null;
        self.failure = null;
    }
};
const Worker = struct {
    inputs: []Input,
    font_fds: []c_int,
    limit: usize,
    notify: Notify,
    dark: c_int,
    provider: c.MdfBuiltinFont,
    tracing: bool,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mutex: c.pthread_mutex_t = undefined,
    changed: c.pthread_cond_t = undefined,
    allowed: bool,
    failed: bool = false,
    results: std.ArrayList(Prepared) = .empty,
    popped: usize = 0,
    first_diagram_ns: u64 = 0,

    fn create(inputs: []const Input, limit: usize, notify: Notify, dark: c_int, fds: []const c_int, allowed: bool, provider: c.MdfBuiltinFont, tracing: bool) !*Worker {
        for (inputs) |input| if (input.kind > 2 or (input.length != 0 and input.bytes == null)) return error.InvalidInput;
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        const descriptors = try a.dupe(Input, inputs);
        errdefer a.free(descriptors);
        const font_fds = try a.dupe(c_int, fds);
        errdefer a.free(font_fds);
        self.* = .{ .inputs = descriptors, .font_fds = font_fds, .limit = limit, .notify = notify,
            .dark = dark, .allowed = allowed, .provider = provider, .tracing = tracing };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.changed, null) != 0) return error.ConditionFailed;
        errdefer _ = c.pthread_cond_destroy(&self.changed);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn destroy(self: *Worker) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stop.store(true, .monotonic);
        _ = c.pthread_cond_broadcast(&self.changed);
        _ = c.pthread_mutex_unlock(&self.mutex);
        self.join();
        for (self.results.items) |*result| result.deinit();
        self.results.deinit(a);
        a.free(self.inputs);
        a.free(self.font_fds);
        _ = c.pthread_cond_destroy(&self.changed);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }
    fn join(self: *Worker) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }
    fn check(self: *Worker) !void {
        if (self.stop.load(.monotonic)) return error.Canceled;
    }
    fn cancel(context: ?*const anyopaque) callconv(.c) c_int {
        const self: *const Worker = @ptrCast(@alignCast(context.?));
        return @intFromBool(self.stop.load(.monotonic));
    }
    fn renderer(self: *Worker, kind: u32, error_buffer: []u8) !*const c.struct_MdfDiagramApi {
        return c.mdf_diagram_renderer(kind, cancel, self, self.provider, profile.nestingDepth(),
            error_buffer.ptr, error_buffer.len) orelse error.RendererFailed;
    }
    fn run(self: *Worker) void {
        self.prepare() catch |err| {
            if (err == error.Canceled) return;
            self.failed = true;
        };
        profile.signal(self.tracing, @src(), "Images ready", 4);
        self.done.store(true, .release);
        if (self.notify) |notify| notify();
    }
    fn prepare(self: *Worker) !void {
        const total = profile.begin(self.tracing, @src(), "Prepare image and diagram pixels", 4);
        defer total.end();
        for (self.inputs) |input| {
            try self.check();
            if (input.kind != 0 or input.length < 4) continue;
            var prepared = Prepared{ .index = input.index };
            errdefer prepared.deinit();
            var codec_error: [512]u8 = @splat(0);
            const codec: *const c.struct_MdfImageApi = c.mdf_image_renderer(cancel, self, profile.nestingDepth(), &codec_error, codec_error.len) orelse {
                try self.check();
                prepared.failure = try a.dupe(u8, std.mem.sliceTo(&codec_error, 0));
                try self.results.append(a, prepared);
                continue;
            };
            const decoded = block: {
                const phase = if (input.bytes[0] == 137)
                    profile.begin(self.tracing, @src(), "Decode PNG pixels", 4)
                else if (input.bytes[0] == 'G')
                    profile.begin(self.tracing, @src(), "Decode GIF first frame", 4)
                else if (input.bytes[0] == 'B')
                    profile.begin(self.tracing, @src(), "Decode BMP pixels", 4)
                else
                    profile.begin(self.tracing, @src(), "Decode JPEG pixels", 4);
                defer phase.end();
                break :block codec.decode.?(input.bytes, input.length, self.limit, &prepared.pixels) != 0;
            };
            if (!decoded) continue;
            try self.results.append(a, prepared);
        }
        var optional = false;
        for (self.inputs) |input| optional = optional or input.kind != 0;
        if (optional) {
            _ = c.pthread_mutex_lock(&self.mutex);
            defer _ = c.pthread_mutex_unlock(&self.mutex);
            if (!self.allowed) {
                const waiting = profile.wait(self.tracing, @src(), "Wait for first Markdown viewport before diagram loading", 4);
                defer waiting.end();
                while (!self.allowed and !self.stop.load(.monotonic)) {
                    if (c.pthread_cond_wait(&self.changed, &self.mutex) != 0) return error.PresentationGateFailed;
                }
            }
            try self.check();
        }
        var mapped: std.ArrayList(c.struct_MdfFontData) = .empty;
        defer {
            for (mapped.items) |font| _ = c.munmap(@constCast(font.data), font.length);
            mapped.deinit(a);
        }
        if (self.font_fds.len != 0) {
            const phase = profile.begin(self.tracing, @src(), "Map prepared fallback fonts for diagram labels", 4);
            defer phase.end();
            for (self.font_fds) |fd| {
                try self.check();
                var info: c.struct_stat = undefined;
                if (c.fstat(fd, &info) != 0 or info.st_size <= 0) return error.FontInspectionFailed;
                const size: usize = @intCast(info.st_size);
                const memory = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
                if (memory == c.MAP_FAILED or memory == null) return error.FontMappingFailed;
                errdefer _ = c.munmap(memory, size);
                try mapped.append(a, .{ .data = @ptrCast(memory.?), .length = size });
            }
        }
        for (self.inputs) |input| {
            try self.check();
            if (input.kind == 0) continue;
            const phase = if (input.kind == 2)
                profile.begin(self.tracing, @src(), "Render SVG image", 4)
            else
                profile.begin(self.tracing, @src(), "Render Mermaid diagram", 4);
            defer phase.end();
            var prepared = Prepared{ .index = input.index, .diagram = true, .svg = input.kind == 2 };
            errdefer prepared.deinit();
            var error_buffer: [512]u8 = @splat(0);
            self.render(input, mapped.items, &prepared, &error_buffer) catch |err| {
                try self.check();
                prepared.failure = try a.dupe(u8, if (error_buffer[0] != 0) std.mem.sliceTo(&error_buffer, 0) else @errorName(err));
            };
            try self.results.append(a, prepared);
            if (self.first_diagram_ns == 0 and prepared.pixels.data != null) {
                self.first_diagram_ns = mdf_now_ns();
                profile.signal(self.tracing, @src(), "First diagram pixels ready", 4);
            }
        }
    }
    fn render(self: *Worker, input: Input, mapped: []const c.struct_MdfFontData, prepared: *Prepared, error_buffer: []u8) !void {
        const fonts = if (input.fallback != 0) mapped else &.{};
        var generated = std.mem.zeroes(c.struct_MdfSvgText);
        defer c.free(@constCast(generated.data));
        var svg = input.bytes;
        var length = input.length;
        if (input.kind == 1) {
            const layout = try self.renderer(c.MDF_MODULE_MERMAID, error_buffer);
            const phase = profile.begin(self.tracing, @src(), "Generate Mermaid SVG", 4);
            defer phase.end();
            if (layout.mermaid_svg.?(svg, length, self.dark, fonts.ptr, fonts.len, self.limit, &generated,
                error_buffer.ptr, error_buffer.len) == 0) return error.MermaidLayoutFailed;
            svg = generated.data;
            length = generated.length;
        }
        try self.check();
        const renderer_api = try self.renderer(c.MDF_MODULE_SVG, error_buffer);
        if (renderer_api.svg.?(svg, length, self.dark, fonts.ptr, fonts.len, self.limit, &prepared.pixels,
            &prepared.width, &prepared.height, error_buffer.ptr, error_buffer.len, &prepared.missing_glyphs) == 0) return error.SvgRenderFailed;
    }
};

export fn mdf_image_worker_create(inputs: ?[*]const Input, count: usize, limit: usize, notify: Notify, dark: c_int,
    font_fds: ?[*]const c_int, font_count: usize, allow: c_int, provider: c.MdfBuiltinFont, tracing: c_int) ?*Worker
{
    if (count > 1_000_000 or font_count > 256 or (count != 0 and inputs == null) or (font_count != 0 and font_fds == null)) return null;
    return Worker.create(if (inputs) |ptr| ptr[0..count] else &.{}, limit, notify, dark,
        if (font_fds) |ptr| ptr[0..font_count] else &.{}, allow != 0, provider, tracing != 0) catch null;
}
export fn mdf_image_worker_destroy(self: ?*Worker) void {
    if (self) |worker| worker.destroy();
}
export fn mdf_image_worker_allow_diagrams(self: *Worker) void {
    _ = c.pthread_mutex_lock(&self.mutex);
    self.allowed = true;
    _ = c.pthread_cond_broadcast(&self.changed);
    _ = c.pthread_mutex_unlock(&self.mutex);
}
export fn mdf_image_worker_complete(self: *Worker) c_int {
    return @intFromBool(self.done.load(.acquire));
}
export fn mdf_image_worker_join(self: *Worker) c_int {
    if (!self.done.load(.acquire)) return 0;
    self.join();
    return if (self.failed) -1 else 1;
}
export fn mdf_image_worker_pop(self: *Worker, out: *Output) c_int {
    if (!self.done.load(.acquire) or self.popped >= self.results.items.len) return 0;
    const result = &self.results.items[self.popped];
    out.* = std.mem.zeroes(Output);
    out.index = result.index;
    out.pixels = result.pixels;
    result.pixels.data = null;
    out.diagram = @intFromBool(result.diagram);
    out.svg = @intFromBool(result.svg);
    out.missing_glyphs = result.missing_glyphs;
    result.missing_glyphs = .{ .data = null, .length = 0 };
    out.logical_width = result.width;
    out.logical_height = result.height;
    if (result.failure) |message| {
        const len = @min(message.len, out.@"error".len - 1);
        @memcpy(out.@"error"[0..len], message[0..len]);
        a.free(message);
        result.failure = null;
    }
    self.popped += 1;
    return 1;
}
export fn mdf_image_worker_first_diagram(self: *Worker) u64 {
    return if (self.done.load(.acquire)) self.first_diagram_ns else 0;
}
