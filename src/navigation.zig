const std = @import("std");
const document = @import("document.zig");
const layout = @import("layout.zig");
const profiling = @import("profiling.zig");
const c = @import("native");

pub const Parameters = struct {
    width: f32,
    zoom: f32,
    character_width: f32,

    pub fn eql(self: Parameters, other: Parameters) bool {
        return @abs(self.width - other.width) < 1 and self.zoom == other.zoom and
            @abs(self.character_width - other.character_width) < 0.01;
    }
};

pub const Heading = struct { index: usize, level: u8, title: []const u8, tag: []const u8 };
pub const Preview = struct { columns: usize, lines: []const []const u8 };
pub const Image = struct { index: usize, bytes: []const u8 };

pub const Model = struct {
    arena: std.heap.ArenaAllocator,
    preview_arena: std.heap.ArenaAllocator,
    headings: []const Heading,
    preview: []const Preview,
    images: []const Image,
    parameters: Parameters,

    pub fn deinit(self: *Model) void {
        self.preview_arena.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn prepare(allocator: std.mem.Allocator, blocks: []const document.Block, path: []const u8, parameters: Parameters, stop: ?*const std.atomic.Value(bool)) !Model {
        const profile_span = profiling.begin(@src(), "Prepare deferred navigation and assets", .navigation);
        defer profile_span.end();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var headings: std.ArrayList(Heading) = .empty;
        for (blocks, 0..) |block, index| {
            if (canceled(stop)) return error.Canceled;
            var text: std.ArrayList(u8) = .empty;
            if (block.kind == .heading) {
                for (block.spans) |span| try text.appendSlice(a, span.text);
                try headings.append(a, .{
                    .index = index,
                    .level = block.heading,
                    .title = if (text.items.len > 0) try a.dupe(u8, text.items) else "(Untitled section)",
                    .tag = try std.fmt.allocPrint(a, "toc-entry-{d}", .{index}),
                });
            }
        }
        var images: std.ArrayList(Image) = .empty;
        {
            const image_span = profiling.begin(@src(), "Read deferred local images", .navigation);
            defer image_span.end();
            for (blocks, 0..) |block, index| {
                if (canceled(stop)) return error.Canceled;
                if (block.image_data != null) continue;
                if (block.image_src) |source| {
                    if (try document.localImage(a, path, source)) |bytes| try images.append(a, .{ .index = index, .bytes = bytes });
                }
            }
        }
        const owned_headings = try headings.toOwnedSlice(a);
        const owned_images = try images.toOwnedSlice(a);
        profiling.signal(@src(), "Document assets ready", .navigation);
        var model: Model = .{ .arena = arena, .preview_arena = .init(allocator), .headings = owned_headings, .images = owned_images, .preview = &.{}, .parameters = parameters };
        errdefer model.preview_arena.deinit();
        if (parameters.width > 0) try model.reflow(blocks, parameters, stop);
        return model;
    }

    // Outline and image bytes are independent of window/font metrics. Keep
    // those allocations when the GUI supplies or changes the preview width.
    pub fn reflow(self: *Model, blocks: []const document.Block, parameters: Parameters, stop: ?*const std.atomic.Value(bool)) !void {
        const preview_span = profiling.begin(@src(), "Prepare navigation preview for viewport", .navigation);
        defer preview_span.end();
        self.preview_arena.deinit();
        self.preview_arena = .init(self.arena.child_allocator);
        self.preview = &.{};
        const a = self.preview_arena.allocator();
        const preview = try a.alloc(Preview, blocks.len);
        for (blocks, 0..) |block, index| {
            if (canceled(stop)) return error.Canceled;
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(a, block.prefix);
            if (block.task) |checked| try text.appendSlice(a, if (checked) "[x] " else "[ ] ");
            if (block.kind == .details) try text.appendSlice(a, "> ");
            if (block.alert_start) {
                try text.appendSlice(a, block.alert.?.title());
                try text.append(a, '\n');
            }
            for (block.spans) |span| try text.appendSlice(a, span.text);
            for (block.cells, 0..) |cell, column| {
                if (column > 0) try text.appendSlice(a, " | ");
                for (cell.spans) |span| try text.appendSlice(a, span.text);
            }
            const spacing = layout.blockSpacing(block, if (index > 0) blocks[index - 1] else null, parameters.zoom);
            const indent = @as(f32, @floatFromInt(@min(20, block.indent + block.quote))) * 22 * parameters.zoom;
            const advance = parameters.character_width * layout.fontSize(block, parameters.zoom) / 12;
            const columns: usize = @intFromFloat(@max(1, @floor(@max(40, parameters.width - indent - 2 * spacing.padding) / @max(1, advance))));
            preview[index] = .{ .columns = columns, .lines = try wrap(a, text.items, columns, stop) };
        }
        self.preview = preview;
        self.parameters = parameters;
    }
};

fn canceled(stop: ?*const std.atomic.Value(bool)) bool {
    return if (stop) |value| value.load(.monotonic) else false;
}

pub fn wrap(a: std.mem.Allocator, text: []const u8, columns: usize, stop: ?*const std.atomic.Value(bool)) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        if (canceled(stop)) return error.Canceled;
        var end = at;
        var count: usize = 0;
        var space: ?usize = null;
        while (end < text.len and text[end] != '\n' and count < @max(1, columns)) : (count += 1) {
            if (count % 1024 == 0 and canceled(stop)) return error.Canceled;
            if (text[end] == ' ') space = end;
            end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
        }
        if (end < text.len and text[end] != '\n') {
            if (space) |boundary| if (boundary > at) {
                end = boundary;
            };
        }
        try lines.append(a, text[at..end]);
        at = end;
        if (at < text.len and text[at] == '\n') {
            at += 1;
        } else {
            while (at < text.len and text[at] == ' ') : (at += 1) {}
        }
    }
    return lines.items;
}

