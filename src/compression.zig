//! Checked zlib streams shared by bundled fonts and optional renderer modules.
const std = @import("std");
pub const Cancel = struct {
    check: ?*const fn (?*const anyopaque) callconv(.c) c_int = null,
    context: ?*const anyopaque = null,
    fn poll(self: Cancel) !void {
        if (self.check) |check| if (check(self.context) != 0) return error.Canceled;
    }
};

pub fn inflate(input: []const u8, output: []u8, checksum: u32, cancel: Cancel) !void {
    if (input.len < 6 or input[0] & 15 != 8 or input[0] >> 4 > 7 or input[1] & 32 != 0 or
        ((@as(u16, input[0]) << 8) | input[1]) % 31 != 0) return error.InvalidHeader;
    var source: std.Io.Reader = .fixed(input);
    var decoder: std.compress.flate.Decompress = .init(&source, .zlib, &.{});
    var target: std.Io.Writer = .fixed(output);
    while (true) {
        try cancel.poll();
        _ = decoder.reader.stream(&target, .limited(65536)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.InvalidLength,
            else => return error.CorruptStream,
        };
    }
    if (target.end != output.len or source.seek != input.len) return error.InvalidLength;
    var crc: std.hash.Crc32 = .init();
    var adler: std.hash.Adler32 = .{};
    var at: usize = 0;
    while (at < output.len) {
        try cancel.poll();
        const bytes = output[at..@min(at + 65536, output.len)];
        crc.update(bytes);
        adler.update(bytes);
        at += bytes.len;
    }
    try cancel.poll();
    if (decoder.container_metadata.zlib.adler != adler.adler or crc.final() != checksum)
        return error.InvalidChecksum;
}

pub export fn mdf_inflate_zlib(input: ?[*]const u8, length: usize, output: ?[*]u8, expanded: usize, checksum: u32, canceled: ?*const fn (?*const anyopaque) callconv(.c) c_int, context: ?*const anyopaque) c_int {
    const bytes = input orelse return 0;
    const storage = output orelse return 0;
    if (length > 256 * 1024 * 1024 or expanded > 256 * 1024 * 1024) return 0;
    inflate(bytes[0..length], storage[0..expanded], checksum, .{ .check = canceled, .context = context }) catch |err|
        return if (err == error.Canceled) -1 else 0;
    return 1;
}
