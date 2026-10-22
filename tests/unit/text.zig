const std = @import("std");
const text = @import("mdf").text;
const document = @import("mdf").document;
const fonts = @import("mdf").fonts;
const a = std.testing.allocator;

test "text: projection preserves prefixes table separators and UTF-8 byte offsets" {
    const blocks = [_]document.Block{
        .{ .prefix = "• ", .spans = &.{ .{ .text = "café" }, .{ .text = " text" } } },
        .{ .kind = .table_row, .cells = &.{
            .{ .spans = &.{.{ .text = "A" }} },
            .{ .spans = &.{} },
            .{ .spans = &.{.{ .text = "中" }} },
        } },
        .{ .kind = .rule },
    };
    const result = try text.Projection.init(a, &blocks);
    defer result.deinit(a);
    try std.testing.expectEqualStrings("• café text\n\nA\t\t中\n\n\n\n", result.text);
    try std.testing.expectEqualSlices(usize, &.{ 0, 16, 24 }, result.starts);
}
test "text: plain text includes every block kind and retains explicit code newlines" {
    var doc = try document.Document.parse(a,
        "# Head\n\n> Quote\n\n- Item\n\n| Key | Value |\n|---|---|\n| A | B |\n\n\x60\x60\x60zig\nconst x = 1;\n\x60\x60\x60\n",
        "text.md");
    defer doc.deinit();
    try std.testing.expect(std.mem.indexOf(u8, doc.rendered.text, "Head\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.rendered.text, "Key\tValue\n\nA\tB\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc.rendered.text, "const x = 1;") != null);
    try std.testing.expectEqual(doc.blocks.len, doc.rendered.starts.len);
    try std.testing.expectEqual(@as(u32, 1), doc.rendered.flags);
    for (doc.blocks, doc.rendered.starts) |block, start|
        try std.testing.expect(std.mem.startsWith(u8, doc.rendered.text[start..], block.prefix));
}
test "text: required styles agree with the asynchronous font worker" {
    const blocks = [_]document.Block{
        .{ .spans = &.{ .{ .text = "regular" }, .{ .text = "italic", .italic = true }, .{ .text = "", .bold = true, .italic = true } } },
        .{ .kind = .heading, .spans = &.{.{ .text = "heading", .italic = true }} },
        .{ .kind = .table_row, .table_header = true, .cells = &.{.{ .spans = &.{.{ .text = "header", .italic = true }} }} },
    };
    const result = try text.Projection.init(a, &blocks);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(u32, 12), result.styles);
    try std.testing.expectEqual(fonts.requiredStyles(&blocks), result.styles);
}
test "text: Mermaid and code requirements remain independent" {
    const code = [_]document.Block{.{ .kind = .code, .language = "zig" }};
    const mermaid = [_]document.Block{.{ .kind = .code, .language = "mermaid" }};
    const both = code ++ mermaid;
    for ([_][]const document.Block{ &code, &mermaid, &both }, [_]u32{ 1, 2, 3 }) |blocks, flags| {
        const result = try text.Projection.init(a, blocks);
        defer result.deinit(a);
        try std.testing.expectEqual(flags, result.flags);
    }
}
test "text: an empty document has no synthetic text or positions" {
    const result = try text.Projection.init(a, &.{});
    defer result.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), result.text.len);
    try std.testing.expectEqual(@as(usize, 0), result.starts.len);
    try std.testing.expectEqual(@as(u32, 0), result.flags);
}
fn allocationCheck(allocator: std.mem.Allocator) !void {
    const blocks = [_]document.Block{ .{ .prefix = "1. ", .spans = &.{.{ .text = "Item" }} }, .{ .kind = .rule } };
    const result = try text.Projection.init(allocator, &blocks);
    defer result.deinit(allocator);
}
test "text: allocation failure releases the partial projection" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
}
