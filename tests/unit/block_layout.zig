const std = @import("std");
const engine = @import("mdf").block_layout;
const document = @import("mdf").document;
const measurement = @import("mdf").measurement;
const flow = @import("mdf").flow;
const a = std.testing.allocator;
const options: engine.Options = .{ .content_width = 200, .margin = 24, .zoom = 1 };
fn metrics(_: ?*anyopaque, font: measurement.Font, _: [*]const u8, len: usize) callconv(.c) flow.Metrics {
    return .{ .width = @as(f32, @floatFromInt(len)) * @as(f32, @floatFromInt(font.size)) * 0.5,
        .height = @floatFromInt(font.size), .descent = 2 };
}
fn columns(_: ?*anyopaque, _: usize, _: f32, count: *usize) callconv(.c) ?[*]const f32 {
    const widths = &[_]f32{ 80, 120 };
    count.* = widths.len;
    return widths.ptr;
}

test "block layout: bold and linked word fragments share a wrapped line and source positions" {
    var doc = try document.Document.parse(a, "one ab**cd**[ef](#target) x\n", "");
    defer doc.deinit();
    var opts = options;
    opts.content_width = 70;
    var result = try engine.measure(a, doc.blocks[0], 0, 100, opts, metrics, columns, null);
    defer result.deinit();
    const first = try bodyRun(result, 104);
    const bold = try bodyRun(result, 106);
    const link = try bodyRun(result, 108);
    try std.testing.expectEqual(first.y, bold.y);
    try std.testing.expectEqual(first.y, link.y);
    try std.testing.expect(first.y > result.runs.items[0].y);
    try std.testing.expectEqualStrings("ab", first.text.slice());
    try std.testing.expect(bold.flags & 1 != 0);
    try std.testing.expectEqualStrings("#target", link.link.slice());
}

test "block layout: renderer boundaries reach paragraph and table flows" {
    const boundaries = struct {
        fn get(_: ?*anyopaque, _: [*]const flow.Span, _: usize) callconv(.c) ?[*]const u8 {
            return &.{ 1, 0, 0, 1, 1, 0, 0, 1 };
        }
        fn columns(_: ?*anyopaque, _: usize, _: f32, count: *usize) callconv(.c) ?[*]const f32 {
            count.* = 1;
            return &.{20};
        }
    };
    const spans: []const document.Span = &.{.{ .text = "e\xcc\x81xe\xcc\x81" }};
    for ([_]document.Block{
        .{ .spans = spans },
        .{ .kind = .table_row, .cells = &.{.{ .spans = spans }} },
    }) |block| {
        var opts = options;
        opts.content_width = 20;
        opts.boundaries = boundaries.get;
        var result = try engine.measure(a, block, 0, 100, opts, metrics, boundaries.columns, null);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 3), result.runs.items.len);
        try std.testing.expectEqual(@as(usize, 100), result.runs.items[0].position);
        try std.testing.expectEqual(@as(usize, 3), result.runs.items[0].text.len);
        try std.testing.expectEqual(@as(usize, 104), result.runs.items[2].position);
        try std.testing.expectEqual(@as(usize, 3), result.runs.items[2].text.len);
    }
}

