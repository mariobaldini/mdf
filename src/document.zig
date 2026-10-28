const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;
const footnotes = @import("footnotes.zig");
const zigmark = @import("zigmark");
const entities = @import("html_entities");
const text_projection = @import("text.zig");

pub const Span = struct {
    text: []const u8,
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strike: bool = false,
    underline: bool = false,
    highlight: bool = false,
    small: bool = false,
    link: ?[]const u8 = null,
};

pub const Alignment = enum { left, center, right };
pub const TableColumn = struct { characters: usize = 1 };
pub const TableCell = struct {
    spans: []const Span,
    alignment: Alignment = .left,
};
pub const Alert = enum {
    note,
    tip,
    important,
    warning,
    caution,

    pub fn title(self: Alert) []const u8 {
        return switch (self) {
            .note => "Note",
            .tip => "Tip",
            .important => "Important",
            .warning => "Warning",
            .caution => "Caution",
        };
    }
};

// Shared by every flattened block in one quote. The parser completes the
// range before publishing the document; nested quotes borrow their parent.
pub const QuoteContext = struct {
    parent: ?*QuoteContext = null,
    first: usize,
    end: usize = 0,
    indent: usize,
    depth: usize,
    alert: ?Alert = null,
};

pub const Block = struct {
    kind: enum { paragraph, heading, code, rule, table_row, details, image } = .paragraph,
    heading: u8 = 0,
    indent: usize = 0,
    quote: usize = 0,
    quote_context: ?*const QuoteContext = null,
    prefix: []const u8 = "",
    spans: []const Span = &.{},
    bytes: usize = 0,
    lines: usize = 1,
    source_offset: usize = 0,
    task: ?bool = null,
    alert: ?Alert = null,
    alert_start: bool = false,
    language: []const u8 = "",
    anchor: []const u8 = "",
    cells: []const TableCell = &.{},
    columns: []const TableColumn = &.{},
    table_header: bool = false,
    table_last: bool = false,
    table_stripe: bool = false,
    details_parent: ?usize = null,
    details_open: bool = false,
    image_src: ?[]const u8 = null,
    image_data: ?[]const u8 = null,
};

