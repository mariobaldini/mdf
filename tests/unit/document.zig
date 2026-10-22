const std = @import("std");
const Document = @import("mdf").document.Document;
const Block = @import("mdf").document.Block;
const a = std.testing.allocator;

fn text(block: Block) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    for (block.spans) |span| try result.appendSlice(a, span.text);
    return result.toOwnedSlice(a);
}

test "document: all six ATX heading levels retain their level" {
    var doc = try Document.parse(a, "# A\n## B\n### C\n#### D\n##### E\n###### F\n\n####### Plain\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 7), doc.blocks.len);
    for (doc.blocks[0..6], 1..) |block, level| {
        try std.testing.expectEqual(.heading, block.kind);
        try std.testing.expectEqual(@as(u8, @intCast(level)), block.heading);
    }
    try std.testing.expectEqual(.paragraph, doc.blocks[6].kind);
}
test "document: setext headings remain headings rather than rules" {
    var doc = try Document.parse(a, "Title\n=====\n\nSection\n-------\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    try std.testing.expectEqual(@as(u8, 1), doc.blocks[0].heading);
    try std.testing.expectEqual(@as(u8, 2), doc.blocks[1].heading);
}
test "document: code fences preserve Markdown markers as literal text" {
    var doc = try Document.parse(a, "```zig\n**literal** [link](x.md)\n```\n", "");
    defer doc.deinit();
    const block = doc.blocks[0];
    try std.testing.expectEqual(.code, block.kind);
    try std.testing.expectEqualStrings("zig", block.language);
    const value = try text(block);
    defer a.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "**literal** [link](x.md)") != null);
    for (block.spans) |span| try std.testing.expect(!span.bold and span.link == null);
}
test "document: an unclosed fence keeps its final lines as code" {
    var doc = try Document.parse(a, "~~~text\nfirst\nsecond", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expectEqual(.code, doc.blocks[0].kind);
    const value = try text(doc.blocks[0]);
    defer a.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "first\nsecond") != null);
}
test "document: named and numeric entities decode without losing Unicode" {
    var doc = try Document.parse(a, "A &amp; B &#x1F680; &lt;\n", "");
    defer doc.deinit();
    const value = try text(doc.blocks[0]);
    defer a.free(value);
    try std.testing.expectEqualStrings("A & B 🚀 <", value);
}
test "document: ordered lists retain a non-one starting number" {
    var doc = try Document.parse(a, "3. Third\n4. Fourth\n", "");
    defer doc.deinit();
    try std.testing.expectEqualStrings("3. ", doc.blocks[0].prefix);
    try std.testing.expectEqualStrings("4. ", doc.blocks[1].prefix);
}
test "document: reference links use their definition and keep visible labels" {
    var doc = try Document.parse(a, "[Visible][target]\n\n[target]: other.md\n", "");
    defer doc.deinit();
    try std.testing.expectEqualStrings("Visible", doc.blocks[0].spans[0].text);
    try std.testing.expectEqualStrings("other.md", doc.blocks[0].spans[0].link.?);
}
test "document: a short table row retains empty trailing cells" {
    var doc = try Document.parse(a, "| A | B | C |\n| --- | --- | --- |\n| one |\n", "");
    defer doc.deinit();
    const row = doc.blocks[1];
    try std.testing.expectEqual(@as(usize, 3), row.cells.len);
    try std.testing.expectEqual(@as(usize, 0), row.cells[1].spans.len);
    try std.testing.expectEqual(@as(usize, 0), row.cells[2].spans.len);
}
test "document: Mermaid source is a distinct fenced code language" {
    var doc = try Document.parse(a, "```mermaid\nflowchart TD\nA --> B\n```\n\n```zig\nconst n = 1;\n```\n", "");
    defer doc.deinit();
    try std.testing.expectEqualStrings("mermaid", doc.blocks[0].language);
    try std.testing.expectEqualStrings("zig", doc.blocks[1].language);
    try std.testing.expectEqual(.code, doc.blocks[0].kind);
}
test "document: source and filename remain owned after inputs change" {
    var source = "# Owned\n\nText".*;
    var path = "owned.md".*;
    var doc = try Document.parse(a, &source, &path);
    defer doc.deinit();
    @memset(&source, 'x');
    @memset(&path, 'y');
    try std.testing.expectEqualStrings("# Owned\n\nText", doc.source);
    try std.testing.expectEqualStrings("owned.md", doc.path);
    try std.testing.expectEqualStrings("Owned", doc.blocks[0].spans[0].text);
}
test "document: truncated and overlong UTF-8 is rejected before parsing" {
    for ([_][]const u8{ "ok\xe2\x82", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80" }) |source|
        try std.testing.expectError(error.InvalidUtf8, Document.parse(a, source, ""));
}
test "document: CRLF paragraphs do not merge across blank lines" {
    var doc = try Document.parse(a, "First.\r\n\r\nSecond.\r\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.blocks.len);
    for (doc.blocks) |block| try std.testing.expectEqual(.paragraph, block.kind);
}
