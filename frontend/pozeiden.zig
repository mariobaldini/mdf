//! MDF's bounded C ABI adapter for the pinned Pozeiden Mermaid renderer.
const std = @import("std");
const pozeiden = @import("root.zig");
const theme = @import("svg/theme.zig");

const FontData = extern struct { data: ?[*]const u8, length: usize };
const SvgText = extern struct { data: ?[*]const u8, length: usize };
const max_input = 256 * 1024;
const max_svg = 16 * 1024 * 1024;

fn generate(allocator: std.mem.Allocator, source: []const u8, dark: bool, limit: usize) ![]const u8 {
    if (source.len == 0) return error.EmptyDiagram;
    if (source.len > max_input) return error.InputTooLarge;
    if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;
    defer theme.resetToDefaults();
    // Retain upstream's light note/ref/subgraph colors in the normalized
    // renderers. Dark text and node colors also drive actors and signals.
    theme.note_fill = "#fffde7";
    theme.note_stroke = "#f0c040";
    theme.loop_fill = "#f0f4ff";
    theme.loop_stroke = "#6688cc";
    theme.subgraph_fill = "#f0f4ff";
    theme.subgraph_stroke = "#b0c0e8";
    if (dark) {
        // RenderOptions derives actor/signal colors from nodes/text, but
        // notes and subgraphs have separate public theme fields.
        theme.note_fill = "#4b4226";
        theme.note_stroke = "#c4ad63";
        theme.subgraph_fill = "#292c31";
        theme.subgraph_stroke = "#687386";
        theme.loop_fill = "#292c31";
        theme.loop_stroke = "#687386";
    }
    const svg = try pozeiden.renderWithOptions(allocator, source, .{
        .strict = true,
        .max_input_bytes = max_input,
        .theme_override = if (dark) .{
            .font_family = "Open Sans",
            .background = "#202124",
            .text_color = "#e0e0e0",
            .node_fill = "#30344b",
            .node_stroke = "#8daff0",
            .edge_color = "#bfc7d5",
        } else .{ .font_family = "Open Sans" },
    });
    errdefer allocator.free(svg);
    if (svg.len > @min(limit, max_svg)) return error.OutputTooLarge;
    if (dark) {
        // Upstream's canonical arrow markers hardcode a dark ink. Recolor
        // only that exact block in our owned SVG, retaining custom fills.
        const markers = @import("svg/writer.zig").arrow_marker_defs;
        if (std.mem.indexOf(u8, svg, markers)) |at| {
            _ = std.mem.replace(u8, markers, "#333333", "#bfc7d5", @constCast(svg[at..][0..markers.len]));
        }
    }
    return svg;
}

fn fail(buffer: ?[*]u8, length: usize, message: []const u8) c_int {
    if (buffer) |out| if (length > 0) {
        const count = @min(message.len, length - 1);
        @memcpy(out[0..count], message[0..count]);
        out[count] = 0;
    };
    return 0;
}

// c_allocator returns a C-owned byte slice. The host frees the successful SVG
// with libc free, matching the existing independent-module ABI.
export fn mdf_mermaid_svg(source: ?[*]const u8, length: usize, dark: c_int,
    fonts: ?[*]const FontData, font_count: usize, limit: usize, output: ?*SvgText,
    error_buffer: ?[*]u8, error_length: usize) c_int
{
    const out = output orelse return 0;
    out.* = .{ .data = null, .length = 0 };
    if (font_count > 256 or (font_count > 0 and fonts == null))
        return fail(error_buffer, error_length, "Invalid prepared diagram fonts");
    const input = source orelse return fail(error_buffer, error_length, "Empty Mermaid diagram");
    if (length > max_input) return fail(error_buffer, error_length, "Mermaid source exceeds 256 KiB");
    const svg = generate(std.heap.c_allocator, input[0..length], dark != 0, limit) catch |err| {
        return fail(error_buffer, error_length, switch (err) {
            error.UnknownDiagramType => "Unsupported Mermaid diagram type: Pozeiden supports 17 types; source is shown below",
            error.EmptyDiagram => "Empty Mermaid diagram",
            error.InvalidUtf8 => "Mermaid source is not UTF-8",
            error.InputTooLarge => "Mermaid source exceeds 256 KiB",
            error.OutputTooLarge => "Generated SVG exceeds the image memory limit",
            error.OutOfMemory => "Cannot allocate Mermaid layout",
            error.ParseError => "Cannot parse Mermaid diagram",
            error.DiagramTooLarge => "Mermaid diagram exceeds the size limit",
            error.NestingTooDeep => "Mermaid diagram is nested too deeply",
            else => @errorName(err),
        });
    };
    out.* = .{ .data = svg.ptr, .length = svg.len };
    if (error_buffer) |buffer| if (error_length > 0) { buffer[0] = 0; };
    return 1;
}