pub const Document = struct {
    pub const Anchor = struct { name: []const u8, index: usize };
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    source: []const u8,
    blocks: []Block,
    explicit_anchors: []const Anchor = &.{},
    rendered: text_projection.Projection = .{},

    pub fn findAnchor(self: *const Document, name: []const u8) ?usize {
        if (self.blocks.len == 0) return null;
        if (name.len == 0) return 0;
        var explicit: ?usize = null;
        for (self.explicit_anchors) |anchor| if (std.mem.eql(u8, anchor.name, name)) {
            explicit = @min(anchor.index, self.blocks.len - 1);
            break;
        };
        for (self.blocks, 0..) |block, index| if (std.mem.eql(u8, block.anchor, name))
            return if (explicit) |target| @min(index, target) else index;
        return explicit;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn parse(allocator: Allocator, input: []const u8, path: []const u8) !Document {
        return parseInternal(allocator, input, path, true);
    }

    pub fn parseDeferred(allocator: Allocator, input: []const u8, path: []const u8) !Document {
        return parseInternal(allocator, input, path, false);
    }

    fn parseInternal(allocator: Allocator, input: []const u8, path: []const u8, load_images: bool) !Document {
        const profiling = @import("profiling.zig");
        const profile_span = profiling.begin(@src(), "Parse Markdown", .document);
        defer profile_span.end();
        if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;
        if (input.len > std.math.maxInt(u32)) return error.FileTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = try a.dupe(u8, input);
        const prepared = prepare: {
            const prepare_span = profiling.begin(@src(), "Prepare footnotes", .document);
            defer prepare_span.end();
            break :prepare try footnotes.prepare(a, source);
        };
        var ctx = Parser{ .a = a, .source = prepared.markdown, .notes = prepared.notes };
        {
            const parse_span = profiling.begin(@src(), "Zigmark parse and block conversion", .document);
            defer parse_span.end();
            try ctx.parseAst(prepared.markdown);
        }
        const finish_span = profiling.begin(@src(), "Finish blocks, links, images and footnotes", .document);
        defer finish_span.end();
        try ctx.flush();
        try ctx.appendFootnotes();
        try ctx.finish(path, load_images);
        const owned_path = try a.dupeSentinel(u8, path, 0);
        const blocks = try ctx.blocks.toOwnedSlice(a);
        const explicit_anchors = try ctx.explicit_anchors.toOwnedSlice(a);
        const projection_span = @import("profiling.zig").begin(@src(), "Prepare rendered document text and positions", .document);
        const rendered = text_projection.Projection.init(a, blocks) catch |err| {
            projection_span.end();
            return err;
        };
        projection_span.end();
        return .{
            .arena = arena,
            .path = owned_path,
            .source = source,
            .blocks = blocks,
            .explicit_anchors = explicit_anchors,
            .rendered = rendered,
        };
    }
};

const Parser = struct {
    a: Allocator,
    source: []const u8,
    blocks: std.ArrayList(Block) = .empty,
    explicit_anchors: std.ArrayList(Document.Anchor) = .empty,
    spans: std.ArrayList(Span) = .empty,
    lists: std.ArrayList(?u32) = .empty,
    links: std.ArrayList([]const u8) = .empty,
    cells: std.ArrayList(TableCell) = .empty,
    columns: []TableColumn = &.{},
    cell_alignment: Alignment = .left,
    in_cell: bool = false,
    table_row: usize = 0,
    details: std.ArrayList(usize) = .empty,
    alerts: std.ArrayList(?Alert) = .empty,
    quote_start: std.ArrayList(bool) = .empty,
    current: ?Block = null,
    pending_prefix: []const u8 = "",
    pending_task: ?bool = null,
    quote: usize = 0,
    quote_context: ?*QuoteContext = null,
    block_offset: usize = 0,
    bold: usize = 0,
    italic: usize = 0,
    code: usize = 0,
    image: usize = 0,
    strike: usize = 0,
    html_bold: usize = 0,
    html_italic: usize = 0,
    html_code: usize = 0,
    html_strike: usize = 0,
    underline: usize = 0,
    highlight: usize = 0,
    small: usize = 0,
    comment: bool = false,
    suppressed_html: ?[]const u8 = null,
    notes: []footnotes.Note = &.{},
    note_count: usize = 0,
    adding_note: bool = false,

    fn start(self: *Parser, kind: @FieldType(Block, "kind"), heading: u8) !void {
        try self.flush();
        self.current = .{
            .kind = kind,
            .heading = heading,
            .indent = self.lists.items.len,
            .quote = self.quote,
            .quote_context = self.quote_context,
            .prefix = self.pending_prefix,
            .task = self.pending_task,
            .alert = if (self.alerts.items.len > 0) self.alerts.items[self.alerts.items.len - 1] else null,
            .details_parent = if (self.details.items.len > 0) self.details.items[self.details.items.len - 1] else null,
        };
        self.pending_prefix = "";
        self.pending_task = null;
    }

    fn flush(self: *Parser) !void {
        if (self.current) |*block| {
            if (block.kind == .details and self.spans.items.len == 0) {
                try self.spans.append(self.a, .{ .text = "Details" });
                block.bytes = 7;
            }
            block.spans = try self.spans.toOwnedSlice(self.a);
            if (block.kind != .paragraph or block.bytes > 0 or block.task != null or block.prefix.len > 0)
                try self.blocks.append(self.a, block.*);
            self.current = null;
        }
    }

    const EnterBlock = union(enum) {
        heading: u8,
        code: []const u8,
        paragraph,
        rule,
        quote,
        list: ?u32,
        item: ?bool,
        table: usize,
        row,
        cell: Alignment,
    };
    const BlockTag = std.meta.Tag(EnterBlock);
    const EnterSpan = union(enum) { strong, emphasis, code, strike, image: []const u8, link: []const u8 };
    const SpanTag = std.meta.Tag(EnterSpan);
    const TextKind = enum { normal, html, soft_break, hard_break, null_char, entity, code };

    fn blockEnter(self: *Parser, event: EnterBlock) !void {
        switch (event) {
            .heading => |level| try self.start(.heading, level),
            .code => |language| {
                try self.start(.code, 0);
                self.current.?.language = language;
            },
            .paragraph => try self.start(.paragraph, 0),
            .rule => try self.start(.rule, 0),
            .quote => {
                try self.flush();
                self.quote += 1;
                const context = try self.a.create(QuoteContext);
                context.* = .{ .parent = self.quote_context, .first = self.blocks.items.len + self.block_offset,
                    .indent = self.lists.items.len, .depth = self.quote };
                self.quote_context = context;
                try self.alerts.append(self.a, null);
                try self.quote_start.append(self.a, true);
            },
            .list => |first| {
                try self.flush();
                try self.lists.append(self.a, first);
            },
            .item => |task| {
                try self.flush();
                if (self.lists.items.len > 0) {
                    const index = self.lists.items.len - 1;
                    if (self.lists.items[index]) |n| {
                        self.pending_prefix = try std.fmt.allocPrint(self.a, "{d}. ", .{n});
                        self.lists.items[index] = n +| 1;
                    } else self.pending_prefix = "• ";
                }
                if (task) |checked| {
                    self.pending_task = checked;
                    if (self.lists.items.len == 0 or self.lists.items[self.lists.items.len - 1] == null) self.pending_prefix = "";
                }
            },
            .table => |columns| {
                try self.flush();
                self.columns = try self.a.alloc(TableColumn, columns);
                @memset(self.columns, .{});
                self.table_row = 0;
            },
            .row => {
                try self.start(.table_row, 0);
                self.current.?.columns = self.columns;
                self.current.?.table_header = self.table_row == 0;
                self.current.?.table_stripe = self.table_row % 2 == 0;
                self.table_row += 1;
            },
            .cell => |alignment| {
                self.in_cell = true;
                self.cell_alignment = alignment;
            },
        }
    }
    fn blockLeave(self: *Parser, kind: BlockTag) !void {
        if (kind == .cell) {
            self.in_cell = false;
            const spans = try self.spans.toOwnedSlice(self.a);
            var characters: usize = 0;
            for (spans) |span| characters += try std.unicode.utf8CountCodepoints(span.text);
            self.columns[self.cells.items.len].characters = @max(self.columns[self.cells.items.len].characters, characters);
            try self.cells.append(self.a, .{ .spans = spans, .alignment = self.cell_alignment });
            return;
        }
        if (kind == .row) self.current.?.cells = try self.cells.toOwnedSlice(self.a);
        try self.flush();
        switch (kind) {
            .quote => {
                self.quote_context.?.end = self.blocks.items.len + self.block_offset;
                self.quote_context = self.quote_context.?.parent;
                self.quote -= 1;
                _ = self.alerts.pop();
                _ = self.quote_start.pop();
            },
            .list => _ = self.lists.pop(),
            .item => {
                self.pending_prefix = "";
                self.pending_task = null;
            },
            .table => {
                if (self.blocks.items.len > 0) self.blocks.items[self.blocks.items.len - 1].table_last = true;
                self.columns = &.{};
            },
            else => {},
        }
    }
    fn spanEnter(self: *Parser, event: EnterSpan) !void {
        switch (event) {
            .strong => self.bold += 1,
            .emphasis => self.italic += 1,
            .code => self.code += 1,
            .strike => self.strike += 1,
            .image => |src| {
                self.image += 1;
                if (self.image == 1 and self.current != null and self.current.?.kind == .image) {
                    self.current.?.kind = .paragraph;
                    self.current.?.image_src = null;
                }
                if (self.image == 1 and self.current != null and self.current.?.bytes == 0 and self.current.?.kind == .paragraph) {
                    self.current.?.kind = .image;
                    self.current.?.image_src = src;
                }
            },
            .link => |href| try self.links.append(self.a, href),
        }
    }
    fn spanLeave(self: *Parser, event: SpanTag) void {
        switch (event) {
            .strong => self.bold -= 1,
            .emphasis => self.italic -= 1,
            .code => self.code -= 1,
            .strike => self.strike -= 1,
            .image => self.image -= 1,
            .link => _ = self.links.pop(),
        }
    }
    fn attribute(self: *Parser, raw: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (at < raw.len) {
            if (raw[at] == '\\' and at + 1 < raw.len and std.ascii.isPunctuation(raw[at + 1])) {
                try result.append(self.a, raw[at + 1]);
                at += 2;
            } else if (entities.decode(raw, at)) |decoded| {
                try result.appendSlice(self.a, decoded.bytes[0..decoded.len]);
                at += decoded.consumed;
            } else {
                try result.append(self.a, raw[at]);
                at += 1;
            }
        }
        return result.toOwnedSlice(self.a);
    }
    fn parseAst(self: *Parser, input: []const u8) !void {
        // The AST and final block views share this document's arena. Do not
        // deinit borrowed AST text before the rendered document is released.
        const ast = parse: {
            const phase = @import("profiling.zig").begin(@src(), "Parse Zigmark AST", .document);
            defer phase.end();
            break :parse try (zigmark.Parser{ .max_input_bytes = 0 }).parseMarkdown(self.a, input);
        };
        const convert = @import("profiling.zig").begin(@src(), "Convert Markdown AST into viewer blocks", .document);
        defer convert.end();
        try self.walkBlocks(ast.children.items);
    }
    fn walkBlocks(self: *Parser, blocks: []const zigmark.AST.Block) anyerror!void {
        for (blocks) |block| switch (block) {
            .paragraph => |p| {
                try self.blockEnter(.paragraph);
                try self.walkInlines(p.children.items, p.inline_source);
                try self.blockLeave(.paragraph);
            },
            .heading => |h| {
                try self.blockEnter(.{ .heading = h.level });
                try self.walkInlines(h.children.items, h.inline_source);
                try self.blockLeave(.heading);
            },
            .code_block => |code| {
                try self.blockEnter(.{ .code = "" });
                try self.addText(.code, code.content);
                try self.blockLeave(.code);
            },
            .fenced_code_block => |code| {
                const info = std.mem.trim(u8, code.language orelse "", " \t\r\n");
                const end = std.mem.indexOfAny(u8, info, " \t\r\n") orelse info.len;
                try self.blockEnter(.{ .code = try self.attribute(info[0..end]) });
                try self.addText(.code, code.content);
                try self.blockLeave(.code);
            },
            .blockquote => |quote| {
                try self.blockEnter(.quote);
                try self.walkBlocks(quote.children.items);
                try self.blockLeave(.quote);
            },
            .list => |list| {
                try self.blockEnter(.{ .list = if (list.type == .ordered) @as(u32, @intCast(list.start orelse 1)) else null });
                for (list.items.items) |item| {
                    try self.blockEnter(.{ .item = item.task_list_checked });
                    try self.walkBlocks(item.children.items);
                    try self.blockLeave(.item);
                }
                try self.blockLeave(.list);
            },
            .thematic_break => {
                try self.blockEnter(.rule);
                try self.blockLeave(.rule);
            },
            .html_block => |markup| try self.addText(.html, markup.content),
            .footnote_definition => {}, // MDF's footnote preparation owns these.
            .table => |table| {
                try self.blockEnter(.{ .table = table.alignments.items.len });
                try self.walkRow(table.header, table.alignments.items);
                for (table.body.items) |row| try self.walkRow(row, table.alignments.items);
                try self.blockLeave(.table);
            },
        };
    }
    fn walkRow(self: *Parser, row: zigmark.AST.TableRow, alignments: []const zigmark.AST.TableAlignment) !void {
        try self.blockEnter(.row);
        for (row.cells.items, alignments) |cell, alignment| {
            try self.blockEnter(.{ .cell = switch (alignment) {
                .center => .center,
                .right => .right,
                else => .left,
            } });
            try self.walkInlines(cell.children.items, cell.inline_source);
            try self.blockLeave(.cell);
        }
        try self.blockLeave(.row);
    }
    fn escapedText(text: []const u8, source: ?[]const u8) bool {
        const original = source orelse return false;
        if (text.len != 1 or @intFromPtr(text.ptr) <= @intFromPtr(original.ptr) or
            @intFromPtr(text.ptr) >= @intFromPtr(original.ptr) + original.len) return false;
        var at = @intFromPtr(text.ptr) - @intFromPtr(original.ptr);
        var count: usize = 0;
        while (at > 0 and original[at - 1] == '\\') {
            at -= 1;
            count += 1;
        }
        return count % 2 == 1;
    }
    fn plainText(self: *Parser, raw: []const u8) !void {
        var at: usize = 0;
        var first: usize = 0;
        while (std.mem.indexOfScalarPos(u8, raw, at, '&')) |entity_at| {
            if (entities.decode(raw, entity_at)) |decoded| {
                if (entity_at > first) try self.addText(.normal, raw[first..entity_at]);
                try self.addText(.entity, raw[entity_at..][0..decoded.consumed]);
                at = entity_at + decoded.consumed;
                first = at;
            } else {
                at = entity_at + 1;
            }
        }
        if (first < raw.len) try self.addText(.normal, raw[first..]);
    }
    fn walkInlines(self: *Parser, inlines: []const zigmark.AST.Inline, source: ?[]const u8) anyerror!void {
        var index: usize = 0;
        while (index < inlines.len) {
            const item = inlines[index];
            index += 1;
            switch (item) {
                .text => |text| {
                    if (escapedText(text.content, source)) {
                        try self.addText(.normal, text.content);
                        continue;
                    }
                    var joined: std.ArrayList(u8) = .empty;
                    var value = text.content;
                    while (index < inlines.len and inlines[index] == .text and !escapedText(inlines[index].text.content, source)) : (index += 1) {
                        if (joined.items.len == 0) try joined.appendSlice(self.a, value);
                        try joined.appendSlice(self.a, inlines[index].text.content);
                    }
                    if (joined.items.len > 0) value = try joined.toOwnedSlice(self.a);
                    try self.plainText(value);
                },
                .emphasis => |e| {
                    try self.spanEnter(.emphasis);
                    try self.walkInlines(e.children.items, source);
                    self.spanLeave(.emphasis);
                },
                .strong => |e| {
                    try self.spanEnter(.strong);
                    try self.walkInlines(e.children.items, source);
                    self.spanLeave(.strong);
                },
                .strikethrough => |e| {
                    try self.spanEnter(.strike);
                    try self.walkInlines(e.children.items, source);
                    self.spanLeave(.strike);
                },
                .code_span => |code| {
                    try self.spanEnter(.code);
                    try self.addText(.code, code.content);
                    self.spanLeave(.code);
                },
                .link => |link| {
                    try self.spanEnter(.{ .link = try self.attribute(link.destination.url) });
                    try self.walkInlines(link.children.items, source);
                    self.spanLeave(.link);
                },
                .image => |image| {
                    try self.spanEnter(.{ .image = try self.attribute(image.destination.url) });
                    // Zigmark already flattened the inline label. Parsing it
                    // again would turn literal code/escaped punctuation into markup.
                    try self.addText(.normal, image.alt_text);
                    self.spanLeave(.image);
                },
                .autolink => |link| {
                    const href = if (link.is_email) try std.fmt.allocPrint(self.a, "mailto:{s}", .{link.url}) else if (link.is_gfm_www) try std.fmt.allocPrint(self.a, "http://{s}", .{link.url}) else link.url;
                    try self.spanEnter(.{ .link = href });
                    try self.addText(.normal, link.url);
                    self.spanLeave(.link);
                },
                .footnote_reference => |reference| try self.addText(.normal, try std.fmt.allocPrint(self.a, "[^{s}]", .{reference.label})),
                .hard_break => try self.addText(.hard_break, "\n"),
                .soft_break => try self.addText(.soft_break, "\n"),
                .html_in_line => |markup| try self.addText(.html, markup.content),
                .math => return error.UnexpectedMathNode,
            }
        }
    }

    fn addText(self: *Parser, kind: TextKind, raw: []const u8) anyerror!void {
        if (raw.len == 0) return;
        if (kind == .html) return self.html(raw);
        if (self.comment or self.suppressed_html != null) return;
        if (self.current == null) try self.start(.paragraph, 0);
        if (kind == .normal and !self.adding_note and self.code == 0 and self.html_code == 0 and self.image == 0 and self.links.items.len == 0 and self.current.?.kind != .code) {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, raw, search, "[^")) |ref| {
                const end = std.mem.indexOfScalarPos(u8, raw, ref + 2, ']') orelse break;
                for (self.notes) |*note| {
                    if (!std.ascii.eqlIgnoreCase(note.id, raw[ref + 2 .. end])) continue;
                    if (ref > 0) try self.addText(kind, raw[0..ref]);
                    if (note.number == 0) {
                        self.note_count += 1;
                        note.number = self.note_count;
                    }
                    try note.references.append(self.a, self.blocks.items.len);
                    const url = try std.fmt.allocPrint(self.a, "#mdf-footnote-{d}", .{note.number});
                    try self.links.append(self.a, url);
                    self.small += 1;
                    self.adding_note = true;
                    try self.addText(kind, try std.fmt.allocPrint(self.a, "[{d}]", .{note.number}));
                    self.adding_note = false;
                    self.small -= 1;
                    _ = self.links.pop();
                    if (end + 1 < raw.len) try self.addText(kind, raw[end + 1 ..]);
                    return;
                }
                search = end + 1;
            }
        }
        if (kind == .soft_break and self.current.?.bytes == 0) return;
        if (kind == .normal and self.current.?.kind == .paragraph and self.current.?.bytes == 0 and self.quote > 0 and self.quote_start.items[self.quote_start.items.len - 1] and self.image == 0 and self.code == 0 and self.bold == 0 and self.italic == 0 and self.links.items.len == 0) {
            inline for (std.meta.tags(Alert)) |alert| {
                const name = @tagName(alert);
                if (raw.len == name.len + 3 and std.mem.startsWith(u8, raw, "[!") and raw[raw.len - 1] == ']' and std.ascii.eqlIgnoreCase(raw[2 .. raw.len - 1], name)) {
                    self.alerts.items[self.alerts.items.len - 1] = alert;
                    self.current.?.alert = alert;
                    self.quote_context.?.alert = alert;
                    self.current.?.alert_start = true;
                    self.quote_start.items[self.quote_start.items.len - 1] = false;
                    return;
                }
            }
        }
        if (self.quote > 0 and kind != .soft_break) self.quote_start.items[self.quote_start.items.len - 1] = false;
        const value = switch (kind) {
            .soft_break => " ",
            .hard_break => "\n",
            .null_char => "�",
            .entity => try self.entity(raw),
            else => raw,
        };
        const block = &self.current.?;
        if (block.kind == .image and self.image == 0 and std.mem.trim(u8, value, " \t\r\n").len > 0) {
            block.kind = .paragraph;
            block.image_src = null;
        }
        if (self.spans.items.len == 0 and @intFromPtr(raw.ptr) >= @intFromPtr(self.source.ptr) and
            @intFromPtr(raw.ptr) < @intFromPtr(self.source.ptr) + self.source.len)
            block.source_offset = @intFromPtr(raw.ptr) - @intFromPtr(self.source.ptr);
        block.bytes += value.len;
        block.lines += std.mem.count(u8, value, "\n");
        try self.spans.append(self.a, .{
            .text = value,
            .bold = self.bold > 0 or self.html_bold > 0,
            .italic = self.italic > 0 or self.html_italic > 0,
            .code = self.code > 0 or self.html_code > 0 or block.kind == .code,
            .strike = self.strike > 0 or self.html_strike > 0,
            .underline = self.underline > 0,
            .highlight = self.highlight > 0,
            .small = self.small > 0,
            .link = if (self.links.items.len > 0 and self.image == 0) self.links.items[self.links.items.len - 1] else null,
        });
    }

    fn html(self: *Parser, raw: []const u8) anyerror!void {
        if (std.mem.startsWith(u8, raw, "<!--") or self.comment) {
            self.comment = std.mem.indexOf(u8, raw, "-->") == null;
            return;
        }
        if (raw.len < 3 or raw[0] != '<') return self.addText(.normal, raw);
        const closing = raw[1] == '/';
        const tag_start: usize = if (closing) 2 else 1;
        const end = tag_start + (std.mem.indexOfAny(u8, raw[tag_start..], " \t\r\n/>") orelse return);
        const tag = raw[tag_start..end];
        if (self.suppressed_html) |suppressed| {
            if (closing and std.ascii.eqlIgnoreCase(suppressed, tag)) self.suppressed_html = null;
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "script") or std.ascii.eqlIgnoreCase(tag, "style") or std.ascii.eqlIgnoreCase(tag, "iframe")) {
            if (!closing) self.suppressed_html = tag;
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "details")) {
            if (self.in_cell) return;
            try self.flush();
            if (closing) {
                _ = self.details.pop();
            } else {
                try self.start(.details, 0);
                try self.htmlAnchors(raw, tag);
                self.current.?.details_open = htmlHasAttribute(raw, "open");
                try self.details.append(self.a, self.blocks.items.len);
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "summary")) {
            if (self.in_cell) return;
            if (!closing) try self.htmlAnchors(raw, tag);
            if (closing) try self.flush();
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "br")) {
            if (!closing) try self.htmlAnchors(raw, tag);
            return self.addText(.hard_break, "\n");
        }
        if (std.ascii.eqlIgnoreCase(tag, "hr")) {
            if (self.in_cell) return;
            try self.start(.rule, 0);
            if (!closing) try self.htmlAnchors(raw, tag);
            try self.flush();
            return;
        }
        if (!closing) try self.htmlAnchors(raw, tag);
        const counter: ?*usize = if (std.ascii.eqlIgnoreCase(tag, "strong") or std.ascii.eqlIgnoreCase(tag, "b")) &self.html_bold else if (std.ascii.eqlIgnoreCase(tag, "em") or std.ascii.eqlIgnoreCase(tag, "i")) &self.html_italic else if (std.ascii.eqlIgnoreCase(tag, "del") or std.ascii.eqlIgnoreCase(tag, "s") or std.ascii.eqlIgnoreCase(tag, "strike")) &self.html_strike else if (std.ascii.eqlIgnoreCase(tag, "code") or std.ascii.eqlIgnoreCase(tag, "kbd") or std.ascii.eqlIgnoreCase(tag, "samp")) &self.html_code else if (std.ascii.eqlIgnoreCase(tag, "ins") or std.ascii.eqlIgnoreCase(tag, "u")) &self.underline else if (std.ascii.eqlIgnoreCase(tag, "mark")) &self.highlight else if (std.ascii.eqlIgnoreCase(tag, "small")) &self.small else null;
        if (counter) |count| {
            if (closing) count.* -|= 1 else count.* += 1;
        }
        // Other HTML tags are inert. Their readable content remains in the document.
    }

    fn htmlAnchors(self: *Parser, raw: []const u8, tag: []const u8) !void {
        if (tag.len == 0 or !std.ascii.isAlphabetic(tag[0])) return;
        if (htmlAttribute(raw, "id")) |name| try self.htmlAnchor(name);
        if (std.ascii.eqlIgnoreCase(tag, "a"))
            if (htmlAttribute(raw, "name")) |name| try self.htmlAnchor(name);
    }

    fn htmlAnchor(self: *Parser, raw: []const u8) !void {
        var decoded: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        while (at < raw.len) {
            if (entities.decode(raw, at)) |value| {
                try decoded.appendSlice(self.a, value.bytes[0..value.len]);
                at += value.consumed;
            } else {
                try decoded.append(self.a, raw[at]);
                at += 1;
            }
        }
        if (decoded.items.len == 0 or std.mem.indexOfAny(u8, decoded.items, " \t\r\n\x0b\x0c\x00") != null) return;
        // An empty HTML-only paragraph is discarded by flush(), so this
        // index naturally targets the next rendered block without a spacer.
        try self.explicit_anchors.append(self.a, .{ .name = try decoded.toOwnedSlice(self.a), .index = self.blocks.items.len + self.block_offset });
    }

    fn htmlAttribute(raw: []const u8, name: []const u8) ?[]const u8 {
        var at = std.mem.indexOfAny(u8, raw, " \t\r\n>") orelse return null;
        while (at < raw.len) {
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at == raw.len or raw[at] == '>' or raw[at] == '/') break;
            const attribute_start = at;
            while (at < raw.len and !std.ascii.isWhitespace(raw[at]) and raw[at] != '=' and raw[at] != '>' and raw[at] != '/') : (at += 1) {}
            const matches = std.ascii.eqlIgnoreCase(raw[attribute_start..at], name);
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at == raw.len or raw[at] != '=') {
                if (matches) return null;
                continue;
            }
            at += 1;
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at == raw.len) return null;
            const quoted = raw[at] == '\'' or raw[at] == '"';
            const quote_mark = raw[at];
            if (quoted) at += 1;
            const value_start = at;
            if (quoted) {
                while (at < raw.len and raw[at] != quote_mark) : (at += 1) {}
                if (at == raw.len) return null;
            } else {
                while (at < raw.len and !std.ascii.isWhitespace(raw[at]) and raw[at] != '>') : (at += 1) {}
            }
            const value = raw[value_start..at];
            if (quoted) at += 1;
            if (matches) {
                if (!quoted and std.mem.indexOfAny(u8, value, "\"'`<=") != null) return null;
                return value;
            }
        }
        return null;
    }

    fn htmlHasAttribute(raw: []const u8, name: []const u8) bool {
        var at = std.mem.indexOfAny(u8, raw, " \t\r\n>") orelse return false;
        while (at < raw.len) {
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at == raw.len or raw[at] == '>' or raw[at] == '/') break;
            const attribute_start = at;
            while (at < raw.len and !std.ascii.isWhitespace(raw[at]) and raw[at] != '=' and raw[at] != '>') : (at += 1) {}
            if (std.ascii.eqlIgnoreCase(raw[attribute_start..at], name)) return true;
            while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
            if (at < raw.len and raw[at] == '=') {
                at += 1;
                while (at < raw.len and std.ascii.isWhitespace(raw[at])) : (at += 1) {}
                if (at < raw.len and (raw[at] == '\'' or raw[at] == '"')) {
                    const quote_mark = raw[at];
                    at += 1;
                    while (at < raw.len and raw[at] != quote_mark) : (at += 1) {}
                    if (at < raw.len) at += 1;
                } else {
                    while (at < raw.len and !std.ascii.isWhitespace(raw[at]) and raw[at] != '>') : (at += 1) {}
                }
            }
        }
        return false;
    }

    fn finish(self: *Parser, path: []const u8, load_images: bool) !void {
        // Retain the last suffix for each base. Repeated sections must not
        // allocate and probe every earlier suffix again (quadratic work).
        var anchors: std.StringHashMapUnmanaged(usize) = .empty;
        for (self.blocks.items) |*block| {
            if (block.kind == .heading and block.anchor.len == 0) {
                var slug: std.ArrayList(u8) = .empty;
                for (block.spans) |span| for (span.text) |ch| {
                    if (std.ascii.isAlphanumeric(ch) or ch >= 128 or ch == '_' or ch == '-') {
                        try slug.append(self.a, std.ascii.toLower(ch));
                    } else if (ch == ' ') try slug.append(self.a, '-');
                };
                const base = try slug.toOwnedSlice(self.a);
                var anchor = base;
                var suffix = anchors.get(base) orelse 0;
                while (anchors.contains(anchor)) {
                    suffix += 1;
                    anchor = try std.fmt.allocPrint(self.a, "{s}-{d}", .{ base, suffix });
                }
                try anchors.put(self.a, base, suffix);
                if (!std.mem.eql(u8, anchor, base)) try anchors.put(self.a, anchor, 0);
                block.anchor = anchor;
            }
            if (load_images) {
                if (block.image_src) |src| block.image_data = try localImage(self.a, path, src);
            }
        }
    }

    fn appendFootnotes(self: *Parser) !void {
        if (self.note_count == 0) return;
        self.details.clearRetainingCapacity();
        try self.start(.rule, 0);
        try self.start(.heading, 2);
        try self.addText(.normal, "Footnotes");
        try self.flush();
        for (1..self.note_count + 1) |number| {
            for (self.notes) |note| {
                if (note.number != number) continue;
                var body = Parser{ .a = self.a, .source = note.body, .block_offset = self.blocks.items.len };
                try body.parseAst(note.body);
                try body.flush();
                if (body.blocks.items.len == 0) continue;
                body.blocks.items[0].anchor = try std.fmt.allocPrint(self.a, "mdf-footnote-{d}", .{number});
                body.blocks.items[0].prefix = try std.fmt.allocPrint(self.a, "{d}. ", .{number});
                const last = &body.blocks.items[body.blocks.items.len - 1];
                const spans = try self.a.alloc(Span, last.spans.len + note.references.items.len);
                @memcpy(spans[0..last.spans.len], last.spans);
                for (note.references.items, spans[last.spans.len..], 0..) |block_index, *span, reference| {
                    span.* = .{
                        .text = if (reference == 0) " Back" else try std.fmt.allocPrint(self.a, " Back {d}", .{reference + 1}),
                        .link = try std.fmt.allocPrint(self.a, "#mdf-block-{d}", .{block_index}),
                    };
                    last.bytes += span.text.len;
                }
                last.spans = spans;
                // Footnote bodies have their own details indices.
                const offset = self.blocks.items.len;
                for (body.blocks.items) |*block| {
                    if (block.details_parent) |parent| block.details_parent = parent + offset;
                }
                try self.blocks.appendSlice(self.a, body.blocks.items);
                try self.explicit_anchors.appendSlice(self.a, body.explicit_anchors.items);
            }
        }
    }

    fn entity(self: *Parser, raw: []const u8) ![]const u8 {
        const decoded = entities.decode(raw, 0) orelse return raw;
        return self.a.dupe(u8, decoded.bytes[0..decoded.len]);
    }
};

