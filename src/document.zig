const std = @import("std");
const c = @import("native");
const Allocator = std.mem.Allocator;
const footnotes = @import("footnotes.zig");

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

pub const Block = struct {
    kind: enum { paragraph, heading, code, rule, table_row, details, image } = .paragraph,
    heading: u8 = 0,
    indent: usize = 0,
    quote: usize = 0,
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
    arena: std.heap.ArenaAllocator,
    path: [:0]const u8,
    source: []const u8,
    blocks: []Block,

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
        if (input.len > std.math.maxInt(c.MD_SIZE)) return error.FileTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const source = try a.dupe(u8, input);
        const prepare_span = profiling.begin(@src(), "Prepare footnotes", .document);
        const prepared = try footnotes.prepare(a, source);
        prepare_span.end();
        var ctx = Parser{ .a = a, .source = prepared.markdown, .notes = prepared.notes };
        const parser: c.MD_PARSER = .{
            .abi_version = 0,
            .flags = c.MD_DIALECT_GITHUB | c.MD_FLAG_NOHTMLBLOCKS,
            .enter_block = Parser.enterBlock,
            .leave_block = Parser.leaveBlock,
            .enter_span = Parser.enterSpan,
            .leave_span = Parser.leaveSpan,
            .text = Parser.text,
            .debug_log = null,
            .syntax = null,
        };
        const parse_span = profiling.begin(@src(), "MD4C parse and callbacks", .document);
        const result = c.md_parse(prepared.markdown.ptr, @intCast(prepared.markdown.len), &parser, &ctx);
        parse_span.end();
        if (ctx.failure) |err| return err;
        if (result != 0) return error.ParseFailed;
        const finish_span = profiling.begin(@src(), "Finish blocks, links, images and footnotes", .document);
        defer finish_span.end();
        try ctx.flush();
        try ctx.appendFootnotes(parser);
        try ctx.finish(path, load_images);
        const owned_path = try a.dupeSentinel(u8, path, 0);
        const blocks = try ctx.blocks.toOwnedSlice(a);
        return .{
            .arena = arena,
            .path = owned_path,
            .source = source,
            .blocks = blocks,
        };
    }
};

