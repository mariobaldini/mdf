const std = @import("std");
const directory = @import("native_directory");
const c = @import("native");
const a = std.testing.allocator;
const Fixture = struct {
    path: [:0]u8,
    fn init() !Fixture {
        var template = "/tmp/mdf-directory-XXXXXX".* ++ [_]u8{0};
        const path = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
        errdefer _ = c.rmdir(path);
        return .{ .path = try a.dupeSentinel(u8, std.mem.span(path), 0) };
    }
    fn deinit(self: Fixture) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.path) catch {};
        a.free(self.path);
    }
    fn fullPath(self: Fixture, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.path, name }, 0);
    }
    fn file(self: Fixture, name: []const u8) !void {
        const path = try self.fullPath(name);
        defer a.free(path);
        const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
        if (fd < 0) return error.TestWriteFailed;
        _ = c.close(fd);
    }
    fn folder(self: Fixture, name: []const u8) !void {
        const path = try self.fullPath(name);
        defer a.free(path);
        try std.testing.expectEqual(@as(c_int, 0), c.mkdir(path, 0o700));
    }
};
fn notify() callconv(.c) void {}
fn wait(browser: *directory.Browser) !void {
    for (0..1000) |_| {
        if (browser.poll()) return;
        var delay: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = std.time.ns_per_ms };
        _ = c.nanosleep(&delay, null);
    }
    return error.DirectoryWorkerTimeout;
}
test "directory: UTF-8 names and symlinks sort folders first without opening special files" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.folder("Z directory");
    try f.folder("alpha");
    try f.file("Bravo.md");
    try f.file("a.md");
    try f.file("café.txt");
    try f.file(".secret.md");
    const pipe = try f.fullPath("pipe.md");
    defer a.free(pipe);
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(pipe, 0o600));
    const folder_link = try f.fullPath("linkdir");
    defer a.free(folder_link);
    const file_link = try f.fullPath("link.md");
    defer a.free(file_link);
    const broken = try f.fullPath("broken");
    defer a.free(broken);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("alpha", folder_link));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("a.md", file_link));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("missing", broken));
    var stop = std.atomic.Value(bool).init(false);
    var result = try directory.read(a, f.path, false, false, &stop, 10000);
    defer result.deinit();
    try std.testing.expectEqualStrings(f.path, result.path);
    try std.testing.expect(!result.is_file and !result.truncated);
    const names = [_][]const u8{ "alpha", "linkdir", "Z directory", "a.md", "Bravo.md", "café.txt", "link.md" };
    try std.testing.expectEqual(names.len, result.entries.len);
    for (names, result.entries, 0..) |expected, entry, index| {
        try std.testing.expectEqualStrings(expected, entry.name);
        try std.testing.expectEqual(index < 3, entry.directory);
    }
    var hidden = try directory.read(a, f.path, true, false, &stop, 10000);
    defer hidden.deinit();
    try std.testing.expectEqual(names.len + 1, hidden.entries.len);
}
test "directory: entry limits cancellation and file classification preserve ownership" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("one.md");
    try f.file("two.md");
    try f.file("three.md");
    var stop = std.atomic.Value(bool).init(false);
    var limited = try directory.read(a, f.path, false, false, &stop, 2);
    defer limited.deinit();
    try std.testing.expect(limited.truncated and limited.entries.len == 2);
    const path = try f.fullPath("one.md");
    defer a.free(path);
    var file = try directory.read(a, path, false, true, &stop, 10000);
    defer file.deinit();
    try std.testing.expect(file.is_file and file.entries.len == 0);
    try std.testing.expectError(error.NotDirectory, directory.read(a, path, false, false, &stop, 10000));
    try std.testing.expectError(error.InvalidDirectoryPath, directory.read(a, "bad\x00path", false, false, &stop, 10000));
    stop.store(true, .release);
    try std.testing.expectError(error.Canceled, directory.read(a, "/missing", false, false, &stop, 10000));
}
test "directory: no startup worker; repeated requests and failures release old results" {
    const f = try Fixture.init();
    defer f.deinit();
    try f.file("one.md");
    var browser: directory.Browser = .{ .allocator = a };
    defer browser.deinit();
    try std.testing.expect(browser.job == null and browser.jobs == 0 and browser.listing == null);
    for (0..8) |_| {
        try browser.request(f.path, false, false, notify);
        try wait(&browser);
        try std.testing.expect(browser.failure == null);
        try std.testing.expectEqual(@as(usize, 1), browser.listing.?.entries.len);
    }
    const path = try f.fullPath("absent");
    defer a.free(path);
    try browser.request(path, false, false, notify);
    try wait(&browser);
    try std.testing.expect(browser.failure.? == error.DirectoryNotFound and browser.listing == null);
    try browser.request(f.path, false, false, notify);
    browser.deinit();
    try std.testing.expect(browser.job == null and browser.listing == null);
}
test "directory: navigation may reuse the current listing path" {
    const f=try Fixture.init();defer f.deinit();try f.file("one.md");
    var browser:directory.Browser=.{.allocator=a};defer browser.deinit();
    try browser.request(f.path,false,false,notify);try wait(&browser);
    const borrowed=browser.listing.?.path;
    try browser.request(borrowed,false,false,notify);try wait(&browser);
    try std.testing.expect(browser.failure==null);
    try std.testing.expectEqualStrings(f.path,browser.listing.?.path);
}