pub fn localImage(a: Allocator, path: []const u8, src: []const u8) !?[]const u8 {
    if (src.len == 0 or std.mem.indexOfScalar(u8, src, ':') != null or std.mem.startsWith(u8, src, "//")) return null;
    const decoded = @import("links.zig").decode(a, src) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    const resolved = try std.fs.path.resolve(a, &.{ std.fs.path.dirname(path) orelse ".", decoded });
    const filename = try a.dupeSentinel(u8, resolved, 0);
    const fd = c.open(filename.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or stat.st_size <= 0 or stat.st_size > 16 * 1024 * 1024) return null;
    const bytes = try a.alloc(u8, @intCast(stat.st_size));
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.read(fd, bytes.ptr + at, bytes.len - at);
        if (n < 0 and c.__errno_location().* == c.EINTR) continue;
        if (n <= 0) return null;
        at += @intCast(n);
    }
    return bytes;
}

test "core markdown keeps structure, styles, and decoded links" {
    var doc = try Document.parse(std.testing.allocator, "# Title\n\nA **bold** and *soft* [link](next.md?a=1&amp;b=2).\n\n> Quote\n\n3. first\n   - nested\n4. second\n\n```zig\nconst x = 1;\n```\n\n---\n", "readme.md");
    defer doc.deinit();
    try std.testing.expectEqual(.heading, doc.blocks[0].kind);
    try std.testing.expectEqual(@as(u8, 1), doc.blocks[0].heading);
    var bold = false;
    var italic = false;
    var link = false;
    var nested = false;
    var code = false;
    for (doc.blocks) |block| {
        nested = nested or block.indent == 2;
        code = code or block.kind == .code;
        for (block.spans) |span| {
            bold = bold or span.bold;
            italic = italic or span.italic;
            if (span.link) |url| link = std.mem.eql(u8, url, "next.md?a=1&b=2");
        }
    }
    try std.testing.expect(bold and italic and link and nested and code);
    try std.testing.expectEqual(.rule, doc.blocks[doc.blocks.len - 1].kind);
}

