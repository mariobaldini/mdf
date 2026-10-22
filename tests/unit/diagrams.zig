const std = @import("std");
const diagrams = @import("mdf").diagrams;
const c = @import("mdf").native;

fn header() [40]u8 {
    var bytes: [40]u8 = @splat(0);
    @memcpy(bytes[0..8], "MDFDG01\x00");
    std.mem.writeInt(u32, bytes[8..12], 2, .little);
    std.mem.writeInt(u32, bytes[12..16], 40, .little);
    std.mem.writeInt(u64, bytes[16..24], 2, .little);
    std.mem.writeInt(u64, bytes[24..32], 20, .little);
    std.mem.writeInt(u32, bytes[32..36], 123, .little);
    return bytes;
}
test "diagrams: payload headers validate magic version exact sizes and reserved bits" {
    var bytes = header();
    const info = try diagrams.parseHeader(&bytes, 42);
    try std.testing.expectEqual(@as(usize, 2), info.stored);
    try std.testing.expectEqual(@as(usize, 20), info.expanded);
    try std.testing.expectEqual(@as(u32, 123), info.checksum);
    bytes[0] = 0;
    try std.testing.expectError(error.UnsupportedModuleVersion, diagrams.parseHeader(&bytes, 42));
    bytes = header();
    bytes[8] = 99;
    try std.testing.expectError(error.UnsupportedModuleVersion, diagrams.parseHeader(&bytes, 42));
    bytes = header();
    bytes[36] = 2;
    try std.testing.expectError(error.UnsupportedModuleVersion, diagrams.parseHeader(&bytes, 42));
    bytes = header();
    try std.testing.expectError(error.InvalidModuleSize, diagrams.parseHeader(&bytes, 41));
    std.mem.writeInt(u64, bytes[24..32], 1 << 63, .little);
    try std.testing.expectError(error.InvalidModuleSize, diagrams.parseHeader(&bytes, 42));
    try std.testing.expectError(error.UnsupportedModuleVersion, diagrams.parseHeader(bytes[0..10], 42));
}

test "diagrams: raw headers require equal stored and mapped lengths" {
    var bytes = header();
    std.mem.writeInt(u32, bytes[36..40], c.MDF_MODULE_PAYLOAD_RAW, .little);
    try std.testing.expectError(error.InvalidModuleSize, diagrams.parseHeader(&bytes, 42));
    std.mem.writeInt(u64, bytes[24..32], 2, .little);
    const info = try diagrams.parseHeader(&bytes, 42);
    try std.testing.expect(info.raw);
    try std.testing.expectEqual(info.stored, info.expanded);
}

