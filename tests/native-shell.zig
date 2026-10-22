const std = @import("std");
const ui = @import("native_shell");

test "native diagrams: natural scale is default and Fit adapts without enlarging small diagrams" {
    var state: ui.diagrams.State = .{};
    try std.testing.expectEqual(@as(f32, 1), state.factor(368, 880));
    state.apply(.fit, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 368.0 / 880.0), state.factor(368, 880), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), state.factor(440, 880), 0.00001);
    try std.testing.expectEqual(@as(f32, 1), state.factor(1000, 880));
    state.apply(.larger, state.factor(368, 880));
    try std.testing.expect(!state.fit and state.zoom > 368.0 / 880.0);
    for (0..100) |_| state.apply(.larger, state.zoom);
    try std.testing.expectEqual(@as(f32, 2), state.zoom);
    for (0..100) |_| state.apply(.smaller, state.zoom);
    try std.testing.expectEqual(@as(f32, 0.25), state.zoom);
    state.apply(.reset, state.zoom);
    try std.testing.expectEqual(@as(f32, 1), state.zoom);
}

test "native diagrams: controls wrap without overlap and retain distinct clickable actions" {
    for ([_]f32{ 30, 70, 100, 238, 368, 816 }) |width| {
        const controls = ui.diagrams.Controls.init(24, 100, width);
        for (controls.boxes, 0..) |box, i| {
            try std.testing.expect(box.x >= 24 and box.x + box.width <= 24 + width);
            try std.testing.expect(box.y >= 100 and box.y + box.height <= 100 + controls.height);
            try std.testing.expectEqual(@as(ui.diagrams.Action, @enumFromInt(i)), controls.hit(box.x + box.width / 2, box.y + 14).?);
            for (controls.boxes[0..i]) |previous|
                try std.testing.expect(box.x >= previous.x + previous.width or box.y >= previous.y + previous.height);
        }
        try std.testing.expect(controls.hit(0, 0) == null);
    }
    try std.testing.expectEqual(@as(f32, 32), ui.diagrams.Controls.init(24, 0, 238).height);
}

test "native path input: UTF-8 cursor selection replacement and forward delete preserve text" {
    var shell:ui.Shell=.{};
    shell.openDialog("a中é🙂z");
    shell.movePath(.home,false);shell.movePath(.right,false);shell.movePath(.right,true);
    try std.testing.expectEqualStrings("中",shell.selectedPath());
    shell.insertPath("X");
    try std.testing.expectEqualStrings("aXé🙂z",shell.path[0..shell.path_len]);
    shell.deletePath();
    try std.testing.expectEqualStrings("aX🙂z",shell.path[0..shell.path_len]);
    shell.movePath(.end,false);shell.movePath(.left,false);shell.backspacePath();
    try std.testing.expectEqualStrings("aXz",shell.path[0..shell.path_len]);
    shell.movePath(.home,false);shell.insertPath("prefix/");
    try std.testing.expectEqualStrings("prefix/aXz",shell.path[0..shell.path_len]);
    shell.selectPath();shell.insertPath("短.md");
    try std.testing.expectEqualStrings("短.md",shell.path[0..shell.path_len]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(shell.path[0..shell.path_len]));
}
test "native path input: rejected insertion leaves selection and the complete existing path intact" {
    var shell:ui.Shell=.{};
    const full:[4096]u8=@splat('a');shell.openDialog(&full);
    shell.movePath(.home,false);shell.movePath(.right,true);
    shell.insertPath("é");
    try std.testing.expectEqualStrings(&full,shell.path[0..shell.path_len]);
    try std.testing.expectEqualStrings("a",shell.selectedPath());
    shell.insertPath("z");
    try std.testing.expectEqual(@as(u8,'z'),shell.path[0]);
    shell.selectPath();shell.insertPath("invalid\x00path");
    try std.testing.expectEqual(@as(usize,4096),shell.selectedPath().len);
}

test "native frame: movement and resize cursor changes have no painted button highlight" {
    try std.testing.expect(ui.window_frame.control(.move)==.none);
    try std.testing.expect(ui.window_frame.control(.{.resize=.top_left})==.none);
    try std.testing.expect(ui.window_frame.control(.close)==.close);
}

