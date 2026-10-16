const std = @import("std");
const document = @import("document.zig");
const layout = @import("layout.zig");
const profiling = @import("profiling.zig");

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
    headings: []const Heading,
    preview: []const Preview,
    images: []const Image,
    parameters: Parameters,

    pub fn deinit(self: *Model) void {
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
        const preview = try a.alloc(Preview, blocks.len);
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
                text.clearRetainingCapacity();
            }
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
        // Image files and optional UI work are deliberately outside the first viewport path.
        const image_span = profiling.begin(@src(), "Read deferred local images", .navigation);
        defer image_span.end();
        var images: std.ArrayList(Image) = .empty;
        for (blocks, 0..) |block, index| {
            if (canceled(stop)) return error.Canceled;
            if (block.image_data != null) continue;
            if (block.image_src) |source| {
                if (try document.localImage(a, path, source)) |bytes| try images.append(a, .{ .index = index, .bytes = bytes });
            }
        }
        return .{
            .arena = arena,
            .headings = try headings.toOwnedSlice(a),
            .preview = preview,
            .images = try images.toOwnedSlice(a),
            .parameters = parameters,
        };
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

    pub fn create(allocator: std.mem.Allocator, notify: *const fn () void) !*Worker {
        const self = try allocator.create(Worker);
        self.* = .{ .allocator = allocator, .notify = notify };
        return self;
    }

    pub fn status(self: *const Worker) State {
        return self.state.load(.acquire);
    }

    // Join before the owner frees a document or replaces a prepared model.
    pub fn reset(self: *Worker) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.model) |*model| model.deinit();
        self.model = null;
        self.blocks = &.{};
        self.path = "";
        self.state.store(.idle, .release);
    }

    pub fn destroy(self: *Worker) void {
        self.reset();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Worker, blocks: []const document.Block, path: []const u8, parameters: Parameters) !void {
        self.reset();
        self.blocks = blocks;
        self.path = path;
        self.parameters = parameters;
        self.stop.store(false, .monotonic);
        self.state.store(.working, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.state.store(.failed, .release);
            return err;
        };
    }

    fn run(self: *Worker) void {
        self.model = Model.prepare(self.allocator, self.blocks, self.path, self.parameters, &self.stop) catch {
            self.state.store(.failed, .release);
            self.notify();
            return;
        };
        profiling.signal(@src(), "Navigation ready", .navigation);
        self.state.store(.ready, .release);
        self.notify();
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

test "navigation worker joins before borrowed document storage is released" {
    const allocator = std.testing.allocator;
    var doc = try document.Document.parse(allocator, "# Title\n\ntext " ** 100, "test.md");
    defer doc.deinit();
    const worker = try Worker.create(allocator, struct {
        fn notify() void {}
    }.notify);
    defer worker.destroy();
    try worker.start(doc.blocks, doc.path, .{ .width = 600, .zoom = 1, .character_width = 7 });
    worker.reset();
    try std.testing.expect(worker.thread == null and worker.model == null);
    try std.testing.expectEqual(State.idle, worker.status());
}