fn elfFixture() [512]u8 {
    var bytes: [512]u8 = @splat(0);
    var elf = std.mem.zeroes(c.Elf64_Ehdr);
    @memcpy(elf.e_ident[0..4], "\x7fELF");
    elf.e_ident[c.EI_CLASS] = c.ELFCLASS64;
    elf.e_ident[c.EI_DATA] = c.ELFDATA2LSB;
    elf.e_shoff = 64;
    elf.e_shentsize = @sizeOf(c.Elf64_Shdr);
    elf.e_shnum = 3;
    elf.e_shstrndx = 1;
    @memcpy(bytes[0..@sizeOf(c.Elf64_Ehdr)], std.mem.asBytes(&elf));
    var names = std.mem.zeroes(c.Elf64_Shdr);
    names.sh_offset = 256;
    names.sh_size = 10;
    @memcpy(bytes[128..192], std.mem.asBytes(&names));
    @memcpy(bytes[256..266], "\x00.mdf_svg\x00");
    var payload = std.mem.zeroes(c.Elf64_Shdr);
    payload.sh_name = 1;
    payload.sh_type = c.SHT_PROGBITS;
    payload.sh_offset = 320;
    payload.sh_size = 42;
    @memcpy(bytes[192..256], std.mem.asBytes(&payload));
    @memcpy(bytes[320..360], &header());
    @memcpy(bytes[360..362], "xy");
    return bytes;
}
fn file(bytes: []const u8) !c_int {
    const fd = c.memfd_create("mdf-module-unit", c.MFD_CLOEXEC);
    if (fd < 0) return error.FileFailed;
    errdefer _ = c.close(fd);
    if (c.write(fd, bytes.ptr, bytes.len) != bytes.len) return error.WriteFailed;
    return fd;
}
test "diagrams: section reader loads only the requested bounded ELF payload" {
    const bytes = elfFixture();
    const fd = try file(&bytes);
    defer _ = c.close(fd);
    const payload = try diagrams.readPayload(fd, bytes.len, .svg, .{});
    defer std.heap.c_allocator.free(payload.data);
    try std.testing.expectEqualStrings("xy", payload.data);
    try std.testing.expectEqual(@as(usize, 20), payload.expanded);
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .mermaid, .{}));
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, 350, .svg, .{}));
}
test "diagrams: raw section remains lazy and independent of sibling renderers" {
    var bytes = elfFixture();
    std.mem.writeInt(u64, bytes[344..352], 2, .little);
    std.mem.writeInt(u32, bytes[356..360], c.MDF_MODULE_PAYLOAD_RAW, .little);
    const fd = try file(&bytes);
    defer _ = c.close(fd);
    const payload = try diagrams.readPayload(fd, bytes.len, .svg, .{});
    defer std.heap.c_allocator.free(payload.data);
    try std.testing.expect(payload.raw);
    try std.testing.expectEqualStrings("xy", payload.data);
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .mermaid, .{}));
}
test "modules: system text has an independent non-allocated ELF payload" {
    var bytes = elfFixture();
    var names: c.Elf64_Shdr = undefined;
    @memcpy(std.mem.asBytes(&names), bytes[128..192]);
    names.sh_size = 11;
    @memcpy(bytes[128..192], std.mem.asBytes(&names));
    @memcpy(bytes[256..267], "\x00.mdf_text\x00");
    const fd = try file(&bytes);
    defer _ = c.close(fd);
    const payload = try diagrams.readPayload(fd, bytes.len, .text, .{});
    defer std.heap.c_allocator.free(payload.data);
    try std.testing.expectEqualStrings("xy", payload.data);
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .svg, .{}));
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .mermaid, .{}));
}
test "modules: raster codecs have an independent non-allocated ELF payload" {
    var bytes = elfFixture();
    var names: c.Elf64_Shdr = undefined;
    @memcpy(std.mem.asBytes(&names), bytes[128..192]);
    names.sh_size = 12;
    @memcpy(bytes[128..192], std.mem.asBytes(&names));
    @memcpy(bytes[256..268], "\x00.mdf_image\x00");
    const fd = try file(&bytes);
    defer _ = c.close(fd);
    const payload = try diagrams.readPayload(fd, bytes.len, .image, .{});
    defer std.heap.c_allocator.free(payload.data);
    try std.testing.expectEqualStrings("xy", payload.data);
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .svg, .{}));
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .mermaid, .{}));
}
test "modules: codec ABI rejects wrong kinds reserved bits and missing callbacks" {
    const callbacks = struct {
        fn decode(_: [*c]const u8, _: usize, _: usize, _: [*c]c.struct_MdfPixels) callconv(.c) c_int { return 0; }
        fn encode(_: [*c]const c.struct_MdfPixels, _: usize, _: [*c]c.struct_MdfEncodedImage) callconv(.c) c_int { return 0; }
    };
    var api = std.mem.zeroes(c.struct_MdfImageApi);
    try std.testing.expect(!diagrams.validImageApi(&api));
    api = .{ .abi = c.MDF_IMAGE_ABI, .size = @sizeOf(c.struct_MdfImageApi), .kind = c.MDF_MODULE_IMAGE,
        .reserved = 0, .decode = callbacks.decode, .encode = callbacks.encode };
    try std.testing.expect(diagrams.validImageApi(&api));
    api.kind = c.MDF_MODULE_SVG;
    try std.testing.expect(!diagrams.validImageApi(&api));
    api.kind = c.MDF_MODULE_IMAGE;
    api.reserved = 1;
    try std.testing.expect(!diagrams.validImageApi(&api));
    api.reserved = 0;
    api.decode = null;
    try std.testing.expect(!diagrams.validImageApi(&api));
    api.decode = callbacks.decode;
    api.encode = null;
    try std.testing.expect(!diagrams.validImageApi(&api));
}
test "diagrams: section reader rejects allocated duplicate and truncated sections" {
    var bytes = elfFixture();
    var payload: c.Elf64_Shdr = undefined;
    @memcpy(std.mem.asBytes(&payload), bytes[192..256]);
    payload.sh_flags = c.SHF_ALLOC;
    @memcpy(bytes[192..256], std.mem.asBytes(&payload));
    var fd = try file(&bytes);
    try std.testing.expectError(error.MissingModuleSection, diagrams.readPayload(fd, bytes.len, .svg, .{}));
    _ = c.close(fd);
    bytes = elfFixture();
    @memcpy(bytes[64..128], bytes[192..256]);
    fd = try file(&bytes);
    try std.testing.expectError(error.DuplicateModuleSection, diagrams.readPayload(fd, bytes.len, .svg, .{}));
    _ = c.close(fd);
    bytes = elfFixture();
    var elf: c.Elf64_Ehdr = undefined;
    @memcpy(std.mem.asBytes(&elf), bytes[0..64]);
    elf.e_shoff = std.math.maxInt(u64);
    @memcpy(bytes[0..64], std.mem.asBytes(&elf));
    fd = try file(&bytes);
    defer _ = c.close(fd);
    try std.testing.expectError(error.TruncatedModule, diagrams.readPayload(fd, bytes.len, .svg, .{}));
}
test "diagrams: cancellation stops section reads before allocation or parsing" {
    const check = struct {
        fn stop(_: ?*const anyopaque) callconv(.c) c_int {
            return 1;
        }
    };
    const bytes = elfFixture();
    const fd = try file(&bytes);
    defer _ = c.close(fd);
    try std.testing.expectError(error.Canceled, diagrams.readPayload(fd, bytes.len, .svg, .{ .check = check.stop }));
}
test "diagrams: SVG sniffing handles XML prefixes without classifying binary images" {
    for ([_][]const u8{ "<svg/>", "\xef\xbb\xbf \n<?xml version='1.0'?><!-- comment --><svg/>", "<p:svg/>" }) |text|
        try std.testing.expect(diagrams.mdf_svg_image(text.ptr, text.len));
    for ([_][]const u8{ "", "PNG<svg/>", "<html/>", "\x89PNG\r\n" }) |text|
        try std.testing.expect(!diagrams.mdf_svg_image(text.ptr, text.len));
    try std.testing.expect(!diagrams.mdf_svg_image(null, 5));
}
