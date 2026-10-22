const std = @import("std");
const entities = @import("mdf").entities;

test "entities: every standard name preserves its complete Unicode expansion" {
    var lines = std.mem.splitScalar(u8, @embedFile("html-entity-source"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next().?;
        var expected: [8]u8 = undefined;
        var length: usize = 0;
        for (0..2) |index| {
            const cp = try std.fmt.parseInt(u21, fields.next().?, 10);
            if (index == 1 and cp == 0) break;
            length += try std.unicode.utf8Encode(cp, expected[length..][0..4]);
        }
        try std.testing.expectEqualStrings(expected[0..length], entities.named(name).?);
        var buffer: [64]u8 = undefined;
        const reference = try std.fmt.bufPrint(&buffer, "&{s};", .{name});
        const decoded = entities.decode(reference, 0).?;
        try std.testing.expectEqual(reference.len, decoded.consumed);
        try std.testing.expectEqualStrings(expected[0..length], decoded.bytes[0..decoded.len]);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2125), count);
}
test "entities: invalid names and incomplete references remain literal" {
    for ([_][]const u8{ "", "Amp", "not-an-entity", "amp;", "ampExtra" }) |name|
        try std.testing.expect(entities.named(name) == null);
    for ([_][]const u8{ "&amp", "&;", "&#;", "&#x;", "&#12345678;", "&#x1234567;", "&doesnotexist;" }) |raw|
        try std.testing.expect(entities.decode(raw, 0) == null);
}
test "entities: numeric references retain replacement and HTML5 C1 behavior" {
    for ([_]struct { source: []const u8, value: []const u8 }{
        .{ .source = "&#0;", .value = "�" },
        .{ .source = "&#xD800;", .value = "�" },
        .{ .source = "&#1114112;", .value = "�" },
        .{ .source = "&#128;", .value = "€" },
        .{ .source = "&#x1F600;", .value = "😀" },
    }) |case| {
        const decoded = entities.decode(case.source, 0).?;
        try std.testing.expectEqualStrings(case.value, decoded.bytes[0..decoded.len]);
    }
}
