const std = @import("std");
const footnotes = @import("mdf").footnotes;

test "footnotes: ordinary text needs no replacement allocation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "# Ordinary\n\nBody without notes.\n";
    const value = try footnotes.prepare(arena.allocator(), input);
    try std.testing.expectEqual(@as(usize, 0), value.notes.len);
    try std.testing.expectEqual(input.ptr, value.markdown.ptr);
}
test "footnotes: case-insensitive duplicate definitions keep the first body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try footnotes.prepare(arena.allocator(), "[^A]: first\n[^a]: second\n");
    try std.testing.expectEqual(@as(usize, 1), value.notes.len);
    try std.testing.expectEqualStrings("first\n", value.notes[0].body);
}
test "footnotes: a shorter fence cannot end a longer fenced block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try footnotes.prepare(arena.allocator(), "````md\n[^a]: literal\n```\n[^b]: still literal\n````\n[^c]: real\n");
    try std.testing.expectEqual(@as(usize, 1), value.notes.len);
    try std.testing.expectEqualStrings("c", value.notes[0].id);
}
test "footnotes: invalid and empty identifiers stay visible as source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "[^]: empty\n[^two words]: spaces\n[^bad[id]: brackets\n";
    const value = try footnotes.prepare(arena.allocator(), source);
    try std.testing.expectEqual(@as(usize, 0), value.notes.len);
    try std.testing.expectEqualStrings(source, value.markdown);
}
test "footnotes: removing definitions preserves every CRLF source position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = "Before.\r\n[^id]: note\r\nAfter.\r\n";
    const value = try footnotes.prepare(arena.allocator(), source);
    try std.testing.expectEqual(source.len, value.markdown.len);
    for (source, 0..) |byte, i| if (byte == '\r' or byte == '\n') try std.testing.expectEqual(byte, value.markdown[i]);
    try std.testing.expectEqualStrings("After.\r\n", value.markdown[source.len - 8 ..]);
}
test "footnotes: tab-indented continuation belongs to the definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try footnotes.prepare(arena.allocator(), "[^id]: first\n\tsecond\n\nParagraph.\n");
    try std.testing.expectEqualStrings("first\nsecond", std.mem.trimEnd(u8, value.notes[0].body, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, value.markdown, "Paragraph.") != null);
}