fn bodyRun(result: engine.Result, start: usize) !engine.Run {
    for (result.runs.items) |run| if (run.position == start) return run;
    return error.MissingBodyRun;
}
fn quoteBorder(result: engine.Result, depth: usize) !engine.Rect {
    const x = options.margin + @as(f32, @floatFromInt(depth)) * 22;
    for (result.rects.items) |rect| if (rect.x == x and rect.width == 3 and rect.role == 1) return rect;
    return error.MissingQuoteBorder;
}
test "block layout: larger unordered bullets preserve body geometry and source positions" {
    for ([_]f32{ 0.5, 1, 2 }) |zoom| {
        var opts = options;
        opts.zoom = zoom;
        const spans: []const document.Span = &.{.{ .text = "Alpha beta gamma delta" }};
        var bullet = try engine.measure(a, .{ .indent = 1, .prefix = "• ", .spans = spans }, 0, 100, opts, metrics, columns, null);
        defer bullet.deinit();
        // Both prefixes occupy four bytes and have equal test-metric widths.
        var ordered = try engine.measure(a, .{ .indent = 1, .prefix = "12. ", .spans = spans }, 0, 100, opts, metrics, columns, null);
        defer ordered.deinit();
        try std.testing.expectEqual(ordered.height, bullet.height);
        try std.testing.expectEqual(ordered.right, bullet.right);
        try std.testing.expectEqual(ordered.runs.items.len, bullet.runs.items.len);
        const marker = bullet.runs.items[0];
        const original = ordered.runs.items[0];
        try std.testing.expectEqualStrings("•", marker.text.slice());
        try std.testing.expectEqual(@as(usize, 100), marker.position);
        try std.testing.expect(marker.font.size > original.font.size);
        try std.testing.expectEqual(original.font.face, marker.font.face);
        try std.testing.expectEqual(original.font.flags, marker.font.flags);
        try std.testing.expectEqual(original.height, marker.height);
        const center = marker.y - marker.font_height / 2 + marker.font_descent;
        const original_center = original.y - original.font_height / 2 + original.font_descent;
        try std.testing.expectApproxEqAbs(original_center, center, 0.001);
        for (bullet.runs.items, ordered.runs.items) |actual, expected| {
            if (actual.position < 104) continue;
            try std.testing.expectEqualStrings(expected.text.slice(), actual.text.slice());
            try std.testing.expectEqual(expected.position, actual.position);
            try std.testing.expectEqual(expected.font, actual.font);
            try std.testing.expectEqual(expected.x, actual.x);
            try std.testing.expectEqual(expected.y, actual.y);
            try std.testing.expectEqual(expected.width, actual.width);
            try std.testing.expectEqual(expected.height, actual.height);
        }
        var task = try engine.measure(a, .{ .indent = 1, .prefix = "• ", .task = false, .spans = spans }, 0, 100, opts, metrics, columns, null);
        defer task.deinit();
        try std.testing.expectEqual(original.font.size, task.runs.items[0].font.size);
    }
}
test "block layout: quoted markers stay centered with the body and inside the quote" {
    var doc = try document.Document.parse(a, "> - First item with enough words to wrap onto another line.\n> - Second item.\n", "");
    defer doc.deinit();
    for (doc.blocks, 0..) |block, index| {
        var result = try engine.measure(a, block, index, doc.rendered.starts[index], options, metrics, columns, null);
        defer result.deinit();
        const body = try bodyRun(result, doc.rendered.starts[index] + block.prefix.len);
        const marker = result.runs.items[0];
        const border = try quoteBorder(result, 1);
        const marker_center = marker.y - marker.font_height / 2 + marker.font_descent;
        const body_center = body.y - body.font_height / 2 + body.font_descent;
        try std.testing.expectApproxEqAbs(marker_center, body_center, 0.001);
        try std.testing.expect(marker.x >= border.x + 12 and body.x > marker.x);
        for (result.runs.items) |run| if (run.position >= body.position and run.position != std.math.maxInt(usize))
            try std.testing.expect(run.x >= body.x);
    }
}
test "block layout: quote backgrounds join paragraphs and retain nested rules" {
    var doc = try document.Document.parse(a, "> First paragraph.\n>\n> > Nested paragraph.\n>\n> Last paragraph.\n", "");
    defer doc.deinit();
    for (doc.blocks, 0..) |block, index| {
        var result = try engine.measure(a, block, index, doc.rendered.starts[index], options, metrics, columns, null);
        defer result.deinit();
        const outer = try quoteBorder(result, 1);
        try std.testing.expectEqual(@as(f32, 0), outer.y);
        try std.testing.expectApproxEqAbs(result.height - (if (index + 1 == doc.blocks.len) @as(f32, 12) else 0), outer.height, 0.001);
        if (index == 1) {
            const inner = try quoteBorder(result, 2);
            try std.testing.expect(inner.x > outer.x and inner.height < outer.height);
        }
    }
}
test "block layout: quoted task boxes align with their text and alert color spans list items" {
    var doc = try document.Document.parse(a, "> [!WARNING]\n> Take care.\n>\n> - [x] Done.\n> - [ ] Pending.\n", "");
    defer doc.deinit();
    for (doc.blocks, 0..) |block, index| {
        var result = try engine.measure(a, block, index, doc.rendered.starts[index], options, metrics, columns, null);
        defer result.deinit();
        var colored = false;
        for (result.rects.items) |rect| colored = colored or (rect.role == 8 and rect.width == 3 and rect.x == 46);
        try std.testing.expect(colored);
        if (block.task) |_| {
            const body = try bodyRun(result, doc.rendered.starts[index] + block.prefix.len);
            var checkbox = false;
            for (result.rects.items) |rect| if (rect.x > 46 and rect.x < body.x and rect.width < 20 and
                rect.y >= body.y - body.font_height and rect.y < body.y) { checkbox = true; };
            try std.testing.expect(checkbox);
        }
    }
}
test "block layout: quotes inside lists keep a stable gutter across headings and tables" {
    var doc = try document.Document.parse(a, "- Outer item.\n\n  > ## Heading\n  >\n  > Paragraph.\n  >\n  > | A | B |\n  > |---|---|\n  > | C | D |\n", "");
    defer doc.deinit();
    var previous_x: ?f32 = null;
    for (doc.blocks, 0..) |block, index| {
        if (block.quote == 0) continue;
        var result = try engine.measure(a, block, index, doc.rendered.starts[index], options, metrics, columns, null);
        defer result.deinit();
        var bar: ?engine.Rect = null;
        for (result.rects.items) |rect| if (rect.width == 3 and rect.role == 1) { bar = rect; };
        const border = bar orelse return error.MissingQuoteBorder;
        if (previous_x) |x| try std.testing.expectApproxEqAbs(x, border.x, 0.001);
        previous_x = border.x;
        for (result.runs.items) |run| try std.testing.expect(run.x >= border.x + 8);
    }
    try std.testing.expect(previous_x != null);
}
test "block layout: paragraph runs preserve style links byte positions and margins" {
    const block: document.Block = .{ .spans = &.{.{ .text = "abc", .bold = true, .link = "#target" }} };
    var result = try engine.measure(a, block, 0, 100, options, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 37.5), result.height);
    try std.testing.expectEqual(@as(f32, 224), result.right);
    try std.testing.expectEqual(@as(usize, 1), result.runs.items.len);
    const run = result.runs.items[0];
    try std.testing.expectEqual(@as(f32, 24), run.x);
    try std.testing.expectEqual(@as(f32, 19.25), run.y);
    try std.testing.expectEqual(@as(usize, 100), run.position);
    try std.testing.expectEqual(@as(u32, 1), run.font.face);
    try std.testing.expectEqualStrings("#target", run.link.slice());
}
test "block layout: heading spacing and rules retain exact heights" {
    var result = try engine.measure(a, .{ .kind = .heading, .heading = 1, .spans = &.{.{ .text = "Head" }} },
        0, 0, options, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 78), result.height);
    try std.testing.expectEqual(@as(usize, 1), result.rects.items.len);
    try std.testing.expectEqual(@as(f32, 60), result.rects.items[0].y);
    var following = try engine.measure(a, .{ .kind = .heading, .heading = 2 }, 5, 0, options, metrics, columns, null);
    defer following.deinit();
    try std.testing.expectEqual(@as(f32, 82), following.height);
}
test "block layout: code labels are bold nonselectable and share prepared monospace" {
    var opts = options;
    opts.mono_ready = true;
    var result = try engine.measure(a, .{ .kind = .code, .language = "zig", .spans = &.{.{ .text = "x\ny" }} },
        0, 20, opts, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 103.5), result.height);
    try std.testing.expectEqual(@as(usize, 3), result.runs.items.len);
    try std.testing.expectEqual(std.math.maxInt(usize), result.runs.items[0].position);
    try std.testing.expectEqual(@as(u32, 1), result.runs.items[0].font.flags);
    try std.testing.expectEqual(@as(usize, 20), result.runs.items[1].position);
    try std.testing.expectEqual(@as(usize, 22), result.runs.items[2].position);
    try std.testing.expectEqual(@as(u32, 2), result.rects.items[0].role);
}
test "block layout: alert labels and quote borders use semantic roles" {
    var result = try engine.measure(a, .{ .quote = 1, .alert = .warning, .alert_start = true,
        .spans = &.{.{ .text = "Care" }} }, 0, 200, options, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 95), result.height);
    try std.testing.expectEqual(@as(f32, 46), result.rects.items[0].x);
    try std.testing.expectEqual(@as(u32, 8), result.rects.items[1].role);
    try std.testing.expectEqual(std.math.maxInt(usize), result.runs.items[0].position);
    try std.testing.expectEqual(@as(u32, 8), result.runs.items[0].role);
}
test "block layout: task decorations reserve text space and retain check geometry" {
    var checked = try engine.measure(a, .{ .task = true, .spans = &.{.{ .text = "done" }} }, 0, 50, options, metrics, columns, null);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 8), checked.rects.items.len);
    try std.testing.expectEqual(@as(f32, 49.5), checked.runs.items[0].x);
    try std.testing.expectEqual(@as(u32, 3), checked.rects.items[0].role);
    var unchecked = try engine.measure(a, .{ .task = false }, 0, 0, options, metrics, columns, null);
    defer unchecked.deinit();
    try std.testing.expectEqual(@as(usize, 4), unchecked.rects.items.len);
    for (unchecked.rects.items) |rect| try std.testing.expectEqual(@as(u32, 10), rect.role);
}
test "block layout: aligned table cells preserve tab positions and background order" {
    const block: document.Block = .{ .kind = .table_row, .table_header = true, .table_last = true,
        .cells = &.{ .{ .spans = &.{.{ .text = "A" }} }, .{ .spans = &.{.{ .text = "B" }}, .alignment = .right } } };
    var result = try engine.measure(a, block, 0, 100, options, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(f32, 53.5), result.height);
    try std.testing.expectEqual(@as(usize, 6), result.rects.items.len);
    try std.testing.expectEqual(@as(u32, 2), result.rects.items[0].role);
    try std.testing.expectEqual(@as(f32, 207.5), result.runs.items[1].x);
    try std.testing.expectEqual(@as(usize, 102), result.runs.items[1].position);
}
test "block layout: images fit available width and Mermaid is centered" {
    var opts = options;
    opts.image_ready = true;
    opts.image_width = 400;
    opts.image_height = 200;
    var image = try engine.measure(a, .{ .kind = .image }, 0, 0, opts, metrics, columns, null);
    defer image.deinit();
    try std.testing.expect(image.image);
    try std.testing.expectEqual(@as(f32, 200), image.iw);
    try std.testing.expectEqual(@as(f32, 100), image.ih);
    opts.image_width = 80;
    opts.image_height = 40;
    var diagram = try engine.measure(a, .{ .kind = .code, .language = "mermaid" }, 0, 0, opts, metrics, columns, null);
    defer diagram.deinit();
    try std.testing.expectEqual(@as(f32, 84), diagram.ix);
    try std.testing.expectEqual(@as(f32, 52), diagram.height);
    try std.testing.expectEqual(@as(usize, 0), diagram.runs.items.len);
}
test "block layout: generated error labels remain owned until result release" {
    var opts = options;
    opts.failure = .{ .ptr = "bad svg", .len = 7 };
    var result = try engine.measure(a, .{ .kind = .image, .spans = &.{.{ .text = "alt" }} }, 0, 0, opts, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqualStrings("SVG: bad svg", result.labels.items[0]);
    try std.testing.expectEqual(@as(f32, 63), result.height);
    try std.testing.expectEqual(std.math.maxInt(usize), result.runs.items[0].position);
}

test "block layout: native Mermaid preserves label scale and exposes its full width" {
    var opts = options;
    opts.content_width = 368;
    opts.image_ready = true;
    opts.logical_image = true;
    opts.image_width = 880;
    opts.image_height = 336;
    opts.diagram_scale = 1;
    opts.diagram_controls_height = 32;
    const block: document.Block = .{ .kind = .code, .language = "mermaid" };
    var natural = try engine.measure(a, block, 0, 0, opts, metrics, columns, null);
    defer natural.deinit();
    try std.testing.expectEqual(@as(f32, 880), natural.iw);
    try std.testing.expectEqual(@as(f32, 336), natural.ih);
    try std.testing.expectEqual(@as(f32, 24), natural.ix);
    try std.testing.expectEqual(@as(f32, 32), natural.iy);
    try std.testing.expectEqual(@as(f32, 904), natural.right);
    opts.diagram_scale = 368.0 / 880.0;
    var fitted = try engine.measure(a, block, 0, 0, opts, metrics, columns, null);
    defer fitted.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 368), fitted.iw, 0.001);
    opts.diagram_scale = 2;
    var enlarged = try engine.measure(a, block, 0, 0, opts, metrics, columns, null);
    defer enlarged.deinit();
    try std.testing.expectEqual(@as(f32, 1760), enlarged.iw);
    var photo = try engine.measure(a, .{ .kind = .image }, 0, 0, opts, metrics, columns, null);
    defer photo.deinit();
    try std.testing.expectEqual(@as(f32, 368), photo.iw);
    try std.testing.expectEqual(@as(f32, 0), photo.iy);
    opts.diagram_scale = 0.25;
    var reduced = try engine.measure(a, block, 0, 0, opts, metrics, columns, null);
    defer reduced.deinit();
    try std.testing.expectEqual(@as(f32, 220), reduced.iw);
    try std.testing.expectEqual(@as(f32, 98), reduced.ix);
    for ([_]f32{ -1, 3, std.math.nan(f32), std.math.inf(f32) }) |invalid| {
        opts.diagram_scale = invalid;
        try std.testing.expectError(error.InvalidGeometry, engine.measure(a, block, 0, 0, opts, metrics, columns, null));
    }
}
test "block layout: no-wrap measurement needs no text-run allocation" {
    var opts = options;
    opts.content_width = 40;
    opts.collect = false;
    opts.wrap = false;
    var result = try engine.measure(std.testing.failing_allocator, .{ .spans = &.{.{ .text = "long word longer" }} },
        0, 0, opts, metrics, columns, null);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.runs.items.len);
    try std.testing.expect(result.right > 100);
}
fn allocationCheck(allocator: std.mem.Allocator) !void {
    var spans: [20]document.Span = undefined;
    for (&spans) |*span| span.* = .{ .text = "Styled " };
    var opts = options;
    opts.failure = .{ .ptr = "failure", .len = 7 };
    var result = try engine.measure(allocator, .{ .kind = .code, .language = "mermaid",
        .quote = 1, .alert = .note, .alert_start = true, .spans = &spans },
        0, 0, opts, metrics, columns, null);
    defer result.deinit();
}
test "block layout: errors release labels runs rectangles and large-span temporaries" {
    try std.testing.checkAllAllocationFailures(a, allocationCheck, .{});
}
