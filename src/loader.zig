const std = @import("std");
const c = @import("native");
const Document = @import("document.zig").Document;
const Allocator = std.mem.Allocator;
const profiling = @import("profiling.zig");

pub fn nowNs() u64 {
    return profiling.nowNs();
}

pub fn absolutePath(a: Allocator, path: []const u8) ![:0]u8 {
    if (std.fs.path.isAbsolute(path)) return a.dupeSentinel(u8, path, 0);
    var cwd: [4096]u8 = undefined;
    if (c.getcwd(&cwd, cwd.len) == null) return error.CurrentDirectoryUnavailable;
    const resolved = try std.fs.path.resolve(a, &.{ std.mem.sliceTo(&cwd, 0), path });
    defer a.free(resolved);
    return a.dupeSentinel(u8, resolved, 0);
}

pub fn readDocument(a: Allocator, path: [:0]const u8) ![]u8 {
    const profile_span = profiling.begin(@src(), "Read Markdown file", .document);
    defer profile_span.end();
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return switch (c.__errno_location().*) {
        c.ENOENT => error.FileNotFound,
        c.EACCES => error.PermissionDenied,
        else => error.OpenFailed,
    };
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.StatFailed;
    if (stat.st_mode & c.S_IFMT != c.S_IFREG) return error.NotARegularFile;
    if (stat.st_size < 0 or stat.st_size > std.math.maxInt(u32)) return error.FileTooLarge;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    errdefer a.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.FileChangedDuringRead;
        offset += @intCast(n);
    }
    var after: c.struct_stat = undefined;
    if (c.fstat(fd, &after) != 0 or after.st_size != stat.st_size or
        after.st_mtim.tv_sec != stat.st_mtim.tv_sec or after.st_mtim.tv_nsec != stat.st_mtim.tv_nsec)
        return error.FileChangedDuringRead;
    return bytes;
}

pub const Result = struct {
    generation: u64,
    automatic: bool = false,
    document: ?Document = null,
    failure: ?anyerror = null,
    read_ns: u64 = 0,
    parse_ns: u64 = 0,
    watch_available: bool = true,

    pub fn deinit(self: *Result) void {
        if (self.document) |*doc| doc.deinit();
        self.* = undefined;
    }
};

