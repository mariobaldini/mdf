const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Note = struct {
    id: []const u8,
    body: []const u8,
    number: usize = 0,
    references: std.ArrayList(usize) = .empty,
};

pub const Prepared = struct { markdown: []const u8, notes: []Note };

// Blank definitions without moving source offsets. MD4C handles the remaining
// Markdown and each footnote body, including indented continuation paragraphs.
pub fn prepare(a: Allocator, input: []const u8) !Prepared {
    if (std.mem.indexOf(u8, input, "[^") == null) return .{ .markdown = input, .notes = &.{} };
    const markdown = try a.dupe(u8, input);
    var notes: std.ArrayList(Note) = .empty;
    var at: usize = 0;
    var fence: u8 = 0;
    var fence_length: usize = 0;
    while (at < input.len) {
        const end = lineEnd(input, at);
        const line = std.mem.trimEnd(u8, input[at..end], "\r");
        const trimmed = std.mem.trimStart(u8, line, " ");
        const indentation = line.len - trimmed.len;
        if (indentation <= 3 and trimmed.len > 0 and (trimmed[0] == '`' or trimmed[0] == '~')) {
            var count: usize = 0;
            while (count < trimmed.len and trimmed[count] == trimmed[0]) : (count += 1) {}
            if (count >= 3) {
                if (fence == 0) {
                    fence = trimmed[0];
                    fence_length = count;
                } else if (fence == trimmed[0] and count >= fence_length and std.mem.trim(u8, trimmed[count..], " \t").len == 0) fence = 0;
                at = @min(input.len, end + 1);
                continue;
            }
        }
        if (fence != 0 or indentation > 3 or !std.mem.startsWith(u8, trimmed, "[^")) {
            at = @min(input.len, end + 1);
            continue;
        }
        const close = std.mem.indexOf(u8, trimmed, "]:") orelse {
            at = @min(input.len, end + 1);
            continue;
        };
        const id = trimmed[2..close];
        if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t[]") != null) {
            at = @min(input.len, end + 1);
            continue;
        }
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(a, std.mem.trimStart(u8, trimmed[close + 2 ..], " \t"));
        try body.append(a, '\n');
        var next = @min(input.len, end + 1);
        var definition_end = next;
        while (next < input.len) {
            const continuation_end = lineEnd(input, next);
            const continuation = input[next..continuation_end];
            if (std.mem.trim(u8, continuation, " \t\r").len == 0) {
                try body.append(a, '\n');
                next = @min(input.len, continuation_end + 1);
                continue;
            }
            const skip: usize = if (std.mem.startsWith(u8, continuation, "    ")) 4 else if (continuation[0] == '\t') 1 else break;
            try body.appendSlice(a, continuation[skip..]);
            try body.append(a, '\n');
            next = @min(input.len, continuation_end + 1);
            definition_end = next;
        }
        var duplicate = false;
        for (notes.items) |note| duplicate = duplicate or std.ascii.eqlIgnoreCase(note.id, id);
        if (!duplicate) try notes.append(a, .{ .id = id, .body = try body.toOwnedSlice(a) });
        for (markdown[at..definition_end]) |*byte| if (byte.* != '\n' and byte.* != '\r') {
            byte.* = ' ';
        };
        at = definition_end;
    }
    return .{ .markdown = markdown, .notes = try notes.toOwnedSlice(a) };
}

fn lineEnd(input: []const u8, at: usize) usize {
    return at + (std.mem.indexOfScalar(u8, input[at..], '\n') orelse input.len - at);
}

test "definitions preserve offsets and ignore fenced or indented code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = "Ref[^one].\n\n[^one]: First.\n\n    Second **paragraph**.\n\nAfter.\n\n```md\n[^code]: literal\n```\n\n    [^indented]: literal\n";
    const prepared = try prepare(arena.allocator(), input);
    try std.testing.expectEqual(input.len, prepared.markdown.len);
    try std.testing.expectEqual(@as(usize, 1), prepared.notes.len);
    try std.testing.expectEqualStrings("one", prepared.notes[0].id);
    try std.testing.expect(std.mem.indexOf(u8, prepared.notes[0].body, "Second **paragraph**.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.markdown, "[^code]: literal") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.markdown, "[^indented]: literal") != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.markdown, "After.") != null);
}
