//! Bounded incoming clipboard/drop data. The GUI never blocks on a sender.
const std = @import("std");
const c = @import("native");
pub const Reader = struct {
    allocator: std.mem.Allocator,
    fd: c_int = -1,
    bytes: std.ArrayList(u8) = .empty,
    limit: usize = 1024 * 1024,
    deadline: u64 = 0,
    pub fn cancel(self: *Reader) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.deadline = 0;
        self.bytes.deinit(self.allocator);
        self.bytes = .empty;
    }
    pub fn adopt(self: *Reader, fd: c_int) !void {
        self.cancel();
        self.fd = fd;
        errdefer self.cancel();
        if (fd < 0) return error.InvalidReceiveDescriptor;
        const flags = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.ReceiveDescriptorFailed;
        self.deadline = c.mdf_now_ns() + 5 * std.time.ns_per_s;
    }
    pub fn poll(self: *Reader) !?[]u8 {
        if (self.fd < 0) return null;
        errdefer self.cancel();
        if (c.mdf_now_ns() > self.deadline) return error.ReceiveTimeout;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const count = c.read(self.fd, &buffer, buffer.len);
            if (count > 0) {
                const size: usize = @intCast(count);
                if (self.bytes.items.len > self.limit or size > self.limit - self.bytes.items.len) return error.ReceiveTooLarge;
                try self.bytes.appendSlice(self.allocator, buffer[0..size]);
            } else if (count == 0) {
                _ = c.close(self.fd);
                self.fd = -1;
                self.deadline = 0;
                return try self.bytes.toOwnedSlice(self.allocator);
            } else if (c.__errno_location().* == c.EINTR) continue else if (c.__errno_location().* == c.EAGAIN) return null else return error.ReceiveFailed;
        }
    }
};
