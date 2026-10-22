const std = @import("std");
const nav = @import("mdf").navigation;
const document = @import("mdf").document;
const a = std.testing.allocator;

fn wrapped(input: []const u8, columns: usize, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const lines = try nav.wrap(arena.allocator(), input, columns, null);
    try std.testing.expectEqual(expected.len, lines.len);
    for (expected, lines) |want, got| try std.testing.expectEqualStrings(want, got);
}
test "navigation: wrapping respects word boundaries" {
    try wrapped("alpha beta gamma", 8, &.{ "alpha", "beta", "gamma" });
}
test "navigation: long unbroken words wrap without losing characters" {
    try wrapped("abcdefgh", 3, &.{ "abc", "def", "gh" });
}
test "navigation: wrapping counts Unicode code points rather than UTF-8 bytes" {
    try wrapped("é中🚀ab", 2, &.{ "é中", "🚀a", "b" });
}
test "navigation: zero requested columns still make forward progress" {
    try wrapped("abc", 0, &.{ "a", "b", "c" });
}
test "navigation: blank lines remain visible without inventing a trailing line" {
    try wrapped("a\n\nb\n", 20, &.{ "a", "", "b" });
    try wrapped("", 20, &.{});
}
test "navigation: cancellation stops wrapping before producing content" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var stop: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, nav.wrap(arena.allocator(), "some text", 5, &stop));
}
test "navigation: parameter caching tolerates subpixel width changes only" {
    const value = nav.Parameters{ .width = 600, .zoom = 1, .character_width = 7 };
    try std.testing.expect(value.eql(.{ .width = 600.5, .zoom = 1, .character_width = 7.005 }));
    try std.testing.expect(!value.eql(.{ .width = 601, .zoom = 1, .character_width = 7 }));
    try std.testing.expect(!value.eql(.{ .width = 600, .zoom = 1.1, .character_width = 7 }));
    try std.testing.expect(!value.eql(.{ .width = 600, .zoom = 1, .character_width = 7.02 }));
}
test "navigation: an empty model has no headings images or preview rows" {
    var model = try nav.Model.prepare(a, &.{}, "empty.md", .{ .width = 600, .zoom = 1, .character_width = 7 }, null);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 0), model.headings.len + model.images.len + model.preview.len);
}
test "navigation: outline titles combine styled spans and keep document indices" {
    var doc = try document.Document.parse(a, "# One **bold**\n\nBody.\n\n### Sub\n", "");
    defer doc.deinit();
    var model = try nav.Model.prepare(a, doc.blocks, doc.path, .{ .width = 0, .zoom = 1, .character_width = 7 }, null);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 2), model.headings.len);
    try std.testing.expectEqualStrings("One bold", model.headings[0].title);
    try std.testing.expectEqual(@as(usize, 2), model.headings[1].index);
    try std.testing.expectEqual(@as(u8, 3), model.headings[1].level);
    try std.testing.expectEqual(@as(usize, 0), model.preview.len);
}
test "navigation: an empty heading has a readable TOC label" {
    const blocks = [_]document.Block{.{ .kind = .heading, .heading = 2 }};
    var model = try nav.Model.prepare(a, &blocks, "", .{ .width = 0, .zoom = 1, .character_width = 7 }, null);
    defer model.deinit();
    try std.testing.expectEqualStrings("(Untitled section)", model.headings[0].title);
}
test "navigation: a canceled reflow can be retried on the same model" {
    const blocks = [_]document.Block{.{ .spans = &.{.{ .text = "A paragraph" }} }};
    const params = nav.Parameters{ .width = 600, .zoom = 1, .character_width = 7 };
    var model = try nav.Model.prepare(a, &blocks, "", params, null);
    defer model.deinit();
    var stop: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Canceled, model.reflow(&blocks, params, &stop));
    stop.store(false, .monotonic);
    try model.reflow(&blocks, params, &stop);
    try std.testing.expectEqual(@as(usize, 1), model.preview.len);
    try std.testing.expectEqualStrings("A paragraph", model.preview[0].lines[0]);
}
