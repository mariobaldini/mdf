const std = @import("std");
const links = @import("mdf").links;
const a = std.testing.allocator;

test "drops: URI lists decode the first local file without shell interpretation" {
    const path=try links.droppedPath(a,"# Files\r\n\r\nfile://localhost/tmp/caf%C3%A9%20name.md\r\nfile:///tmp/second.md\n");
    defer a.free(path);
    try std.testing.expectEqualStrings("/tmp/café name.md",path);
    const plain=try links.droppedPath(a,"file:///tmp/a%3Bb.md\n");
    defer a.free(plain);
    try std.testing.expectEqualStrings("/tmp/a;b.md",plain);
}
test "drops: remote files unsupported schemes invalid escapes and controls are rejected" {
    try std.testing.expectError(error.RemoteFileDrop,links.droppedPath(a,"file://server/tmp/a.md\n"));
    try std.testing.expectError(error.UnsupportedDrop,links.droppedPath(a,"https://example.invalid/a.md\n"));
    try std.testing.expectError(error.InvalidLink,links.droppedPath(a,"file:///tmp/a%00.md\n"));
    try std.testing.expectError(error.InvalidDropPath,links.droppedPath(a,"file:///tmp/a%0A.md\n"));
    try std.testing.expectError(error.InvalidDropPath,links.droppedPath(a,"file://relative.md\n"));
    try std.testing.expectError(error.EmptyDrop,links.droppedPath(a,"# Nothing\r\n\n"));
}

fn resolved(url: []const u8, expected: links.Link) !void {
    const result = try links.resolve(a, "/docs/guide/start.md", url);
    defer switch (result) {
        inline else => |s| a.free(s),
    };
    try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(result));
    switch (expected) {
        inline else => |s, tag| try std.testing.expectEqualStrings(s, @field(result, @tagName(tag))),
    }
}

test "links: uppercase web schemes preserve the original URL" {
    try resolved("HTTPS://example.com/a?q=1#b", .{ .web = "HTTPS://example.com/a?q=1#b" });
}
test "links: encoded UTF-8 local filenames resolve beside the document" {
    try resolved("caf%C3%A9.md", .{ .local = "/docs/guide/café.md" });
}
test "links: queries and fragments do not become filesystem names" {
    try resolved("next.markdown?view=raw#part", .{ .local = "/docs/guide/next.markdown" });
}
test "links: parent components are normalized after percent decoding" {
    try resolved("%2E%2E/notes/../README.MD", .{ .local = "/docs/README.MD" });
}
test "links: an absolute text document keeps its absolute location" {
    try resolved("/other/notes.TXT", .{ .local = "/other/notes.TXT" });
}
test "links: unsupported schemes and file types never become local commands" {
    for ([_][]const u8{ "javascript:alert(1)", "file:///tmp/x.md", "data:text/plain,x", "//server/x.md", "page.html", "picture.png", "" }) |url|
        try std.testing.expectError(error.UnsupportedLink, links.resolve(a, "/docs/start.md", url));
}
test "links: raw control bytes are rejected before opening a destination" {
    for ([_][]const u8{ "a\n.md", "a\r.md", "a\x00.md", "https://x/\n" }) |url|
        try std.testing.expectError(error.InvalidLink, links.resolve(a, "", url));
}
test "links: incomplete or nonhex percent escapes are invalid" {
    for ([_][]const u8{ "%", "%a", "%GG", "foo%0x.md" }) |text|
        try std.testing.expectError(error.InvalidLink, links.decode(a, text));
}
test "links: invalid UTF-8 and encoded NUL cannot enter filenames" {
    for ([_][]const u8{ "%00", "%C0%AF", "%ED%A0%80", "%F4%90%80%80", "%FF" }) |text|
        try std.testing.expectError(error.InvalidLink, links.decode(a, text));
}
test "links: a percent sign is decoded once and plus remains literal" {
    const result = try links.decode(a, "100%25+ready%2520");
    defer a.free(result);
    try std.testing.expectEqualStrings("100%+ready%20", result);
}
test "links: allocation failures release intermediate decoded paths" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const result = try links.resolve(allocator, "/docs/start.md", "sub/a%20b.md");
            defer allocator.free(result.local);
        }
    }.run, .{});
}
