//! Local image decoding on the existing image worker. Only pixel storage crosses
//! the C ABI; successful output is malloc-compatible and owned by the caller.
const std = @import("std");
const zignal = @import("zignal");
const a = std.heap.c_allocator;
const io: std.Io = .failing; // Async work runs inline; no I/O or extra workers.
const max_dimension = 32768;
const max_pixels = 64 * 1024 * 1024;

pub const Pixels = extern struct {
    data: ?[*]u8 = null,
    width: c_int = 0,
    height: c_int = 0,
    channels: c_int = 0,
};
pub const EncodedImage = extern struct { data: ?[*]u8 = null, length: usize = 0 };

fn encodePng(pixels: Pixels, length: usize) ![]u8 {
    const input = pixels.data orelse return error.InvalidPixels;
    if (pixels.width <= 0 or pixels.height <= 0 or
        (pixels.channels != 1 and pixels.channels != 3 and pixels.channels != 4)) return error.InvalidPixels;
    const width: u32 = @intCast(pixels.width);
    const height: u32 = @intCast(pixels.height);
    const count = try imageBytes(width, height, @intCast(pixels.channels), length);
    inline for (.{ u8, zignal.Rgb(u8), zignal.Rgba(u8) }) |T| {
        if (pixels.channels == @sizeOf(T)) {
            // C callers may supply a byte-aligned view; packed RGBA has a
            // stronger alignment than an arbitrary byte slice in Zignal.
            var aligned: ?[]T = null;
            defer if (aligned) |storage| a.free(storage);
            const bytes = if (@intFromPtr(input) % @alignOf(T) == 0) input[0..count] else blk: {
                const storage = try a.alloc(T, count / @sizeOf(T));
                aligned = storage;
                const raw = std.mem.sliceAsBytes(storage);
                @memcpy(raw, input[0..count]);
                break :blk raw;
            };
            const image = zignal.Image(T).initFromBytes(height, width, bytes);
            return zignal.png.encode(T, io, a, image, .default);
        }
    }
    unreachable;
}

test "MDF image: PNG encoder accepts unaligned C RGBA views" {
    var data: [9]u8 align(8) = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };
    const encoded = try encodePng(.{ .data = data[1..].ptr, .width = 2, .height = 1, .channels = 4 }, 8);
    defer a.free(encoded);
    const decoded = try png(encoded, 8);
    defer a.free(decoded.data.?[0..8]);
    try std.testing.expectEqualSlices(u8, data[1..], decoded.data.?[0..8]);
}

pub export fn mdf_encode_png(input: ?*const Pixels, length: usize, output: ?*EncodedImage) c_int {
    const out = output orelse return 0;
    out.* = .{};
    const pixels = input orelse return 0;
    const bytes = encodePng(pixels.*, length) catch return 0;
    out.* = .{ .data = bytes.ptr, .length = bytes.len };
    return 1;
}

fn imageBytes(width: u32, height: u32, channels: usize, limit: usize) !usize {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension)
        return error.ImageTooLarge;
    const count = try std.math.mul(usize, width, height);
    if (count > max_pixels) return error.ImageTooLarge;
    const bytes = try std.math.mul(usize, count, channels);
    if (bytes > limit) return error.ImageTooLarge;
    return bytes;
}