test "native file dialog: path access survives short windows and the box stays below window controls" {
    for([_][2]i32{.{480,240},.{800,600},.{1040,780},.{6400,4000}}) |size| {
        const box=ui.Shell.fileBox(size[0],size[1]);
        var shell:ui.Shell=.{};
        try std.testing.expect(box.x>=0 and box.y>=28 and box.x+box.width<=size[0] and box.y+box.height<=size[1]);
        try std.testing.expect(ui.Shell.fileRows(size[0],size[1])<=12);
        try std.testing.expect(shell.fileHit(@floatFromInt(box.x+30),@floatFromInt(box.y+75),size[0],size[1])==.path);
        try std.testing.expect(shell.fileHit(@floatFromInt(box.x+box.width-70),@floatFromInt(box.y+box.height-35),size[0],size[1])==.open);
    }
    try std.testing.expectEqual(@as(usize,0),ui.Shell.fileRows(480,240));
}
test "native file dialog: scrolled rows retain their global index and scrollbar does not select a filename" {
    var entries:[100]ui.directory.Entry=@splat(.{.name=@constCast("a.md"),.directory=false});
    var listing:ui.directory.Listing=.{.allocator=std.testing.allocator,.path=@constCast("/tmp"),.entries=&entries};
    var shell:ui.Shell=.{.files=&listing,.file_first=40};
    const box=ui.Shell.fileBox(1040,780);
    const row=shell.fileHit(@floatFromInt(box.x+60),@floatFromInt(box.y+140+2*24+4),1040,780);
    try std.testing.expect(row==.row);
    try std.testing.expectEqual(@as(usize,42),row.row);
    const scrollbar=shell.fileHit(@floatFromInt(box.x+box.width-27),@floatFromInt(box.y+140+12*12),1040,780);
    try std.testing.expect(scrollbar==.scroll and scrollbar.scroll>0 and scrollbar.scroll<1);
    shell.files=null;
    try std.testing.expect(shell.fileHit(@floatFromInt(box.x+60),@floatFromInt(box.y+144),1040,780)==.none);
}

test "native minimap: sampling is bounded for huge documents without arithmetic overflow" {
    try std.testing.expectEqual(@as(usize,1),ui.minimap.sampleStride(0,100));
    try std.testing.expectEqual(@as(usize,1),ui.minimap.sampleStride(100,100));
    try std.testing.expectEqual(@as(usize,2),ui.minimap.sampleStride(101,100));
    const total=std.math.maxInt(usize);
    const stride=ui.minimap.sampleStride(total,1024);
    try std.testing.expect((total-1)/stride+1<=1024);
    try std.testing.expectEqual(@as(usize,17),ui.minimap.sampleStride(17,0));
}
test "native minimap: line placement spans the document and excludes hidden blocks" {
    try std.testing.expect(ui.minimap.lineBaseline(0,0,1000,600,0,1,4)==null);
    try std.testing.expect(ui.minimap.lineBaseline(0,20,1000,600,1,1,4)==null);
    const first=ui.minimap.lineBaseline(0,100,1000,600,0,4,4).?;
    const last=ui.minimap.lineBaseline(900,100,1000,600,3,4,4).?;
    try std.testing.expect(first>0 and first<60 and last>540 and last<=600);
}
test "native minimap: scrollbar and selector use a fixed ten-percent track height" {
    try std.testing.expectEqual(@as(i32,64),ui.thumbHeight(682));
    try std.testing.expectEqual(@as(i32,12),ui.thumbHeight(142));
    try std.testing.expectEqual(@as(i32,1),ui.thumbHeight(20));
}

test "native scale: fractional preference wins only with a viewport and integers retain output fallback" {
    var scale: ui.scaling.Policy = .{ .output = 2 };
    try std.testing.expectEqual(@as(u32, 240), scale.units());
    scale.preferred = 3;
    try std.testing.expectEqual(@as(u32, 360), scale.units());
    scale.fractional = 150;
    try std.testing.expectEqual(@as(u32, 360), scale.units());
    scale.viewport = true;
    try std.testing.expectEqual(@as(u32, 150), scale.units());
    try std.testing.expectEqual(@as(u32, 2), scale.cursorScale());
    scale.fractional = 960;
    try std.testing.expectEqual(@as(u32, 8), scale.cursorScale());
    scale.fractional = 9999; scale.preferred = 0;
    try std.testing.expectEqual(@as(u32, 240), scale.units());
    scale.viewport = false; scale.buffer_scale = false;
    try std.testing.expectEqual(@as(u32, 120), scale.units());
}

