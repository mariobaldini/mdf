//! Bootstrap font bytes need only libc and Zig's inflater, not the UI libraries.
const std = @import("std");
const profiling = @import("profiling.zig");
const compression = @import("compression.zig");
const layout = @import("layout.zig");
const Allocator = std.mem.Allocator;

pub fn requiredStyles(blocks: anytype) u32 {
    var mask: u32 = 0;
    for (blocks) |block| {
        const bold = block.kind == .heading or block.table_header;
        for (block.spans) |span| if (span.italic and span.text.len > 0) {
            mask |= @as(u32, 1) << @as(u5, @intCast(layout.faceOffset(span.bold, span.italic, bold)));
        };
        for (block.cells) |cell| for (cell.spans) |span| if (span.italic and span.text.len > 0) {
            mask |= @as(u32, 1) << @as(u5, @intCast(layout.faceOffset(span.bold, span.italic, bold)));
        };
    }
    return mask;
}

pub fn unpack(a: Allocator, resource: []const u8) ![]u8 {
    if (resource.len < 22 or !std.mem.eql(u8, resource[0..8], "MDFONT1\x00")) return error.InvalidFontHeader;
    const size = std.mem.readInt(u32, resource[8..12], .little);
    const checksum = std.mem.readInt(u32, resource[12..16], .little);
    if (size < 12 or size > 16 * 1024 * 1024) return error.InvalidFontSize;
    const compressed = resource[16..];
    const bytes = try a.alloc(u8, size);
    errdefer a.free(bytes);
    compression.inflate(compressed, bytes, checksum, .{}) catch |err| return switch (err) {
        error.InvalidHeader => error.InvalidFontStream,
        error.InvalidLength => error.InvalidFontLength,
        error.InvalidChecksum => error.InvalidFontChecksum,
        else => error.CorruptFontStream,
    };
    if (!std.mem.eql(u8, bytes[0..4], "\x00\x01\x00\x00") and !std.mem.eql(u8, bytes[0..4], "OTTO")) return error.InvalidFontSignature;
    return bytes;
}

pub const Startup = struct {
    const Face = struct {
        // 0: untouched, 1: one decoder owns it, 2: immutable bytes, 3: error.
        state: std.atomic.Value(u32) = .init(0),
        bytes: ?[]u8 = null,
        failure: ?anyerror = null,
    };
    allocator: Allocator,
    resources: []const []const u8,
    faces: [4]Face = @splat(.{}),
    thread: ?std.Thread = null,
    started: bool = false,

    pub fn get(self: *Startup, style: usize) ![]const u8 {
        if (style >= self.faces.len or style >= self.resources.len) return error.InvalidFontStyle;
        const face = &self.faces[style];
        if (face.state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
            if (unpack(self.allocator, self.resources[style])) |bytes| {
                face.bytes = bytes;
                face.state.store(2, .release);
            } else |err| {
                face.failure = err;
                face.state.store(3, .release);
            }
            _ = std.os.linux.futex_3arg(&face.state, .{ .cmd = .WAKE, .private = true }, std.math.maxInt(i32));
        } else {
            while (face.state.load(.acquire) == 1)
                _ = std.os.linux.futex_4arg(&face.state, .{ .cmd = .WAIT, .private = true }, 1, null);
        }
        if (face.failure) |err| return err;
        return face.bytes.?;
    }

    pub fn start(self: *Startup) void {
        if (self.started) return;
        self.started = true;
        profiling.signal(@src(), "Request startup font data", .gui);
        // Thread exhaustion keeps the same checked decoder available on demand.
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *Startup) void {
        const total = profiling.begin(@src(), "Prepare startup Open Sans data", .bundled_fonts);
        defer total.end();
        inline for (0..2) |style| {
            const part = profiling.begin(@src(), if (style == 0) "Inflate Open Sans regular" else "Inflate Open Sans bold", .bundled_fonts);
            _ = self.get(style) catch {
                part.end();
                profiling.signal(@src(), "Startup font data failed", .bundled_fonts);
                return;
            };
            part.end();
        }
        profiling.signal(@src(), "Startup font data prepared", .bundled_fonts);
    }

    pub fn finish(self: *Startup) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    pub fn deinit(self: *Startup) void {
        self.finish();
        for (&self.faces) |*face| {
            if (face.bytes) |bytes| self.allocator.free(bytes);
            face.* = .{};
        }
        self.started = false;
    }
};
