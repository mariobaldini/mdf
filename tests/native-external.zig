const std = @import("std");
const c = @import("native");
const Launcher = @import("native_external").Launcher;

fn finish(launcher: *Launcher) !bool {
    var failed = false;
    for (0..5000) |_| {
        failed = launcher.poll() or failed;
        if (launcher.children.items.len == 0) return failed;
        var descriptor = c.struct_pollfd{ .fd = -1, .events = 0, .revents = 0 };
        _ = c.poll(&descriptor, 1, 1);
    }
    return error.ChildTimeout;
}
test "links: spawn failures keep no child and preserve the system error" {
    var launcher: Launcher = .{ .allocator = std.testing.allocator, .executable = "/no/mdf/link-handler" };
    defer launcher.deinit();
    try std.testing.expectError(error.LinkHandlerUnavailable, launcher.open("https://example.invalid/a"));
    try std.testing.expectEqual(@as(usize, 0), launcher.children.items.len);
    try std.testing.expectEqual(@as(c_int, c.ENOENT), launcher.last_error);
    try std.testing.expectError(error.InvalidLink, launcher.open("https://example.invalid/\n"));
}
test "links: asynchronous children are reaped without waiting for a GUI action" {
    var launcher: Launcher = .{ .allocator = std.testing.allocator, .executable = "/bin/true" };
    defer launcher.deinit();
    for (0..8) |_| try launcher.open("https://example.invalid/; $(literal)");
    try std.testing.expect(!(try finish(&launcher)));
    try std.testing.expectEqual(@as(usize, 8), launcher.launches);
}
test "links: nonzero handler exits are reported once" {
    var launcher: Launcher = .{ .allocator = std.testing.allocator, .executable = "/bin/false" };
    defer launcher.deinit();
    try launcher.open("mailto:reader@example.invalid");
    try std.testing.expect(try finish(&launcher));
    try std.testing.expect(!launcher.poll());
}