test "entities, raw HTML, images, and UTF-8" {
    var doc = try Document.parse(std.testing.allocator, "Olá &amp; &#x1f680; &copy; ![alternative](https://example.com/a.png) <b>literal</b>", "");
    defer doc.deinit();
    var text_out: std.ArrayList(u8) = .empty;
    defer text_out.deinit(std.testing.allocator);
    for (doc.blocks[0].spans) |span| {
        try text_out.appendSlice(std.testing.allocator, span.text);
        try std.testing.expect(span.link == null);
    }
    try std.testing.expectEqualStrings("Olá & 🚀 © alternative literal", text_out.items);
    try std.testing.expectError(error.InvalidUtf8, Document.parse(std.testing.allocator, "\xff", ""));
}

test "empty and long documents" {
    var empty = try Document.parse(std.testing.allocator, "", "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.blocks.len);
    const long = try std.testing.allocator.alloc(u8, 100_000);
    defer std.testing.allocator.free(long);
    @memset(long, 'a');
    var doc = try Document.parse(std.testing.allocator, long, "");
    defer doc.deinit();
    try std.testing.expectEqual(long.len, doc.blocks[0].bytes);
}

test "parser releases its arena after allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn parse(a: Allocator) !void {
            var doc = try Document.parse(a, "# Heading\n\n- **Bold** and [link](other.md?a=1&amp;b=2)\n\n&copy; &#128;", "test.md");
            defer doc.deinit();
        }
    }.parse, .{});
}