pub const Loader = struct {
    const Request = struct { path: [:0]u8, generation: u64 };
    allocator: Allocator,
    notify: *const fn () void,
    mutex: c.pthread_mutex_t = undefined,
    thread: ?std.Thread = null,
    wake_fd: c_int = -1,
    watch_fd: c_int = -1,
    pending: ?Request = null,
    ready: ?Result = null,
    generation: u64 = 0,
    stopped: bool = false,
    auto_reload: bool = true,

    pub fn create(a: Allocator, notify: *const fn () void) !*Loader {
        const self = try a.create(Loader);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .notify = notify };
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        self.wake_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (self.wake_fd < 0) return error.EventFdFailed;
        errdefer _ = c.close(self.wake_fd);
        self.watch_fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
        // A failed watcher still permits manual opening and reloading.
        errdefer _ = c.close(self.watch_fd);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn destroy(self: *Loader) void {
        self.lock();
        self.stopped = true;
        self.unlock();
        self.wake();
        if (self.thread) |thread| thread.join();
        if (self.pending) |req| self.allocator.free(req.path);
        if (self.ready) |*res| res.deinit();
        _ = c.close(self.watch_fd);
        _ = c.close(self.wake_fd);
        _ = c.pthread_mutex_destroy(&self.mutex);
        self.allocator.destroy(self);
    }

    pub fn request(self: *Loader, path: []const u8) !u64 {
        const absolute = try absolutePath(self.allocator, path);
        self.lock();
        defer self.unlock();
        self.generation +%= 1;
        if (self.pending) |req| self.allocator.free(req.path);
        self.pending = .{ .path = absolute, .generation = self.generation };
        self.wake();
        return self.generation;
    }

    pub fn take(self: *Loader) ?Result {
        self.lock();
        defer self.unlock();
        const result = self.ready;
        self.ready = null;
        return result;
    }

    pub fn setAutoReload(self: *Loader, enabled: bool) void {
        self.lock();
        defer self.unlock();
        self.auto_reload = enabled;
        if (!enabled) {
            if (self.ready) |*result| {
                if (result.automatic) {
                    result.deinit();
                    self.ready = null;
                }
            }
        }
        self.wake();
    }

    fn lock(self: *Loader) void {
        _ = c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *Loader) void {
        _ = c.pthread_mutex_unlock(&self.mutex);
    }
    fn wake(self: *Loader) void {
        var one: u64 = 1;
        _ = c.write(self.wake_fd, &one, @sizeOf(u64));
    }

    fn publish(self: *Loader, value: Result) void {
        var result = value;
        self.lock();
        if (self.stopped or result.generation != self.generation or (result.automatic and !self.auto_reload)) {
            self.unlock();
            result.deinit();
            return;
        }
        if (self.ready) |*old| old.deinit();
        self.ready = result;
        profiling.signal(@src(), "Document ready", .document);
        self.unlock();
        self.notify();
    }

    fn load(self: *Loader, req: Request, watch_available: bool, automatic: bool) void {
        const profile_span = profiling.begin(@src(), "Load document", .document);
        defer profile_span.end();
        var result = Result{ .generation = req.generation, .watch_available = watch_available, .automatic = automatic };
        const start = nowNs();
        const bytes = readDocument(self.allocator, req.path) catch |err| {
            result.failure = err;
            self.publish(result);
            return;
        };
        defer self.allocator.free(bytes);
        const parsed_at = nowNs();
        result.read_ns = parsed_at - start;
        result.document = Document.parseDeferred(self.allocator, bytes, req.path) catch |err| {
            result.failure = err;
            self.publish(result);
            return;
        };
        result.parse_ns = nowNs() - parsed_at;
        self.publish(result);
    }

    fn run(self: *Loader) void {
        var active: ?Request = null;
        defer if (active) |req| self.allocator.free(req.path);
        var watch: c_int = -1;
        var deadline: ?u64 = null;
        while (true) {
            self.lock();
            const stop = self.stopped;
            const auto_reload = self.auto_reload;
            const requested = self.pending;
            self.pending = null;
            self.unlock();
            if (stop) {
                if (requested) |req| self.allocator.free(req.path);
                return;
            }
            if (!auto_reload) deadline = null;
            if (requested) |req| {
                const watch_span = profiling.begin(@src(), "Set up file watcher", .document);
                if (active) |old| self.allocator.free(old.path);
                active = req;
                if (watch >= 0) _ = c.inotify_rm_watch(self.watch_fd, watch);
                const parent = self.allocator.dupeSentinel(u8, std.fs.path.dirname(req.path) orelse ".", 0) catch {
                    self.publish(.{ .generation = req.generation, .failure = error.OutOfMemory });
                    continue;
                };
                watch = c.inotify_add_watch(self.watch_fd, parent.ptr, c.IN_CLOSE_WRITE | c.IN_MOVED_TO | c.IN_MOVED_FROM | c.IN_CREATE | c.IN_DELETE | c.IN_ATTRIB | c.IN_DELETE_SELF | c.IN_MOVE_SELF);
                self.allocator.free(parent);
                watch_span.end();
                self.load(req, watch >= 0, false);
                deadline = null;
            }
            const now = nowNs();
            if (deadline) |due| {
                if (now >= due) {
                    if (active) |req| self.load(req, watch >= 0, true);
                    deadline = null;
                }
            }
            var fds = [_]c.struct_pollfd{
                .{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.watch_fd, .events = c.POLLIN, .revents = 0 },
            };
            const timeout: c_int = if (deadline) |due| @intCast(@min(100, (due -| nowNs()) / std.time.ns_per_ms + 1)) else -1;
            if (c.poll(&fds, fds.len, timeout) < 0) continue;
            if (fds[0].revents & c.POLLIN != 0) {
                var count: u64 = 0;
                _ = c.read(self.wake_fd, &count, @sizeOf(u64));
            }
            if (fds[1].revents & c.POLLIN != 0) {
                var buffer: [16 * 1024]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
                while (true) {
                    const n = c.read(self.watch_fd, &buffer, buffer.len);
                    if (n <= 0) break;
                    var offset: usize = 0;
                    while (offset + @sizeOf(c.struct_inotify_event) <= @as(usize, @intCast(n))) {
                        const event: *align(1) const c.struct_inotify_event = @ptrCast(buffer[offset..].ptr);
                        const begin = offset + @sizeOf(c.struct_inotify_event);
                        const end = begin + event.len;
                        if (end > @as(usize, @intCast(n))) break;
                        const name = std.mem.sliceTo(buffer[begin..end], 0);
                        if (active) |req| {
                            // Record saves even if the setting changed during poll.
                            // The next loop cancels the deadline while updates are off.
                            if (event.mask & c.IN_Q_OVERFLOW != 0 or
                                (event.wd == watch and std.mem.eql(u8, name, std.fs.path.basename(req.path))))
                                deadline = nowNs() + 100 * std.time.ns_per_ms;
                        }
                        offset = end;
                    }
                }
            }
        }
    }
};

