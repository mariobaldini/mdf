const std = @import("std");
const c = @import("native");

pub const Track = enum { gui, document, fonts, navigation, images, fallback, input, ui, ui_dependencies };
pub const Kind = enum { work, wait, signal };
pub const Event = struct {
    name: []const u8,
    track: Track,
    kind: Kind,
    source: []const u8,
    function: []const u8,
    line: u32,
    start_ns: u64,
    duration_ns: u64,
    depth: usize,
    thread_id: u64 = 0,
};

// Set before starting workers, and cleared only after all workers have joined.
// Normal launches allocate no recorder and take no extra timestamps.
var active: ?*Recorder = null;
threadlocal var cached_thread_id: u64 = 0;

fn threadId() u64 {
    if (cached_thread_id == 0) cached_thread_id = std.Thread.getCurrentId();
    return cached_thread_id;
}

pub fn nowNs() u64 {
    var value: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &value);
    return @as(u64, @intCast(value.tv_sec)) * std.time.ns_per_s + @as(u64, @intCast(value.tv_nsec));
}

pub fn begin(comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: Track) Span {
    return if (active) |recorder| recorder.start(src, name, track, .work) else .{};
}

pub fn wait(comptime src: std.builtin.SourceLocation, comptime name: []const u8) Span {
    return waitOn(src, name, .gui);
}

pub fn waitOn(comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: Track) Span {
    return if (active) |recorder| recorder.start(src, name, track, .wait) else .{};
}

// Readiness signals establish cross-thread dependencies without inventing
// causality from overlapping calls. They do not affect call-stack depth.
pub fn signal(comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: Track) void {
    const recorder = active orelse return;
    const at = nowNs();
    _ = c.pthread_mutex_lock(&recorder.mutex);
    defer _ = c.pthread_mutex_unlock(&recorder.mutex);
    if (recorder.count == recorder.events.len) {
        recorder.dropped += 1;
        return;
    }
    recorder.events[recorder.count] = .{ .name = name, .source = src.file, .function = src.fn_name, .line = src.line, .track = track, .kind = .signal, .start_ns = at - recorder.origin, .duration_ns = 0, .depth = 0, .thread_id = threadId() };
    recorder.count += 1;
}

// The C++ frontend supplies static source/name strings that outlive the recorder.
pub fn external(track: Track, kind: Kind, name: []const u8, source: []const u8, line: u32, start: u64, duration: u64, depth: usize) void {
    const recorder = active orelse return;
    _ = c.pthread_mutex_lock(&recorder.mutex);
    defer _ = c.pthread_mutex_unlock(&recorder.mutex);
    if (recorder.count == recorder.events.len) {
        recorder.dropped += 1;
        return;
    }
    recorder.events[recorder.count] = .{ .name = name, .source = source, .function = "Native frontend", .line = line, .track = track, .kind = kind, .start_ns = start - recorder.origin, .duration_ns = duration, .depth = depth, .thread_id = threadId() };
    recorder.count += 1;
}

pub const Span = struct {
    recorder: ?*Recorder = null,
    event: Event = undefined,
    started: u64 = 0,

    pub fn end(self: Span) void {
        const recorder = self.recorder orelse return;
        var event = self.event;
        event.duration_ns = nowNs() - self.started;
        // Each track has one writer. Only the completed event buffer is shared.
        recorder.depths[@backingInt(event.track)] -= 1;
        _ = c.pthread_mutex_lock(&recorder.mutex);
        defer _ = c.pthread_mutex_unlock(&recorder.mutex);
        if (recorder.count == recorder.events.len) {
            recorder.dropped += 1;
            return;
        }
        recorder.events[recorder.count] = event;
        recorder.count += 1;
    }
};

pub const Recorder = struct {
    origin: u64,
    mutex: c.pthread_mutex_t = undefined,
    events: [4096]Event = undefined,
    count: usize = 0,
    dropped: usize = 0,
    depths: [@typeInfo(Track).@"enum".field_names.len]usize = @splat(0),

    pub fn init(self: *Recorder, origin: u64) !void {
        self.* = .{ .origin = origin };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.ProfileMutexFailed;
    }

    pub fn enable(self: *Recorder) void {
        std.debug.assert(active == null);
        active = self;
    }

    pub fn deinit(self: *Recorder) void {
        if (active == self) active = null;
        _ = c.pthread_mutex_destroy(&self.mutex);
    }

    pub fn start(self: *Recorder, comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: Track, kind: Kind) Span {
        const started = nowNs();
        const index = @backingInt(track);
        const depth = self.depths[index];
        self.depths[index] += 1;
        return .{
            .recorder = self,
            .started = started,
            .event = .{
                .name = name,
                .track = track,
                .kind = kind,
                .source = src.file,
                .function = src.fn_name,
                .line = src.line,
                .start_ns = started - self.origin,
                .duration_ns = 0,
                .depth = depth,
                .thread_id = threadId(),
            },
        };
    }

    pub const Snapshot = struct { events: []Event, dropped: usize };

    pub fn snapshot(self: *Recorder, allocator: std.mem.Allocator) !Snapshot {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        return .{ .events = try allocator.dupe(Event, self.events[0..self.count]), .dropped = self.dropped };
    }
};