test "GitHub tables retain alignment, rich cells, empty cells, and shared columns" {
    var doc = try Document.parse(std.testing.allocator, "| Left | Center | Right |\n| :--- | :---: | ---: |\n" ++
        "| **bold** | [link](next.md) | 12 |\n| red \\| blue | `x \\| y` | |\n\nAfter.\n", "sample.md");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 4), doc.blocks.len);
    const head = doc.blocks[0];
    const first = doc.blocks[1];
    const last = doc.blocks[2];
    try std.testing.expectEqual(.table_row, head.kind);
    try std.testing.expect(head.table_header and !first.table_header and last.table_last);
    try std.testing.expectEqual(@as(usize, 3), first.cells.len);
    try std.testing.expect(first.cells[0].spans[0].bold);
    try std.testing.expectEqualStrings("next.md", first.cells[1].spans[0].link.?);
    try std.testing.expectEqual(.left, first.cells[0].alignment);
    try std.testing.expectEqual(.center, first.cells[1].alignment);
    try std.testing.expectEqual(.right, first.cells[2].alignment);
    try std.testing.expectEqual(@as(usize, 0), last.cells[2].spans.len);
    try std.testing.expect(head.columns.ptr == last.columns.ptr);
    try std.testing.expectEqual(.paragraph, doc.blocks[3].kind);
}

