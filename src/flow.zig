//! Font-independent text flow. The GUI supplies measurements; Zig owns wrapping,
//! alignment, tab stops and byte positions. All text remains borrowed.
const std = @import("std");

pub const Span = extern struct {
    text: ?[*]const u8,
    len: usize,
    flags: u32 = 0, // 1: a prepared monospace face

    pub fn bytes(self: Span) []const u8 {
        return if (self.text) |ptr| ptr[0..self.len] else "";
    }
};
pub const Spec = extern struct {
    left: f32,
    top: f32,
    width: f32,
    size: i32,
    start: usize = 0,
    alignment: u32 = 0, // 0: left, 1: center, 2: right
    flags: u32 = 5, // 1: wrap, 2: retain leading code whitespace, 4: collect runs
};
pub const Metrics = extern struct { width: f32, height: f32, descent: f32 };
pub const Measure = *const fn (?*anyopaque, usize, [*]const u8, usize) callconv(.c) Metrics;
pub const Run = extern struct {
    span: usize,
    offset: usize,
    len: usize,
    position: usize,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    font_height: f32,
    font_descent: f32,
};
pub const Result = struct {
    runs: []Run,
    height: f32,
    right: f32,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
    }
};

const Engine = struct {
    allocator: std.mem.Allocator,
    spec: Spec,
    runs: std.ArrayList(Run) = .empty,
    x: f32,
    y: f32,
    right: f32,
    position: usize,
    line_start: usize = 0,

    fn endLine(self: *Engine) void {
        const used = self.x - self.spec.left;
        const shift = @max(0, switch (self.spec.alignment) {
            1 => (self.spec.width - used) / 2,
            2 => self.spec.width - used,
            else => 0,
        });
        self.right = @max(self.right, self.x + shift);
        for (self.runs.items[self.line_start..]) |*run| run.x += shift;
        self.line_start = self.runs.items.len;
    }

    fn nextLine(self: *Engine) void {
        self.endLine();
        self.x = self.spec.left;
        self.y += self.lineHeight();
    }

    fn lineHeight(self: Engine) f32 {
        return @as(f32, @floatFromInt(self.spec.size)) * 1.5;
    }

    fn emit(self: *Engine, span: usize, offset: usize, len: usize, metrics: Metrics, width: f32, glyph_baseline: bool) !void {
        if (self.spec.flags & 4 != 0) {
            // Preserve operation order: whole-word baselines used a precomputed
            // ascent, while individual glyph/tab baselines add then subtract.
            const baseline = if (glyph_baseline)
                self.y + (self.lineHeight() - metrics.height) / 2 + metrics.height - metrics.descent
            else
                self.y + (self.lineHeight() - metrics.height) / 2 + (metrics.height - metrics.descent);
            try self.runs.append(self.allocator, .{
                .span = span,
                .offset = offset,
                .len = len,
                .position = self.position,
                .x = self.x,
                .y = baseline,
                .width = width,
                .height = self.lineHeight(),
                .font_height = metrics.height,
                .font_descent = metrics.descent,
            });
        }
        self.x += width;
        self.position += len;
    }
};

fn sequenceLength(text: []const u8, at: usize) usize {
    // Documents are UTF-8, but keep the boundary safe for callers with malformed
    // input. A truncated sequence still advances and never reads outside text.
    const size = std.unicode.utf8ByteSequenceLength(text[at]) catch 1;
    return @min(size, text.len - at);
}

fn measureText(callback: Measure, context: ?*anyopaque, span: usize, text: []const u8) !Metrics {
    const result = callback(context, span, text.ptr, text.len);
    if (!std.math.isFinite(result.width) or !std.math.isFinite(result.height) or
        !std.math.isFinite(result.descent) or result.width < 0 or result.height < 0)
        return error.InvalidMetrics;
    return result;
}

pub fn layout(allocator: std.mem.Allocator, spans: []const Span, spec: Spec, callback: Measure, context: ?*anyopaque) !Result {
    if (!std.math.isFinite(spec.left) or !std.math.isFinite(spec.top) or
        !std.math.isFinite(spec.width) or spec.width <= 0 or spec.size <= 0)
        return error.InvalidGeometry;
    var total = spec.start;
    for (spans) |span| {
        if (span.len != 0 and span.text == null) return error.InvalidText;
        total = std.math.add(usize, total, span.len) catch return error.InvalidText;
    }
    var engine = Engine{
        .allocator = allocator,
        .spec = spec,
        .x = spec.left,
        .y = spec.top,
        .right = spec.left,
        .position = spec.start,
    };
    errdefer engine.runs.deinit(allocator);
    const wrap = spec.flags & 1 != 0;
    for (spans, 0..) |span, index| {
        const text = span.bytes();
        var at: usize = 0;
        while (at < text.len) {
            if (text[at] == '\n') {
                engine.nextLine();
                at += 1;
                engine.position += 1;
                continue;
            }
            if (span.flags & 1 != 0 and text[at] == '\t') {
                const metrics = try measureText(callback, context, index, " ");
                const stop = @max(1, metrics.width * 4);
                var gap = stop - @rem(@max(0, engine.x - spec.left), stop);
                if (gap < 0.01) gap = stop;
                try engine.emit(index, at, 1, metrics, gap, true);
                at += 1;
                continue;
            }
            var end = at;
            const space = std.ascii.isWhitespace(text[at]);
            while (end < text.len and text[end] != '\n' and
                !(span.flags & 1 != 0 and text[end] == '\t') and
                std.ascii.isWhitespace(text[end]) == space)
                end += sequenceLength(text, end);
            const word = text[at..end];
            const metrics = try measureText(callback, context, index, word);
            if (wrap and engine.x > spec.left and engine.x + metrics.width > spec.left + spec.width and !space)
                engine.nextLine();
            if (!wrap or metrics.width <= spec.width or space) {
                if (space and engine.x == spec.left and spec.flags & 2 == 0) {
                    engine.position += word.len;
                } else try engine.emit(index, at, word.len, metrics, metrics.width, false);
            } else {
                var p = at;
                while (p < end) {
                    const len = sequenceLength(text, p);
                    const glyph = try measureText(callback, context, index, text[p..][0..len]);
                    if (engine.x > spec.left and engine.x + glyph.width > spec.left + spec.width)
                        engine.nextLine();
                    try engine.emit(index, p, len, glyph, glyph.width, true);
                    p += len;
                }
            }
            at = end;
        }
    }
    engine.endLine();
    return .{
        .runs = try engine.runs.toOwnedSlice(allocator),
        .height = engine.y - spec.top + engine.lineHeight(),
        .right = engine.right,
    };
}