const Parser = struct {
    a: Allocator,
    source: []const u8,
    blocks: std.ArrayList(Block) = .empty,
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
    failure: ?anyerror = null,

    fn get(ptr: ?*anyopaque) *Parser {
        return @ptrCast(@alignCast(ptr.?));
    }

    fn failed(self: *Parser, err: anyerror) c_int {
        self.failure = err;
        return 1;
    }

    fn start(self: *Parser, kind: @FieldType(Block, "kind"), heading: u8) !void {
        try self.flush();
        self.current = .{
            .kind = kind,
            .heading = heading,
            .indent = self.lists.items.len,
            .quote = self.quote,
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

    fn enterBlock(kind: c.MD_BLOCKTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const self = get(userdata);
        self.blockEnter(kind, detail) catch |err| return self.failed(err);
        return 0;
    }

    fn blockEnter(self: *Parser, kind: c.MD_BLOCKTYPE, detail: ?*anyopaque) !void {
        switch (kind) {
            c.MD_BLOCK_H => {
                const h: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail.?));
                try self.start(.heading, @intCast(h.level));
            },
            c.MD_BLOCK_CODE => {
                try self.start(.code, 0);
                const code: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail.?));
                self.current.?.language = try self.attribute(code.lang);
            },
            c.MD_BLOCK_P => try self.start(.paragraph, 0),
            c.MD_BLOCK_HR => try self.start(.rule, 0),
            c.MD_BLOCK_QUOTE => {
                try self.flush();
                self.quote += 1;
                try self.alerts.append(self.a, null);
                try self.quote_start.append(self.a, true);
            },
            c.MD_BLOCK_UL, c.MD_BLOCK_OL => {
                try self.flush();
                const first_number: ?u32 = if (kind == c.MD_BLOCK_OL)
                    @as(*c.MD_BLOCK_OL_DETAIL, @ptrCast(@alignCast(detail.?))).start
                else
                    null;
                try self.lists.append(self.a, first_number);
            },
            c.MD_BLOCK_LI => {
                try self.flush();
                if (self.lists.items.len > 0) {
                    const index = self.lists.items.len - 1;
                    if (self.lists.items[index]) |n| {
                        self.pending_prefix = try std.fmt.allocPrint(self.a, "{d}. ", .{n});
                        self.lists.items[index] = n +| 1;
                    } else self.pending_prefix = "• ";
                }
                const li: *c.MD_BLOCK_LI_DETAIL = @ptrCast(@alignCast(detail.?));
                if (li.is_task != 0) {
                    self.pending_task = li.task_mark != ' ';
                    if (self.lists.items.len == 0 or self.lists.items[self.lists.items.len - 1] == null) self.pending_prefix = "";
                }
            },
            c.MD_BLOCK_TABLE => {
                try self.flush();
                const table: *c.MD_BLOCK_TABLE_DETAIL = @ptrCast(@alignCast(detail.?));
                self.columns = try self.a.alloc(TableColumn, table.col_count);
                @memset(self.columns, .{});
                self.table_row = 0;
            },
            c.MD_BLOCK_TR => {
                try self.start(.table_row, 0);
                self.current.?.columns = self.columns;
                self.current.?.table_header = self.table_row == 0;
                self.current.?.table_stripe = self.table_row % 2 == 0;
                self.table_row += 1;
            },
            c.MD_BLOCK_TH, c.MD_BLOCK_TD => {
                self.in_cell = true;
                const cell: *c.MD_BLOCK_TD_DETAIL = @ptrCast(@alignCast(detail.?));
                self.cell_alignment = switch (cell.@"align") {
                    c.MD_ALIGN_CENTER => .center,
                    c.MD_ALIGN_RIGHT => .right,
                    else => .left,
                };
            },
            else => {},
        }
    }

    fn leaveBlock(kind: c.MD_BLOCKTYPE, _: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const self = get(userdata);
        self.blockLeave(kind) catch |err| return self.failed(err);
        return 0;
    }

    fn blockLeave(self: *Parser, kind: c.MD_BLOCKTYPE) !void {
        if (kind == c.MD_BLOCK_TH or kind == c.MD_BLOCK_TD) {
            self.in_cell = false;
            const spans = try self.spans.toOwnedSlice(self.a);
            var characters: usize = 0;
            for (spans) |span| characters += try std.unicode.utf8CountCodepoints(span.text);
            self.columns[self.cells.items.len].characters = @max(self.columns[self.cells.items.len].characters, characters);
            try self.cells.append(self.a, .{ .spans = spans, .alignment = self.cell_alignment });
            return;
        }
        if (kind == c.MD_BLOCK_TR) self.current.?.cells = try self.cells.toOwnedSlice(self.a);
        try self.flush();
        switch (kind) {
            c.MD_BLOCK_QUOTE => {
                self.quote -= 1;
                _ = self.alerts.pop();
                _ = self.quote_start.pop();
            },
            c.MD_BLOCK_UL, c.MD_BLOCK_OL => _ = self.lists.pop(),
            c.MD_BLOCK_LI => {
                self.pending_prefix = "";
                self.pending_task = null;
            },
            c.MD_BLOCK_TABLE => {
                if (self.blocks.items.len > 0) self.blocks.items[self.blocks.items.len - 1].table_last = true;
                self.columns = &.{};
            },
            else => {},
        }
    }

    fn enterSpan(kind: c.MD_SPANTYPE, detail: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const self = get(userdata);
        switch (kind) {
            c.MD_SPAN_STRONG => self.bold += 1,
            c.MD_SPAN_EM => self.italic += 1,
            c.MD_SPAN_CODE => self.code += 1,
            c.MD_SPAN_DEL => self.strike += 1,
            c.MD_SPAN_IMG => {
                self.image += 1;
                if (self.image == 1 and self.current != null and self.current.?.kind == .image) {
                    self.current.?.kind = .paragraph;
                    self.current.?.image_src = null;
                }
                if (self.image == 1 and self.current != null and self.current.?.bytes == 0 and self.current.?.kind == .paragraph) {
                    const img: *c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail.?));
                    self.current.?.kind = .image;
                    self.current.?.image_src = self.attribute(img.src) catch |err| return self.failed(err);
                }
            },
            c.MD_SPAN_A => {
                const a: *c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail.?));
                const href = self.attribute(a.href) catch |err| return self.failed(err);
                self.links.append(self.a, href) catch |err| return self.failed(err);
            },
            else => {},
        }
        return 0;
    }

    fn leaveSpan(kind: c.MD_SPANTYPE, _: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) c_int {
        const self = get(userdata);
        switch (kind) {
            c.MD_SPAN_STRONG => self.bold -= 1,
            c.MD_SPAN_EM => self.italic -= 1,
            c.MD_SPAN_CODE => self.code -= 1,
            c.MD_SPAN_DEL => self.strike -= 1,
            c.MD_SPAN_IMG => self.image -= 1,
            c.MD_SPAN_A => _ = self.links.pop(),
            else => {},
        }
        return 0;
    }

    fn attribute(self: *Parser, attr: c.MD_ATTRIBUTE) ![]const u8 {
        if (attr.size == 0) return "";
        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (attr.substr_offsets[i] < attr.size) : (i += 1) {
            const part = attr.text[attr.substr_offsets[i]..attr.substr_offsets[i + 1]];
            const value = if (attr.substr_types[i] == c.MD_TEXT_ENTITY) try self.entity(part) else part;
            try result.appendSlice(self.a, value);
        }
        return result.toOwnedSlice(self.a);
    }

    fn text(kind: c.MD_TEXTTYPE, ptr: [*c]const u8, len: c.MD_SIZE, userdata: ?*anyopaque) callconv(.c) c_int {
        const self = get(userdata);
        self.addText(kind, ptr[0..len]) catch |err| return self.failed(err);
        return 0;
    }

    fn addText(self: *Parser, kind: c.MD_TEXTTYPE, raw: []const u8) anyerror!void {
        if (kind == c.MD_TEXT_HTML) return self.html(raw);
        if (self.comment or self.suppressed_html != null) return;
        if (self.current == null) try self.start(.paragraph, 0);
        if (kind == c.MD_TEXT_NORMAL and !self.adding_note and self.code == 0 and self.html_code == 0 and self.image == 0 and self.links.items.len == 0 and self.current.?.kind != .code) {
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
        if (kind == c.MD_TEXT_SOFTBR and self.current.?.bytes == 0) return;
        if (kind == c.MD_TEXT_NORMAL and self.current.?.kind == .paragraph and self.current.?.bytes == 0 and self.quote > 0 and self.quote_start.items[self.quote_start.items.len - 1] and self.image == 0 and self.code == 0 and self.bold == 0 and self.italic == 0 and self.links.items.len == 0) {
            inline for (std.meta.tags(Alert)) |alert| {
                const name = @tagName(alert);
                if (raw.len == name.len + 3 and std.mem.startsWith(u8, raw, "[!") and raw[raw.len - 1] == ']' and std.ascii.eqlIgnoreCase(raw[2 .. raw.len - 1], name)) {
                    self.alerts.items[self.alerts.items.len - 1] = alert;
                    self.current.?.alert = alert;
                    self.current.?.alert_start = true;
                    self.quote_start.items[self.quote_start.items.len - 1] = false;
                    return;
                }
            }
        }
        if (self.quote > 0 and kind != c.MD_TEXT_SOFTBR) self.quote_start.items[self.quote_start.items.len - 1] = false;
        const value = switch (kind) {
            c.MD_TEXT_SOFTBR => " ",
            c.MD_TEXT_BR => "\n",
            c.MD_TEXT_NULLCHAR => "�",
            c.MD_TEXT_ENTITY => try self.entity(raw),
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
        if (raw.len < 3 or raw[0] != '<') return self.addText(c.MD_TEXT_NORMAL, raw);
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
                self.current.?.details_open = htmlHasAttribute(raw, "open");
                try self.details.append(self.a, self.blocks.items.len);
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "summary")) {
            if (self.in_cell) return;
            if (closing) try self.flush();
            return;
        }
        if (std.ascii.eqlIgnoreCase(tag, "br")) return self.addText(c.MD_TEXT_BR, "\n");
        if (std.ascii.eqlIgnoreCase(tag, "hr")) {
            if (self.in_cell) return;
            try self.start(.rule, 0);
            try self.flush();
            return;
        }
        const counter: ?*usize = if (std.ascii.eqlIgnoreCase(tag, "strong") or std.ascii.eqlIgnoreCase(tag, "b")) &self.html_bold else if (std.ascii.eqlIgnoreCase(tag, "em") or std.ascii.eqlIgnoreCase(tag, "i")) &self.html_italic else if (std.ascii.eqlIgnoreCase(tag, "del") or std.ascii.eqlIgnoreCase(tag, "s") or std.ascii.eqlIgnoreCase(tag, "strike")) &self.html_strike else if (std.ascii.eqlIgnoreCase(tag, "code") or std.ascii.eqlIgnoreCase(tag, "kbd") or std.ascii.eqlIgnoreCase(tag, "samp")) &self.html_code else if (std.ascii.eqlIgnoreCase(tag, "ins") or std.ascii.eqlIgnoreCase(tag, "u")) &self.underline else if (std.ascii.eqlIgnoreCase(tag, "mark")) &self.highlight else if (std.ascii.eqlIgnoreCase(tag, "small")) &self.small else null;
        if (counter) |count| {
            if (closing) count.* -|= 1 else count.* += 1;
        }
        // Other HTML tags are inert. Their readable content remains in the document.
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

    fn appendFootnotes(self: *Parser, parser: c.MD_PARSER) !void {
        if (self.note_count == 0) return;
        self.details.clearRetainingCapacity();
        try self.start(.rule, 0);
        try self.start(.heading, 2);
        try self.addText(c.MD_TEXT_NORMAL, "Footnotes");
        try self.flush();
        for (1..self.note_count + 1) |number| {
            for (self.notes) |note| {
                if (note.number != number) continue;
                var body = Parser{ .a = self.a, .source = note.body };
                const result = c.md_parse(note.body.ptr, @intCast(note.body.len), &parser, &body);
                if (body.failure) |err| return err;
                if (result != 0) return error.ParseFailed;
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
            }
        }
    }

    fn entity(self: *Parser, raw: []const u8) ![]const u8 {
        if (raw.len < 3) return raw;
        var codepoints = [_]u32{ 0, 0 };
        if (raw[1] == '#') {
            const hex = raw.len > 3 and (raw[2] == 'x' or raw[2] == 'X');
            codepoints[0] = std.fmt.parseInt(u32, raw[if (hex) 3 else 2 .. raw.len - 1], if (hex) 16 else 10) catch 0xfffd;
            if (codepoints[0] >= 0x80 and codepoints[0] <= 0x9f) {
                const windows = [_]u32{ 0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178 };
                codepoints[0] = windows[codepoints[0] - 0x80];
            }
        } else if (c.entity_lookup(raw.ptr, raw.len)) |found| {
            codepoints = found.*.codepoints;
        } else return raw;
        var buffer: [8]u8 = undefined;
        var count: usize = 0;
        for (codepoints, 0..) |cp, i| {
            if (i == 1 and cp == 0) break;
            const valid = if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) 0xfffd else cp;
            count += try std.unicode.utf8Encode(@intCast(valid), buffer[count..][0..4]);
        }
        return self.a.dupe(u8, buffer[0..count]);
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