test "GitHub task lists and strikethrough compose with nested inline styles" {
    var doc = try Document.parse(std.testing.allocator, "- [x] **Done** and ~~*removed*~~\n  - [ ] Child\n- [X] Uppercase\n- Ordinary\n\n`~~literal~~`\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(true, doc.blocks[0].task.?);
    try std.testing.expectEqual(false, doc.blocks[1].task.?);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[1].indent);
    try std.testing.expectEqual(true, doc.blocks[2].task.?);
    try std.testing.expect(doc.blocks[3].task == null);
    var strike = false;
    for (doc.blocks[0].spans) |span| if (span.strike and span.italic) {
        strike = true;
    };
    try std.testing.expect(strike);
    try std.testing.expect(doc.blocks[4].spans[0].code and !doc.blocks[4].spans[0].strike);
}

test "GitHub alerts hide markers and retain styling across paragraphs" {
    var doc = try Document.parse(std.testing.allocator, "> [!NOTE]\n> Read **this**.\n>\n> Another paragraph.\n\n" ++
        "> [!TIP]\n> A tip.\n\n> [!IMPORTANT]\n> Important.\n\n" ++
        "> [!WARNING]\n> Warning.\n\n> [!CAUTION]\n> Caution.\n\n" ++
        "> Ordinary quote.\n\n`[!NOTE]`\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(Alert.note, doc.blocks[0].alert.?);
    try std.testing.expect(doc.blocks[0].alert_start);
    try std.testing.expectEqual(Alert.note, doc.blocks[1].alert.?);
    try std.testing.expect(!doc.blocks[1].alert_start);
    try std.testing.expectEqual(Alert.tip, doc.blocks[2].alert.?);
    try std.testing.expectEqual(Alert.important, doc.blocks[3].alert.?);
    try std.testing.expectEqual(Alert.warning, doc.blocks[4].alert.?);
    try std.testing.expectEqual(Alert.caution, doc.blocks[5].alert.?);
    try std.testing.expect(doc.blocks[6].alert == null and doc.blocks[7].alert == null);
}

test "GitHub bare URLs, mail, code languages, and duplicate heading anchors" {
    var doc = try Document.parse(std.testing.allocator, "https://example.com www.example.com reader@example.com\n\n" ++
        "```zig title\nconst a = 1;\n```\n\n# Repeat\n# Repeat\n# Repeat-1\n# Café **time**\n", "");
    defer doc.deinit();
    var count: usize = 0;
    for (doc.blocks[0].spans) |span| if (span.link != null) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("zig", doc.blocks[1].language);
    try std.testing.expectEqualStrings("repeat", doc.blocks[2].anchor);
    try std.testing.expectEqualStrings("repeat-1", doc.blocks[3].anchor);
    try std.testing.expectEqualStrings("repeat-1-1", doc.blocks[4].anchor);
    try std.testing.expectEqualStrings("café-time", doc.blocks[5].anchor);
}

test "HTML styles, comments, and nested details have native structure" {
    var doc = try Document.parse(std.testing.allocator, "<details>\n<summary>More <strong>information</strong></summary>\n\n" ++
        "A <kbd>key</kbd> and <mark>highlight</mark>.<!-- hidden -->\n\n" ++
        "<details open>\n<summary>Nested</summary>\n\nChild.\n\n</details>\n\n</details>\n\nAfter.\n", "");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 5), doc.blocks.len);
    try std.testing.expectEqual(.details, doc.blocks[0].kind);
    try std.testing.expect(!doc.blocks[0].details_open and doc.blocks[0].details_parent == null);
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[1].details_parent.?);
    try std.testing.expectEqual(.details, doc.blocks[2].kind);
    try std.testing.expect(doc.blocks[2].details_open);
    try std.testing.expectEqual(@as(usize, 0), doc.blocks[2].details_parent.?);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[3].details_parent.?);
    try std.testing.expect(doc.blocks[4].details_parent == null);
    var key = false;
    var highlight = false;
    for (doc.blocks[1].spans) |span| {
        key = key or span.code;
        highlight = highlight or span.highlight;
        try std.testing.expect(std.mem.indexOf(u8, span.text, "hidden") == null);
    }
    try std.testing.expect(key and highlight);
}

