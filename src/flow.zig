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
// One byte per source byte plus the final position. Nonzero marks a cursor /
// grapheme boundary in the concatenation of all spans. The renderer retains
// this storage until layout returns; the core has no shaping dependency.
pub const Boundaries = *const fn (?*anyopaque, [*]const Span, usize) callconv(.c) ?[*]const u8;
pub const Spec = extern struct {
    left: f32,
    top: f32,
    width: f32,
    size: i32,
    start: usize = 0,
    alignment: u32 = 0, // 0: left, 1: center, 2: right
    flags: u32 = 5, // 1: wrap, 2: retain leading code whitespace, 4: collect runs
    boundaries: ?Boundaries = null,
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

const Cursor = struct {
    span: usize = 0,
    offset: usize = 0,
    position: usize = 0,

    fn normalize(self: *Cursor, spans: []const Span) void {
        while (self.span < spans.len and self.offset == spans[self.span].len) {
            self.span += 1;
            self.offset = 0;
        }
    }
    fn advance(self: *Cursor, spans: []const Span, len: usize) void {
        self.offset += len;
        self.position += len;
        self.normalize(spans);
    }
    fn pieceEnd(self: Cursor, spans: []const Span, end: Cursor) usize {
        return if (self.span == end.span) end.offset else spans[self.span].len;
    }
};
const RangeMetrics = struct { first: Metrics, width: f32 };
fn measureRange(spans: []const Span, begin: Cursor, end: Cursor, callback: Measure, context: ?*anyopaque) !RangeMetrics {
    var at = begin;
    var result: RangeMetrics = undefined;
    result.width = 0;
    while (at.position < end.position) {
        const len = at.pieceEnd(spans, end) - at.offset;
        const metrics = try measureText(callback, context, at.span, spans[at.span].bytes()[at.offset..][0..len]);
        if (at.position == begin.position) result.first = metrics;
        result.width += metrics.width;
        at.advance(spans, len);
    }
    if (!std.math.isFinite(result.width)) return error.InvalidMetrics;
    return result;
}
fn emitRange(engine: *Engine, spans: []const Span, begin: Cursor, end: Cursor, first: Metrics, glyph: bool, callback: Measure, context: ?*anyopaque) !void {
    var at = begin;
    while (at.position < end.position) {
        const len = at.pieceEnd(spans, end) - at.offset;
        const metrics = if (at.position == begin.position) first else
            try measureText(callback, context, at.span, spans[at.span].bytes()[at.offset..][0..len]);
        try engine.emit(at.span, at.offset, len, metrics, metrics.width, glyph);
        at.advance(spans, len);
    }
}

fn needsBoundaries(spans: []const Span, begin: Cursor, end: Cursor) bool {
    var at = begin;
    while (at.position < end.position) {
        const len = at.pieceEnd(spans, end) - at.offset;
        for (spans[at.span].bytes()[at.offset..][0..len]) |byte|
            if (byte >= 128) return true;
        at.advance(spans, len);
    }
    return false;
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
    var at = Cursor{ .position = spec.start };
    at.normalize(spans);
    var boundaries: ?[*]const u8 = null;
    while (at.span < spans.len) {
        const span = spans[at.span];
        const text = span.bytes();
        if (text[at.offset] == '\n') {
            engine.nextLine();
            engine.position += 1;
            at.advance(spans, 1);
            continue;
        }
        if (span.flags & 1 != 0 and text[at.offset] == '\t') {
            const metrics = try measureText(callback, context, at.span, " ");
            const stop = @max(1, metrics.width * 4);
            var gap = stop - @rem(@max(0, engine.x - spec.left), stop);
            if (gap < 0.01) gap = stop;
            try engine.emit(at.span, at.offset, 1, metrics, gap, true);
            at.advance(spans, 1);
            continue;
        }
        // Style boundaries are not word boundaries. Scan and measure the
        // complete token before deciding whether it belongs on this line.
        const space = std.ascii.isWhitespace(text[at.offset]);
        var end = at;
        while (end.span < spans.len) {
            const part = spans[end.span];
            const bytes = part.bytes();
            var offset = end.offset;
            while (offset < bytes.len and bytes[offset] != '\n' and
                !(part.flags & 1 != 0 and bytes[offset] == '\t') and
                std.ascii.isWhitespace(bytes[offset]) == space) : (offset += 1) {}
            if (offset == end.offset) break;
            const finished = offset < bytes.len;
            end.advance(spans, offset - end.offset);
            if (finished) break;
        }
        const len = end.position - at.position;
        const single_span = len <= span.len - at.offset;
        // Most words stay in one span. Keep that path to one measurement and
        // one emission; cross-span lookahead must not penalize ordinary prose.
        const metrics: RangeMetrics = if (single_span) single: {
            const first = try measureText(callback, context, at.span, text[at.offset..][0..len]);
            break :single .{ .first = first, .width = first.width };
        } else try measureRange(spans, at, end, callback, context);
        if (wrap and !space and engine.x > spec.left and engine.x + metrics.width > spec.left + spec.width)
            engine.nextLine();
        if (!wrap or metrics.width <= spec.width or space) {
            if (space and engine.x == spec.left and spec.flags & 2 == 0)
                engine.position += len
            else if (single_span)
                try engine.emit(at.span, at.offset, len, metrics.first, metrics.width, false)
            else
                try emitRange(&engine, spans, at, end, metrics.first, false, callback, context);
            at = end;
        } else {
            if (boundaries == null and spec.boundaries != null and needsBoundaries(spans, at, end)) {
                if (spec.boundaries) |get|
                    boundaries = get(context, spans.ptr, spans.len) orelse return error.InvalidBoundaries;
            }
            while (at.position < end.position) {
                var next = at;
                if (boundaries) |mask| {
                    next.advance(spans, 1);
                    while (next.position < end.position and mask[next.position - spec.start] == 0)
                        next.advance(spans, 1);
                } else next.advance(spans, sequenceLength(spans[at.span].bytes(), at.offset));
                const glyph_len = next.position - at.position;
                const single_glyph = glyph_len <= spans[at.span].len - at.offset;
                const glyph: RangeMetrics = if (single_glyph) single: {
                    const first = try measureText(callback, context, at.span, spans[at.span].bytes()[at.offset..][0..glyph_len]);
                    break :single .{ .first = first, .width = first.width };
                } else try measureRange(spans, at, next, callback, context);
                if (engine.x > spec.left and engine.x + glyph.width > spec.left + spec.width)
                    engine.nextLine();
                if (single_glyph)
                    try engine.emit(at.span, at.offset, glyph_len, glyph.first, glyph.width, true)
                else
                    try emitRange(&engine, spans, at, next, glyph.first, true, callback, context);
                at = next;
            }
        }
    }
    engine.endLine();
    return .{
        .runs = try engine.runs.toOwnedSlice(allocator),
        .height = engine.y - spec.top + engine.lineHeight(),
        .right = engine.right,
    };
}
