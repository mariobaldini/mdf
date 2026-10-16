const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .glibc_version = .{ .major = 2, .minor = 38, .patch = 0 } } });
    if (target.result.os.tag != .linux or target.result.abi.isAndroid()) @panic("Markdown FAST requires desktop Linux with Wayland");
    const optimize = b.standardOptimizeOption(.{});
    @import("frontend/core-build.zig").build(b, target, optimize);
}