pub const State = enum(u8) { idle, working, ready, failed };

pub const Worker = struct {
    allocator: std.mem.Allocator,
    notify: *const fn () void,
    state: std.atomic.Value(State) = .init(.idle),
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    blocks: []const document.Block = &.{},
    path: []const u8 = "",
    parameters: Parameters = .{ .width = 0, .zoom = 0, .character_width = 0 },
    model: ?Model = null,
    mutex: c.pthread_mutex_t = undefined,
    condition: c.pthread_cond_t = undefined,
    busy: bool = false,
    queued: bool = false,
    quit: bool = false,

    pub fn create(allocator: std.mem.Allocator, notify: *const fn () void) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .notify = notify };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.NavigationMutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.condition, null) != 0) return error.NavigationConditionFailed;
        errdefer _ = c.pthread_cond_destroy(&self.condition);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn status(self: *const Worker) State {
        return self.state.load(.acquire);
    }

    // Wait before freeing borrowed document storage. The persistent thread is
    // started before dlopen, which can serialize pthread TLS initialization.
    pub fn reset(self: *Worker) void {
        self.stop.store(true, .monotonic);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.queued = false;
        while (self.busy) _ = c.pthread_cond_wait(&self.condition, &self.mutex);
        if (self.model) |*model| model.deinit();
        self.model = null;
        self.blocks = &.{};
        self.path = "";
        self.state.store(.idle, .release);
    }

    pub fn destroy(self: *Worker) void {
        self.reset();
        _ = c.pthread_mutex_lock(&self.mutex);
        self.quit = true;
        _ = c.pthread_cond_signal(&self.condition);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        _ = c.pthread_cond_destroy(&self.condition);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Worker, blocks: []const document.Block, path: []const u8, parameters: Parameters) !void {
        const same_document = self.blocks.ptr == blocks.ptr and self.blocks.len == blocks.len and std.mem.eql(u8, self.path, path);
        if (!same_document) self.reset();
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        self.blocks = blocks;
        self.path = path;
        self.parameters = parameters;
        self.stop.store(false, .monotonic);
        if (!self.busy and self.model != null and self.status() == .ready and self.model.?.parameters.eql(parameters)) return;
        self.state.store(.working, .release);
        if (!self.busy) self.queued = true;
        _ = c.pthread_cond_signal(&self.condition);
    }

    fn run(self: *Worker) void {
        while (true) {
            _ = c.pthread_mutex_lock(&self.mutex);
            while (!self.queued and !self.quit) {
                const waiting = if (self.model != null and self.parameters.width == 0)
                    profiling.waitOn(@src(), "Wait for GUI font and viewport metrics", .navigation)
                else
                    profiling.Span{};
                _ = c.pthread_cond_wait(&self.condition, &self.mutex);
                waiting.end();
            }
            if (self.quit) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                return;
            }
            self.queued = false;
            self.busy = true;
            var parameters = self.parameters;
            _ = c.pthread_mutex_unlock(&self.mutex);
            while (true) {
                const successful = self.prepare(parameters);
                _ = c.pthread_mutex_lock(&self.mutex);
                if (successful and !self.stop.load(.monotonic) and !parameters.eql(self.parameters)) {
                    parameters = self.parameters;
                    _ = c.pthread_mutex_unlock(&self.mutex);
                    continue;
                }
                if (successful and !self.stop.load(.monotonic)) {
                    if (self.parameters.width > 0) profiling.signal(@src(), "Navigation ready", .navigation);
                    self.state.store(.ready, .release);
                } else self.state.store(if (self.stop.load(.monotonic)) .idle else .failed, .release);
                self.busy = false;
                _ = c.pthread_cond_broadcast(&self.condition);
                _ = c.pthread_mutex_unlock(&self.mutex);
                break;
            }
            self.notify();
        }
    }

    fn prepare(self: *Worker, parameters: Parameters) bool {
        if (self.model) |*model| {
            model.reflow(self.blocks, parameters, &self.stop) catch return false;
        } else {
            self.model = Model.prepare(self.allocator, self.blocks, self.path, parameters, &self.stop) catch return false;
        }
        return true;
    }
};

