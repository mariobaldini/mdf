const std = @import("std");
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const release = optimize == .ReleaseFast;
    const md4c = b.dependency("md4c", .{});
    const native = b.addTranslateC(.{
        .root_source_file = b.path("src/native.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addIncludePath(md4c.path("src"));
    const c_module = native.createModule();
    c_module.addIncludePath(md4c.path("src"));
    c_module.addCSourceFile(.{ .file = md4c.path("src/md4c.c"), .flags = &.{"-std=c99"} });
    c_module.addCSourceFile(.{ .file = md4c.path("src/entity.c"), .flags = &.{"-std=c99"} });
    const core = b.addLibrary(.{
        .name = "mdf-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
        }),
    });
    core.root_module.addImport("native", c_module);
    core.root_module.addAnonymousImport("notices", .{ .root_source_file = b.path("assets/NOTICE.txt") });
    core.root_module.addAnonymousImport("mermaid-notices", .{ .root_source_file = b.path("assets/MERMAID-NOTICE.txt") });
    core.bundle_compiler_rt = true;
    core.bundle_ubsan_rt = !release;
    for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "open-sans-regular", .path = "assets/fonts/open-sans/OpenSans-Regular.ttf" },
        .{ .name = "open-sans-bold", .path = "assets/fonts/open-sans/OpenSans-Bold.ttf" },
        .{ .name = "open-sans-italic", .path = "assets/fonts/open-sans/OpenSans-Italic.ttf" },
        .{ .name = "open-sans-bold-italic", .path = "assets/fonts/open-sans/OpenSans-BoldItalic.ttf" },
    }) |font| {
        var resource = b.path(font.path);
        if (std.mem.indexOf(u8, font.name, "italic") != null) {
            const pack = b.addSystemCommand(&.{"python3"});
            pack.addFileArg(b.path("scripts/pack-font.py"));
            pack.addFileArg(resource);
            resource = pack.addOutputFileArg(b.fmt("{s}.zlib", .{font.name}));
        }
        core.root_module.addAnonymousImport(font.name, .{ .root_source_file = resource });
    }
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, core, &visited);
    }
    const tests_module = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for (core.root_module.import_table.keys(), core.root_module.import_table.values()) |name, module| tests_module.addImport(name, module);
    const tests = b.addTest(.{ .root_module = tests_module });
    b.step("test", "Run parser, loader, settings, navigation and profiling tests").dependOn(&b.addRunArtifact(tests).step);
    b.installArtifact(core);
}

fn optimizeArtifact(b: *std.Build, artifact: *std.Build.Step.Compile, visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) void {
    artifact.use_llvm = true;
    artifact.use_lld = true;
    artifact.lto = .full;
    artifact.link_function_sections = true;
    artifact.link_data_sections = true;
    artifact.link_gc_sections = true;
    optimizeModule(b, artifact.root_module, visited);
}
fn optimizeModule(b: *std.Build, module: *std.Build.Module, visited: *std.AutoHashMapUnmanaged(*std.Build.Module, void)) void {
    const entry = visited.getOrPut(b.allocator, module) catch @panic("OOM");
    if (entry.found_existing) return;
    module.optimize = .ReleaseFast;
    module.strip = true;
    module.omit_frame_pointer = true;
    module.unwind_tables = .none;
    for (module.import_table.values()) |imported| optimizeModule(b, imported, visited);
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |dependency| optimizeArtifact(b, dependency, visited),
        else => {},
    };
}
