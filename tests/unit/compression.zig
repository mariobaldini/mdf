const std = @import("std");
const codec = @import("mdf").compression;
const fixture = "\x78\xda\x63\x60\x64\x60\x48\xcb\xcf\x2b\xd1\x4d\xcb\xac\x28\x29\x2d\x4a\x65\x00\x00\x24\x71\x04\xed";
const expected = "\x00\x01\x00\x00font-fixture\x00";
const crc = std.hash.Crc32.hash(expected);

test "compression: Python zlib stream and empty stream decode exactly" {
    var output: [expected.len]u8 = undefined;
    try codec.inflate(fixture, &output, crc, .{});
    try std.testing.expectEqualStrings(expected, &output);
    try codec.inflate("\x78\xda\x03\x00\x00\x00\x00\x01", &.{}, 0, .{});
}
test "compression: short oversized and trailing streams are rejected" {
    var output: [expected.len + 1]u8 = @splat(0xee);
    try std.testing.expectError(error.InvalidLength, codec.inflate(fixture, output[0 .. expected.len - 1], crc, .{}));
    try std.testing.expectError(error.InvalidLength, codec.inflate(fixture, &output, crc, .{}));
    try std.testing.expectError(error.InvalidLength, codec.inflate(fixture ++ "extra", output[0..expected.len], crc, .{}));
    for (0..fixture.len) |size| {
        if (codec.inflate(fixture[0..size], output[0..expected.len], crc, .{}))
            return error.AcceptedTruncatedStream
        else |_| {}
    }
}
test "compression: Adler CRC and zlib header checks are independent" {
    var output: [expected.len]u8 = undefined;
    try std.testing.expectError(error.InvalidChecksum, codec.inflate(fixture, &output, crc ^ 1, .{}));
    var invalid = fixture.*;
    invalid[invalid.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidChecksum, codec.inflate(&invalid, &output, crc, .{}));
    invalid = fixture.*;
    invalid[1] ^= 1;
    try std.testing.expectError(error.InvalidHeader, codec.inflate(&invalid, &output, crc, .{}));
    try std.testing.expectError(error.InvalidHeader, codec.inflate("\x78\x20" ++ fixture[2..], &output, crc, .{}));
}
const Cancellation = struct {
    polls: usize = 0,
    fn check(context: ?*const anyopaque) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(@constCast(context.?)));
        self.polls += 1;
        return @intFromBool(self.polls >= 2);
    }
};
test "compression: cancellation interrupts large output between bounded chunks" {
    const a = std.testing.allocator;
    const output = try a.alloc(u8, 4 * 65536);
    defer a.free(output);
    @memset(output, 0xee);
    var stop: Cancellation = .{};
    try std.testing.expectError(error.Canceled, codec.inflate(@embedFile("../fixtures/compression-repeat.zlib"), output, 0, .{ .check = Cancellation.check, .context = &stop }));
    try std.testing.expectEqual(@as(u8, 'A'), output[0]);
    try std.testing.expectEqual(@as(u8, 0xee), output[65536]);
}
test "compression: C ABI rejects invalid bounds and preserves cancellation status" {
    var output: [expected.len]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), codec.mdf_inflate_zlib(null, fixture.len, &output, output.len, crc, null, null));
    try std.testing.expectEqual(@as(c_int, 0), codec.mdf_inflate_zlib(fixture, fixture.len, null, output.len, crc, null, null));
    try std.testing.expectEqual(@as(c_int, 0), codec.mdf_inflate_zlib(fixture, 256 * 1024 * 1024 + 1, &output, output.len, crc, null, null));
    try std.testing.expectEqual(@as(c_int, 0), codec.mdf_inflate_zlib(fixture, fixture.len, &output, 256 * 1024 * 1024 + 1, crc, null, null));
    try std.testing.expectEqual(@as(c_int, 1), codec.mdf_inflate_zlib(fixture, fixture.len, &output, output.len, crc, null, null));
    var stop: Cancellation = .{};
    try std.testing.expectEqual(@as(c_int, -1), codec.mdf_inflate_zlib(fixture, fixture.len, &output, output.len, crc, Cancellation.check, &stop));
}