fn png(bytes: []const u8, limit: usize) !Pixels {
    var limits: zignal.png.DecodeLimits = .{
        .max_width = .limited(max_dimension),
        .max_height = .limited(max_dimension),
    };
    var reader: std.Io.Reader = .fixed(bytes);
    const header = try zignal.png.getInfo(&reader, limits);
    const minimum_channels: usize = if (header.color_type == .palette) 3 else header.channels();
    _ = try imageBytes(header.width, header.height, minimum_channels, limit);
    limits.max_pixels = .limited(@min(max_pixels, limit / minimum_channels));
    limits.max_decompressed_bytes = .limited(@min(536_886_272, (limit *| 2) +| (@as(usize, header.height) * 7)));
    var state = try zignal.png.decode(a, bytes, limits);
    defer state.deinit(a);
    // MDF rejects incomplete images rather than displaying a partial decode.
    if (state.truncated) return error.TruncatedImage;
    const channels: usize = switch (state.header.color_type) {
        .grayscale => if (state.transparency != null) 2 else 1,
        .grayscale_alpha => 2,
        .rgb, .palette => if (state.transparency != null) 4 else 3,
        .rgba => 4,
    };
    const count = try imageBytes(header.width, header.height, channels, limit);
    if (header.bit_depth == 8 and header.interlace_method == 0 and
        header.color_type != .palette and state.transparency == null)
    {
        // Zignal already defiltered these native eight-bit pixels. Remove
        // the per-row filter byte in place and transfer the malloc allocation,
        // avoiding another full image allocation and pixel conversion/copy.
        const data = state.scanlines;
        const stride = @as(usize, header.width) * channels;
        for (0..header.height) |row|
            std.mem.copyForwards(u8, data[row * stride ..][0..stride], data[row * (stride + 1) + 1 ..][0..stride]);
        state.scanlines = &.{};
        return .{ .data = data.ptr, .width = @intCast(header.width), .height = @intCast(header.height), .channels = @intCast(channels) };
    }
    var image = try zignal.png.toAnyImage(a, &state);
    errdefer image.deinit(a);
    const data: [*]u8 = switch (image) {
        .grayscale => |gray| gray.data.ptr,
        .rgb => |rgb| @ptrCast(rgb.data.ptr),
        .rgba => |rgba| blk: {
            if (channels == 4) break :blk @ptrCast(rgba.data.ptr);
            // Zignal represents grayscale+alpha as RGBA. Preserve the native
            // two-channel layout used by FLTK and its output-byte limit.
            const gray_alpha = try a.alloc(u8, count);
            for (rgba.data, 0..) |pixel, i| {
                gray_alpha[2 * i] = pixel.r;
                gray_alpha[2 * i + 1] = pixel.a;
            }
            image.deinit(a);
            break :blk gray_alpha.ptr;
        },
    };
    return .{ .data = data, .width = @intCast(header.width), .height = @intCast(header.height), .channels = @intCast(channels) };
}

fn jpeg(bytes: []const u8, limit: usize) !Pixels {
    var limits: zignal.jpeg.DecodeLimits = .{
        .max_jpeg_bytes = .limited(bytes.len),
        .max_marker_bytes = .limited(bytes.len),
        .max_width = .limited(max_dimension),
        .max_height = .limited(max_dimension),
        .max_pixels = .limited(@min(max_pixels, limit / 3)),
    };
    var reader: std.Io.Reader = .fixed(bytes);
    const header = try zignal.jpeg.getInfo(&reader, limits);
    _ = try imageBytes(header.width, header.height, 3, limit);
    limits.max_pixels = .limited(@min(max_pixels, limit / 3));
    const image = try zignal.jpeg.loadFromBytes(zignal.Rgb(u8), io, a, bytes, limits);
    return .{ .data = @ptrCast(image.data.ptr), .width = @intCast(image.cols), .height = @intCast(image.rows), .channels = 3 };
}

fn adopt(image_value: anytype, width: u32, height: u32, limit: usize) !Pixels {
    var image = image_value;
    errdefer image.deinit(a);
    const channels: usize = switch (image) { .grayscale => 1, .rgb => 3, .rgba => 4 };
    _ = try imageBytes(width, height, channels, limit);
    const data: [*]u8 = switch (image) { .grayscale => |value| value.data.ptr,
        .rgb => |value| @ptrCast(value.data.ptr), .rgba => |value| @ptrCast(value.data.ptr) };
    return .{ .data = data, .width = @intCast(width), .height = @intCast(height), .channels = @intCast(channels) };
}
fn gif(bytes: []const u8, limit: usize) !Pixels {
    const count = @min(max_pixels, limit / 3);
    var state = try zignal.gif.decode(a, bytes, .{ .max_width = .limited(max_dimension), .max_height = .limited(max_dimension),
        .max_pixels = .limited(count), .max_total_pixels = .limited(count), .max_frames = .limited(1) }, .first);
    defer state.deinit(a);
    if (state.frames.len == 0) return error.MissingPixelData;
    const transparent = if (state.frames[0].gce) |control| control.has_transparent else false;
    _ = try imageBytes(state.header.width, state.header.height, if (transparent) 4 else 3, limit);
    return adopt(try zignal.gif.toAnyImage(io, a, state), state.header.width, state.header.height, limit);
}
fn bmp(bytes: []const u8, limit: usize) !Pixels {
    var reader: std.Io.Reader = .fixed(bytes);
    var limits: zignal.bmp.DecodeLimits = .{ .max_width = .limited(max_dimension), .max_height = .limited(max_dimension) };
    const header = try zignal.bmp.getInfo(&reader, limits);
    const channels: usize = if (header.hasAlpha()) 4 else 3;
    _ = try imageBytes(header.width, header.height, channels, limit);
    limits.max_pixels = .limited(@min(max_pixels, limit / channels));
    var state = try zignal.bmp.decode(a, bytes, limits);
    defer state.deinit(a);
    return adopt(try zignal.bmp.toAnyImage(a, state), header.width, header.height, limit);
}

