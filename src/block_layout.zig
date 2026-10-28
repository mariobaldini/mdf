//! Markdown block geometry. Font metrics and cached table widths are supplied
//! by the backend; text, decoration, selection and image bounds stay in Zig.
const std = @import("std");
const document = @import("document.zig");
const flow = @import("flow.zig");
const measurement = @import("measurement.zig");
const Allocator = std.mem.Allocator;
fn alertRole(alert: ?document.Alert) u32 {
    return if (alert) |value| switch (value) {
        .note => 5, .tip => 6, .important => 7, .warning => 8, .caution => 9,
    } else 5;
}
pub const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
    pub fn slice(self: Bytes) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else "";
    }
};
fn borrowed(value: []const u8) Bytes {
    return .{ .ptr = value.ptr, .len = value.len };
}
pub const Options = extern struct {
    content_width: f32,
    margin: f32,
    zoom: f32,
    wrap: bool = true,
    collect: bool = true,
    mono_ready: bool = false,
    visible: bool = true,
    image_ready: bool = false,
    logical_image: bool = false,
    image_width: f32 = 0,
    image_height: f32 = 0,
    failure: Bytes = .{},
    diagram_scale: f32 = 0, // Zero preserves the reference frontend's fit policy.
    diagram_controls_height: f32 = 0,
    boundaries: ?flow.Boundaries = null,
};
pub const Columns = *const fn (?*anyopaque, usize, f32, *usize) callconv(.c) ?[*]const f32;
pub const Rect = extern struct { x: f32, y: f32, width: f32, height: f32, role: u32 };
pub const Run = extern struct {
    text: Bytes,
    link: Bytes,
    font: measurement.Font,
    flags: u32,
    role: u32,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    position: usize,
    font_height: f32,
    font_descent: f32,
};
pub const View = extern struct {
    runs: ?[*]const Run,
    run_count: usize,
    rects: ?[*]const Rect,
    rect_count: usize,
    height: f32,
    right: f32,
    image: bool,
    ix: f32,
    iy: f32,
    iw: f32,
    ih: f32,
};
pub const Result = struct {
    allocator: Allocator,
    runs: std.ArrayList(Run) = .empty,
    rects: std.ArrayList(Rect) = .empty,
    labels: std.ArrayList([]u8) = .empty,
    height: f32 = 0,
    right: f32 = 0,
    image: bool = false,
    ix: f32 = 0,
    iy: f32 = 0,
    iw: f32 = 0,
    ih: f32 = 0,

    pub fn deinit(self: *Result) void {
        self.runs.deinit(self.allocator);
        self.rects.deinit(self.allocator);
        for (self.labels.items) |label| self.allocator.free(label);
        self.labels.deinit(self.allocator);
    }
    pub fn view(self: *const Result) View {
        return .{ .runs = if (self.runs.items.len > 0) self.runs.items.ptr else null, .run_count = self.runs.items.len,
            .rects = if (self.rects.items.len > 0) self.rects.items.ptr else null, .rect_count = self.rects.items.len,
            .height = self.height, .right = self.right, .image = self.image, .ix = self.ix, .iy = self.iy, .iw = self.iw, .ih = self.ih };
    }
    fn rectangle(self: *Result, x: f32, y: f32, width: f32, height: f32, role: u32) !void {
        try self.rects.append(self.allocator, .{ .x = x, .y = y, .width = width, .height = height, .role = role });
    }
    fn background(self: *Result, x: f32, y: f32, width: f32, height: f32) !void {
        try self.rects.insert(self.allocator, 0, .{ .x = x, .y = y, .width = width, .height = height, .role = 2 });
    }
    fn quoteBackgrounds(self: *Result, block: document.Block, index: usize, options: Options,
        content_bottom: f32, after: f32, top_padding: f32, bottom_padding: f32, list_gutter: f32) !void
    {
        var current = block.quote_context;
        var top = top_padding;
        var bottom = bottom_padding;
        while (current) |quote| : (current = quote.parent) {
            if (quote.first == index) top -= 12 * options.zoom;
            if (quote.end == index + 1) bottom -= 12 * options.zoom;
            const left = options.margin + @as(f32, @floatFromInt(@min(20, quote.indent +| quote.depth))) * 22 * options.zoom +
                (if (quote.indent > 0) list_gutter else 0);
            const edge = @max(self.right, options.margin + options.content_width);
            const height = @max(0, content_bottom - bottom - top + (if (quote.end > index + 1) after else 0));
            try self.background(left, top, @max(30, edge - left), height);
            try self.rectangle(left, top, 3 * options.zoom, height, if (quote.alert != null) alertRole(quote.alert) else 1);
        }
    }
    fn message(self: *Result, prefix: []const u8, detail: []const u8) ![]const u8 {
        const value = try self.allocator.alloc(u8, try std.math.add(usize, prefix.len, detail.len));
        errdefer self.allocator.free(value);
        @memcpy(value[0..prefix.len], prefix);
        @memcpy(value[prefix.len..], detail);
        try self.labels.append(self.allocator, value);
        return value;
    }
};
const Engine = struct {
    block: document.Block,
    options: Options,
    result: *Result,
    callback: measurement.Measure,
    context: ?*anyopaque,
    size: i32,
    width: f32,

    fn flowText(self: *Engine, spans: []const document.Span, left: f32, top: f32, width: f32, start: usize, alignment: document.Alignment, is_label: bool, role: u32) !struct { height: f32, right: f32 } {
        const a = self.result.allocator;
        var local_spans: [16]flow.Span = undefined;
        var local_fonts: [16]measurement.Font = undefined;
        const inputs = if (spans.len <= 16) local_spans[0..spans.len] else try a.alloc(flow.Span, spans.len);
        defer if (spans.len > 16) a.free(inputs);
        const fonts = if (spans.len <= 16) local_fonts[0..spans.len] else try a.alloc(measurement.Font, spans.len);
        defer if (spans.len > 16) a.free(fonts);
        for (spans, inputs, fonts) |span, *input, *font| {
            font.* = measurement.font(self.block, measurement.spanFlags(span), self.options.zoom, self.options.mono_ready);
            input.* = .{ .text = span.text.ptr, .len = span.text.len, .flags = font.flags & 1 };
        }
        const Context = struct {
            engine: *Engine,
            fonts: []const measurement.Font,
            fn measure(userdata: ?*anyopaque, index: usize, text: [*]const u8, len: usize) callconv(.c) flow.Metrics {
                const state: *@This() = @ptrCast(@alignCast(userdata.?));
                return state.engine.callback(state.engine.context, state.fonts[index], text, len);
            }
            fn boundaries(userdata: ?*anyopaque, text: [*]const flow.Span, count: usize) callconv(.c) ?[*]const u8 {
                const state: *@This() = @ptrCast(@alignCast(userdata.?));
                return state.engine.options.boundaries.?(state.engine.context, text, count);
            }
        };
        var context = Context{ .engine = self, .fonts = fonts };
        const flowing = try flow.layout(a, inputs, .{ .left = left, .top = top, .width = width, .size = self.size,
            .start = start, .alignment = switch (alignment) { .left => 0, .center => 1, .right => 2 },
            .flags = @as(u32, @intFromBool(self.options.wrap)) | (if (self.block.kind == .code) @as(u32, 2) else 0) | (if (self.options.collect) @as(u32, 4) else 0),
            .boundaries = if (self.options.boundaries != null) Context.boundaries else null,
        }, Context.measure, &context);
        defer flowing.deinit(a);
        for (flowing.runs) |run| {
            const span = spans[run.span];
            try self.result.runs.append(a, .{ .text = borrowed(span.text[run.offset..][0..run.len]), .link = borrowed(span.link orelse ""),
                .font = fonts[run.span], .flags = measurement.spanFlags(span), .role = role,
                .x = run.x, .y = run.y, .width = run.width, .height = run.height,
                .position = if (is_label) std.math.maxInt(usize) else run.position,
                .font_height = run.font_height, .font_descent = run.font_descent });
        }
        return .{ .height = flowing.height, .right = flowing.right };
    }
    fn label(self: *Engine, value: []const u8, x: f32, y: f32, role: u32) !f32 {
        const flowing = try self.flowText(&.{.{ .text = value, .bold = true }}, x, y,
            self.width - 24 * self.options.zoom, 0, .left, true, role);
        self.result.right = @max(self.result.right, flowing.right + 12 * self.options.zoom);
        return flowing.height;
    }
};

