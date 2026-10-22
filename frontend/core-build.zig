const std = @import("std");
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const release = optimize == .fast;
    // Build only the pinned library sources. Its standalone CLI build script
    // uses the retired b.args API; MDF does not need that CLI or C wrapper.
    const mvzr = b.dependency("mvzr", .{ .target = target, .optimize = optimize });
    const mvzr_module = mvzr.module("mvzr");
    const prepare_mvzr = b.addSystemCommand(&.{"python3"});
    prepare_mvzr.addFileArg(b.path("scripts/prepare-mvzr.py"));
    prepare_mvzr.addFileArg(mvzr.path("src/mvzr.zig"));
    mvzr_module.root_source_file = prepare_mvzr.addOutputFileArg("mvzr.zig");
    const layout_config = b.addOptions();
    layout_config.addOption([]const u8, "version", "0.4.1");
    // Normalize a generated copy; the pinned submodule stays pristine.
    // Palette adjustments are documented in docs/compressed-diagrams.md.
    const layout_sources = b.addWriteFiles();
    _ = layout_sources.addCopyDirectory(b.path("modules/pozeiden/src"), "pozeiden", .{
        .exclude_extensions = &.{ "renderers/sequence.zig", "renderers/flowchart.zig", "renderers/state.zig", "renderers/class.zig", "renderers/timeline.zig", "renderers/quadrant.zig", "renderers/pie.zig", "renderers/c4.zig", "renderers/block.zig", "svg/layout.zig" },
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
            .{ "var col_count = [_]usize{0} ** 64", "var col_count: [64]usize = @splat(0)" },
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
    const block_source = @embedFile("../modules/pozeiden/src/renderers/block.zig");
    if (std.mem.count(u8, block_source, "@memset(track_end_x, .{0} ** MAX_TRACKS)") != 1)
        std.debug.panic("Pozeiden block initialization changed; review the documented adapter", .{});
    _ = layout_sources.add("pozeiden/renderers/block.zig", std.mem.replaceOwned(u8, b.allocator, block_source, "@memset(track_end_x, .{0} ** MAX_TRACKS)", "@memset(track_end_x, @splat(0))") catch @panic("OOM"));
    const svg_layout_source = @embedFile("../modules/pozeiden/src/svg/layout.zig");
    if (std.mem.count(u8, svg_layout_source, "var seen = [_]bool{false} ** kids") != 1)
        std.debug.panic("Pozeiden SVG layout initialization changed; review the documented adapter", .{});
    _ = layout_sources.add("pozeiden/svg/layout.zig", std.mem.replaceOwned(u8, b.allocator, svg_layout_source, "var seen = [_]bool{false} ** kids", "var seen: [kids]bool = @splat(false)") catch @panic("OOM"));
    const layout_source = layout_sources.addCopyFile(b.path("frontend/pozeiden.zig"), "pozeiden/mdf.zig");
    const layout_module = b.createModule(.{
        .root_source_file = layout_source,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = true,
    });
    layout_module.addImport("mvzr", mvzr_module);
    layout_module.addOptions("config", layout_config);
    const layout = b.addLibrary(.{ .name = "mdf-pozeiden", .linkage = .static, .root_module = layout_module });
    layout.bundle_compiler_rt = true;
    layout.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, layout, &visited);
    }
    b.installArtifact(layout);
    const layout_tests_module = b.createModule(.{
        .root_source_file = layout_source,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    layout_tests_module.addImport("mvzr", mvzr_module);
    layout_tests_module.addOptions("config", layout_config);
    inline for (.{ "pie", "flowchart", "sequence", "gitgraph", "class", "state", "er", "gantt", "timeline", "xychart", "quadrant", "mindmap", "sankey", "c4", "block", "requirement", "kanban" }) |name| {
        layout_tests_module.addAnonymousImport("pozeiden-fixture-" ++ name, .{ .root_source_file = b.path("modules/pozeiden/examples/" ++ name ++ ".mmd") });
    }
    const layout_tests = b.addTest(.{ .root_module = layout_tests_module });
    b.step("test-mermaid", "Check Pozeiden SVG generation, supported families and error handling").dependOn(&b.addRunArtifact(layout_tests).step);
    const svg_dependency = b.dependency("zig_svg", .{ .target = target, .optimize = optimize });
    const svg_module = b.createModule(.{ .root_source_file = b.path("frontend/svg.zig"), .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    svg_module.addImport("svg", svg_dependency.module("svg"));
    svg_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    const svg_library = b.addLibrary(.{ .name = "mdf-svg", .linkage = .static, .root_module = svg_module });
    svg_library.bundle_compiler_rt = true;
    svg_library.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, svg_library, &visited);
    }
    b.installArtifact(svg_library);
    const svg_test_module = b.createModule(.{ .root_source_file = b.path("frontend/svg.zig"), .target = target, .optimize = optimize, .link_libc = true });
    svg_test_module.addImport("svg", svg_dependency.module("svg"));
    svg_test_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    inline for (.{ "Regular", "Bold", "Italic", "BoldItalic" }) |face| {
        svg_test_module.addAnonymousImport("svg-font-" ++ face, .{ .root_source_file = b.path("assets/fonts/open-sans/OpenSans-" ++ face ++ ".ttf") });
    }
    b.step("test-svg", "Check Zig SVG rasterization, resources, font styles and ABI ownership").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = svg_test_module })).step);
    const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
    // Keep the pinned submodule pristine; use a checked build-cache copy for
    // the two PNG compatibility corrections described in image-decoding.md.
    const image_sources = b.addWriteFiles();
    _ = image_sources.addCopyDirectory(b.path("modules/zignal/src"), "zignal", .{
        .exclude_extensions = &.{ "codecs/png.zig", "root.zig" },
    });
    const fix_png = b.addSystemCommand(&.{"python3"});
    fix_png.addFileArg(b.path("scripts/prepare-zignal.py"));
    fix_png.addFileArg(b.path("modules/zignal/src/codecs/png.zig"));
    _ = image_sources.addCopyFile(fix_png.addOutputFileArg("png.zig"), "zignal/codecs/png.zig");
    zignal.module("zignal").root_source_file = image_sources.addCopyFile(b.path("modules/zignal/src/root.zig"), "zignal/root.zig");
    const image_module = b.createModule(.{ .root_source_file = b.path("frontend/image-pixels.zig"), .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    image_module.addImport("zignal", zignal.module("zignal"));
    const image_library = b.addLibrary(.{ .name = "mdf-image", .linkage = .static, .root_module = image_module });
    image_library.bundle_compiler_rt = true;
    image_library.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, image_library, &visited);
    }
    b.installArtifact(image_library);
    const image_fixtures = b.addSystemCommand(&.{ "python3", "tests/image-fixtures.py" });
    const fixture_directory = image_fixtures.addOutputDirectoryArg("image-fixtures");
    const image_tests = b.createModule(.{ .root_source_file = b.path("frontend/image-pixels.zig"), .target = target, .optimize = optimize, .link_libc = true });
    image_tests.addImport("zignal", zignal.module("zignal"));
    inline for (.{ "png-4-8-0-0.png", "png-4-8-1-0.png", "png-2-16-1-1.png", "png-0-16-0-1.png", "bad-crc.bad", "huge-header.bad" }) |fixture| {
        image_tests.addAnonymousImport(fixture, .{ .root_source_file = fixture_directory.path(b, fixture) });
    }
    b.step("test-codecs", "Check Zignal image ownership, limits and PNG compatibility").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = image_tests, .filters = &.{"MDF image:"} })).step);
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
    const tested_core = b.createModule(.{ .root_source_file = b.path("src/tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for (core.root_module.import_table.keys(), core.root_module.import_table.values()) |name, module| tested_core.addImport(name, module);
    const tests_module = b.createModule(.{ .root_source_file = b.path("tests/unit.zig"), .target = target, .optimize = optimize, .link_libc = true });
    tests_module.addImport("mdf", tested_core);
    const unit_step = b.step("test", "Run application unit tests from tests/unit and the source modules");
    // Zig discovers test declarations in the root module. Run the original
    // source suite separately so importing its API cannot hide those tests.
    for ([_]*std.Build.Step.Compile{
        b.addTest(.{ .name = "mdf-core-tests", .root_module = tested_core }),
        b.addTest(.{ .name = "mdf-unit-tests", .root_module = tests_module }),
    }) |suite| {
        const run_suite = b.addRunArtifact(suite);
        // Reuse compiled artifacts, but execute the checks on every build.
        run_suite.has_side_effects = true;
        unit_step.dependOn(&run_suite.step);
    }
    const startup_native = b.addTranslateC(.{ .root_source_file = b.path("frontend/launcher-native.h"), .target = target, .optimize = optimize, .link_libc = true });
    const launcher_module = b.createModule(.{ .root_source_file = b.path("frontend/launcher.zig"), .target = target, .optimize = optimize, .link_libc = true });
    launcher_module.addImport("startup_native", startup_native.createModule());
    launcher_module.linkLibrary(core);
    const launcher = b.addExecutable(.{ .name = "mdf-launcher", .root_module = launcher_module });
    launcher.rdynamic = true;
    launcher.build_id = .sha1;
    launcher.bundle_compiler_rt = true;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, launcher, &visited);
        launcher.root_module.strip = false;
    }
    b.installArtifact(launcher);
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
    module.optimize = .fast;
    module.strip = true;
    module.omit_frame_pointer = true;
    module.unwind_tables = .none;
    for (module.import_table.values()) |imported| optimizeModule(b, imported, visited);
    for (module.link_objects.items) |object| switch (object) {
        .other_step => |dependency| optimizeArtifact(b, dependency, visited),
        else => {},
    };
}