test "navigation caches complete heading labels and UTF-8 preview lines" {
    const allocator = std.testing.allocator;
    var doc = try document.Document.parse(allocator, "# A **rich** heading\n\nação café\n", "test.md");
    defer doc.deinit();
    var model = try Model.prepare(allocator, doc.blocks, doc.path, .{ .width = 300, .zoom = 1, .character_width = 7 }, null);
    defer model.deinit();
    try std.testing.expectEqualStrings("A rich heading", model.headings[0].title);
    try std.testing.expectEqualStrings("toc-entry-0", model.headings[0].tag);
    try std.testing.expectEqual(doc.blocks.len, model.preview.len);
    for (model.preview) |preview| for (preview.lines) |line| {
        try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    };
    var stop = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Canceled, Model.prepare(allocator, doc.blocks, doc.path, model.parameters, &stop));
}

test "navigation worker quiesces before borrowed document storage is released" {
    const allocator = std.testing.allocator;
    const repeated: [100][14]u8 = @splat("# Title\n\ntext ".*);
    var doc = try document.Document.parse(allocator, std.mem.asBytes(&repeated), "test.md");
    defer doc.deinit();
    const worker = try Worker.create(allocator, struct {
        fn notify() void {}
    }.notify);
    defer worker.destroy();
    try worker.start(doc.blocks, doc.path, .{ .width = 600, .zoom = 1, .character_width = 7 });
    worker.reset();
    try std.testing.expect(worker.thread != null and worker.model == null);
    try std.testing.expectEqual(State.idle, worker.status());
}

test "early assets survive viewport reflow without reading their files again" {
    const allocator = std.testing.allocator;
    var template = "/tmp/mdf-navigation-assets-XXXXXX".* ++ [_]u8{0};
    const directory = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
    defer _ = c.rmdir(directory);
    var image_buffer: [256]u8 = undefined;
    const image = try std.fmt.bufPrintSentinel(&image_buffer, "{s}/image.png", .{directory}, 0);
    defer _ = c.unlink(image.ptr);
    const fd = c.open(image.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.TestWriteFailed;
    _ = c.write(fd, "image-bytes", 11);
    _ = c.close(fd);
    const path = try std.fmt.allocPrint(allocator, "{s}/sample.md", .{directory});
    defer allocator.free(path);
    var doc = try document.Document.parseDeferred(allocator, "# Title\n\n![Image](image.png)\n", path);
    defer doc.deinit();
    var model = try Model.prepare(allocator, doc.blocks, doc.path, .{ .width = 0, .zoom = 1, .character_width = 1 }, null);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.images.len);
    const bytes = model.images[0].bytes;
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(image.ptr));
    try model.reflow(doc.blocks, .{ .width = 300, .zoom = 1, .character_width = 7 }, null);
    try std.testing.expect(model.images[0].bytes.ptr == bytes.ptr);
    try std.testing.expectEqualStrings("image-bytes", model.images[0].bytes);
    try std.testing.expectEqual(doc.blocks.len, model.preview.len);
}