test "all seventeen Pozeiden families generate SVG in light and dark themes" {
    inline for (.{ "pie", "flowchart", "sequence", "gitgraph", "class", "state", "er", "gantt",
        "timeline", "xychart", "quadrant", "mindmap", "sankey", "c4", "block", "requirement", "kanban" }) |name| {
        const source = @embedFile("pozeiden-fixture-" ++ name);
        for ([_]bool{ false, true }) |dark| {
            const svg = try generate(std.testing.allocator, source, dark, max_svg);
            defer std.testing.allocator.free(svg);
            try std.testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
            try std.testing.expect(std.mem.indexOf(u8, svg, "<text") != null);
            try std.testing.expect(std.mem.indexOf(u8, svg, "Open Sans") != null);
        }
    }
}

test "unsupported families report errors instead of placeholder diagrams" {
    inline for (.{ "journey\n title Trip", "packet-beta\n0-7: Bits", "architecture-beta\n", "treemap-beta\n",
        "radar-beta\n", "zenuml\nAlice->Bob: Hello", "not a diagram" }) |source| {
        try std.testing.expectError(error.UnknownDiagramType, generate(std.testing.allocator, source, false, max_svg));
    }
}

test "dark sequence actors notes and signals use a complete readable palette" {
    const source = "sequenceDiagram\n Alice->>Bob: Hello\n Note over Alice,Bob: A readable note";
    const svg = try generate(std.testing.allocator, source, true, max_svg);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#30344b") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#e0e0e0") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#4b4226") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "#ececff") == null);
    try std.testing.expectEqualStrings("#ececff", theme.actor_fill);
}

test "dark arrow markers change without rewriting explicit node colors" {
    const svg = try generate(std.testing.allocator, "flowchart LR\n A[Read] --> B[Draw]\n style A fill:#333333", true, max_svg);
    defer std.testing.allocator.free(svg);
    try std.testing.expect(std.mem.indexOf(u8, svg, "points=\"0 0, 10 3.5, 0 7\" fill=\"#bfc7d5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, svg, "fill=\"#333333\"") != null);
}

test "dark default chart and note backgrounds preserve label contrast" {
    inline for (.{ "class", "timeline", "quadrant", "pie", "c4" }) |name| {
        const source = @embedFile("pozeiden-fixture-" ++ name);
        const light = try generate(std.testing.allocator, source, false, max_svg);
        defer std.testing.allocator.free(light);
        const dark = try generate(std.testing.allocator, source, true, max_svg);
        defer std.testing.allocator.free(dark);
        try std.testing.expect(std.mem.indexOf(u8, dark, "#e0e0e0") != null);
        if (comptime std.mem.eql(u8, name, "class")) {
            try std.testing.expect(std.mem.indexOf(u8, light, "#fffde7") != null);
            try std.testing.expect(std.mem.indexOf(u8, dark, "#fffde7") == null);
        } else if (comptime std.mem.eql(u8, name, "timeline")) {
            try std.testing.expect(std.mem.indexOf(u8, light, "#f8f9fa") != null);
            try std.testing.expect(std.mem.indexOf(u8, dark, "#f8f9fa") == null);
        } else if (comptime std.mem.eql(u8, name, "quadrant")) {
            try std.testing.expect(std.mem.indexOf(u8, light, "#fafafa") != null);
            try std.testing.expect(std.mem.indexOf(u8, dark, "#fafafa") == null);
        }
    }
}

test "FFI ownership and bounded input output failures" {
    const source = "flowchart LR\n A[Read] --> B[Draw]";
    var out: SvgText = .{ .data = null, .length = 0 };
    var message: [256]u8 = @splat(0);
    try std.testing.expectEqual(@as(c_int, 1), mdf_mermaid_svg(source.ptr, source.len, 0, null, 0, max_svg, &out, &message, message.len));
    defer std.heap.c_allocator.free(out.data.?[0..out.length]);
    var failed: SvgText = undefined;
    try std.testing.expectEqual(@as(c_int, 0), mdf_mermaid_svg(source.ptr, source.len, 0, null, 0, 1, &failed, &message, message.len));
    try std.testing.expect(failed.data == null and failed.length == 0 and message[0] != 0);
    try std.testing.expectEqual(@as(c_int, 0), mdf_mermaid_svg(source.ptr, max_input + 1, 0, null, 0, max_svg, &failed, &message, message.len));
    try std.testing.expectError(error.InvalidUtf8, generate(std.testing.allocator, "\xff", false, max_svg));
}
