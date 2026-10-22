const std = @import("std");
const c = @import("mdf").native;
const a = std.testing.allocator;

pub const Directory = struct {
    path: [:0]u8,
    pub fn init() !Directory {
        var template = "/tmp/mdf-unit-XXXXXX".* ++ [_]u8{0};
        const path = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
        errdefer _ = c.rmdir(path);
        return .{ .path = try a.dupeSentinel(u8, std.mem.span(path), 0) };
    }
    pub fn deinit(self: Directory) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        a.free(self.path);
    }
    pub fn name(self: Directory, filename: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.path, filename }, 0);
    }
    pub fn file(self: Directory, filename: []const u8, bytes: []const u8) ![:0]u8 {
        const path = try self.name(filename);
        errdefer a.free(path);
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
        if (fd < 0) return error.TestWriteFailed;
        defer _ = c.close(fd);
        var at: usize = 0;
        while (at < bytes.len) {
            const n = c.write(fd, bytes.ptr + at, bytes.len - at);
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            if (n <= 0) return error.TestWriteFailed;
            at += @intCast(n);
        }
        return path;
    }
};
