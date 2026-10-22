//! Bounded asynchronous clipboard writes. A slow or closed reader never blocks
//! the Wayland dispatch thread or keeps shutdown waiting on a full pipe.
const std = @import("std");
pub const Reader = @import("receive.zig").Reader;
const c = @import("native");
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    fd: c_int,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    pub fn create(allocator: std.mem.Allocator, fd: c_int, bytes: []const u8) !*Writer {
        errdefer _ = c.close(fd);
        const self = try allocator.create(Writer);
        errdefer allocator.destroy(self);
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0 or
            c.fcntl(fd, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) < 0) return error.ClipboardPipeFailed;
        self.* = .{ .allocator = allocator, .bytes = copy, .fd = fd };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *Writer) void {
        // A clipboard consumer may close its pipe at any time. SIGPIPE is
        // blocked only in this short-lived writer thread.
        var blocked = std.posix.sigemptyset();
        std.posix.sigaddset(&blocked, .PIPE);
        std.posix.sigprocmask(std.posix.SIG.BLOCK, &blocked, null);
        defer self.done.store(true, .release);
        defer _ = c.close(self.fd);
        var offset: usize = 0;
        while (offset < self.bytes.len and !self.stop.load(.acquire)) {
            const count = c.write(self.fd, self.bytes.ptr + offset, self.bytes.len - offset);
            if (count > 0) {
                offset += @intCast(count);
            } else if (count < 0 and c.__errno_location().* == c.EINTR) {
                continue;
            } else if (count < 0 and c.__errno_location().* == c.EAGAIN) {
                var descriptor = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
                _ = c.poll(&descriptor, 1, 100);
            } else break;
        }
    }
    pub fn destroy(self: *Writer) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.bytes);
        self.allocator.destroy(self);
    }
};
