//! Standard HTML entity references; compact static data with no C dependency.
const std = @import("std");
const data = @embedFile("html-entity-data");
const count = std.mem.readInt(u32, data[0..4], .little);
const names_at = 12 + count * 6;
const values_at = names_at + std.mem.readInt(u32, data[4..8], .little);

pub fn named(name: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi: usize = count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const record = data[12 + mid * 6 ..][0..6];
        const at = std.mem.readInt(u16, record[0..2], .little);
        const key = data[names_at + at ..][0..record[4]];
        switch (std.mem.order(u8, name, key)) {
            .lt => hi = mid,
            .gt => lo = mid + 1,
            .eq => {
                const value = std.mem.readInt(u16, record[2..4], .little);
                return data[values_at + value ..][0..record[5]];
            },
        }
    }
    return null;
}

pub const Decoded = struct { bytes: [8]u8 = undefined, len: u4, consumed: usize };
pub fn decode(input: []const u8, at: usize) ?Decoded {
    if (at >= input.len or input[at] != '&' or input.len - at < 3) return null;
    var end = at + 1;
    if (input[end] == '#') {
        end += 1;
        const hex = end < input.len and (input[end] == 'x' or input[end] == 'X');
        if (hex) end += 1;
        const start = end;
        const max_digits: usize = if (hex) 6 else 7;
        while (end < input.len and end - start < max_digits and
            (if (hex) std.ascii.isHex(input[end]) else std.ascii.isDigit(input[end]))) : (end += 1)
        {}
        if (end == start or end == input.len or input[end] != ';') return null;
        var cp = std.fmt.parseInt(u32, input[start..end], if (hex) 16 else 10) catch return null;
        if (cp >= 0x80 and cp <= 0x9f) {
            const windows = [_]u32{ 0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178 };
            cp = windows[cp - 0x80];
        }
        if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) cp = 0xfffd;
        var result: Decoded = .{ .len = 0, .consumed = end + 1 - at };
        result.len = std.unicode.utf8Encode(@intCast(cp), result.bytes[0..4]) catch unreachable;
        return result;
    }
    while (end < input.len and end - at <= 32 and std.ascii.isAlphanumeric(input[end])) : (end += 1) {}
    if (end == input.len or input[end] != ';') return null;
    const value = named(input[at + 1 .. end]) orelse return null;
    var result: Decoded = .{ .len = @intCast(value.len), .consumed = end + 1 - at };
    @memcpy(result.bytes[0..value.len], value);
    return result;
}
