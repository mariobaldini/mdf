const std = @import("std");
const fonts = @import("mdf").fonts;
const a = std.testing.allocator;
const document = @import("mdf").document;

// A real zlib stream containing a small sfnt-signature fixture. Font parsing
// remains FreeType's job; these tests exercise the resource's integrity layer.
const fixture = "\x4d\x44\x46\x4f\x4e\x54\x31\x00\x11\x00\x00\x00\x25\x71\x7e\xed\x78\xda\x63\x60\x64\x60\x48\xcb\xcf\x2b\xd1\x4d\xcb\xac\x28\x29\x2d\x4a\x65\x00\x00\x24\x71\x04\xed";
const expected = "\x00\x01\x00\x00font-fixture\x00";

test "fonts: required faces follow emphasis HTML headings and table-header weight" {
    for ([_]struct { source: []const u8, mask: u32 }{
        .{ .source = "# Heading\n\nRegular **bold** and `code`.", .mask = 0 },
        .{ .source = "*italic*", .mask = 4 },
        .{ .source = "***both***", .mask = 8 },
        .{ .source = "# *Italic heading*", .mask = 8 },
        .{ .source = "<em>italic</em> <strong><em>both</em></strong>", .mask = 12 },
        .{ .source = "| *Header* |\n| --- |\n| plain |", .mask = 8 },
        .{ .source = "| Header |\n| --- |\n| *italic cell* |", .mask = 4 },
        .{ .source = "```\n*literal code*\n```", .mask = 0 },
    }) |case| {
        var doc = try document.Document.parseDeferred(a, case.source, "faces.md");
        defer doc.deinit();
        try std.testing.expectEqual(case.mask, fonts.requiredStyles(doc.blocks));
    }
}

fn decode(allocator: std.mem.Allocator) !void {
    const bytes = try fonts.unpack(allocator, fixture);
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings(expected, bytes);
}

test "fonts: zlib resource expands to the original bytes" {
    try decode(a);
}
test "fonts: all decoder allocation failures release their buffers" {
    try std.testing.checkAllAllocationFailures(a, decode, .{});
}
test "fonts: truncated headers and invalid magic are rejected" {
    for (0..22) |size| try std.testing.expectError(error.InvalidFontHeader, fonts.unpack(a, fixture[0..size]));
    var invalid = fixture.*;
    invalid[0] = 'X';
    try std.testing.expectError(error.InvalidFontHeader, fonts.unpack(a, &invalid));
}
test "fonts: expanded size is bounded before allocation" {
    var invalid = fixture.*;
    for ([_]u32{ 0, 11, 16 * 1024 * 1024 + 1, std.math.maxInt(u32) }) |size| {
        std.mem.writeInt(u32, invalid[8..12], size, .little);
        try std.testing.expectError(error.InvalidFontSize, fonts.unpack(a, &invalid));
    }
}
test "fonts: corrupt and truncated streams cannot return partial data" {
    for (22..fixture.len) |size| {
        const result = fonts.unpack(a, fixture[0..size]);
        if (result) |bytes| {
            a.free(bytes);
            return error.AcceptedTruncatedFont;
        } else |_| {}
    }
    var invalid = fixture.*;
    invalid[17] ^= 1;
    try std.testing.expectError(error.InvalidFontStream, fonts.unpack(a, &invalid));
}
test "fonts: both container and stream checksums are verified" {
    var invalid = fixture.*;
    invalid[12] ^= 1;
    try std.testing.expectError(error.InvalidFontChecksum, fonts.unpack(a, &invalid));
    invalid = fixture.*;
    invalid[invalid.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidFontChecksum, fonts.unpack(a, &invalid));
}
test "fonts: declared length and trailing data must match exactly" {
    var invalid = fixture.*;
    std.mem.writeInt(u32, invalid[8..12], expected.len - 1, .little);
    try std.testing.expectError(error.InvalidFontLength, fonts.unpack(a, &invalid));
    std.mem.writeInt(u32, invalid[8..12], expected.len + 1, .little);
    try std.testing.expectError(error.InvalidFontLength, fonts.unpack(a, &invalid));
    try std.testing.expectError(error.InvalidFontLength, fonts.unpack(a, fixture ++ "\x00"));
}
test "fonts: repeated requests borrow one immutable allocation per face" {
    var cache: fonts.Startup = .{ .allocator = a, .resources = &.{ fixture, fixture } };
    defer cache.deinit();
    const first = try cache.get(0);
    const second = try cache.get(0);
    const bold = try cache.get(1);
    try std.testing.expectEqual(first.ptr, second.ptr);
    try std.testing.expect(first.ptr != bold.ptr);
    try std.testing.expectEqualStrings(expected, bold);
    try std.testing.expectError(error.InvalidFontStyle, cache.get(2));
}
test "fonts: decoder failures are cached and never expose bytes" {
    var cache: fonts.Startup = .{ .allocator = a, .resources = &.{ "invalid", fixture } };
    defer cache.deinit();
    for (0..3) |_| try std.testing.expectError(error.InvalidFontHeader, cache.get(0));
    try std.testing.expectEqualStrings(expected, try cache.get(1));
}

test "fonts: requesting bold italic never decodes the other optional face" {
    var cache: fonts.Startup = .{ .allocator = a, .resources = &.{ fixture, fixture, "invalid", fixture } };
    defer cache.deinit();
    cache.start();
    cache.finish();
    try std.testing.expectEqualStrings(expected, try cache.get(3));
    try std.testing.expectError(error.InvalidFontHeader, cache.get(2));
}

fn consume(cache: *fonts.Startup) void {
    for (0..50) |_| {
        for (0..2) |style| {
            const bytes = cache.get(style) catch @panic("font decode failed");
            std.debug.assert(std.mem.eql(u8, expected, bytes));
        }
    }
}
test "fonts: worker and simultaneous consumers share completed font data" {
    var cache: fonts.Startup = .{ .allocator = a, .resources = &.{ fixture, fixture } };
    defer cache.deinit();
    cache.start();
    cache.start();
    const other = try std.Thread.spawn(.{}, consume, .{&cache});
    defer other.join();
    consume(&cache);
    cache.finish();
    cache.finish();
}
