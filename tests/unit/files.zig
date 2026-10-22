const std = @import("std");
const mdf = @import("mdf");
const c = mdf.native;
const a = std.testing.allocator;
const Directory = @import("support.zig").Directory;

test "files: document reads preserve UTF-8 bytes and spaces in filenames" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.file("space café.md", "# café\n\nПривет 中 🚀\n");
    defer a.free(path);
    const bytes = try mdf.loader.readDocument(a, path);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("# café\n\nПривет 中 🚀\n", bytes);
}
test "files: reading an empty regular document returns an empty slice" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.file("empty.md", "");
    defer a.free(path);
    const bytes = try mdf.loader.readDocument(a, path);
    defer a.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}
test "files: a missing document has a distinct not-found error" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.name("missing.md");
    defer a.free(path);
    try std.testing.expectError(error.FileNotFound, mdf.loader.readDocument(a, path));
}
test "files: a directory cannot be read as Markdown" {
    const dir = try Directory.init();
    defer dir.deinit();
    try std.testing.expectError(error.NotARegularFile, mdf.loader.readDocument(a, dir.path));
}
test "files: a named pipe is rejected without waiting for a writer" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.name("pipe.md");
    defer a.free(path);
    try std.testing.expectEqual(@as(c_int, 0), c.mkfifo(path.ptr, 0o600));
    try std.testing.expectError(error.NotARegularFile, mdf.loader.readDocument(a, path));
}
test "files: documents larger than the parser limit fail before allocation" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.file("oversize.md", "");
    defer a.free(path);
    const fd = c.open(path.ptr, c.O_WRONLY);
    if (fd < 0) return error.TestOpenFailed;
    defer _ = c.close(fd);
    // Sparse length: no multi-gigabyte buffer or disk data is allocated.
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, @as(c.off_t, std.math.maxInt(c.MD_SIZE)) + 1));
    try std.testing.expectError(error.FileTooLarge, mdf.loader.readDocument(a, path));
}
test "files: relative document paths resolve dot segments and gain a sentinel" {
    const path = try mdf.loader.absolutePath(a, "child/../readme.md");
    defer a.free(path);
    try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.endsWith(u8, path, "/readme.md"));
    try std.testing.expect(std.mem.indexOf(u8, path, "/child/../") == null);
    try std.testing.expectEqual(@as(u8, 0), path[path.len]);
}
test "files: remote data and protocol-relative images never read local files" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_][]const u8{ "https://example.com/a.png", "data:image/png,x", "//server/a.png", "file:///tmp/a.png", "" }) |source|
        try std.testing.expectEqual(@as(?[]const u8, null), try mdf.document.localImage(arena.allocator(), "/docs/sample.md", source));
}
test "files: empty missing and directory image sources remain unavailable" {
    const dir = try Directory.init();
    defer dir.deinit();
    const empty = try dir.file("empty.png", "");
    defer a.free(empty);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_][]const u8{ empty, dir.path, "/definitely-missing-mdf-unit-image.png" }) |source|
        try std.testing.expectEqual(@as(?[]const u8, null), try mdf.document.localImage(arena.allocator(), "", source));
}
test "files: oversized image sources are skipped before reading their pixels" {
    const dir = try Directory.init();
    defer dir.deinit();
    const path = try dir.file("oversize.png", "");
    defer a.free(path);
    const fd = c.open(path.ptr, c.O_WRONLY);
    if (fd < 0) return error.TestOpenFailed;
    defer _ = c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(fd, 16 * 1024 * 1024 + 1));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try mdf.document.localImage(arena.allocator(), "", path));
}
test "files: malformed persisted settings fail without replacing the file" {
    const dir = try Directory.init();
    defer dir.deinit();
    var store = try mdf.settings.Store.init(a, dir.path);
    defer store.deinit();
    try store.save(.{ .save_settings_across_sessions = true });
    const path = try dir.file(".config/mdf/settings.json", "{broken");
    defer a.free(path);
    if (store.load()) |_| return error.ExpectedInvalidSettings else |_| {}
    const bytes = try mdf.loader.readDocument(a, path);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("{broken", bytes);
}
test "files: oversized settings are rejected before JSON parsing" {
    const dir = try Directory.init();
    defer dir.deinit();
    var store = try mdf.settings.Store.init(a, dir.path);
    defer store.deinit();
    try store.save(.{ .save_settings_across_sessions = true });
    const bytes: [17000]u8 = @splat(' ');
    const path = try dir.file(".config/mdf/settings.json", &bytes);
    defer a.free(path);
    try std.testing.expectError(error.SettingsFileTooLarge, store.load());
}
test "files: clearing settings twice remains harmless" {
    const dir = try Directory.init();
    defer dir.deinit();
    var store = try mdf.settings.Store.init(a, dir.path);
    defer store.deinit();
    try store.save(.{ .save_settings_across_sessions = true, .font_size = 18 });
    try store.clear();
    try store.clear();
    try std.testing.expectEqualDeep(mdf.settings.Values{}, try store.load());
}
