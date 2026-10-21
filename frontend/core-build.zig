const std = @import("std");
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const release = optimize == .ReleaseFast;
    const pozeiden = b.dependency("pozeiden", .{ .target = target, .optimize = optimize, .version = "0.4.1" });
    // Normalize a generated copy; the pinned submodule stays pristine.
    // Palette adjustments are documented in docs/compressed-diagrams.md.
    const layout_sources = b.addWriteFiles();
    _ = layout_sources.addCopyDirectory(pozeiden.path("src"), "pozeiden", .{
        .exclude_extensions = &.{ "renderers/sequence.zig", "renderers/flowchart.zig", "renderers/state.zig",
            "renderers/class.zig", "renderers/timeline.zig", "renderers/quadrant.zig", "renderers/pie.zig", "renderers/c4.zig" },
    });
    const PaletteSource = struct { file: []const u8, source: []const u8, changes: []const [2][]const u8 };
    for ([_]PaletteSource{
        .{ .file = "sequence", .source = @embedFile("../modules/pozeiden/src/renderers/sequence.zig"), .changes = &.{
            .{ "\"#fffde7\", \"#f0c040\", 1.2", "theme.note_fill, theme.note_stroke, 1.2" },
            .{ "\"#f0f4ff\", \"#6688cc\", 1.2", "theme.loop_fill, theme.loop_stroke, 1.2" },
            .{ "const blk_fill = switch (b.kind)", "const blk_fill = if (std.mem.eql(u8, theme.text_color, \"#e0e0e0\")) theme.loop_fill else switch (b.kind)" },
        } },
        .{ .file = "flowchart", .source = @embedFile("../modules/pozeiden/src/renderers/flowchart.zig"), .changes = &.{
            .{ "6.0, \"#f0f4ff\", \"#b0c0e8\", 1.2", "6.0, theme.subgraph_fill, theme.subgraph_stroke, 1.2" },
            .{ "\"#4466aa\", theme.font_size_small", "theme.text_color, theme.font_size_small" },
        } },
        .{ .file = "state", .source = @embedFile("../modules/pozeiden/src/renderers/state.zig"), .changes = &.{
            .{ "\"#fffde7\", \"#f0c040\", 1.2", "theme.note_fill, theme.note_stroke, 1.2" },
        } },
        .{ .file = "class", .source = @embedFile("../modules/pozeiden/src/renderers/class.zig"), .changes = &.{
            .{ "\"#fffde7\", \"#f0c040\", 1.2", "theme.note_fill, theme.note_stroke, 1.2" },
            .{ "8.0, \"#f0f4ff\", \"#8888cc\", 1.5", "8.0, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.subgraph_fill else \"#f0f4ff\", if (std.mem.eql(u8, theme.background, \"#202124\")) theme.subgraph_stroke else \"#8888cc\", 1.5" },
            .{ "ns_name, \"#6666aa\"", "ns_name, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.text_color else \"#6666aa\"" },
            .{ "ste_raw, \"#666666\"", "ste_raw, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.text_color else \"#666666\"" },
        } },
        .{ .file = "timeline", .source = @embedFile("../modules/pozeiden/src/renderers/timeline.zig"), .changes = &.{
            .{ "3.0, \"#f8f9fa\", color", "3.0, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.node_fill else \"#f8f9fa\", color" },
        } },
        .{ .file = "quadrant", .source = @embedFile("../modules/pozeiden/src/renderers/quadrant.zig"), .changes = &.{
            .{ "0, \"#fafafa\", \"#cccccc\", 1.0", "0, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.subgraph_fill else \"#fafafa\", \"#cccccc\", 1.0" },
        } },
        .{ .file = "pie", .source = @embedFile("../modules/pozeiden/src/renderers/pie.zig"), .changes = &.{
            .{ "theme.pie_text_color, theme.font_size_small", "if (std.mem.eql(u8, theme.background, \"#202124\")) theme.text_color else theme.pie_text_color, theme.font_size_small" },
        } },
        .{ .file = "c4", .source = @embedFile("../modules/pozeiden/src/renderers/c4.zig"), .changes = &.{
            .{ "bnd.label, bstroke", "bnd.label, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.text_color else bstroke" },
            .{ "rel.label, TEXT_DARK", "rel.label, theme.text_color" },
            .{ "rel.tech, \"#666666\"", "rel.tech, if (std.mem.eql(u8, theme.background, \"#202124\")) theme.text_color else \"#666666\"" },
        } },
    }) |palette| {
        var source = palette.source;
        for (palette.changes) |change| {
            if (std.mem.count(u8, source, change[0]) != 1)
                std.debug.panic("Pozeiden {s} palette changed; review the documented adapter", .{palette.file});
            source = std.mem.replaceOwned(u8, b.allocator, source, change[0], change[1]) catch @panic("OOM");
        }
        _ = layout_sources.add(b.fmt("pozeiden/renderers/{s}.zig", .{palette.file}), source);
    }
    const layout_source = layout_sources.addCopyFile(b.path("frontend/pozeiden.zig"), "pozeiden/mdf.zig");
    const upstream_module = pozeiden.module("pozeiden");
    const layout_module = b.createModule(.{
        .root_source_file = layout_source, .target = target, .optimize = optimize,
        .link_libc = true, .pic = true,
    });
    for (upstream_module.import_table.keys(), upstream_module.import_table.values()) |name, module|
        layout_module.addImport(name, module);
    const layout = b.addLibrary(.{ .name = "mdf-pozeiden", .linkage = .static, .root_module = layout_module });
    layout.bundle_compiler_rt = true;
    layout.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, layout, &visited);
    }
    b.installArtifact(layout);
    const layout_tests_module = b.createModule(.{
        .root_source_file = layout_source, .target = target, .optimize = optimize,
        .link_libc = true,
    });
    for (upstream_module.import_table.keys(), upstream_module.import_table.values()) |name, module|
        layout_tests_module.addImport(name, module);
    inline for (.{ "pie", "flowchart", "sequence", "gitgraph", "class", "state", "er", "gantt",
        "timeline", "xychart", "quadrant", "mindmap", "sankey", "c4", "block", "requirement", "kanban" }) |name| {
        layout_tests_module.addAnonymousImport("pozeiden-fixture-" ++ name, .{ .root_source_file = pozeiden.path("examples/" ++ name ++ ".mmd") });
    }
    const layout_tests = b.addTest(.{ .root_module = layout_tests_module });
    b.step("test-mermaid", "Check Pozeiden SVG generation, supported families and error handling").dependOn(&b.addRunArtifact(layout_tests).step);
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