test "profile records nested scopes and actual work on separate threads" {
    const allocator = std.testing.allocator;
    const recorder = try allocator.create(Recorder);
    defer allocator.destroy(recorder);
    try recorder.init(nowNs());
    defer recorder.deinit();
    recorder.enable();
    const outer = begin(@src(), "GUI work", .gui);
    const inner = begin(@src(), "Nested GUI work", .gui);
    inner.end();
    const worker = try std.Thread.spawn(.{}, struct {
        fn run() void {
            const span = begin(@src(), "Worker work", .document);
            defer span.end();
        }
    }.run, .{});
    worker.join();
    outer.end();
    const snapshot = try recorder.snapshot(allocator);
    defer allocator.free(snapshot.events);
    try std.testing.expectEqual(@as(usize, 3), snapshot.events.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.events[0].depth);
    try std.testing.expectEqual(Track.document, snapshot.events[1].track);
    try std.testing.expect(snapshot.events[2].start_ns <= snapshot.events[0].start_ns);
    try std.testing.expect(snapshot.events[2].duration_ns >= snapshot.events[0].duration_ns);
    try std.testing.expectEqual(@as(usize, 0), snapshot.dropped);
    try std.testing.expectEqual(@as(@TypeOf(recorder.depths), @splat(0)), recorder.depths);
    try std.testing.expect(snapshot.events[0].thread_id != 0);
    try std.testing.expectEqual(snapshot.events[0].thread_id, snapshot.events[2].thread_id);
    try std.testing.expect(snapshot.events[1].thread_id != snapshot.events[0].thread_id);
}

test "readiness signals preserve their thread and do not alter call nesting" {
    const allocator = std.testing.allocator;
    const recorder = try allocator.create(Recorder);
    defer allocator.destroy(recorder);
    try recorder.init(nowNs());
    defer recorder.deinit();
    recorder.enable();
    const span = begin(@src(), "GUI call", .gui);
    signal(@src(), "Request document", .gui);
    try std.testing.expectEqual(@as(usize, 1), recorder.depths[0]);
    const worker = try std.Thread.spawn(.{}, struct {
        fn run() void {
            signal(@src(), "Document ready", .document);
        }
    }.run, .{});
    worker.join();
    span.end();
    const snapshot = try recorder.snapshot(allocator);
    defer allocator.free(snapshot.events);
    try std.testing.expectEqual(@as(usize, 3), snapshot.events.len);
    try std.testing.expectEqual(Kind.signal, snapshot.events[0].kind);
    try std.testing.expectEqual(Track.document, snapshot.events[1].track);
    try std.testing.expectEqual(@as(u64, 0), snapshot.events[1].duration_ns);
    try std.testing.expectEqual(Kind.work, snapshot.events[2].kind);
    try std.testing.expectEqual(@as(@TypeOf(recorder.depths), @splat(0)), recorder.depths);
}

test "native event waits retain their measured kind and nesting" {
    const allocator = std.testing.allocator;
    const recorder = try allocator.create(Recorder);
    defer allocator.destroy(recorder);
    try recorder.init(nowNs());
    defer recorder.deinit();
    recorder.enable();
    external(.gui, .wait, "Wait for Wayland events", "frontend/profile.cpp", 1, nowNs(), 100, 2);
    const snapshot = try recorder.snapshot(allocator);
    defer allocator.free(snapshot.events);
    try std.testing.expectEqual(@as(usize, 1), snapshot.events.len);
    try std.testing.expectEqual(Kind.wait, snapshot.events[0].kind);
    try std.testing.expectEqual(@as(usize, 2), snapshot.events[0].depth);
    try std.testing.expectEqual(@as(u64, 100), snapshot.events[0].duration_ns);
}