pub export fn mdf_decode_pixels(input: ?[*]const u8, length: usize, limit: usize, output: ?*Pixels) c_int {
    const out = output orelse return 0;
    out.* = .{};
    const data = input orelse return 0;
    const bytes = data[0..length];
    out.* = if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &zignal.png.signature))
        png(bytes, limit) catch return 0
    else if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..2], &zignal.jpeg.signature))
        jpeg(bytes, limit) catch return 0
    else if (bytes.len >= 6 and std.mem.eql(u8, bytes[0..3], &zignal.gif.signature))
        gif(bytes, limit) catch return 0
    else if (bytes.len >= 14 and std.mem.eql(u8, bytes[0..2], &zignal.bmp.signature))
        bmp(bytes, limit) catch return 0
    else
        return 0;
    return 1;
}

test "MDF image: interlaced grayscale alpha retains two channels" {
    const bytes = @embedFile("png-4-8-1-0.png");
    const image = try png(bytes, std.math.maxInt(usize));
    defer a.free(image.data.?[0..@as(usize, @intCast(image.width * image.height * image.channels))]);
    try std.testing.expectEqual(@as(c_int, 2), image.channels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 168 }, image.data.?[0..2]);
}

test "MDF image: packed PNG pixels survive state cleanup and later decoding" {
    const bytes = @embedFile("png-4-8-0-0.png");
    const first = try png(bytes, std.math.maxInt(usize));
    defer a.free(first.data.?[0..@as(usize, @intCast(first.width * first.height * first.channels))]);
    const second = try png(bytes, std.math.maxInt(usize));
    defer a.free(second.data.?[0..@as(usize, @intCast(second.width * second.height * second.channels))]);
    try std.testing.expect(first.data != second.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 168 }, first.data.?[0..2]);
    try std.testing.expectEqual(@as(c_int, 2), second.channels);
}

test "MDF image: RGB and grayscale transparency compare full 16-bit samples" {
    const rgb = try png(@embedFile("png-2-16-1-1.png"), std.math.maxInt(usize));
    defer a.free(rgb.data.?[0..@as(usize, @intCast(rgb.width * rgb.height * rgb.channels))]);
    try std.testing.expectEqual(@as(c_int, 4), rgb.channels);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x56, 0x9a, 0, 0x12, 0x56, 0x9a, 255 }, rgb.data.?[0..8]);
    const gray = try png(@embedFile("png-0-16-0-1.png"), std.math.maxInt(usize));
    defer a.free(gray.data.?[0..@as(usize, @intCast(gray.width * gray.height * gray.channels))]);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0, 0x12, 255 }, gray.data.?[0..4]);
}

