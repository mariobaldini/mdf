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

test "document: quote scopes retain paragraph groups and nested boundaries" {
    var doc = try Document.parse(a, "> First\n>\n> Second\n>\n> > Nested\n> >\n> > More\n>\n> Last\n\n> Separate\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 6), doc.blocks.len);
    const outer = doc.blocks[0].quote_context.?;
    const inner = doc.blocks[2].quote_context.?;
    try std.testing.expectEqual(@as(usize, 0), outer.first);
    try std.testing.expectEqual(@as(usize, 5), outer.end);
    try std.testing.expect(doc.blocks[1].quote_context == outer and doc.blocks[4].quote_context == outer);
    try std.testing.expect(inner.parent == outer and doc.blocks[3].quote_context == inner);
    try std.testing.expectEqual(@as(usize, 2), inner.first);
    try std.testing.expectEqual(@as(usize, 4), inner.end);
    try std.testing.expect(doc.blocks[5].quote_context != outer);
    try std.testing.expectEqual(@as(usize, 5), doc.blocks[5].quote_context.?.first);
}

test "document: quote anchors distinguish lists inside quotes from quotes inside lists" {
    var doc = try Document.parse(a, "> - Quoted list\n>   - Nested list\n\n- Outside item\n\n  > Inside list\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[0].quote_context.?.indent);
    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].indent);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[1].indent);
    const quoted = doc.blocks[doc.blocks.len - 1];
    try std.testing.expectEqual(@as(usize, 1), quoted.quote_context.?.indent);
    try std.testing.expectEqual(@as(usize, 1), quoted.quote);
}

test "document: appended footnote quotes use document-wide block ranges" {
    var doc = try Document.parse(a, "Reference.[^q]\n\n[^q]: > Quoted note\n", "");
    defer doc.deinit();
    var found = false;
    for (doc.blocks, 0..) |block, index| if (block.quote_context) |quote| {
        try std.testing.expect(quote.first <= index and index < quote.end);
        try std.testing.expect(quote.first > 0);
        found = true;
    };
    try std.testing.expect(found);
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
test "document: explicit HTML aliases preserve generated heading anchors" {
    var doc = try Document.parse(a,
        "[BLE-18](#ble-18)\n\n<a name='compat'></a>\n\n<a id=\"ble-18\"></a>\n" ++
        "## BLE-18 Shared transport implementation\n\nBody.\n", "todo.md");
    defer doc.deinit();
    const heading = doc.findAnchor("ble-18-shared-transport-implementation").?;
    try std.testing.expectEqual(.heading, doc.blocks[heading].kind);
    try std.testing.expectEqual(heading, doc.findAnchor("ble-18").?);
    try std.testing.expectEqual(heading, doc.findAnchor("compat").?);
    try std.testing.expectEqualStrings("ble-18-shared-transport-implementation", doc.blocks[heading].anchor);
    try std.testing.expect(doc.findAnchor("BLE-18") == null);
    try std.testing.expect(doc.findAnchor("missing") == null);
}
test "document: inline HTML IDs retain their paragraph and entity spelling" {
    var doc = try Document.parse(a,
        "Paragraph <span ID='caf&eacute;-a&amp;b'>target</span>.\n\n" ++
        "<a data-id='wrong' id=plain name='legacy'></a>\n\n## Next\n", "anchors.md");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.findAnchor("café-a&b").?);
    try std.testing.expectEqual(doc.findAnchor("next").?, doc.findAnchor("plain").?);
    try std.testing.expectEqual(doc.findAnchor("next").?, doc.findAnchor("legacy").?);
    try std.testing.expect(doc.findAnchor("wrong") == null);
}
test "document: code comments and suppressed HTML never define jump aliases" {
    var doc = try Document.parse(a,
        "```html\n<a id=\"fenced\"></a>\n```\n\n" ++
        "    <a id=\"indented\"></a>\n\n" ++
        "`<a id=\"inline-code\"></a>`\n\n" ++
        "<!-- <a id=\"comment\"></a> -->\n\n" ++
        "Before <script id='script'><a id='script-body'></a></script> after.\n\n" ++
        "<a id=''></a><a id='white space'></a>\n\n## End\n", "literal.md");
    defer doc.deinit();
    for ([_][]const u8{ "fenced", "indented", "inline-code", "comment", "script", "script-body", "white space" }) |name|
        try std.testing.expect(doc.findAnchor(name) == null);
    try std.testing.expect(doc.findAnchor("end") != null);
}
test "document: duplicate aliases use the first target and remain owned" {
    var input = "<a id='alias'></a>\n\n# First\n\n<a id='alias'></a>\n\n# Second\n".*;
    var doc = try Document.parse(a, &input, "anchors.md");
    defer doc.deinit();
    @memset(&input, 'x');
    try std.testing.expectEqual(doc.findAnchor("first").?, doc.findAnchor("alias").?);
    try std.testing.expect(doc.findAnchor("second") != null);
    try std.testing.expectEqual(@as(usize, 0), doc.findAnchor("").?);
}
test "document: HTML aliases release all storage after allocation failures" {
    try std.testing.checkAllAllocationFailures(a, struct {
        fn parse(allocator: std.mem.Allocator) !void {
            var doc = try Document.parse(allocator, "<a id='owned&amp;id' name=legacy></a>\n\n## Heading\n", "anchors.md");
            defer doc.deinit();
        }
    }.parse, .{});
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

test "document: image labels stay semantic text without a second Markdown parse" {
    for ([_]struct { source: []const u8, value: []const u8 }{
        .{ .source = "![`*literal*`](missing.png)", .value = "*literal*" },
        .{ .source = "![\\*literal\\*](missing.png)", .value = "*literal*" },
        .{ .source = "![&copy;](missing.png)", .value = "©" },
        .{ .source = "![\\&copy;](missing.png)", .value = "&copy;" },
        .{ .source = "![`&copy;`](missing.png)", .value = "&copy;" },
        .{ .source = "![<https://example.com>](missing.png)", .value = "https://example.com" },
    }) |case| {
        var doc = try Document.parseDeferred(a, case.source, "image.md");
        defer doc.deinit();
        const label = try text(doc.blocks[0]);
        defer a.free(label);
        try std.testing.expectEqualStrings(case.value, label);
        for (doc.blocks[0].spans) |span| try std.testing.expect(!span.italic and !span.code);
    }
}

test "document: deeply nested image labels fail with balanced profiling scopes" {
    const profile = @import("mdf").profiling;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for (0..160) |_| try source.appendSlice(a, "![");
    try source.append(a, 'x');
    for (0..160) |_| try source.appendSlice(a, "](missing.png)");
    const recorder = try a.create(profile.Recorder);
    defer a.destroy(recorder);
    try recorder.init(profile.nowNs());
    recorder.enable();
    defer recorder.deinit();
    try std.testing.expectError(error.NestingTooDeep, Document.parseDeferred(a, source.items, "nested.md"));
    for (recorder.depths) |depth| try std.testing.expectEqual(@as(usize, 0), depth);
}