test "footnotes are numbered by first use, keep Markdown, and link back" {
    var doc = try Document.parse(std.testing.allocator, "First[^b], second[^a], again[^b], unknown[^missing].\n\n" ++
        "`[^a]` and \\[^a] remain literal.\n\n" ++
        "[^a]: **Bold note.**\n\n    A second paragraph.\n\n" ++
        "[^b]: A [link](README.md) and `code`.\n\n[^unused]: Not displayed.\n", "");
    defer doc.deinit();
    var reference_count: usize = 0;
    for (doc.blocks[0].spans) |span| {
        if (span.link) |url| {
            try std.testing.expect(std.mem.startsWith(u8, url, "#mdf-footnote-"));
            reference_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), reference_count);
    for (doc.blocks[1].spans) |span| try std.testing.expect(span.link == null);
    try std.testing.expectEqual(.rule, doc.blocks[2].kind);
    try std.testing.expectEqualStrings("Footnotes", doc.blocks[3].spans[0].text);
    try std.testing.expectEqualStrings("mdf-footnote-1", doc.blocks[4].anchor);
    try std.testing.expectEqualStrings("1. ", doc.blocks[4].prefix);
    const first_note = doc.blocks[4].spans;
    try std.testing.expectEqualStrings(" Back", first_note[first_note.len - 2].text);
    try std.testing.expectEqualStrings(" Back 2", first_note[first_note.len - 1].text);
    try std.testing.expectEqualStrings("#mdf-block-0", first_note[first_note.len - 2].link.?);
    try std.testing.expectEqualStrings("#mdf-block-0", first_note[first_note.len - 1].link.?);
    try std.testing.expectEqualStrings("mdf-footnote-2", doc.blocks[5].anchor);
    try std.testing.expect(doc.blocks[5].spans[0].bold);
    const last = doc.blocks[6];
    try std.testing.expectEqualStrings("#mdf-block-0", last.spans[last.spans.len - 1].link.?);
    try std.testing.expectEqual(@as(usize, 7), doc.blocks.len);
}

