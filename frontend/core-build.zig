const std = @import("std");
pub fn build(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const release = optimize == .fast;
    const version = b.fmt("{s}.0", .{std.mem.trim(u8, @embedFile("../VERSION"), " \t\r\n")});
    _ = std.SemanticVersion.parse(version) catch @panic("VERSION must contain MAJOR.MINOR, such as 0.3");
    if (!std.mem.eql(u8, version, @import("../build.zig.zon").version))
        @panic("VERSION and build.zig.zon disagree; run make version-check for the required version");
    const app_version = b.addOptions();
    app_version.addOption([]const u8, "value", version);
    if(b.option(bool,"reference","Build the FLTK comparison worker library") orelse false) {
    const ui_native = b.addTranslateC(.{ .root_source_file = b.path("frontend/ui-native.h"), .target = target, .optimize = optimize });
    ui_native.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    var text_includes = std.mem.tokenizeAny(u8, b.run(&.{ "pkg-config", "--cflags-only-I", "pangocairo", "pangoft2", "fontconfig" }), " \t\r\n");
    while (text_includes.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I") and flag.len > 2)
            ui_native.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
    }
    const ui_workers_module = b.createModule(.{ .root_source_file = b.path("frontend/workers.zig"), .target = target,
        .optimize = optimize, .link_libc = true, .pic = true });
    ui_workers_module.addImport("ui_native", ui_native.createModule());
    const cairo_text_options = b.addOptions();
    cairo_text_options.addOption(bool, "ft2", false);
    ui_workers_module.addOptions("system_text_options", cairo_text_options);
    const ui_workers = b.addLibrary(.{ .name = "mdf-ui-workers", .linkage = .static, .root_module = ui_workers_module });
    ui_workers.bundle_compiler_rt = true;
    ui_workers.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, ui_workers, &visited);
    }
    b.installArtifact(ui_workers);
    }
    const native_workers_header=b.addTranslateC(.{.root_source_file=b.path("frontend/native-workers.h"),.target=target,.optimize=optimize});
    native_workers_header.addSystemIncludePath(.{.cwd_relative="/usr/include"});
    const native_workers_module=b.createModule(.{.root_source_file=b.path("frontend/native-workers.zig"),.target=target,.optimize=optimize,.link_libc=true,.pic=true});
    native_workers_module.addImport("ui_native",native_workers_header.createModule());
    const native_workers=b.addLibrary(.{.name="mdf-native-workers",.linkage=.static,.root_module=native_workers_module});
    native_workers.bundle_compiler_rt=true;
    native_workers.bundle_ubsan_rt=!release;
    if(release) {
        var visited:std.AutoHashMapUnmanaged(*std.Build.Module,void)=.empty;
        optimizeArtifact(b,native_workers,&visited);
    }
    // Build only the pinned library sources. Its standalone CLI build script
    // uses the retired b.args API; MDF does not need that CLI or C wrapper.
    const mvzr = b.dependency("mvzr", .{ .target = target, .optimize = optimize });
    const mvzr_module = mvzr.module("mvzr");
    const prepare_mvzr = b.addSystemCommand(&.{"python3"});
    prepare_mvzr.addFileArg(b.path("tools/scripts/prepare-mvzr.py"));
    prepare_mvzr.addFileArg(mvzr.path("src/mvzr.zig"));
    mvzr_module.root_source_file = prepare_mvzr.addOutputFileArg("mvzr.zig");
    const layout_config = b.addOptions();
    layout_config.addOption([]const u8, "version", "0.4.1");
    // Normalize a generated copy; the pinned submodule stays pristine.
    // Palette adjustments are documented in docs/architecture.md#images-and-diagrams.
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
    // Additive callback context for fallback selection. Keep the pinned module
    // pristine; see frontend/patches/zig-svg/README.md when updating it.
    const svg_sources = b.addWriteFiles();
    _ = svg_sources.addCopyDirectory(b.path("modules/zig-svg/src"), "svg", .{ .exclude_extensions = &.{"raster.zig"} });
    var svg_raster_source: []const u8 = @embedFile("../modules/zig-svg/src/raster.zig");
    for ([_][2][]const u8{
        .{ "    italic: bool = false,\n};\n\n/// How the caller supplies fonts.", "    italic: bool = false,\n    /// The decoded text run, borrowed for this resolver call.\n    text: []const u8 = \"\",\n};\n\n/// How the caller supplies fonts." },
        .{ "            .italic = shape.font_italic orelse false,", "            .italic = shape.font_italic orelse false,\n            .text = switch (shape.geometry) { .text => |run| run.utf8, else => \"\" }," },
    }) |change| {
        if (std.mem.count(u8, svg_raster_source, change[0]) != 1)
            std.debug.panic("zig-svg font callback changed; review the documented adapter", .{});
        svg_raster_source = std.mem.replaceOwned(u8, b.allocator, svg_raster_source, change[0], change[1]) catch @panic("OOM");
    }
    _ = svg_sources.add("svg/raster.zig", svg_raster_source);
    svg_dependency.module("svg").root_source_file = svg_sources.getDirectory().path(b, "svg/root.zig");
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
    // the two PNG compatibility corrections described in docs/architecture.md#images-and-diagrams.
    const image_sources = b.addWriteFiles();
    _ = image_sources.addCopyDirectory(b.path("modules/zignal/src"), "zignal", .{
        .exclude_extensions = &.{ "codecs/png.zig", "root.zig" },
    });
    const fix_png = b.addSystemCommand(&.{"python3"});
    fix_png.addFileArg(b.path("tools/scripts/prepare-zignal.py"));
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
    const image_fixtures = b.addSystemCommand(&.{"python3"});
    image_fixtures.addFileArg(b.path("tests/image-fixtures.py"));
    const fixture_directory = image_fixtures.addOutputDirectoryArg("image-fixtures");
    const image_tests = b.createModule(.{ .root_source_file = b.path("frontend/image-pixels.zig"), .target = target, .optimize = optimize, .link_libc = true });
    image_tests.addImport("zignal", zignal.module("zignal"));
    inline for (.{ "png-4-8-0-0.png", "png-4-8-1-0.png", "png-2-16-1-1.png", "png-0-16-0-1.png", "bad-crc.bad", "huge-header.bad",
        "gif-0-1-1-1.gif", "gif-0-1-1-1.gif.rgba", "bmp-24-1.bmp", "huge-gif.bad", "huge-bmp.bad" }) |fixture| {
        image_tests.addAnonymousImport(fixture, .{ .root_source_file = fixture_directory.path(b, fixture) });
    }
    b.step("test-codecs", "Check Zignal image ownership, limits and PNG compatibility").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = image_tests, .filters = &.{"MDF image:"} })).step);
    const entity_pack = b.addSystemCommand(&.{"python3"});
    entity_pack.addFileArg(b.path("tools/scripts/pack-entities.py"));
    entity_pack.addFileArg(b.path("assets/html-entities.tsv"));
    const entities = b.createModule(.{ .root_source_file = b.path("src/entities.zig"), .target = target, .optimize = optimize });
    entities.addAnonymousImport("html-entity-data", .{ .root_source_file = entity_pack.addOutputFileArg("html-entities.bin") });
    const mecha_sources = b.addWriteFiles();
    _ = mecha_sources.addCopyDirectory(b.path("modules/mecha/src"), "mecha/src", .{});
    const prepare_mecha = b.addSystemCommand(&.{"python3"});
    prepare_mecha.addFileArg(b.path("tools/scripts/prepare-mecha.py"));
    prepare_mecha.addFileArg(b.path("modules/mecha/mecha.zig"));
    const mecha = b.createModule(.{ .root_source_file = mecha_sources.addCopyFile(prepare_mecha.addOutputFileArg("mecha.zig"), "mecha/mecha.zig"), .target = target, .optimize = optimize });
    const prepare_markdown = b.addSystemCommand(&.{"python3"});
    prepare_markdown.addFileArg(b.path("tools/scripts/prepare-zigmark.py"));
    prepare_markdown.addDirectoryArg(b.path("modules/zigmark/src"));
    const markdown_sources = prepare_markdown.addOutputDirectoryArg("zigmark");
    prepare_markdown.addFileArg(b.path("frontend/patches/zigmark/0001-preserve-commonmark-lines-and-container-tabs.patch"));
    prepare_markdown.addFileArg(b.path("frontend/patches/zigmark/0002-preserve-fenced-code-container-content.patch"));
    prepare_markdown.addFileArg(b.path("frontend/patches/zigmark/0003-own-table-row-temporaries.patch"));
    prepare_markdown.addFileArg(b.path("frontend/patches/zigmark/0004-preserve-semantic-image-labels.patch"));
    prepare_markdown.addFileArg(b.path("frontend/patches/zigmark/0005-skip-impossible-reference-work.patch"));
    var markdown_modules: [2]*std.Build.Module = undefined;
    for (0..2) |index| {
        const options = b.addOptions();
        options.addOption(bool, "standard_frontmatter", true);
        options.addOption(bool, "disable_html_blocks", index == 0);
        const module = b.createModule(.{ .root_source_file = markdown_sources.path(b, "mdf.zig"), .target = target, .optimize = optimize });
        module.addOptions("mdf_options", options);
        module.addImport("mecha", mecha);
        module.addImport("html_entities", entities);
        markdown_modules[index] = module;
    }
    const markdown_cli_module = b.createModule(.{ .root_source_file = b.path("tests/markdown-html.zig"), .target = target, .optimize = optimize, .link_libc = true });
    markdown_cli_module.addImport("zigmark", markdown_modules[1]);
    const markdown_stdio = b.addTranslateC(.{ .root_source_file = b.path("tests/stdio.h"), .target = target, .optimize = optimize, .link_libc = true });
    markdown_cli_module.addImport("stdio", markdown_stdio.createModule());
    const markdown_cli = b.addExecutable(.{ .name = "mdf-markdown-html", .root_module = markdown_cli_module });
    // Exercise the same compiler backend and linker as production.
    markdown_cli.use_llvm = true;
    markdown_cli.use_lld = true;
    b.step("build-markdown-reference", "Build the Zigmark specification-test renderer").dependOn(&b.addInstallArtifact(markdown_cli, .{}).step);
    const native = b.addTranslateC(.{
        .root_source_file = b.path("src/native.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const c_module = native.createModule();
    const native_diagrams = b.step("build-native-modules", "Build private Zig diagram modules for the native frontend");
    for ([_]struct { name: []const u8, kind: u32, library: *std.Build.Step.Compile }{
        .{ .name = "mermaid", .kind = 1, .library = layout },
        .{ .name = "svg", .kind = 2, .library = svg_library },
        .{ .name = "image", .kind = 4, .library = image_library },
    }) |renderer| {
        const configuration = b.addOptions();
        configuration.addOption(u32, "kind", renderer.kind);
        const root = b.createModule(.{ .root_source_file = b.path(if (renderer.kind == 4) "frontend/native/image-module.zig" else "frontend/native/diagram-module.zig"),
            .target = target, .optimize = optimize, .link_libc = true, .pic = true });
        root.addImport("native", c_module);
        root.addOptions("diagram_options", configuration);
        root.linkLibrary(renderer.library);
        root.linkSystemLibrary("m", .{});
        const library = b.addLibrary(.{ .name = b.fmt("mdf-native-{s}", .{renderer.name}), .linkage = .dynamic, .root_module = root });
        library.use_lld=true;
        library.use_llvm=true;
        library.version_script = b.path(if (renderer.kind == 4) "frontend/image-module.map" else "frontend/diagram-module.map");
        library.linker_allow_shlib_undefined = false;
        library.bundle_compiler_rt = true;
        library.bundle_ubsan_rt = !release;
        if (release) {
            var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
            optimizeArtifact(b, library, &visited);
        }
        native_diagrams.dependOn(&b.addInstallArtifact(library, .{}).step);
    }
    const text_module = b.createModule(.{ .root_source_file = b.path("frontend/text-module.zig"),
        .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    const ft2_native=b.addTranslateC(.{.root_source_file=b.path("frontend/ui-native.h"),.target=target,.optimize=optimize});
    ft2_native.defineCMacro("MDF_TEXT_FT2_ONLY","1");
    ft2_native.addSystemIncludePath(.{.cwd_relative="/usr/include"});
    var ft2_includes=std.mem.tokenizeAny(u8,b.run(&.{"pkg-config","--cflags-only-I","pangoft2","fontconfig"})," \t\r\n");
    while(ft2_includes.next()) |flag| if(std.mem.startsWith(u8,flag,"-I") and flag.len>2)
        ft2_native.addSystemIncludePath(.{.cwd_relative=flag[2..]});
    text_module.addImport("ui_native", ft2_native.createModule());
    const ft2_options = b.addOptions();
    ft2_options.addOption(bool, "ft2", true);
    text_module.addOptions("system_text_options", ft2_options);
    const text_libdir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "pangoft2" }), " \t\r\n");
    text_module.addLibraryPath(.{ .cwd_relative = text_libdir });
    var text_libraries = std.mem.tokenizeAny(u8, b.run(&.{ "pkg-config", "--libs-only-l", "pangoft2", "fontconfig" }), " \t\r\n");
    while (text_libraries.next()) |flag| if (std.mem.startsWith(u8, flag, "-l")) text_module.linkSystemLibrary(flag[2..], .{});
    const text_library = b.addLibrary(.{ .name = "mdf-native-text", .linkage = .dynamic, .root_module = text_module });
    text_library.use_lld=true;
    text_library.use_llvm=true;
    text_library.version_script = b.path("frontend/text-module.map");
    text_library.linker_allow_shlib_undefined = false;
    text_library.bundle_compiler_rt = true;
    text_library.bundle_ubsan_rt = !release;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, text_library, &visited);
    }
    native_diagrams.dependOn(&b.addInstallArtifact(text_library, .{}).step);
    const native_preferences = b.createModule(.{ .root_source_file = b.path("src/settings.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_preferences.addImport("native", c_module);
    native_preferences.addImport("zigmark", markdown_modules[0]);
    native_preferences.addImport("html_entities", entities);
    const native_profile=b.createModule(.{.root_source_file=b.path("frontend/ui-profile.zig"),.target=target,.optimize=optimize});
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
    core.root_module.addImport("zigmark", markdown_modules[0]);
    core.root_module.addImport("html_entities", entities);
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
        const pack = b.addSystemCommand(&.{"python3"});
        pack.addFileArg(b.path("tools/scripts/pack-font.py"));
        pack.addFileArg(b.path(font.path));
        const resource = pack.addOutputFileArg(b.fmt("{s}.zlib", .{font.name}));
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
    tests_module.addAnonymousImport("html-entity-source", .{ .root_source_file = b.path("assets/html-entities.tsv") });
    const snapshot_module = b.createModule(.{ .root_source_file = b.path("tests/document-snapshot.zig"), .target = target, .optimize = optimize, .link_libc = true });
    snapshot_module.addImport("mdf", tested_core);
    const snapshot = b.addExecutable(.{ .name = "mdf-document-snapshot", .root_module = snapshot_module });
    b.step("build-document-snapshot", "Build the complete Markdown model comparison helper").dependOn(&b.addInstallArtifact(snapshot, .{}).step);
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
    launcher_module.addOptions("app_version", app_version);
    launcher_module.linkLibrary(core);
    const launcher = b.addExecutable(.{ .name = "mdf-launcher", .root_module = launcher_module });
    launcher.use_llvm=true;
    launcher.use_lld=true;
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
    // Kept outside the installed application until native UI parity passes.
    const native_renderer_module = b.createModule(.{ .root_source_file = b.path("frontend/native/render.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_renderer_module.addImport("native", c_module);
    native_renderer_module.addImport("ui_profile",native_profile);
    native_renderer_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    native_renderer_module.linkLibrary(core);
    native_renderer_module.linkLibrary(image_library);
    const native_renderer = b.addExecutable(.{ .name = "mdf-native-render", .root_module = native_renderer_module });
    native_renderer.bundle_compiler_rt = true;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, native_renderer, &visited);
    }
    b.step("build-native-renderer", "Build the offscreen z2d reader evaluation").dependOn(&b.addInstallArtifact(native_renderer, .{}).step);
    const protocol_root = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), " \t\r\n");
    const xdg_xml = b.fmt("{s}/stable/xdg-shell/xdg-shell.xml", .{protocol_root});
    const xdg_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xdg_xml });
    const xdg_header_file = xdg_header.addOutputFileArg("xdg-shell-client.h");
    const xdg_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xdg_xml });
    const xdg_code_file = xdg_code.addOutputFileArg("xdg-shell.c");
    const viewport_xml = b.fmt("{s}/stable/viewporter/viewporter.xml", .{protocol_root});
    const viewport_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", viewport_xml });
    const viewport_header_file = viewport_header.addOutputFileArg("viewporter-client.h");
    const viewport_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", viewport_xml });
    const viewport_code_file = viewport_code.addOutputFileArg("viewporter.c");
    const fractional_xml = b.fmt("{s}/staging/fractional-scale/fractional-scale-v1.xml", .{protocol_root});
    const fractional_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header", fractional_xml });
    const fractional_header_file = fractional_header.addOutputFileArg("fractional-scale-client.h");
    const fractional_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code", fractional_xml });
    const fractional_code_file = fractional_code.addOutputFileArg("fractional-scale.c");
    const wayland_native = b.addTranslateC(.{ .root_source_file = b.path("frontend/native/wayland.h"),
        .target = target, .optimize = optimize, .link_libc = true });
    wayland_native.addIncludePath(xdg_header_file.dirname());
    wayland_native.addIncludePath(viewport_header_file.dirname());
    wayland_native.addIncludePath(fractional_header_file.dirname());
    wayland_native.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    const native_window_module = b.createModule(.{ .root_source_file = b.path("frontend/native/window.zig"),
        .target = target, .optimize = optimize, .link_libc = true, .pic = true });
    native_window_module.addImport("native", c_module);
    native_window_module.addImport("ui_profile",native_profile);
    native_window_module.addImport("settings", native_preferences);
    native_window_module.addOptions("app_version", app_version);
    native_window_module.addImport("wayland", wayland_native.createModule());
    const input_native = b.addTranslateC(.{ .root_source_file = b.path("frontend/native/input.h"),
        .target = target, .optimize = optimize, .link_libc = true });
    input_native.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    native_window_module.addImport("input", input_native.createModule());
    native_window_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    native_window_module.addCSourceFile(.{ .file = xdg_code_file, .flags = &.{} });
    native_window_module.addCSourceFile(.{ .file = viewport_code_file, .flags = &.{} });
    native_window_module.addCSourceFile(.{ .file = fractional_code_file, .flags = &.{} });
    native_window_module.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
    native_window_module.linkSystemLibrary("wayland-client", .{});
    const wayland_libdir = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=libdir", "wayland-client" }), " \t\r\n");
    native_window_module.addLibraryPath(.{ .cwd_relative = wayland_libdir });
    native_window_module.linkLibrary(image_library);
    native_window_module.linkLibrary(native_workers);
    native_window_module.linkSystemLibrary("xkbcommon", .{});
    const native_entry=b.createModule(.{.root_source_file=b.path("frontend/native/entry.zig"),.target=target,.optimize=optimize,.link_libc=true});
    native_entry.addImport("native_window",native_window_module);
    native_entry.linkLibrary(core);
    const native_window = b.addExecutable(.{ .name = "mdf-native-window", .root_module = native_entry });
    native_window.bundle_compiler_rt = true;
    if (release) {
        var visited: std.AutoHashMapUnmanaged(*std.Build.Module, void) = .empty;
        optimizeArtifact(b, native_window, &visited);
    }
    b.step("build-native-window", "Build the native Wayland window evaluation").dependOn(&b.addInstallArtifact(native_window, .{}).step);
    const native_engine_root=b.createModule(.{.root_source_file=b.path("frontend/native/engine.zig"),.target=target,.optimize=optimize,.link_libc=true,.pic=true});
    native_engine_root.addImport("native_window",native_window_module);
    const native_engine=b.addLibrary(.{.name="mdf-native-ui",.linkage=.dynamic,.root_module=native_engine_root});
    native_engine.use_lld=true;
    native_engine.use_llvm=true;
    // Match the optimized link's existing symbols to its stripped packed copy.
    // Do not enable -fno-strip here: Zig 0.17 crashes compiling this UI root.
    native_engine.build_id=.sha1;
    native_engine.version_script=b.path("frontend/frontend.map");
    native_engine.bundle_compiler_rt=true;
    if(release) {
        var visited:std.AutoHashMapUnmanaged(*std.Build.Module,void)=.empty;
        optimizeArtifact(b,native_engine,&visited);
    }
    const native_engine_step=b.step("build-native-engine","Build the native private UI and minimal launcher");
    native_engine_step.dependOn(&b.addInstallArtifact(native_engine,.{}).step);
    native_engine_step.dependOn(&b.addInstallArtifact(launcher,.{}).step);
    const native_canvas_module = b.createModule(.{ .root_source_file = b.path("frontend/native/canvas.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_canvas_module.addImport("native", c_module);
    native_canvas_module.addImport("ui_profile",native_profile);
    native_canvas_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    const native_painter_tests = b.createModule(.{ .root_source_file = b.path("tests/native-painter.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_painter_tests.addImport("native_canvas", native_canvas_module);
    native_painter_tests.linkLibrary(core);
    const native_painter_run = b.addRunArtifact(b.addTest(.{ .root_module = native_painter_tests }));
    native_painter_run.has_side_effects = true;
    b.step("test-native-painter", "Check native ARGB painting, font ownership and text rasterization").dependOn(&native_painter_run.step);
    const native_shell_module = b.createModule(.{ .root_source_file = b.path("frontend/native/shell.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_shell_module.addImport("native", c_module);
    native_shell_module.addImport("ui_profile",native_profile);
    native_shell_module.addImport("settings", native_preferences);
    native_shell_module.addOptions("app_version", app_version);
    native_shell_module.addImport("z2d", svg_dependency.module("svg").import_table.get("z2d").?);
    const native_shell_tests = b.createModule(.{ .root_source_file = b.path("tests/native-shell.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_shell_tests.addImport("native_shell", native_shell_module);
    const native_shell_run = b.addRunArtifact(b.addTest(.{ .root_module = native_shell_tests }));
    native_shell_run.has_side_effects = true;
    b.step("test-native-shell", "Check native toolbar state and document/sidebar bounds").dependOn(&native_shell_run.step);
    const native_transfer_module = b.createModule(.{ .root_source_file = b.path("frontend/native/transfer.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_transfer_module.addImport("native", c_module);
    const native_transfer_tests = b.createModule(.{ .root_source_file = b.path("tests/native-transfer.zig"),
        .target = target, .optimize = optimize, .link_libc = true });
    native_transfer_tests.addImport("native_transfer", native_transfer_module);
    native_transfer_tests.addImport("native", c_module);
    native_transfer_tests.linkLibrary(core);
    const native_transfer_run = b.addRunArtifact(b.addTest(.{ .root_module = native_transfer_tests }));
    native_transfer_run.has_side_effects = true;
    b.step("test-native-transfer", "Check clipboard pipe ownership and nonblocking shutdown").dependOn(&native_transfer_run.step);
    const native_external_module = b.createModule(.{ .root_source_file=b.path("frontend/native/external.zig"),.target=target,.optimize=optimize,.link_libc=true });
    native_external_module.addImport("native",c_module);
    const native_external_tests = b.createModule(.{ .root_source_file=b.path("tests/native-external.zig"),.target=target,.optimize=optimize,.link_libc=true });
    native_external_tests.addImport("native_external",native_external_module);
    native_external_tests.addImport("native",c_module);
    const native_external_run=b.addRunArtifact(b.addTest(.{ .root_module=native_external_tests }));
    native_external_run.has_side_effects=true;
    b.step("test-native-external","Check URL handler spawning, errors and child ownership").dependOn(&native_external_run.step);
    const native_directory=b.createModule(.{.root_source_file=b.path("frontend/native/directory.zig"),.target=target,.optimize=optimize,.link_libc=true});
    native_directory.addImport("native",c_module);
    const native_directory_tests=b.createModule(.{.root_source_file=b.path("tests/native-directory.zig"),.target=target,.optimize=optimize,.link_libc=true});
    native_directory_tests.addImport("native_directory",native_directory);
    native_directory_tests.addImport("native",c_module);
    const native_directory_run=b.addRunArtifact(b.addTest(.{.root_module=native_directory_tests}));
    native_directory_run.has_side_effects=true;
    b.step("test-native-directory","Check bounded directory listing, worker ownership and cancellation").dependOn(&native_directory_run.step);
    // Zig 0.17 crashes compiling this compact entity reader with per-module
    // -fstrip. Keep its debug metadata through compilation; the existing
    // release packer still strips the final ELF. Optimization stays ReleaseFast.
    if (release) entities.strip = false;
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
