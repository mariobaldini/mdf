//! Launch the user's URL handler without a shell or a blocking wait.
const std = @import("std");
const c = @import("native");
pub const Launcher = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    executable: [:0]const u8 = "xdg-open",
    children: std.ArrayList(c.pid_t) = .empty,
    launches: usize = 0,
    last_error: c_int = 0,
    pub fn open(self: *Launcher, url: []const u8) !void {
        _ = self.poll();
        if (url.len == 0 or std.mem.indexOfAny(u8, url, "\x00\r\n") != null) return error.InvalidLink;
        if (self.children.items.len >= 16) return error.TooManyLinkHandlers;
        try self.children.ensureUnusedCapacity(self.allocator, 1);
        const argument = try self.allocator.dupeSentinel(u8, url, 0);
        defer self.allocator.free(argument);
        var argv = [_][*c]u8{ @constCast(self.executable.ptr), argument.ptr, null };
        var pid: c.pid_t = 0;
        self.last_error = c.posix_spawnp(&pid, self.executable.ptr, null, null, &argv, c.environ);
        if (self.last_error != 0) return error.LinkHandlerUnavailable;
        self.children.appendAssumeCapacity(pid);
        self.launches += 1;
    }
    pub fn poll(self: *Launcher) bool {
        var failed = false;
        var i: usize = 0;
        while (i < self.children.items.len) {
            var status: c_int = 0;
            const result = c.waitpid(self.children.items[i], &status, c.WNOHANG);
            if (result > 0 or (result < 0 and c.__errno_location().* == c.ECHILD)) {
                failed = failed or (result > 0 and status != 0);
                _ = self.children.swapRemove(i);
            } else i += 1;
        }
        return failed;
    }
    pub fn deinit(self: *Launcher) void {
        _ = self.poll();
        // A browser or mail client can outlive the viewer.
        self.children.deinit(self.allocator);
    }
};