test "native frame: controls, body and protocol resize edges have distinct regions" {
    const f = ui.window_frame;
    try std.testing.expectEqual(@as(u32, 5), @intFromEnum(f.hit(1, 1, 800, 600, false).resize));
    try std.testing.expectEqual(@as(u32, 10), @intFromEnum(f.hit(799, 599, 800, 600, false).resize));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(f.hit(1, 200, 800, 600, false).resize));
    try std.testing.expectEqual(std.meta.Tag(f.Hit).close, std.meta.activeTag(f.hit(785, 14, 800, 600, false)));
    try std.testing.expectEqual(std.meta.Tag(f.Hit).maximize, std.meta.activeTag(f.hit(755, 14, 800, 600, true)));
    try std.testing.expectEqual(std.meta.Tag(f.Hit).minimize, std.meta.activeTag(f.hit(725, 14, 800, 600, false)));
    try std.testing.expectEqual(std.meta.Tag(f.Hit).move, std.meta.activeTag(f.hit(450, 14, 800, 600, false)));
    for ([_][2]f32{ .{20,14}, .{300,100}, .{0,0}, .{-1,100}, .{800,200}, .{std.math.nan(f32),10} }) |point|
        try std.testing.expectEqual(std.meta.Tag(f.Hit).none, std.meta.activeTag(f.hit(point[0], point[1], 800, 600, true)));
    try std.testing.expectEqual(f.cursors.Kind.nesw, f.cursor(.{ .resize = .top_right }));
    try std.testing.expectEqual(f.cursors.Kind.vertical, f.cursor(.{ .resize = .bottom }));
}
test "native frame: double clicks consume a pair and tolerate timestamp wrap" {
    var clicks: ui.window_frame.Clicks = .{};
    try std.testing.expect(!clicks.press(100));
    try std.testing.expect(clicks.press(300));
    try std.testing.expect(!clicks.press(400));
    try std.testing.expect(!clicks.press(900));
    try std.testing.expect(!clicks.press(0));
    try std.testing.expect(!clicks.press(std.math.maxInt(u32) - 50));
    try std.testing.expect(clicks.press(60));
}
test "native cursors: distinct masks have bounded opaque ink and transparent backgrounds" {
    const cursor = ui.window_frame.cursors;
    var hashes: [cursor.count]u64 = undefined;
    inline for (@typeInfo(cursor.Kind).@"enum".field_names, 0..) |name, i| {
        const kind = @field(cursor.Kind, name);
        var pixels: [cursor.size * cursor.size]u32 = undefined;
        cursor.render(kind, &pixels);
        var ink: usize = 0; var white: usize = 0;
        for (pixels) |value| {
            if (value != 0) { ink += 1; try std.testing.expectEqual(@as(u32, 255), value >> 24); }
            if (value == 0xffffffff) white += 1;
        }
        try std.testing.expect(ink > 20 and ink < 400 and white > 5);
        try std.testing.expectEqual(@as(u32, 0), pixels[0]);
        const hotspot = cursor.hotspot(kind);
        try std.testing.expect(hotspot[0] >= 0 and hotspot[0] < cursor.size and hotspot[1] >= 0 and hotspot[1] < cursor.size);
        hashes[i] = std.hash.Wyhash.hash(0, std.mem.asBytes(&pixels));
        for (hashes[0..i]) |old| try std.testing.expect(old != hashes[i]);
    }
}

test "native shell: initial panes preserve original document bounds" {
    const shell: ui.Shell = .{};
    const bounds = shell.layout(1040, 780);
    try std.testing.expectEqual(@as(i32, 220), bounds.left);
    try std.testing.expectEqual(@as(i32, 124), bounds.right);
    try std.testing.expectEqual(@as(i32, 676), bounds.width);
    try std.testing.expectEqual(@as(i32, 682), bounds.height);
    try std.testing.expect(shell.wrap);
}
test "native shell: no-wrap bar uses body width and twenty pixels of body height" {
    var shell: ui.Shell = .{};
    const wrapped = shell.layout(1040, 780);
    shell.apply(.wrap);
    const unwrapped = shell.layout(1040, 780);
    try std.testing.expectEqual(wrapped.width, unwrapped.width);
    try std.testing.expectEqual(wrapped.height - 20, unwrapped.height);
    shell.apply(.toc);
    shell.apply(.preview);
    try std.testing.expectEqual(@as(i32, 1020), shell.layout(1040, 780).width);
}