test "MDF image: corrupt input and byte limits clear C output" {
    inline for (.{ @embedFile("bad-crc.bad"), @embedFile("huge-header.bad"), @embedFile("huge-gif.bad"), @embedFile("huge-bmp.bad") }) |bytes| {
        var output = Pixels{ .width = 1, .height = 2, .channels = 3 };
        try std.testing.expectEqual(@as(c_int, 0), mdf_decode_pixels(bytes, bytes.len, 1024, &output));
        try std.testing.expect(output.data == null and output.width == 0 and output.height == 0 and output.channels == 0);
    }
    const bytes = @embedFile("png-4-8-1-0.png");
    var output: Pixels = .{};
    try std.testing.expectEqual(@as(c_int, 0), mdf_decode_pixels(bytes, bytes.len, 1, &output));
    try std.testing.expect(output.data == null);
}
test "MDF image: GIF first-frame alpha remains owned after state cleanup" {
    const bytes = @embedFile("gif-0-1-1-1.gif");
    const first = try gif(bytes, 1 << 20);
    defer a.free(first.data.?[0..@as(usize, @intCast(first.width * first.height * first.channels))]);
    const second = try gif(bytes, 1 << 20);
    defer a.free(second.data.?[0..@as(usize, @intCast(second.width * second.height * second.channels))]);
    try std.testing.expectEqual(@as(c_int, 4), first.channels);
    try std.testing.expect(first.data != second.data);
    try std.testing.expectEqualSlices(u8, @embedFile("gif-0-1-1-1.gif.rgba"), first.data.?[0..19 * 17 * 4]);
}
test "MDF image: deterministic GIF BMP mutations stay bounded and clear failures" {
    var generator = std.Random.DefaultPrng.init(0x4d4446474946424d);
    const random = generator.random();
    inline for (.{ @embedFile("gif-0-1-1-1.gif"), @embedFile("bmp-24-1.bmp") }) |original| {
        for (0..512) |_| {
            var mutated = original.*;
            for (0..3) |_| mutated[random.uintLessThan(usize, mutated.len)] ^= random.int(u8);
            var output: Pixels = .{};
            if (mdf_decode_pixels(&mutated, mutated.len, 65536, &output) != 0) {
                const length = @as(usize, @intCast(output.width)) * @as(usize, @intCast(output.height)) * @as(usize, @intCast(output.channels));
                defer a.free(output.data.?[0..length]);
                try std.testing.expect(output.width > 0 and output.height > 0 and length <= 65536);
            } else try std.testing.expect(output.data == null and output.width == 0 and output.height == 0 and output.channels == 0);
        }
    }
}

test "MDF image: PNG encoder preserves grayscale RGB and alpha pixels" {
    inline for (.{ @as(c_int, 1), 3, 4 }) |channels| {
        var data: [24]u8 = undefined;
        for (&data, 0..) |*byte, i| byte.* = @intCast(i * 11);
        const original = data;
        const count: usize = 6 * channels;
        const encoded = try encodePng(.{ .data = &data, .width = 3, .height = 2, .channels = channels }, count);
        defer a.free(encoded);
        const decoded = try png(encoded, count);
        defer a.free(decoded.data.?[0..count]);
        try std.testing.expectEqual(channels, decoded.channels);
        try std.testing.expectEqual(@as(c_int, 3), decoded.width);
        try std.testing.expectEqual(@as(c_int, 2), decoded.height);
        try std.testing.expectEqualSlices(u8, data[0..count], decoded.data.?[0..count]);
        try std.testing.expectEqualSlices(u8, &original, &data);
    }
}

test "MDF image: PNG encoder rejects invalid dimensions format and short storage" {
    var data: [12]u8 = @splat(0);
    var out: EncodedImage = .{ .data = &data, .length = 99 };
    try std.testing.expectEqual(@as(c_int, 0), mdf_encode_png(null, data.len, &out));
    try std.testing.expect(out.data == null and out.length == 0);
    for ([_]Pixels{
        .{ .data = null, .width = 2, .height = 2, .channels = 3 },
        .{ .data = &data, .width = -1, .height = 2, .channels = 3 },
        .{ .data = &data, .width = 2, .height = 0, .channels = 3 },
        .{ .data = &data, .width = 32769, .height = 2, .channels = 3 },
        .{ .data = &data, .width = 2, .height = 2, .channels = 2 },
        .{ .data = &data, .width = 2, .height = 2, .channels = 3 },
    }) |pixels| {
        try std.testing.expectEqual(@as(c_int, 0), mdf_encode_png(&pixels, 11, &out));
        try std.testing.expect(out.data == null and out.length == 0);
    }
}