test "loader drops superseded and disabled automatic results" {
    var loader = Loader{ .allocator = std.testing.allocator, .notify = struct {
        fn notify() void {}
    }.notify, .generation = 2 };
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_mutex_init(&loader.mutex, null));
    defer _ = c.pthread_mutex_destroy(&loader.mutex);
    const old = try Document.parse(std.testing.allocator, "old", "old.md");
    loader.publish(.{ .generation = 1, .document = old });
    try std.testing.expect(loader.take() == null);
    loader.publish(.{ .generation = 2, .failure = error.FileNotFound });
    var result = loader.take().?;
    defer result.deinit();
    try std.testing.expectEqual(error.FileNotFound, result.failure.?);

    loader.publish(.{ .generation = 2, .automatic = true, .document = try Document.parse(std.testing.allocator, "queued", "old.md") });
    loader.setAutoReload(false);
    try std.testing.expect(loader.take() == null);
    loader.publish(.{ .generation = 2, .automatic = true, .document = try Document.parse(std.testing.allocator, "in-flight", "old.md") });
    try std.testing.expect(loader.take() == null);
    loader.publish(.{ .generation = 2, .failure = error.FileNotFound });
    var manual = loader.take().?;
    defer manual.deinit();
    try std.testing.expectEqual(error.FileNotFound, manual.failure.?);
}

fn testWrite(path: [:0]const u8, text: []const u8) !void {
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.TestWriteFailed;
    defer _ = c.close(fd);
    if (c.write(fd, text.ptr, text.len) != text.len) return error.TestWriteFailed;
}

fn testAwait(loader: *Loader) !Result {
    const deadline = nowNs() + 5 * std.time.ns_per_s;
    while (nowNs() < deadline) {
        if (loader.take()) |result| return result;
        _ = c.poll(null, 0, 10);
    }
    return error.LoaderTimeout;
}

fn testExpectDocument(loader: *Loader, text: []const u8) !void {
    var result = try testAwait(loader);
    defer result.deinit();
    try std.testing.expect(result.failure == null);
    try std.testing.expectEqualStrings(text, result.document.?.source);
}

test "real file watcher handles saves, replacement, deletion, and recreation" {
    var template = "/tmp/mdf-watch-XXXXXX".*;
    const directory = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
    defer _ = c.rmdir(directory);
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/file.md", .{directory}, 0);
    defer _ = c.unlink(path.ptr);
    var other_buffer: [256]u8 = undefined;
    const other = try std.fmt.bufPrintSentinel(&other_buffer, "{s}/replacement.md", .{directory}, 0);
    defer _ = c.unlink(other.ptr);
    try testWrite(path, "# First");
    const loader = try Loader.create(std.testing.allocator, struct {
        fn notify() void {}
    }.notify);
    defer loader.destroy();
    _ = try loader.request(path);
    try testExpectDocument(loader, "# First");
    try testWrite(path, "# Saved");
    try testExpectDocument(loader, "# Saved");
    try testWrite(other, "# Replaced");
    try std.testing.expectEqual(@as(c_int, 0), c.rename(other.ptr, path.ptr));
    try testExpectDocument(loader, "# Replaced");
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(path.ptr));
    var missing = try testAwait(loader);
    defer missing.deinit();
    try std.testing.expectEqual(error.FileNotFound, missing.failure.?);
    try testWrite(path, "# Recreated");
    try testExpectDocument(loader, "# Recreated");
    try testWrite(path, "\xff");
    var invalid = try testAwait(loader);
    defer invalid.deinit();
    try std.testing.expectEqual(error.InvalidUtf8, invalid.failure.?);
    try testWrite(path, "# Valid again");
    try testExpectDocument(loader, "# Valid again");
    for (0..20) |_| try testWrite(path, "intermediate save");
    try testWrite(path, "# Latest save");
    try testExpectDocument(loader, "# Latest save");
    // An unrelated save in the same directory must not reload the document.
    try testWrite(other, "unrelated");
    _ = c.poll(null, 0, 250);
    try std.testing.expect(loader.take() == null);
    // Turning automatic updates off cancels pending saves but keeps manual loads.
    try testWrite(path, "# Pending save");
    loader.setAutoReload(false);
    try testWrite(path, "# Paused save");
    _ = c.poll(null, 0, 300);
    try std.testing.expect(loader.take() == null);
    _ = try loader.request(path);
    try testExpectDocument(loader, "# Paused save");
    try testWrite(path, "# Still paused");
    _ = c.poll(null, 0, 300);
    try std.testing.expect(loader.take() == null);
    loader.setAutoReload(true);
    try testWrite(path, "# Automatic updates resumed");
    try testExpectDocument(loader, "# Automatic updates resumed");
    try std.testing.expectError(error.NotARegularFile, readDocument(std.testing.allocator, std.mem.span(directory)));
    if (c.geteuid() != 0) {
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(path.ptr, 0));
        defer _ = c.chmod(path.ptr, 0o600);
        try std.testing.expectError(error.PermissionDenied, readDocument(std.testing.allocator, path));
    }
}
