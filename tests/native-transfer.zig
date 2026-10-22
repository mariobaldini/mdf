const std = @import("std");
const Writer = @import("native_transfer").Writer;
const c = @import("native");
const a = std.testing.allocator;
const Reader = @import("native_transfer").Reader;

test "clipboard receive: bytes transfer once at EOF and the descriptor closes" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    var reader: Reader = .{ .allocator = a };
    defer reader.cancel();
    try reader.adopt(pipe[0]);
    try std.testing.expect((try reader.poll()) == null);
    const text = "café path.md";
    try std.testing.expectEqual(@as(isize, @intCast(text.len)), c.write(pipe[1], text, text.len));
    _ = c.close(pipe[1]);
    const result = (try reader.poll()).?;
    defer a.free(result);
    try std.testing.expectEqualStrings(text, result);
    try std.testing.expectEqual(@as(c_int, -1), reader.fd);
    try std.testing.expect((try reader.poll()) == null);
}
test "clipboard receive: cancellation does not wait for a blocked sender" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(pipe[1]);
    var reader: Reader = .{ .allocator = a };
    defer reader.cancel();
    try reader.adopt(pipe[0]);
    try std.testing.expect((try reader.poll()) == null);
    reader.cancel();
    try std.testing.expectEqual(@as(c_int, -1), reader.fd);
}
test "clipboard receive: limits and timeouts release partial input" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(pipe[1]);
    var reader: Reader = .{ .allocator = a, .limit = 3 };
    defer reader.cancel();
    try reader.adopt(pipe[0]);
    try std.testing.expectEqual(@as(isize, 4), c.write(pipe[1], "long", 4));
    try std.testing.expectError(error.ReceiveTooLarge, reader.poll());
    try std.testing.expectEqual(@as(c_int, -1), reader.fd);
    var next: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&next, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(next[1]);
    try reader.adopt(next[0]);
    reader.deadline = 0;
    try std.testing.expectError(error.ReceiveTimeout, reader.poll());
    try std.testing.expectEqual(@as(usize, 0), reader.bytes.items.len);
}

test "clipboard: asynchronous writer owns bytes until the pipe drains" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(pipe[0]);
    const data = try a.alloc(u8, 256 * 1024);
    defer a.free(data);
    @memset(data, 0xa5);
    const writer = try Writer.create(a, pipe[1], data);
    defer writer.destroy();
    @memset(data, 0);
    var received: usize = 0;
    var buffer: [4096]u8 = undefined;
    const limit = c.mdf_now_ns() + 5 * std.time.ns_per_s;
    while (c.mdf_now_ns() < limit) {
        const count = c.read(pipe[0], &buffer, buffer.len);
        if (count > 0) {
            for (buffer[0..@intCast(count)]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            received += @intCast(count);
        } else if (count == 0) break else {
            try std.testing.expect(c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR);
            var descriptor = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&descriptor, 1, 20);
        }
    }
    try std.testing.expectEqual(data.len, received);
}
test "clipboard: a blocked reader does not prevent writer shutdown" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    defer _ = c.close(pipe[0]);
    const data = try a.alloc(u8, 256 * 1024);
    defer a.free(data);
    @memset(data, 1);
    const writer = try Writer.create(a, pipe[1], data);
    var descriptor = c.struct_pollfd{ .fd = pipe[0], .events = c.POLLIN, .revents = 0 };
    const ready = c.poll(&descriptor, 1, 5000);
    if (ready <= 0) {
        writer.destroy();
        return error.WriterDidNotStart;
    }
    try std.testing.expect(!writer.done.load(.acquire));
    writer.destroy();
}
test "clipboard: closing the receiving pipe does not deliver SIGPIPE to the app" {
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK));
    _ = c.close(pipe[0]);
    const writer = try Writer.create(a, pipe[1], "closed consumer");
    defer writer.destroy();
    const limit = c.mdf_now_ns() + 5 * std.time.ns_per_s;
    while (!writer.done.load(.acquire) and c.mdf_now_ns() < limit) {
        var descriptor = c.struct_pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(&descriptor, 1, 1);
    }
    try std.testing.expect(writer.done.load(.acquire));
}