pub fn measure(a: Allocator, block: document.Block, index: usize, start: usize, options: Options, callback: measurement.Measure, columns: Columns, context: ?*anyopaque) !Result {
    var result = Result{ .allocator = a };
    errdefer result.deinit();
    if (!options.visible) return result;
    if (!std.math.isFinite(options.content_width) or !std.math.isFinite(options.margin) or
        !std.math.isFinite(options.zoom) or options.zoom <= 0 or
        !std.math.isFinite(options.diagram_scale) or options.diagram_scale < 0 or options.diagram_scale > 2 or
        !std.math.isFinite(options.diagram_controls_height) or options.diagram_controls_height < 0)
        return error.InvalidGeometry;
    const z = options.zoom;
    const size = measurement.font(block, 0, z, options.mono_ready).size;
    const sz: f32 = @floatFromInt(size);
    const list_gutter = @as(f32, @floatFromInt(measurement.font(.{}, 0, z, false).size)) * 1.5;
    const left = options.margin + @as(f32, @floatFromInt(@min(20, block.indent +| block.quote))) * 22 * z;
    var width = @max(30, options.content_width - (left - options.margin));
    var quote_top: f32 = 0;
    var quote_bottom: f32 = 0;
    var quote_end = false;
    var context_quote = block.quote_context;
    while (context_quote) |quote| : (context_quote = quote.parent) {
        if (quote.first == index) quote_top += 12 * z;
        if (quote.end == index + 1) quote_bottom += 12 * z;
        if (quote.parent == null) quote_end = quote.end == index + 1;
    }
    const before: f32 = (if (block.kind == .heading and index != 0) @as(f32, 16) * z else 0) + quote_top;
    var y = before;
    const after: f32 = if (block.quote_context) |quote|
        (if (quote_end) @as(f32, 12) else if (block.kind == .table_row and !block.table_last) @as(f32, 0)
            else if (block.indent > quote.indent) @as(f32, 4) else @as(f32, 8)) * z
        else if (block.kind == .table_row and !block.table_last) 0 else if (block.indent != 0) 6 * z else 12 * z;
    result.right = left + width;
    if (block.kind == .rule) {
        const inset: f32 = if (block.quote_context != null) 12 * z + (if (block.indent > 0) sz * 1.5 else 0) else 0;
        try result.rectangle(left + inset, before + 10 * z, @max(20, width - inset - (if (block.quote > 0) @as(f32, 12) * z else 0)), 1, 1);
        result.height = if (block.quote_context != null) before + 24 * z + quote_bottom + after else 24 * z;
        try result.quoteBackgrounds(block, index, options, before + 24 * z + quote_bottom, after, quote_top, quote_bottom, list_gutter);
        return result;
    }
    var engine = Engine{ .block = block, .options = options, .result = &result, .callback = callback,
        .context = context, .size = size, .width = width };
    const alert_role = alertRole(block.alert);
    if (block.alert_start)
        y += try engine.label(if (block.alert) |alert| alert.title() else "", left + 12 * z, y + 8 * z, alert_role) + 8 * z;
    const diagram = block.kind == .code and std.mem.eql(u8, block.language, "mermaid") and options.image_ready;
    const failure = options.failure.slice();
    if (block.kind == .code and block.language.len > 0 and !diagram) {
        const title = if (failure.len == 0) block.language else try result.message("Mermaid: ", failure);
        y += try engine.label(title, left + 12 * z, y + 8 * z, 0);
    }
    const details = block.kind == .details;
    const prefix: []const u8 = if (details) "" else block.prefix;
    var native = measurement.font(block, 0, z, false);
    native.flags = 2;
    const prefix_metrics = try measurement.text(callback, context, native, prefix);
    const pw = if (block.task != null or details or block.indent > 0) @max(sz * 1.5, prefix_metrics.width) else prefix_metrics.width;
    const pad_x: f32 = if (block.kind == .code or block.quote > 0) 12 * z else 0;
    const pad_y: f32 = if (block.kind == .code or (block.quote > 0 and block.quote_context == null)) 12 * z else 0;
    if (prefix.len > 0 and block.kind != .table_row) {
        const first_prefix_run = result.runs.items.len;
        const flowing = try engine.flowText(&.{.{ .text = prefix }}, left + pad_x, y + pad_y, width, start, .left, false, 0);
        result.right = @max(result.right, flowing.right);
        if (block.task == null and std.mem.eql(u8, prefix, "• ")) {
            for (result.runs.items[first_prefix_run..]) |*run| {
                if (!std.mem.eql(u8, run.text.slice(), "•")) continue;
                var font = run.font;
                font.size = std.math.add(i32, font.size, @max(1, @divTrunc(font.size, 2))) catch return error.InvalidGeometry;
                const enlarged = try measurement.text(callback, context, font, run.text.slice());
                // Enlarge the existing glyph inside its original line/gutter.
                // The source bytes, body wrapping and line height stay intact.
                run.x += (run.width - enlarged.width) / 2;
                run.y += (enlarged.height - run.font_height) / 2 + run.font_descent - enlarged.descent;
                run.width = enlarged.width;
                run.font_height = enlarged.height;
                run.font_descent = enlarged.descent;
                run.font = font;
            }
        }
    }
    if (block.kind == .table_row) {
        var count: usize = 0;
        const table_inset: f32 = if (block.quote_context != null) pad_x + pw else 0;
        const fitted_ptr = columns(context, index, @max(30, width - table_inset - (if (block.quote > 0) pad_x else 0)), &count);
        if (count < block.cells.len or (count != 0 and fitted_ptr == null)) return error.TableColumnsUnavailable;
        const fitted = if (fitted_ptr) |ptr| ptr[0..count] else &.{};
        var x = left + table_inset;
        var mh: f32 = 0;
        var position = start;
        for (block.cells, 0..) |cell, column| {
            const cw = fitted[column];
            const flowing = try engine.flowText(cell.spans, x + 8 * z, y + 8 * z,
                @max(12, cw - 16 * z), position, cell.alignment, false, 0);
            mh = @max(mh, flowing.height + 16 * z);
            try result.rectangle(x, y, 1, 0, 1);
            x += cw;
            for (cell.spans) |span| position += span.text.len;
            position += 1;
        }
        width = x - left;
        result.right = @max(result.right, x);
        for (result.rects.items) |*rect| if (rect.height == 0) {
            rect.height = mh;
        };
        if (block.table_header or block.table_stripe) try result.background(left + table_inset, y, width - table_inset, mh);
        try result.rectangle(x, y, 1, mh, 1);
        try result.rectangle(left + table_inset, y, width - table_inset, 1, 1);
        try result.rectangle(left + table_inset, y + mh - 1, width - table_inset, 1, 1);
        y += mh;
    } else if ((block.kind == .image or diagram) and options.image_ready) {
        result.image = true;
        result.ix = left + (if (block.quote_context != null) pad_x + pw else 0);
        result.iy = y;
        const natural_width = options.image_width * (if (options.logical_image) z else 1);
        const natural_height = options.image_height * (if (options.logical_image) z else 1);
        const native_diagram = diagram and options.diagram_scale > 0;
        const image_width = @max(30, width - (if (block.quote_context != null) 2 * pad_x + pw else 0));
        result.iw = if (native_diagram) natural_width * options.diagram_scale else @min(natural_width, image_width);
        result.ih = result.iw * natural_height / @max(1, natural_width);
        if (diagram) result.ix += @max(0, (image_width - result.iw) / 2);
        if (native_diagram) {
            result.iy += options.diagram_controls_height;
            y += options.diagram_controls_height;
        }
        result.right = @max(result.right, result.ix + result.iw);
        y += result.ih;
    } else {
        if (block.kind == .image and failure.len > 0)
            y += try engine.label(try result.message("SVG: ", failure), left, y, 0);
        const flowing = try engine.flowText(block.spans, left + pad_x + pw, y + pad_y,
            @max(20, width - 2 * pad_x - pw), start + block.prefix.len, .left, false, 0);
        result.right = @max(result.right, flowing.right + pad_x);
        if (!options.wrap) width = @max(width, result.right - left);
        if (block.kind == .code or (block.quote > 0 and block.quote_context == null)) try result.background(left, before, width, y - before + flowing.height + 2 * pad_y);
        if (block.quote > 0 and block.quote_context == null) try result.rectangle(left, before, 3 * z, y - before + flowing.height + 2 * pad_y, if (block.alert == null) 1 else alert_role);
        if (block.task) |checked| {
            const cx = left + pad_x + 2 * z;
            const cy = y + pad_y + sz * 0.35;
            const side = sz * 0.65;
            if (checked) {
                try result.rectangle(cx, cy, side, side, 3);
                for (0..7) |i| {
                    const n: f32 = @floatFromInt(i);
                    const dy = (if (i < 3) 0.48 + n * 0.1 else 0.68 - (n - 2) * 0.11) * side;
                    try result.rectangle(cx + (0.18 + n * 0.09) * side, cy + dy, @max(1, side * 0.15), @max(1, side * 0.15), 4);
                }
            } else {
                try result.rectangle(cx, cy, side, 1, 10);
                try result.rectangle(cx, cy + side - 1, side, 1, 10);
                try result.rectangle(cx, cy, 1, side, 10);
                try result.rectangle(cx + side - 1, cy, 1, side, 10);
            }
        }
        y += flowing.height + 2 * pad_y;
    }
    if (block.kind == .heading and block.heading <= 2) {
        try result.rectangle(left, y + 6 * z, width, 1, 1);
        y += 12 * z;
    }
    y += quote_bottom;
    try result.quoteBackgrounds(block, index, options, y, after, quote_top, quote_bottom, list_gutter);
    result.height = y + after;
    return result;
}