test "native shell: table overflow reserves a body bar without disabling wrap" {
    var shell: ui.Shell = .{};
    const normal = shell.layout(480, 780);
    shell.horizontal_overflow = true;
    const overflowing = shell.layout(480, 780);
    try std.testing.expect(shell.wrap and shell.horizontalVisible());
    try std.testing.expectEqual(normal.width, overflowing.width);
    try std.testing.expectEqual(normal.left, overflowing.left);
    try std.testing.expectEqual(normal.right, overflowing.right);
    try std.testing.expectEqual(normal.height - 20, overflowing.height);
    shell.horizontal_overflow = false;
    try std.testing.expect(!shell.horizontalVisible());
}
test "native shell: controls have distinct hit regions and preserve font bounds" {
    var shell: ui.Shell = .{};
    try std.testing.expectEqual(ui.Action.wrap, shell.actionAt(310, 48, 1040));
    try std.testing.expectEqual(ui.Action.reset, shell.actionAt(225, 48, 1040));
    try std.testing.expectEqual(ui.Action.none, shell.actionAt(225, 70, 1040));
    for (0..100) |_| shell.apply(.larger);
    try std.testing.expectEqual(@as(i32, 72), shell.points);
    for (0..100) |_| shell.apply(.smaller);
    try std.testing.expectEqual(@as(i32, 8), shell.points);
    shell.apply(.reset);
    try std.testing.expectEqual(@as(i32, 12), shell.points);
}
test "native shell: canonical preferences preserve every option and preset defaults" {
    const stored: ui.preferences.Values = .{ .theme = .paper, .font_size = 18, .dark_mode = true,
        .line_wrap = false, .show_toc = false, .show_preview = false, .max_width = .percent_100,
        .auto_reload = false, .save_settings_across_sessions = true, .window = .{ .width = 800, .height = 600, .maximized = true } };
    var shell: ui.Shell = .{};
    shell.load(stored);
    try std.testing.expectEqualDeep(stored, shell.values(stored.window));
    shell.apply(.reset);
    try std.testing.expectEqual(@as(i32, 14), shell.points);
    shell.theme = .terminal;
    shell.apply(.reset);
    try std.testing.expectEqual(@as(i32, 11), shell.points);
    shell.apply(.width);
    try std.testing.expectEqual(@as(u32, 1), shell.width_mode);
    shell.apply(.width);
    try std.testing.expectEqual(@as(u32, 2), shell.width_mode);
}
test "native shell: path editing respects selection, UTF-8 boundaries and fixed capacity" {
    var shell: ui.Shell = .{};
    shell.openDialog("original.md");
    shell.insertPath("\t");
    try std.testing.expectEqualStrings("original.md", shell.path[0..shell.path_len]);
    shell.insertPath("café.md");
    for (0..4) |_| shell.backspacePath();
    try std.testing.expectEqualStrings("caf", shell.path[0..shell.path_len]);
    const huge: [4097]u8 = @splat('x');
    shell.insertPath(&huge);
    try std.testing.expectEqualStrings("caf", shell.path[0..shell.path_len]);
    shell.path_selected = true;
    shell.backspacePath();
    try std.testing.expectEqual(@as(usize, 0), shell.path_len);
    shell.insertPath("\xff");
    try std.testing.expectEqual(@as(usize, 0), shell.path_len);
}
test "native menus: pointer commands and keyboard scrolling stay in window bounds" {
    var menu: ui.menus.Menu = .{};
    try std.testing.expect(menu.press(160, 14, 420, 240).handled);
    const box = menu.bounds(420, 240);
    try std.testing.expect(box.x >= 0 and box.x + box.width <= 420);
    const picked = menu.press(@floatFromInt(box.x + 40), 71, 420, 240);
    try std.testing.expectEqual(ui.preferences.Preset.paper, picked.command.?.theme);
    try std.testing.expectEqual(@as(?ui.menus.Title, null), menu.opened);
    _ = menu.press(110, 14, 420, 240);
    menu.move(-1, 420, 240);
    try std.testing.expect(menu.first > 0);
    menu.fit(1040, 780);
    try std.testing.expectEqual(@as(usize, 0), menu.first);
    try std.testing.expectEqual(@as(i32, 72), menu.accept().?.size);
    _ = menu.press(60, 14, 1040, 780);
    try std.testing.expect(menu.press(600, 650, 1040, 780).handled);
    try std.testing.expectEqual(@as(?ui.menus.Title, null), menu.opened);
}