test "local images resolve percent encoded paths and unavailable images retain alt text" {
    var template = "/tmp/mdf-image-XXXXXX".*;
    const directory = c.mkdtemp(&template) orelse return error.TestDirectoryFailed;
    defer _ = c.rmdir(directory);
    var buffer: [256]u8 = undefined;
    const image = try std.fmt.bufPrintSentinel(&buffer, "{s}/sample image.gif", .{directory}, 0);
    defer _ = c.unlink(image.ptr);
    const fd = c.open(image.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.TestWriteFailed;
    const bytes = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\xff\xff\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;";
    const written = c.write(fd, bytes.ptr, bytes.len);
    _ = c.close(fd);
    try std.testing.expectEqual(@as(isize, bytes.len), written);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/readme.md", .{directory});
    defer std.testing.allocator.free(path);
    var doc = try Document.parse(std.testing.allocator, "![Image](sample%20image.gif)\n\n![Missing](no-file.png)\n\n![Remote](https://example.com/a.png)", path);
    defer doc.deinit();
    try std.testing.expectEqual(.image, doc.blocks[0].kind);
    try std.testing.expectEqualStrings(bytes, doc.blocks[0].image_data.?);
    try std.testing.expect(doc.blocks[1].image_data == null and doc.blocks[2].image_data == null);
    try std.testing.expectEqualStrings("Missing", doc.blocks[1].spans[0].text);
    var deferred = try Document.parseDeferred(std.testing.allocator, "![Image](sample%20image.gif)", path);
    defer deferred.deinit();
    try std.testing.expect(deferred.blocks[0].image_data == null);
    const image_bytes = try localImage(deferred.arena.allocator(), deferred.path, deferred.blocks[0].image_src.?);
    try std.testing.expectEqualStrings(bytes, image_bytes.?);
}

test "GitHub document allocations unwind on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn parse(a: Allocator) !void {
            var doc = try Document.parse(a, "# Repeat\n# Repeat\n\n- [x] ~~done~~\n\n" ++
                "| A | B |\n| --- | ---: |\n| **cell** | value |\n\n" ++
                "> [!TIP]\n> Tip.\n\n<details>\n<summary>More</summary>\n\nText[^note].\n\n</details>\n\n" ++
                "[^note]: A **note**.\n", "test.md");
            defer doc.deinit();
        }
    }.parse, .{});
}

test "empty code attributes and malformed mixed HTML do not break parsing" {
    var doc = try Document.parse(std.testing.allocator, "```\nplain code\n```\n\n    indented code\n\n" ++
        "**bold</strong>** and *italic</em>* and ~~strike</del>~~.\n\n" ++
        "| Cell |\n| --- |\n| <details><summary>Inline</summary>content</details> |\n\n" ++
        "<details title=\"open\">\n<summary>Closed</summary>\n\nBody.\n\n</details>\n\n" ++
        "![alt](missing.png) text after the image.\n", "");
    defer doc.deinit();
    try std.testing.expectEqualStrings("", doc.blocks[0].language);
    try std.testing.expectEqualStrings("", doc.blocks[1].language);
    var closed = false;
    for (doc.blocks) |block| {
        if (block.kind == .details) {
            try std.testing.expect(!block.details_open);
            closed = true;
        }
    }
    try std.testing.expect(closed);
    try std.testing.expectEqual(.paragraph, doc.blocks[doc.blocks.len - 1].kind);
}

test "alert markers only introduce the first unstyled quote paragraph" {
    var doc = try Document.parse(std.testing.allocator, "> Ordinary.\n>\n> [!NOTE]\n> Still ordinary.\n\n> **[!WARNING]**\n> Emphasized marker.\n", "");
    defer doc.deinit();
    for (doc.blocks) |block| try std.testing.expect(block.alert == null);
}

test "many repeated headings retain unique suffixes and explicit collisions" {
    const heading = "# Repeat\n\n";
    const repeated = try std.testing.allocator.alloc(u8, heading.len * 10_000);
    defer std.testing.allocator.free(repeated);
    for (0..10_000) |i| @memcpy(repeated[i * heading.len ..][0..heading.len], heading);
    var doc = try Document.parseDeferred(std.testing.allocator, repeated, "large.md");
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 10_000), doc.blocks.len);
    try std.testing.expectEqualStrings("repeat-9999", doc.blocks[9_999].anchor);
    var collisions = try Document.parseDeferred(std.testing.allocator, "# A-1\n# A\n# A\n# A-2\n# A\n", "");
    defer collisions.deinit();
    try std.testing.expectEqualStrings("a-2", collisions.blocks[2].anchor);
    try std.testing.expectEqualStrings("a-2-1", collisions.blocks[3].anchor);
    try std.testing.expectEqualStrings("a-3", collisions.blocks[4].anchor);
}
