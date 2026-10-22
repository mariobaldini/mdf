//! Read the validated cmap selected by z2d. Coverage checks need no system font
//! library and do not disturb the font reader used by painting.
const std = @import("std");
const z2d = @import("z2d");
fn u16at(bytes: []const u8, at: usize) ?u16 {
    if (at > bytes.len or bytes.len - at < 2) return null;
    return std.mem.readInt(u16, bytes[at..][0..2], .big);
}
fn u32at(bytes: []const u8, at: usize) ?u32 {
    if (at > bytes.len or bytes.len - at < 4) return null;
    return std.mem.readInt(u32, bytes[at..][0..4], .big);
}
pub fn has(font: *const z2d.font.Font, ch: u21) bool {
    const bytes = font.file.buffer;
    switch (font.meta.cmap_subtable_offset) {
        .bmp => |offset| {
            if (ch > 0xffff) return false;
            const base: usize = offset;
            const count: usize = (u16at(bytes, base + 6) orelse return false) / 2;
            const ends = base + 14;
            var left: usize = 0;
            var right = count;
            while (left < right) {
                const middle = left + (right - left) / 2;
                if ((u16at(bytes, ends + middle * 2) orelse return false) < ch) left = middle + 1 else right = middle;
            }
            if (left >= count) return false;
            const starts = ends + count * 2 + 2;
            const start = u16at(bytes, starts + left * 2) orelse return false;
            if (start > ch) return false;
            const deltas = starts + count * 2;
            const delta = u16at(bytes, deltas + left * 2) orelse return false;
            const location = deltas + count * 2 + left * 2;
            const range = u16at(bytes, location) orelse return false;
            if (range == 0) return @as(u16, @truncate(@as(u32, ch) + delta)) != 0;
            const glyph = u16at(bytes, location + range + (@as(usize, ch) - start) * 2) orelse return false;
            return glyph != 0 and @as(u16, @truncate(@as(u32, glyph) + delta)) != 0;
        },
        .full => |offset| {
            const base: usize = offset;
            const count: usize = u32at(bytes, base + 12) orelse return false;
            var left: usize = 0;
            var right = count;
            while (left < right) {
                const middle = left + (right - left) / 2;
                if ((u32at(bytes, base + 16 + middle * 12 + 4) orelse return false) < ch) left = middle + 1 else right = middle;
            }
            if (left >= count) return false;
            const group = base + 16 + left * 12;
            const first = u32at(bytes, group) orelse return false;
            if (first > ch) return false;
            const glyph = u32at(bytes, group + 8) orelse return false;
            return @as(u64, glyph) + @as(u64, ch) - first != 0;
        },
    }
}
pub fn ignorable(ch: u21) bool {
    return ch < 32 or (ch >= 0x7f and ch <= 0x9f) or (ch >= 0x200b and ch <= 0x200f) or
        (ch >= 0x202a and ch <= 0x202e) or (ch >= 0x2060 and ch <= 0x206f) or ch == 0xfeff or
        (ch >= 0xfe00 and ch <= 0xfe0f) or (ch >= 0xe0100 and ch <= 0xe01ef);
}
pub fn missingCount(font: *const z2d.font.Font, text: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[at]) catch { at += 1; continue; };
        if (length > text.len - at) break;
        const ch = std.unicode.utf8Decode(text[at..][0..length]) catch { at += 1; continue; };
        at += length;
        if (!ignorable(ch) and !has(font, ch)) count += 1;
    }
    return count;
}
pub fn missing(allocator: std.mem.Allocator, font: *const z2d.font.Font, text: []const u8) ![]u32 {
    return missingMany(allocator, font, &.{text});
}
pub fn missingMany(allocator: std.mem.Allocator, font: *const z2d.font.Font, texts: []const []const u8) ![]u32 {
    var unique: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer unique.deinit(allocator);
    for (texts) |text| {
        var at: usize = 0;
        while (at < text.len) {
            const begin = at;
            at += 1;
            if (text[begin] < 128) continue;
            const length = std.unicode.utf8ByteSequenceLength(text[begin]) catch continue;
            if (length > text.len - begin) continue;
            const ch = std.unicode.utf8Decode(text[begin..][0..length]) catch continue;
            at = begin + length;
            if (!ignorable(ch) and !has(font, ch)) try unique.put(allocator, ch, {});
        }
    }
    const result = try allocator.alloc(u32, unique.count());
    var keys = unique.keyIterator();
    var index: usize = 0;
    while (keys.next()) |key| : (index += 1) result[index] = key.*;
    std.mem.sort(u32, result, {}, std.sort.asc(u32));
    return result;
}
