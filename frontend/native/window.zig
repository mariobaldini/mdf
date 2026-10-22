//! First Wayland presentation evaluation for the native painter. The shipping
//! frontend remains unchanged until controls and deferred resources pass parity.
const std = @import("std");
const trace=@import("ui_profile");
const Waits=@import("profile.zig").Waits;
pub const c = @import("native");
const wl = @import("wayland");
const input = @import("input");
const paint = @import("canvas.zig");
const reader = @import("reader.zig");
const shell = @import("shell.zig");
const Clipboard = @import("clipboard.zig").Clipboard;
const Assets = @import("assets.zig").Assets;
const FontRuntime = @import("font-runtime.zig").Runtime;
const window_frame = @import("frame.zig");
const CursorSet = @import("cursor.zig").Set;
const DisplayScale = @import("display-scale.zig").Scale;
const Minimap = @import("minimap.zig");
const External = @import("external.zig").Launcher;
const Directory=@import("directory.zig");
const a = std.heap.c_allocator;
var active: std.atomic.Value(?*Window) = .init(null);
fn wake() callconv(.c) void {
    const self = active.load(.acquire) orelse return;
    var value: u64 = 1;
    _ = c.write(self.wake_fd, &value, @sizeOf(u64));
}
const Window = struct {
    const KeyEvent = union(enum) {
        key: struct { key: u32, state: u32, serial: u32 = 0 },
        modifiers: struct { depressed: u32, latched: u32, locked: u32, group: u32 },
        leave,
    };
    const Buffer = struct {
        buffer: ?*wl.wl_buffer = null,
        memory: ?*anyopaque = null,
        size: usize = 0,
        fd: c_int = -1,
        busy: bool = false,
        width: i32 = 0,
        height: i32 = 0,

        fn deinit(self: *Buffer) void {
            if (self.buffer) |value| wl.wl_buffer_destroy(value);
            if (self.memory) |value| _ = c.munmap(value, self.size);
            if (self.fd >= 0) _ = c.close(self.fd);
            self.* = .{};
        }
    };
    core: *c.MdfCore,
    display: *wl.wl_display,
    registry: ?*wl.wl_registry = null,
    compositor: ?*wl.wl_compositor = null,
    shm: ?*wl.wl_shm = null,
    wm: ?*wl.xdg_wm_base = null,
    dpi: DisplayScale = .{},
    surface: ?*wl.wl_surface = null,
    xdg: ?*wl.xdg_surface = null,
    toplevel: ?*wl.xdg_toplevel = null,
    buffers: [2]Buffer = @splat(.{}),
    last_buffer: usize = 0,
    callback: ?*wl.wl_callback = null,
    seat: ?*wl.wl_seat = null,
    pointer: ?*wl.wl_pointer = null,
    cursors: CursorSet = .{},
    frame_hover: window_frame.Hit = .none,
    pointer_inside: bool = false,
    click_time: u32 = 0,
    title_clicks: window_frame.Clicks = .{},
    keyboard: ?*wl.wl_keyboard = null,
    keyboard_worker: ?*anyopaque = null,
    keyboard_value: input.MdfPreparedKeyboard = std.mem.zeroes(input.MdfPreparedKeyboard),
    keyboard_pending: bool = false,
    keyboard_failed: bool = false,
    clipboard: Clipboard = .{},
    browser: Directory.Browser = .{},
    browser_initial: bool = false,
    file_drag: bool = false,
    path_drag: bool = false,
    file_clicks: window_frame.Clicks = .{},
    external: External = .{},
    pending_fragment: []u8 = &.{},
    fragment_revision: u64 = 0,
    last_serial: u32 = 0,
    test_clipboard: bool = false,
    test_paste: bool = false,
    test_browser: bool = false,
    browser_stage: u32 = 0,
    browser_base_revision: u64 = 0,
    browser_scrolled: bool = false,
    test_drop: bool = false,
    drop_stage: u32 = 0,
    paste_stage: u32 = 0,
    clipboard_started: bool = false,
    assets: Assets = .{},
    fonts: FontRuntime = .{},
    minimap: Minimap.Manager = .{},
    minimap_error_shown: bool = false,
    painted_minimap: u64 = 0,
    first_viewport_minimap: bool = false,
    test_minimap: bool = false,
    test_links: bool = false,
    link_stage: u32 = 0,
    minimap_dragged: bool = false,
    minimap_drag_jobs: usize = 0,
    font_document: u64 = 0,
    font_ui_hash: u64 = 0,
    font_asset_version: u64 = 0,
    painted_fonts: u64 = 0,
    font_error_shown: bool = false,
    first_viewport_mono: bool = false,
    first_viewport_fallback: bool = false,
    assets_dark: bool = false,
    painted_assets: u64 = 0,
    ready_mode: bool = false,
    profiling: bool = false,
    recording: bool = false,
    startup_profile: c.Buffer = .{.ptr=null,.len=0},
    startup_paints: usize = 0,
    startup_font_styles: u32 = 0,
    scroll_profile: bool = false,
    scroll_values: [80]f64 = undefined,
    scroll_count: usize = 0,
    scroll_sampling: bool = false,
    scroll_restore: bool = false,
    scroll_original: f32 = 0,
    scroll_revision: u64 = 0,
    capture_done: bool = false,
    waits: Waits = .{},
    ready_ns: u64 = 0,
    backend_ns: u64 = 0,
    read_ns: u64 = 0,
    parse_ns: u64 = 0,
    source_bytes: usize = 0,
    ready_usage: @TypeOf(c.mdf_get_profile_usage())=std.mem.zeroes(@TypeOf(c.mdf_get_profile_usage())),
    asset_jump_done: bool = false,
    anchor_painted: bool = true,
    asset_theme_test: bool = false,
    asset_theme_done: bool = false,
    keys: std.ArrayList(KeyEvent) = .empty,
    canvas: ?*paint.Canvas = null,
    chrome: ?*paint.Canvas = null,
    content: ?*reader.Reader = null,
    ui: shell.Shell = .{},
    full_ui: bool = false,
    path: []const u8 = "",
    document_revision: u64 = 0,
    painted_revision: u64 = 0,
    painted_width: i32 = 0,
    painted_height: i32 = 0,
    painted_scale: u32 = 120,
    first_viewport_scale: u32 = 120,
    test_menu: bool = false,
    menu_stage: u32 = 0,
    test_preferences: bool = false,
    test_watch: bool = false,
    watch_started: bool = false,
    automatic_reloads: usize = 0,
    restore_anchor: ?usize = null,
    restore_delta: f32 = 0,
    restore_horizontal: f32 = 0,
    test_toolbar: bool = false,
    test_table: bool = false,
    table_stage: u32 = 0,
    test_diagram: bool = false,
    diagram_stage: u32 = 0,
    diagram_pixels: [*c]u8 = null,
    diagram_version: u64 = 0,
    diagram_threads: usize = 0,
    toolbar_pan_done: bool = false,
    test_resize: bool = false,
    test_frame: bool = false,
    test_first_dirty: bool = false,
    frame_stage: u32 = 0,
    resize_stage: u32 = 0,
    resized_width: i32 = 0,
    resized_height: i32 = 0,
    ui_drag: bool = false,
    wake_fd: c_int,
    width: i32 = 1020,
    height: i32 = 682,
    normal_width: i32 = 1020,
    normal_height: i32 = 682,
    constrained: bool = false,
    initial_maximized: bool = false,
    configured: bool = false,
    document_ready: bool = false,
    committed: bool = false,
    running: bool = true,
    interactive: bool = false,
    test_scroll: bool = false,
    test_selection: bool = false,
    test_details: bool = false,
    test_keyboard: bool = false,
    keyboard_test_done: bool = false,
    detail_index: ?usize = null,
    detail_initial: bool = false,
    detail_document_flags: u32 = 0,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_pressed: bool = false,
    dirty: bool = true,
    frame_pending: bool = false,
    paints: usize = 0,
    failure: ?anyerror = null,
    capture: ?[*:0]const u8,
    capture_anchor: []const u8 = "",
    fail_load: bool = false,
    began: u64,
    configured_ns: u64 = 0,
    committed_ns: u64 = 0,
    flushed_ns: u64 = 0,
    flushed_revision: u64 = 0,
    frame_ns: u64 = 0,

    fn mark(self:*Window,comptime name:[]const u8,at:u64) void {
        if(self.recording) c.mdf_profile_signal(0,name.ptr,name.len,@src().file.ptr,@src().file.len,@src().line,at);
    }

    fn registryGlobal(data: ?*anyopaque, registry: ?*wl.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const kind = std.mem.span(interface);
        if (std.mem.eql(u8, kind, "wl_compositor")) {
            self.compositor = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, @min(version, 6)));
        } else if (std.mem.eql(u8, kind, "wl_shm")) {
            self.shm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, 1));
            _ = wl.wl_shm_add_listener(self.shm, &shm_listener, self);
        } else if (std.mem.eql(u8, kind, "xdg_wm_base")) {
            self.wm = @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, @min(version, 3)));
            _ = wl.xdg_wm_base_add_listener(self.wm, &wm_listener, self);
        } else if (std.mem.eql(u8, kind, "wl_data_device_manager") and (self.interactive or self.profiling or self.test_clipboard or self.test_paste or self.test_drop)) {
            self.clipboard.manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_data_device_manager_interface, @min(version, 3)));
        } else if (std.mem.eql(u8, kind, "wl_seat") and (self.interactive or self.profiling or self.test_keyboard or self.test_clipboard or self.test_paste or self.test_drop or self.test_menu or self.test_frame)) {
            self.seat = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, @min(version, 5)));
            _ = wl.wl_seat_add_listener(self.seat, &seat_listener, self);
        }
        self.dpi.bind(registry.?, name, kind, version);
        self.clipboard.attach(self.seat);
    }
    fn registryRemove(data: ?*anyopaque, _: ?*wl.wl_registry, name: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?)); self.dpi.remove(name);
    }
    fn format(_: ?*anyopaque, _: ?*wl.wl_shm, _: u32) callconv(.c) void {}
    fn surfaceEnter(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?)); self.dpi.enter(output, true);
    }
    fn surfaceLeave(data: ?*anyopaque, _: ?*wl.wl_surface, output: ?*wl.wl_output) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?)); self.dpi.enter(output, false);
    }
    fn surfaceScale(data: ?*anyopaque, _: ?*wl.wl_surface, factor: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?)); self.dpi.preferred(factor);
    }
    fn surfaceTransform(_: ?*anyopaque, _: ?*wl.wl_surface, _: u32) callconv(.c) void {}
    fn scaleChanged(data: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(data.?)); self.dirty = true; self.updateCursor(0);
    }
    fn release(data: ?*anyopaque, _: ?*wl.wl_buffer) callconv(.c) void {
        const buffer: *Buffer = @ptrCast(@alignCast(data.?));
        buffer.busy = false;
    }
    fn seatCapabilities(data: ?*anyopaque, seat: ?*wl.wl_seat, capabilities: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (capabilities & wl.WL_SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            self.pointer = wl.wl_seat_get_pointer(seat);
            _ = wl.wl_pointer_add_listener(self.pointer, &pointer_listener, self);
        }
        if (capabilities & wl.WL_SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            self.keyboard = wl.wl_seat_get_keyboard(seat);
            _ = wl.wl_keyboard_add_listener(self.keyboard, &keyboard_listener, self);
            const locale: [*c]const u8 = c.getenv("LC_ALL") orelse c.getenv("LC_CTYPE") orelse c.getenv("LANG") orelse @as([*c]const u8, "C.UTF-8");
            self.keyboard_worker = input.mdf_keyboard_create(locale, wake, 0, @intFromBool(self.profiling));
            self.keyboard_failed=self.keyboard_worker==null;
        }
    }
    fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}
    fn pointerEnter(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, _: ?*wl.wl_surface, x: i32, y: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (serial != 0) self.last_serial = serial;
        self.mouse_x = @as(f32, @floatFromInt(x)) / 256;
        self.mouse_y = @as(f32, @floatFromInt(y)) / 256;
        self.pointer_inside = true;
        self.updateCursor(serial);
    }
    fn pointerLeave(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_inside = false;
        self.cursors.leave();
        if (std.meta.activeTag(self.frame_hover) != .none) self.dirty = true;
        self.frame_hover = .none;
    }
    fn pointerMotion(data: ?*anyopaque, pointer: ?*wl.wl_pointer, _: u32, x: i32, y: i32) callconv(.c) void {
        pointerEnter(data, pointer, 0, null, x, y);
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.mouse_pressed) self.pointerAction(1);
        if (self.full_ui and self.ui.modal == .none and self.ui.menu.hover(self.mouse_x, self.mouse_y, self.width, self.height)) self.dirty = true;
    }
    fn pointerButton(data: ?*anyopaque, _: ?*wl.wl_pointer, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void {
        if (button != 0x110) return; // Linux BTN_LEFT
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.last_serial = serial;
        self.click_time = time;
        self.mouse_pressed = state == wl.WL_POINTER_BUTTON_STATE_PRESSED;
        if(self.test_drop) {
            if(self.drop_stage==0 and self.mouse_pressed) {
                const uri=c.getenv("MDF_NATIVE_TEST_DROP") orelse { self.failure=error.DropTestPathMissing; return; };
                self.clipboard.testDrop(self.surface.?,serial,std.mem.span(uri)) catch |err| { self.failure=err; self.running=false; return; };
                self.drop_stage=1;
            }
            return;
        }
        self.pointerAction(if (self.mouse_pressed) 0 else 2);
    }
    fn updateCursor(self: *Window, serial: u32) void {
        if (!self.interactive and !self.profiling and !self.test_frame) return;
        if (!self.pointer_inside) return;
        const pointer = self.pointer orelse return;
        const compositor = self.compositor orelse return;
        const shm = self.shm orelse return;
        const target: window_frame.Hit = if (self.full_ui) window_frame.hit(self.mouse_x, self.mouse_y, self.width, self.height, self.constrained) else .none;
        if (window_frame.control(target) != window_frame.control(self.frame_hover)) self.dirty = true;
        self.frame_hover = target;
        var kind = window_frame.cursor(target);
        if(self.ui.modal==.open) kind=switch(self.ui.fileHit(self.mouse_x,self.mouse_y,self.width,self.height)) {.path=>.text,.none=>.arrow,else=>.hand};
        if (std.meta.activeTag(target) == .none and self.ui.menu.opened == null and self.ui.modal == .none) {
            const bounds = self.ui.layout(self.width, self.height);
            const x = self.mouse_x - (if (self.full_ui) @as(f32, @floatFromInt(bounds.x)) else 0);
            const y = self.mouse_y - (if (self.full_ui) @as(f32, @floatFromInt(bounds.y)) else 0);
            if (self.content) |content| if (x >= 0 and y >= 0 and x < @as(f32, @floatFromInt(content.canvas.logical_width)) and y < @as(f32, @floatFromInt(content.canvas.logical_height))) {
                kind = .text;
                if (content.diagramAt(x, y)) |diagram| {
                    kind = if (diagram.action != null) .hand else .horizontal;
                } else if (content.hit(x, y) catch null) |target_text| if (target_text.link.len > 0) { kind = .hand; };
            };
        }
        self.cursors.apply(compositor, shm, pointer, serial, kind, self.dpi.cursorScale()) catch |err| {
            self.ui.message(@errorName(err)); self.dirty = true;
        };
    }
    fn frameAction(self: *Window, action: window_frame.Hit) !bool {
        if (std.meta.activeTag(action) != .move) self.title_clicks = .{};
        switch (action) {
            .none => return false,
            .close => try self.command(.quit),
            .minimize => wl.xdg_toplevel_set_minimized(self.toplevel),
            .maximize => {
                if (self.constrained) wl.xdg_toplevel_unset_maximized(self.toplevel)
                else wl.xdg_toplevel_set_maximized(self.toplevel);
            },
            .move => {
                const double = self.title_clicks.press(self.click_time);
                if (double) return self.frameAction(.maximize);
                if (self.seat != null and self.last_serial != 0) wl.xdg_toplevel_move(self.toplevel, self.seat, self.last_serial);
            },
            .resize => |edge| if (self.seat != null and self.last_serial != 0)
                wl.xdg_toplevel_resize(self.toplevel, self.seat, self.last_serial, @intFromEnum(edge)),
        }
        self.ui.menu.opened = null;
        return true;
    }
    fn exerciseFrame(self: *Window) !void {
        if (self.frame_stage == 0) {
            if (self.cursors.commits == 0) { self.dirty = true; return; }
            self.content.?.selectAll();
            _ = try self.frameAction(window_frame.hit(@floatFromInt(self.width - 45), 14, self.width, self.height, self.constrained));
            self.frame_stage = 1;
        } else if (self.frame_stage == 1 and self.constrained and
            self.painted_width == self.width and self.painted_height == self.height) {
            self.resized_width = self.width; self.resized_height = self.height;
            _ = try self.frameAction(window_frame.hit(@floatFromInt(self.width - 45), 14, self.width, self.height, self.constrained));
            self.frame_stage = 2;
        } else if (self.frame_stage == 2 and !self.constrained and self.width == 800 and self.height == 600 and
            self.painted_width == self.width and self.painted_height == self.height) {
            self.frame_stage = 3;
            _ = try self.frameAction(window_frame.hit(@floatFromInt(self.width - 15), 14, self.width, self.height, self.constrained));
        }
    }
    fn pointerAction(self: *Window, event: u32) void {
        const content = self.content orelse return;
        var x = self.mouse_x;
        var y = self.mouse_y;
        if (self.full_ui) {
            if (event == 0) {
                const handled = self.frameAction(window_frame.hit(x, y, self.width, self.height, self.constrained)) catch |err| {
                    self.failure = err; self.running = false; return;
                };
                if (handled) { self.mouse_pressed = false; self.ui_drag = false; return; }
            }
            if (self.ui.modal != .none) {
                if(self.ui.modal==.open) {
                    self.filePointer(event) catch |err| { self.failure=err; self.running=false; };
                    return;
                }
                if (event == 0) {
                    const box = shell.Shell.modalBox(self.width, self.height);
                    if (x >= @as(f32, @floatFromInt(box.x + box.width - 106)) and x < @as(f32, @floatFromInt(box.x + box.width - 20)) and
                        y >= @as(f32, @floatFromInt(box.y + box.height - 48)) and y < @as(f32, @floatFromInt(box.y + box.height - 18)))
                    {
                        self.keyAction(input.XKB_KEY_Return, false) catch |err| {
                            self.failure = err;
                            self.running = false;
                        };
                    }
                }
                return;
            }
            if (event == 0) {
                const result = self.ui.menu.press(x, y, self.width, self.height);
                if (result.handled) {
                    if (result.command) |cmd| self.command(cmd) catch |err| {
                        self.failure = err;
                        self.running = false;
                    };
                    self.mouse_pressed = false;
                    self.dirty = true;
                    return;
                }
                const action = self.ui.actionAt(x, y, self.width);
                if (action != .none) {
                    self.ui.apply(action);
                    self.updateSettings() catch |err| {
                        self.failure = err;
                        self.running = false;
                    };
                    self.mouse_pressed = false;
                    self.dirty = true;
                    return;
                }
                if (self.ui.headingAt(self.core, x, y, self.width, self.height)) |index| {
                    content.jump(reader.bytes(c.mdf_core_block(self.core, index).anchor));
                    self.mouse_pressed = false;
                    self.dirty = true;
                    return;
                }
            }
            if ((event == 0 or self.ui_drag) and (self.ui.scrollAt(content, x, y, self.width, self.height) or self.ui.horizontalAt(content, x, y, self.width, self.height))) {
                self.ui_drag = event != 2;
                self.dirty = true;
                return;
            }
            if (event == 2) self.ui_drag = false;
            const bounds = self.ui.layout(self.width, self.height);
            x -= @floatFromInt(bounds.x);
            y -= @floatFromInt(bounds.y);
            if (x < 0 or x >= @as(f32, @floatFromInt(bounds.width)) or y < 0 or y >= @as(f32, @floatFromInt(bounds.height))) return;
        }
        const link = content.pointer(event, x, y) catch |err| {
            self.failure = err;
            self.running = false;
            return;
        };
        if (link.len > 0) self.follow(link) catch |err| self.ui.message(@errorName(err));
        self.dirty = true;
    }
    fn pointerAxis(data: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, axis: u32, value: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if(self.ui.modal==.open) {
            if(axis==wl.WL_POINTER_AXIS_VERTICAL_SCROLL) self.scrollFiles(@intFromFloat(@round(@as(f32,@floatFromInt(value))/256*3)));
            return;
        }
        if (self.content) |content| {
            const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
            const delta = @as(f32, @floatFromInt(value)) / 256 * 4.8;
            const shift=if(self.keyboard_value.state) |state| input.xkb_state_mod_name_is_active(state,input.XKB_MOD_NAME_SHIFT,input.XKB_STATE_MODS_EFFECTIVE)!=0 else false;
            if (self.full_ui and self.ui.toc and self.mouse_x < @as(f32, @floatFromInt(self.ui.layout(self.width, self.height).left))) {
                const next = @as(i64, @intCast(self.ui.toc_scroll)) + @as(i64, @intFromFloat(delta / 16));
                self.ui.toc_scroll = @intCast(@max(0, next));
            } else if (axis == wl.WL_POINTER_AXIS_HORIZONTAL_SCROLL or (shift and axis==wl.WL_POINTER_AXIS_VERTICAL_SCROLL)) {
                const total = content.horizontalTotal() catch |err| {
                    self.failure = err;
                    self.running = false;
                    return;
                };
                c.mdf_viewport_move_horizontal(content.viewport, fields.horizontal_scroll + delta, @max(0, total - @as(f32, @floatFromInt(content.canvas.logical_width))), false);
            } else if (axis == wl.WL_POINTER_AXIS_VERTICAL_SCROLL) {
                c.mdf_viewport_move(content.viewport, fields.scroll + delta, @floatFromInt(content.canvas.logical_height));
            }
            self.dirty = true;
        }
    }
    fn pointerFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
    fn pointerAxisSource(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
    fn pointerAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
    fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
    fn keyboardKeymap(data: ?*anyopaque, _: ?*wl.wl_keyboard, format_value: u32, fd: i32, size: u32) callconv(.c) void {
        defer _ = c.close(fd);
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (format_value != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1 or size == 0 or size > 32 * 1024 * 1024) return;
        const worker = self.keyboard_worker orelse return;
        const memory = c.mmap(null, size, c.PROT_READ, c.MAP_PRIVATE, fd, 0);
        if (memory == c.MAP_FAILED or memory == null) return;
        defer _ = c.munmap(memory, size);
        trace.signal(self.recording,@src(),"Request keyboard preparation",0);
        self.keyboard_failed=false;
        self.keyboard_pending = input.mdf_keyboard_submit(worker, @ptrCast(memory.?), size) != 0;
    }
    fn keyboardEnter(data: ?*anyopaque, _: ?*wl.wl_keyboard, serial: u32, _: ?*wl.wl_surface, _: [*c]wl.wl_array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.last_serial = serial;
    }
    fn keyboardLeave(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.queueKey(.leave);
    }
    fn keyboardKey(data: ?*anyopaque, _: ?*wl.wl_keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.queueKey(.{ .key = .{ .key = key, .state = state, .serial = serial } });
    }
    fn keyboardModifiers(data: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.queueKey(.{ .modifiers = .{ .depressed = depressed, .latched = latched, .locked = locked, .group = group } });
    }
    fn keyboardRepeat(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}
    fn queueKey(self: *Window, event: KeyEvent) void {
        self.keys.append(a, event) catch |err| {
            self.failure = err;
            self.running = false;
        };
    }
    fn pollKeyboard(self: *Window) !void {
        if (self.keyboard_worker) |worker| {
            var value = std.mem.zeroes(input.MdfPreparedKeyboard);
            const status = input.mdf_keyboard_take(worker, &value, 0);
            if (status > 0) {
                const timing=trace.begin(self.recording,@src(),"Adopt prepared keyboard resources",0);
                defer timing.end();
                if (value.initial == 0) {
                    value.compose = self.keyboard_value.compose;
                    self.keyboard_value.compose = null;
                }
                input.mdf_keyboard_release(&self.keyboard_value);
                self.keyboard_value = value;
                self.keyboard_pending = false;
                self.keyboard_failed=false;
                trace.signal(self.recording,@src(),"Keyboard resources adopted",0);
            } else if (status < 0) {
                self.keys.clearRetainingCapacity();
                self.keyboard_pending=false;
                if(!self.keyboard_failed) { self.ui.message("System keyboard unavailable"); self.dirty=true; }
                self.keyboard_failed=true;
                return;
            }
        }
        if (self.keyboard_pending or self.keyboard_value.state == null) return;
        for (self.keys.items) |event| switch (event) {
            .modifiers => |mods| _ = input.xkb_state_update_mask(self.keyboard_value.state, mods.depressed, mods.latched, mods.locked, 0, 0, mods.group),
            .leave => _ = input.xkb_state_update_mask(self.keyboard_value.state, 0, 0, 0, 0, 0, 0),
            .key => |key| if (key.state == wl.WL_KEYBOARD_KEY_STATE_PRESSED) {
                if (key.serial != 0) self.last_serial = key.serial;
                const symbol = input.xkb_state_key_get_one_sym(self.keyboard_value.state, key.key + 8);
                const control = input.xkb_state_mod_name_is_active(self.keyboard_value.state, input.XKB_MOD_NAME_CTRL, input.XKB_STATE_MODS_EFFECTIVE) != 0;
                try self.keyAction(symbol, control);
                if (self.full_ui and self.ui.modal == .open and !control) try self.dialogText(key.key, symbol);
            },
        };
        self.keys.clearRetainingCapacity();
    }
    fn exerciseKeyboard(self: *Window) !void {
        if (self.keyboard_test_done or self.keyboard_pending or self.keyboard_value.state == null or self.paints != 1 or self.frame_pending) return;
        const modifier = input.xkb_keymap_mod_get_index(self.keyboard_value.keymap, input.XKB_MOD_NAME_CTRL);
        if (modifier >= 32) return error.KeyboardTestFailed;
        const control = @as(u32, 1) << @as(u5, @intCast(modifier));
        self.queueKey(.{ .modifiers = .{ .depressed = control, .latched = 0, .locked = 0, .group = 0 } });
        self.queueKey(.{ .key = .{ .key = 30, .state = wl.WL_KEYBOARD_KEY_STATE_PRESSED } }); // KEY_A
        self.queueKey(.{ .key = .{ .key = 13, .state = wl.WL_KEYBOARD_KEY_STATE_PRESSED } }); // KEY_EQUAL
        self.queueKey(.{ .modifiers = .{ .depressed = 0, .latched = 0, .locked = 0, .group = 0 } });
        self.queueKey(.{ .key = .{ .key = 109, .state = wl.WL_KEYBOARD_KEY_STATE_PRESSED } }); // KEY_PAGEDOWN
        try self.pollKeyboard();
        const content = self.content.?;
        if (content.selected().len != c.mdf_core_document_text(self.core).text.len or content.zoom <= 1 or
            c.mdf_viewport_fields(content.viewport).*.scroll <= 0) return error.KeyboardTestFailed;
        self.keyboard_test_done = true;
        self.dirty = true;
    }
    fn keyAction(self: *Window, symbol: u32, control: bool) !void {
        if (self.full_ui and self.ui.modal != .none) {
            if (symbol == input.XKB_KEY_Escape) {
                self.closeDialog();
            } else if (self.ui.modal == .open) {
                if (symbol == input.XKB_KEY_Return or symbol == input.XKB_KEY_KP_Enter) {
                    try self.activateFile();
                } else if(control and (symbol==input.XKB_KEY_l or symbol==input.XKB_KEY_L or symbol==input.XKB_KEY_a or symbol==input.XKB_KEY_A)) {
                    self.ui.file_focus=false; self.ui.file_selected=null; self.ui.selectPath();
                } else if(control and (symbol==input.XKB_KEY_h or symbol==input.XKB_KEY_H)) {
                    try self.toggleHidden();
                } else if(symbol==input.XKB_KEY_Tab) {
                    if(shell.Shell.fileRows(self.width,self.height)>0) {
                        if(!self.ui.file_focus) try self.selectFile(self.ui.file_selected orelse 0)
                        else {self.ui.file_focus=false; self.ui.selectPath();}
                    }
                } else if(!self.ui.file_focus and (symbol==input.XKB_KEY_Left or symbol==input.XKB_KEY_Right or symbol==input.XKB_KEY_Home or symbol==input.XKB_KEY_End)) {
                    const shift=if(self.keyboard_value.state) |state| input.xkb_state_mod_name_is_active(state,input.XKB_MOD_NAME_SHIFT,input.XKB_STATE_MODS_EFFECTIVE)!=0 else false;
                    self.ui.movePath(switch(symbol) {input.XKB_KEY_Left=>.left,input.XKB_KEY_Right=>.right,input.XKB_KEY_Home=>.home,else=>.end},shift);
                } else if(symbol==input.XKB_KEY_Up or symbol==input.XKB_KEY_Down or symbol==input.XKB_KEY_Page_Up or symbol==input.XKB_KEY_Page_Down or symbol==input.XKB_KEY_Home or symbol==input.XKB_KEY_End) {
                    const alt=if(self.keyboard_value.state) |state| input.xkb_state_mod_name_is_active(state,input.XKB_MOD_NAME_ALT,input.XKB_STATE_MODS_EFFECTIVE)!=0 else false;
                    if(alt and symbol==input.XKB_KEY_Up) try self.parentDirectory() else try self.moveFileSelection(symbol);
                } else if(symbol==input.XKB_KEY_BackSpace and self.ui.file_focus) {
                    try self.parentDirectory();
                } else if ((symbol == input.XKB_KEY_BackSpace or symbol == input.XKB_KEY_Delete) and !self.ui.file_focus) {
                    self.ui.file_selected=null;
                    if(symbol==input.XKB_KEY_Delete) self.ui.deletePath() else self.ui.backspacePath();
                } else if (control and (symbol == input.XKB_KEY_c or symbol == input.XKB_KEY_C))
                    self.clipboard.publish(if(self.ui.file_focus) self.ui.path[0..self.ui.path_len] else self.ui.selectedPath(), self.last_serial) catch {}
                else if(control and !self.ui.file_focus and (symbol==input.XKB_KEY_x or symbol==input.XKB_KEY_X)) {
                    self.clipboard.publish(self.ui.selectedPath(),self.last_serial) catch return;
                    if(self.ui.selectedPath().len>0) self.ui.backspacePath();
                }
                else if(control and (symbol==input.XKB_KEY_v or symbol==input.XKB_KEY_V))
                    self.clipboard.paste() catch |err| { self.ui.message(@errorName(err)); };
            } else if (symbol == input.XKB_KEY_Return or symbol == input.XKB_KEY_space) self.ui.modal = .none;
            self.dirty = true;
            return;
        }
        if (self.full_ui and self.ui.menu.opened != null) {
            switch (symbol) {
                input.XKB_KEY_Escape => self.ui.menu.opened = null,
                input.XKB_KEY_Up => self.ui.menu.move(-1, self.width, self.height),
                input.XKB_KEY_Down => self.ui.menu.move(1, self.width, self.height),
                input.XKB_KEY_Return, input.XKB_KEY_KP_Enter => if (self.ui.menu.accept()) |cmd| try self.command(cmd),
                else => {},
            }
            self.dirty = true;
            return;
        }
        if (self.full_ui and control and (symbol == input.XKB_KEY_o or symbol == input.XKB_KEY_O)) return self.command(.open);
        if (self.full_ui and control and (symbol == input.XKB_KEY_r or symbol == input.XKB_KEY_R)) return self.command(.reload);
        if (control and (symbol == input.XKB_KEY_q or symbol == input.XKB_KEY_Q)) {
            self.running = false;
            return;
        }
        const content = self.content orelse return;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        if (!control) if (content.diagram_focus) |index| {
            const action: ?reader.diagrams.Action = switch (symbol) {
                input.XKB_KEY_equal, input.XKB_KEY_plus => .larger,
                input.XKB_KEY_minus => .smaller,
                input.XKB_KEY_0 => .reset,
                else => null,
            };
            if (action) |value| {
                try content.zoomDiagram(index, value);
                self.dirty = true;
                return;
            }
            if (symbol == input.XKB_KEY_Escape) {
                content.diagram_focus = null;
                self.dirty = true;
                return;
            }
        };
        if (control and (symbol == input.XKB_KEY_a or symbol == input.XKB_KEY_A)) {
            content.selectAll();
            self.dirty = true;
        } else if (control and (symbol == input.XKB_KEY_c or symbol == input.XKB_KEY_C)) {
            self.clipboard.publish(content.selected(), self.last_serial) catch |err| {
                if (err != error.ClipboardUnavailable) return err;
            };
        } else if (control and (symbol == input.XKB_KEY_equal or symbol == input.XKB_KEY_plus or symbol == input.XKB_KEY_minus or symbol == input.XKB_KEY_0)) {
            const current = @as(i32, @intFromFloat(@round(content.zoom * 12)));
            const size = if (symbol == input.XKB_KEY_0) (if (self.full_ui) @as(i32, self.ui.theme.fontSize()) else 12) else std.math.clamp(current + (if (symbol == input.XKB_KEY_minus) @as(i32, -1) else 1), 8, 72);
            content.zoom = @as(f32, @floatFromInt(size)) / 12;
            if (self.full_ui) self.ui.points = size;
            if (self.full_ui) try self.updateSettings();
            try content.invalidate();
            self.dirty = true;
        } else {
            if((!content.wrap or (self.full_ui and self.ui.horizontal_overflow)) and (symbol==input.XKB_KEY_Left or symbol==input.XKB_KEY_Right)) {
                const total=try content.horizontalTotal();
                c.mdf_viewport_move_horizontal(content.viewport,fields.horizontal_scroll+(if(symbol==input.XKB_KEY_Left) @as(f32,-48) else 48),
                    @max(0,total-@as(f32,@floatFromInt(content.canvas.logical_width))),false);
                self.dirty=true;return;
            }
            const value = switch (symbol) {
                input.XKB_KEY_Up => fields.scroll - 48,
                input.XKB_KEY_Down => fields.scroll + 48,
                input.XKB_KEY_Page_Up => fields.scroll - @as(f32, @floatFromInt(content.canvas.logical_height)) * 0.85,
                input.XKB_KEY_Page_Down, input.XKB_KEY_space => fields.scroll + @as(f32, @floatFromInt(content.canvas.logical_height)) * 0.85,
                input.XKB_KEY_Home => @as(f32, 0),
                input.XKB_KEY_End => c.mdf_viewport_total(content.viewport),
                else => return,
            };
            c.mdf_viewport_move(content.viewport, value, @floatFromInt(content.canvas.logical_height));
            self.dirty = true;
        }
    }
    fn dialogText(self: *Window, key: u32, symbol: u32) !void {
        var buffer: [128]u8 = undefined;
        var count: c_int = 0;
        if (self.keyboard_value.compose) |compose| {
            _ = input.xkb_compose_state_feed(compose, symbol);
            switch (input.xkb_compose_state_get_status(compose)) {
                input.XKB_COMPOSE_COMPOSING => return,
                input.XKB_COMPOSE_COMPOSED => {
                    count = input.xkb_compose_state_get_utf8(compose, &buffer, buffer.len);
                    input.xkb_compose_state_reset(compose);
                },
                input.XKB_COMPOSE_CANCELLED => {
                    input.xkb_compose_state_reset(compose);
                    return;
                },
                else => count = input.xkb_state_key_get_utf8(self.keyboard_value.state, key + 8, &buffer, buffer.len),
            }
        } else count = input.xkb_state_key_get_utf8(self.keyboard_value.state, key + 8, &buffer, buffer.len);
        if (count > 0 and count < buffer.len) {
            self.ui.file_focus=false; self.ui.file_selected=null;
            self.ui.insertPath(buffer[0..@intCast(count)]);
        }
        self.dirty = true;
    }
    fn openDocument(self: *Window, path: []const u8) !void {
        a.free(self.pending_fragment); self.pending_fragment=&.{}; self.fragment_revision=0;
        const opened = c.mdf_core_open(self.core, path.ptr, path.len);
        defer c.mdf_buffer_free(opened);
        const result = try std.json.parseFromSlice(std.json.Value, a, reader.bytes(opened), .{});
        defer result.deinit();
        if (result.value.object.get("err")) |err| self.ui.message(err.string) else self.ui.message("Opening document...");
        self.dirty = true;
    }
    fn browse(self:*Window,path:[]const u8,allow_file:bool,preserve:bool) !void {
        self.ui.files=null; self.ui.file_first=0; self.ui.file_selected=null; self.ui.file_focus=false;
        self.ui.file_loading=true; self.ui.file_message=""; self.browser_initial=preserve;
        self.file_drag=false; self.path_drag=false; self.file_clicks.last=null;
        self.browser.request(path,self.ui.file_hidden,allow_file,wake) catch |err| {
            self.ui.file_loading=false; self.ui.file_message=directoryMessage(err);
            self.dirty=true; return;
        };
        self.dirty=true;
    }
    fn openFileDialog(self:*Window,path:[]const u8) !void {
        self.ui.openDialog(if(path.len>0) path else ".");
        try self.browse(if(path.len>0) std.fs.path.dirname(path) orelse "." else ".",false,true);
    }
    fn closeDialog(self:*Window) void {
        self.ui.files=null; self.browser.deinit();
        self.ui.file_loading=false; self.ui.file_message=""; self.ui.modal=.none; self.file_drag=false;self.path_drag=false;
        self.dirty=true;
    }
    fn pollBrowser(self:*Window) !void {
        if(!self.browser.poll()) return;
        self.ui.file_loading=false;
        if(self.ui.modal!=.open) {self.ui.files=null; self.browser.deinit(); return;}
        if(self.browser.failure) |err| {self.ui.file_message=directoryMessage(err); self.dirty=true; return;}
        const listing=&self.browser.listing.?;
        if(listing.is_file) {try self.openDocument(listing.path); self.closeDialog();}
        else {
            self.ui.files=listing;
            if(!self.browser_initial) self.ui.openDialog(listing.path);
            self.browser_initial=false; self.dirty=true;
        }
    }
    fn selectFile(self:*Window,index:usize) !void {
        const listing=self.ui.files orelse return;
        if(index>=listing.entries.len) return;
        const path=try std.fs.path.join(a,&.{listing.path,listing.entries[index].name});
        defer a.free(path);
        self.ui.openDialog(path); self.ui.file_focus=true; self.ui.file_selected=index;
        const rows=shell.Shell.fileRows(self.width,self.height);
        if(index<self.ui.file_first) self.ui.file_first=index;
        if(rows>0 and index>=self.ui.file_first+rows) self.ui.file_first=index-rows+1;
        self.dirty=true;
    }
    fn directoryMessage(err:anyerror) []const u8 {
        return switch(err) {
            error.DirectoryNotFound=>"Path not found. Edit the path or choose Home.",
            error.AccessDenied=>"Permission denied. Choose another folder.",
            error.NotDirectory=>"Enter a directory path.",
            error.InvalidDirectoryPath=>"Enter a valid path.",
            error.CurrentDirectoryUnavailable=>"Current directory unavailable. Choose Home.",
            else=>"Cannot read this directory.",
        };
    }
    fn activateFile(self:*Window) !void {
        if(self.ui.file_focus) if(self.ui.file_selected) |index| if(self.ui.files) |listing| {
            if(index>=listing.entries.len) return;
            const entry=listing.entries[index];
            const path=try std.fs.path.join(a,&.{listing.path,entry.name}); defer a.free(path);
            if(entry.directory) try self.browse(path,false,false)
            else {try self.openDocument(path); self.closeDialog();}
            return;
        };
        if(self.ui.path_len>0) try self.browse(self.ui.path[0..self.ui.path_len],true,false);
    }
    fn parentDirectory(self:*Window) !void {
        const path=self.browser.location();
        if(std.mem.eql(u8,path,"/")) return;
        try self.browse(std.fs.path.dirname(path) orelse ".",false,false);
    }
    fn moveFileSelection(self:*Window,symbol:u32) !void {
        const listing=self.ui.files orelse return;
        const rows=shell.Shell.fileRows(self.width,self.height);
        if(rows==0 or listing.entries.len==0) return;
        const selected=self.ui.file_selected orelse 0;
        const target= switch(symbol) {
            input.XKB_KEY_Home=>@as(usize,0),input.XKB_KEY_End=>listing.entries.len-1,
            input.XKB_KEY_Up=>selected-|1,input.XKB_KEY_Down=>if(self.ui.file_selected==null) @as(usize,0) else @min(listing.entries.len-1,selected+1),
            input.XKB_KEY_Page_Up=>selected-|rows,input.XKB_KEY_Page_Down=>@min(listing.entries.len-1,selected+rows),else=>return,
        };
        try self.selectFile(target);
    }
    fn toggleHidden(self:*Window) !void {
        self.ui.file_hidden=!self.ui.file_hidden;
        try self.browse(self.browser.location(),false,false);
    }
    fn scrollFiles(self:*Window,delta:i32) void {
        const count=if(self.ui.files) |files| files.entries.len else 0;
        const rows=shell.Shell.fileRows(self.width,self.height);
        const maximum=count-|rows;
        self.ui.file_first=@intCast(std.math.clamp(@as(i64,@intCast(self.ui.file_first))+delta,0,@as(i64,@intCast(maximum))));
        self.dirty=true;
    }
    fn filePointer(self:*Window,event:u32) !void {
        if(event==2) {self.file_drag=false;self.path_drag=false;return;}
        const box=shell.Shell.fileBox(self.width,self.height);
        if(event==1 and self.path_drag) {
            if(self.chrome) |canvas| try self.ui.pointPath(canvas,self.mouse_x-@as(f32,@floatFromInt(box.x+28)),@floatFromInt(box.width-56),true);
            self.dirty=true;return;
        }
        if(event!=0 and !self.file_drag) return;
        const hit=self.ui.fileHit(self.mouse_x,self.mouse_y,self.width,self.height);
        if(event==0) switch(hit) {
            .path=>{
                self.ui.file_focus=false;self.ui.file_selected=null;self.path_drag=true;
                if(self.chrome) |canvas| try self.ui.pointPath(canvas,self.mouse_x-@as(f32,@floatFromInt(box.x+28)),@floatFromInt(box.width-56),false);
            },
            .parent=>try self.parentDirectory(),
            .home=>try self.browse(if(c.getenv("HOME")) |home| std.mem.span(home) else ".",false,false),
            .hidden=>try self.toggleHidden(),
            .open=>try self.activateFile(),
            .cancel=>self.closeDialog(),
            .row=>|index| {
                if(self.ui.file_selected!=index) self.file_clicks.last=null;
                try self.selectFile(index);
                if(self.file_clicks.press(self.click_time)) try self.activateFile();
            },
            .scroll=>self.file_drag=true,
            .none=>{},
        };
        if(hit==.scroll) {
            const count=if(self.ui.files) |files| files.entries.len else 0;
            const rows=shell.Shell.fileRows(self.width,self.height);
            self.ui.file_first=@intFromFloat(@round(hit.scroll*@as(f32,@floatFromInt(count-|rows))));
        }
        self.dirty=true;
    }
    fn follow(self: *Window, url: []const u8) !void {
        const reply=c.mdf_core_link(self.core,url.ptr,url.len);
        defer c.mdf_buffer_free(reply);
        const parsed=try std.json.parseFromSlice(std.json.Value,a,reader.bytes(reply),.{});
        defer parsed.deinit();
        if(parsed.value.object.get("err")) |err| { self.ui.message(err.string); self.dirty=true; return; }
        const kind=parsed.value.object.get("kind").?.string;
        const value=parsed.value.object.get("url").?.string;
        if(std.mem.eql(u8,kind,"fragment")) {
            if(self.content) |content| content.jump(value);
        } else if(std.mem.eql(u8,kind,"local")) {
            try self.openDocument(value);
            if(parsed.value.object.get("anchor")) |anchor| if(anchor.string.len>0) {
                self.pending_fragment=try a.dupe(u8,anchor.string);
                self.fragment_revision=self.document_revision+1;
            };
        } else if(std.mem.eql(u8,kind,"web")) try self.external.open(value);
        self.dirty=true;
    }
    fn updateSettings(self: *Window) !void {
        const data = try std.json.Stringify.valueAlloc(a, self.ui.values(.{ .width = if (self.constrained) self.normal_width else self.width, .height = if (self.constrained) self.normal_height else self.height, .maximized = self.constrained }), .{});
        defer a.free(data);
        const updated = c.mdf_core_settings_update(self.core, data.ptr, data.len);
        defer c.mdf_buffer_free(updated);
        const result = try std.json.parseFromSlice(std.json.Value, a, reader.bytes(updated), .{});
        defer result.deinit();
        if (result.value.object.get("err")) |err| self.ui.message(err.string);
    }
    fn command(self: *Window, value: shell.menus.Command) !void {
        self.ui.menu.opened = null;
        self.dirty = true;
        switch (value) {
            .open => {
                try self.openFileDialog(self.path);
                return;
            },
            .reload => {
                if (self.path.len > 0) try self.openDocument(self.path);
                return;
            },
            .quit => {
                try self.updateSettings();
                self.running = false;
                return;
            },
            .copy => {
                if (self.content) |content| self.clipboard.publish(content.selected(), self.last_serial) catch |err| {
                    if (err != error.ClipboardUnavailable) return err;
                };
                return;
            },
            .select_all => {
                if (self.content) |content| content.selectAll();
                return;
            },
            .about => {
                self.ui.modal = .about;
                return;
            },
            .licenses => {
                self.ui.modal = .licenses;
                return;
            },
            .toc => self.ui.apply(.toc),
            .preview => self.ui.apply(.preview),
            .wrap => self.ui.apply(.wrap),
            .width80 => self.ui.width_mode = 1,
            .width100 => self.ui.width_mode = 2,
            .larger => self.ui.apply(.larger),
            .smaller => self.ui.apply(.smaller),
            .reset_size => self.ui.apply(.reset),
            .size => |size| self.ui.points = std.math.clamp(size, 8, 72),
            .theme => |theme| {
                self.ui.theme = theme;
                self.ui.points = theme.fontSize();
            },
            .auto_reload => self.ui.reload = !self.ui.reload,
            .save_settings => self.ui.save = !self.ui.save,
            .reset_settings => {
                self.ui = .{};
                wl.xdg_toplevel_unset_maximized(self.toplevel);
                self.width = 1040;
                self.height = 780;
                self.normal_width = 1040;
                self.normal_height = 780;
            },
        }
        try self.updateSettings();
    }
    fn ping(_: ?*anyopaque, wm: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
        wl.xdg_wm_base_pong(wm, serial);
    }
    fn configure(data: ?*anyopaque, surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        wl.xdg_surface_ack_configure(surface, serial);
        self.configured = true;
        if (self.configured_ns == 0) {
            self.configured_ns = c.mdf_now_ns();
            self.mark("Native window configured",self.configured_ns);
        }
    }
    fn toplevelConfigure(data: ?*anyopaque, _: ?*wl.xdg_toplevel, width: i32, height: i32, states: [*c]wl.wl_array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        var constrained = false;
        if (states.*.data != null) for (@as([*]align(1) const u32, @ptrCast(states.*.data))[0 .. states.*.size / @sizeOf(u32)]) |state| {
            if (state == wl.XDG_TOPLEVEL_STATE_MAXIMIZED or state == wl.XDG_TOPLEVEL_STATE_FULLSCREEN) constrained = true;
        };
        if (constrained and !self.constrained) {
            self.normal_width = self.width;
            self.normal_height = self.height;
        }
        // Zero means the client chooses. Weston, among other compositors,
        // leaves restoration of the normal dimensions to the client.
        const restore = self.constrained and !constrained;
        const next_width = if (width > 0) width else if (restore) self.normal_width else self.width;
        const next_height = if (height > 0) height else if (restore) self.normal_height else self.height;
        if (self.constrained != constrained) self.dirty = true;
        self.constrained = constrained;
        if (next_width != self.width or next_height != self.height) {
            self.width = next_width;
            self.height = next_height;
            self.dirty = true;
        }
    }
    fn close(data: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.command(.quit) catch |err| { self.failure = err; self.running = false; };
    }
    fn frame(data: ?*anyopaque, callback: ?*wl.wl_callback, _: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        wl.wl_callback_destroy(callback);
        self.callback = null;
        if (self.frame_ns == 0) self.frame_ns = c.mdf_now_ns();
        self.frame_pending = false;
        if (self.ready_mode) return;
        if(self.test_paste or self.test_drop or self.test_browser) {
            // Incoming data and document completion advance in the event loop.
        } else if(self.test_links) {
            self.exerciseLinks() catch |err| { self.failure=err; self.running=false; };
        } else if (self.test_frame) {
            self.exerciseFrame() catch |err| { self.failure = err; self.running = false; };
        } else if (self.test_watch) {
            if (!self.watch_started) {
                _ = c.fwrite("ready\n", 1, 6, c.stdout);
                _ = c.fflush(c.stdout);
                self.watch_started = true;
            } else if (self.document_revision >= 2 and self.painted_revision == self.document_revision) self.running = false;
            self.dirty = false;
        } else if (self.test_menu) {
            self.exerciseMenu() catch |err| {
                self.failure = err;
                self.running = false;
            };
        } else if (self.test_preferences and self.paints == 1) {
            self.command(.save_settings) catch |err| {
                self.failure = err;
                self.running = false;
            };
            self.command(.{ .theme = .paper }) catch |err| {
                self.failure = err;
                self.running = false;
            };
            self.command(.{ .size = 18 }) catch |err| {
                self.failure = err;
                self.running = false;
            };
            self.command(.wrap) catch |err| {
                self.failure = err;
                self.running = false;
            };
        } else if (self.test_clipboard) {
            self.dirty = false;
        } else if (self.test_resize) {
            if (self.resize_stage == 0) {
                self.content.?.selectAll();
                self.resize_stage = 1;
                wl.xdg_toplevel_set_maximized(self.toplevel);
            } else if (self.resize_stage == 1 and (self.width != 800 or self.height != 600) and
                self.painted_width == self.width and self.painted_height == self.height) {
                self.resized_width = self.width;
                self.resized_height = self.height;
                self.resize_stage = 2;
                wl.xdg_toplevel_unset_maximized(self.toplevel);
            } else if (self.resize_stage == 2 and self.width == 800 and self.height == 600 and
                self.painted_width == self.width and self.painted_height == self.height) {
                self.resize_stage = 3;
                self.running = false;
            }
        } else if (self.test_table and self.table_stage < 3) {
            self.exerciseTable() catch |err| {
                self.failure = err;
                self.running = false;
            };
        } else if (self.test_toolbar and self.paints < 7) {
            const actions = [_]shell.Action{ .theme, .wrap, .toc, .preview, .larger, .reset };
            self.ui.apply(actions[self.paints - 1]);
            self.dirty = true;
        } else if (self.test_toolbar and !self.toolbar_pan_done) {
            const content = self.content.?;
            self.keyAction(input.XKB_KEY_Right,false) catch |err| {self.failure=err;self.running=false;return;};
            if(c.mdf_viewport_fields(content.viewport).*.horizontal_scroll<=0) {self.failure=error.KeyboardHorizontalPanFailed;self.running=false;return;}
            const total = content.horizontalTotal() catch |err| {
                self.failure = err;
                self.running = false;
                return;
            };
            const maximum = @max(0, total - @as(f32, @floatFromInt(content.canvas.logical_width)));
            c.mdf_viewport_move_horizontal(content.viewport, maximum * 0.5, maximum, false);
            self.toolbar_pan_done = true;
            self.dirty = true;
        } else if (self.test_keyboard and !self.keyboard_test_done) {
            self.dirty = false;
        } else if (self.test_details and self.paints < 3) {
            self.exerciseDetails() catch |err| {
                self.failure = err;
                self.running = false;
            };
        } else if (self.test_selection and self.paints == 1) {
            self.exerciseSelection() catch |err| {
                self.failure = err;
                self.running = false;
            };
        } else if (self.test_scroll and self.paints < 6) {
            const content = self.content.?;
            const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
            c.mdf_viewport_move(content.viewport, fields.scroll + 240, @floatFromInt(self.height));
            self.dirty = true;
        } else if (!self.interactive) {
            self.running = false;
            if (self.test_first_dirty) self.dirty = true;
        }
    }
    fn exerciseTable(self: *Window) !void {
        const content = self.content.?;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        const bounds = self.ui.layout(self.width, self.height);
        if (!content.wrap or !self.ui.horizontal_overflow or bounds.height != bounds.view_height - 20 or
            fields.horizontal_extent <= @as(f32, @floatFromInt(bounds.width))) return error.TableOverflowNotScrollable;
        switch (self.table_stage) {
            0 => {
                if (fields.horizontal_scroll != 0) return error.TableInitiallyPanned;
                try self.keyAction(input.XKB_KEY_Right, false);
                if (fields.horizontal_scroll <= 0) return error.TableKeyboardPanFailed;
            },
            1 => {
                const previous = fields.horizontal_scroll;
                pointerAxis(self, self.pointer, 0, wl.WL_POINTER_AXIS_HORIZONTAL_SCROLL, 10 * 256);
                if (fields.horizontal_scroll <= previous) return error.TableWheelPanFailed;
                if (!self.ui.horizontalAt(content, @floatFromInt(bounds.x + bounds.width - 10),
                    @floatFromInt(bounds.y + bounds.height + 10), self.width, self.height)) return error.TableBarHitFailed;
                const maximum = fields.horizontal_extent - @as(f32, @floatFromInt(bounds.width));
                if (@abs(fields.horizontal_scroll - maximum) > 0.01) return error.TableLastColumnUnreachable;
            },
            2 => {
                try self.keyAction(input.XKB_KEY_Left, false);
                if (!self.ui.horizontalAt(content, @floatFromInt(bounds.x + 10),
                    @floatFromInt(bounds.y + bounds.height + 10), self.width, self.height) or
                    fields.horizontal_scroll != 0) return error.TableBarResetFailed;
            },
            else => unreachable,
        }
        self.table_stage += 1;
        self.dirty = true;
    }
    fn exerciseDiagram(self: *Window) !void {
        const content = self.content.?;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        const geometry = c.mdf_viewport_view(content.viewport);
        var index: ?usize = null;
        for (content.layouts, 0..) |entry, i| {
            if (entry != null) if (self.assets.images.values.getPtr(i)) |image| {
                if (image.diagram and !image.svg and image.pixels.data != null) { index = i; break; }
            };
        }
        const selected = index orelse return error.DiagramTestMissingImage;
        const image = self.assets.images.values.getPtr(selected).?;
        const view = c.mdf_layout_result_view(content.layouts[selected].?);
        const bounds = self.ui.layout(self.width, self.height);
        const controls = reader.diagrams.Controls.init(fields.margin,
            geometry.offsets[selected] + view.iy - 32 - fields.scroll, fields.content_width);
        const Click = struct {
            fn action(window: *Window, group: reader.diagrams.Controls, action_value: reader.diagrams.Action) void {
                const box = group.boxes[@intFromEnum(action_value)];
                const body = window.ui.layout(window.width, window.height);
                window.mouse_x = @as(f32, @floatFromInt(body.x)) + box.x + box.width / 2;
                window.mouse_y = @as(f32, @floatFromInt(body.y)) + box.y + box.height / 2;
                window.pointerAction(0); window.pointerAction(2);
            }
        };
        if (self.diagram_stage > 0 and (image.pixels.data != self.diagram_pixels or self.assets.images.version != self.diagram_version or
            self.assets.threads_started != self.diagram_threads)) return error.DiagramZoomDecodedAgain;
        switch (self.diagram_stage) {
            0 => {
                if (view.iw < image.logical_width * content.zoom - 0.01 or !self.ui.horizontal_overflow or
                    content.diagramState(selected).fit) return error.DiagramLabelsShrunk;
                self.diagram_pixels = image.pixels.data;
                self.diagram_version = self.assets.images.version;
                self.diagram_threads = self.assets.threads_started;
                Click.action(self, controls, .larger);
                if (content.diagramState(selected).zoom <= 1) return error.DiagramZoomButtonFailed;
            },
            1 => {
                if (view.iw <= image.logical_width * content.zoom) return error.DiagramZoomNotPainted;
                try self.keyAction(input.XKB_KEY_minus, false);
                if (@abs(content.diagramState(selected).zoom - 1) > 0.001) return error.DiagramZoomKeyFailed;
                Click.action(self, controls, .fit);
            },
            2 => {
                if (!content.diagramState(selected).fit or view.iw > fields.content_width + 0.01) return error.DiagramFitFailed;
                Click.action(self, controls, .reset);
            },
            3 => {
                if (content.diagramState(selected).fit or view.iw < image.logical_width * content.zoom - 0.01) return error.DiagramResetFailed;
                self.mouse_x = @as(f32, @floatFromInt(bounds.x)) + @as(f32, @floatFromInt(bounds.width)) * 0.5;
                self.mouse_y = @as(f32, @floatFromInt(bounds.y)) + geometry.offsets[selected] + view.iy - fields.scroll + 40;
                self.pointerAction(0);
                self.mouse_x -= 60;
                self.pointerAction(1); self.pointerAction(2);
                if (fields.horizontal_scroll <= 0) return error.DiagramDragPanFailed;
                const previous = fields.horizontal_scroll;
                try self.keyAction(input.XKB_KEY_Right, false);
                if (fields.horizontal_scroll <= previous) return error.DiagramArrowPanFailed;
                if (!self.ui.horizontalAt(content, @floatFromInt(bounds.x + bounds.width - 10),
                    @floatFromInt(bounds.y + bounds.height + 10), self.width, self.height)) return error.DiagramBarPanFailed;
            },
            4 => {
                if (@abs(fields.horizontal_scroll - (fields.horizontal_extent - @as(f32, @floatFromInt(bounds.width)))) > 0.01)
                    return error.DiagramRightEdgeUnreachable;
                if (c.getenv("MDF_NATIVE_TEST_DIAGRAM_PAN_CAPTURE")) |path| try self.snapshot(@ptrCast(path));
                // The controls stay reachable after panning the image away.
                Click.action(self, controls, .smaller);
                if (content.diagramState(selected).zoom >= 1) return error.DiagramPannedControlsLost;
                try self.keyAction(input.XKB_KEY_0, false);
                _ = self.ui.horizontalAt(content, @floatFromInt(bounds.x + 10),
                    @floatFromInt(bounds.y + bounds.height + 10), self.width, self.height);
            },
            5 => {
                if (content.diagram_states.count() != 1 or fields.horizontal_scroll != 0 or content.selected().len != 0)
                    return error.DiagramInteractionStateCorrupted;
                var keys = self.assets.images.values.keyIterator();
                while (keys.next()) |key| if (key.* != selected) {
                    const other = content.diagramState(key.*);
                    if (other.zoom != 1 or other.fit) return error.DiagramOtherZoomChanged;
                };
                try self.keyAction(input.XKB_KEY_Escape, false);
                if (content.diagram_focus != null) return error.DiagramFocusNotReleased;
                self.mouse_x = @as(f32, @floatFromInt(bounds.x)) + fields.margin + 50;
                self.mouse_y = @as(f32, @floatFromInt(bounds.y)) + geometry.offsets[selected] + view.iy - fields.scroll + 40;
                self.pointerAction(0);
                self.mouse_x = 1; self.pointerAction(2); // Release outside the body.
                self.mouse_x = @as(f32, @floatFromInt(bounds.x)) + fields.margin + 10;
                self.mouse_y = @as(f32, @floatFromInt(bounds.y)) + 40;
                self.pointerAction(0); self.pointerAction(2);
                if (content.diagram_drag != null or content.diagram_control or content.diagram_focus != null)
                    return error.DiagramStaleDragAfterOutsideRelease;
            },
            else => unreachable,
        }
        self.diagram_stage += 1;
        self.dirty = true;
    }
    fn clickLink(self: *Window, local: bool) !void {
        const content=self.content.?;
        const geometry=c.mdf_viewport_view(content.viewport);
        const fields: *c.MdfViewportFields=c.mdf_viewport_fields(content.viewport);
        const bounds=self.ui.layout(self.width,self.height);
        for(content.layouts,0..) |entry,index| if(entry) |layout| {
            const view=c.mdf_layout_result_view(layout);
            if(view.run_count==0) continue;
            for(view.runs[0..view.run_count]) |text_run| {
                const url=reader.bytes(text_run.link);
                if(url.len==0 or (local==std.mem.startsWith(u8,url,"https://"))) continue;
                self.mouse_x=@as(f32,@floatFromInt(bounds.x))+text_run.x+text_run.width/2-fields.horizontal_scroll;
                self.mouse_y=@as(f32,@floatFromInt(bounds.y))+geometry.offsets[index]+text_run.y-@as(f32,@floatFromInt(text_run.font.size))*0.4-fields.scroll;
                self.pointerAction(0); self.pointerAction(2); return;
            }
        };
        return error.LinkTestTargetMissing;
    }
    fn exerciseLinks(self: *Window) !void {
        if(self.link_stage==0) {
            try self.clickLink(false); self.link_stage=1;
        } else if(self.link_stage==1) {
            if(self.external.children.items.len>0) { self.dirty=true; return; }
            if(self.external.launches!=1) return error.ExternalLinkNotLaunched;
            try self.clickLink(true); self.link_stage=2;
        } else if(self.document_revision>=2 and self.painted_revision==self.document_revision) {
            if(c.mdf_viewport_fields(self.content.?.viewport).*.scroll<=0) return error.LocalLinkFragmentNotApplied;
            self.link_stage=3; self.running=false;
        } else if(self.document_revision<2) self.dirty=false;
    }
    fn exerciseMenu(self: *Window) !void {
        if (self.content == null or self.painted_revision != self.document_revision) {
            self.dirty = true;
            return;
        }
        switch (self.menu_stage) {
            0 => {
                self.mouse_x = 160;
                self.mouse_y = 14;
                self.pointerAction(0);
            },
            1 => {
                self.mouse_x = 180;
                self.mouse_y = 71;
                self.pointerAction(0);
            },
            2 => try self.keyAction(input.XKB_KEY_o, true),
            3 => {
                const path = c.getenv("MDF_NATIVE_TEST_OPEN") orelse return error.MenuTestPathMissing;
                self.ui.insertPath(std.mem.span(path));
                try self.keyAction(input.XKB_KEY_Return, false);
            },
            4 => {
                if (self.document_revision < 2) {
                    self.dirty = false;
                    return;
                }
                try self.keyAction(input.XKB_KEY_r, true);
            },
            5 => {
                if (self.document_revision < 3) {
                    self.dirty = false;
                    return;
                }
                self.running = false;
            },
            else => {},
        }
        self.menu_stage += 1;
    }
    fn exerciseSelection(self: *Window) !void {
        const content = self.content.?;
        const geometry = c.mdf_viewport_view(content.viewport);
        for (content.layouts, 0..) |entry, index| if (entry) |layout| {
            const view = c.mdf_layout_result_view(layout);
            if (view.run_count == 0) continue;
            const text_run = view.runs[0];
            if (text_run.position == std.math.maxInt(usize) or text_run.text.len < 3) continue;
            const y = geometry.offsets[index] + text_run.y - @as(f32, @floatFromInt(text_run.font.size)) * 0.4;
            _ = try content.pointer(0, text_run.x + 1, y);
            _ = try content.pointer(1, text_run.x + text_run.width * 0.75, y);
            _ = try content.pointer(2, text_run.x + text_run.width * 0.75, y);
            if (content.selected().len == 0) return error.SelectionTestFailed;
            self.dirty = true;
            return;
        };
        return error.SelectionTestFailed;
    }
    fn exerciseDetails(self: *Window) !void {
        const content = self.content.?;
        if (self.detail_index == null) {
            for (0..content.layouts.len) |index| {
                const block = c.mdf_core_block(self.core, index);
                if (!std.mem.eql(u8, reader.bytes(block.kind), "details")) continue;
                self.detail_index = index;
                self.detail_initial = content.details_open[index];
                self.detail_document_flags = block.flags;
                break;
            }
        }
        const index = self.detail_index orelse return error.DetailsTestFailed;
        try content.toggle(index);
        if (c.mdf_core_block(self.core, index).flags != self.detail_document_flags) return error.DocumentMutated;
        if (content.details_open[index] != (if (self.paints == 1) !self.detail_initial else self.detail_initial))
            return error.DetailsTestFailed;
        const geometry = c.mdf_viewport_view(content.viewport);
        c.mdf_viewport_move(content.viewport, geometry.offsets[index], @floatFromInt(self.height));
        self.dirty = true;
    }
    const registry_listener: wl.wl_registry_listener = .{ .global = registryGlobal, .global_remove = registryRemove };
    const wm_listener: wl.xdg_wm_base_listener = .{ .ping = ping };
    const shm_listener: wl.wl_shm_listener = .{ .format = format };
    const buffer_listener: wl.wl_buffer_listener = .{ .release = release };
    const seat_listener: wl.wl_seat_listener = .{ .capabilities = seatCapabilities, .name = seatName };
    const keyboard_listener: wl.wl_keyboard_listener = .{
        .keymap = keyboardKeymap,
        .enter = keyboardEnter,
        .leave = keyboardLeave,
        .key = keyboardKey,
        .modifiers = keyboardModifiers,
        .repeat_info = keyboardRepeat,
    };
    const pointer_listener: wl.wl_pointer_listener = listener: {
        var value = std.mem.zeroes(wl.wl_pointer_listener);
        value.enter = pointerEnter;
        value.leave = pointerLeave;
        value.motion = pointerMotion;
        value.button = pointerButton;
        value.axis = pointerAxis;
        value.frame = pointerFrame;
        value.axis_source = pointerAxisSource;
        value.axis_stop = pointerAxisStop;
        value.axis_discrete = pointerAxisDiscrete;
        break :listener value;
    };
    const wl_surface_listener: wl.wl_surface_listener = listener: {
        var value = std.mem.zeroes(wl.wl_surface_listener);
        value.enter = surfaceEnter;
        value.leave = surfaceLeave;
        value.preferred_buffer_scale = surfaceScale;
        value.preferred_buffer_transform = surfaceTransform;
        break :listener value;
    };
    const surface_listener: wl.xdg_surface_listener = .{ .configure = configure };
    const toplevel_listener: wl.xdg_toplevel_listener = listener: {
        var value = std.mem.zeroes(wl.xdg_toplevel_listener);
        value.configure = toplevelConfigure;
        value.close = close;
        break :listener value;
    };
    const frame_listener: wl.wl_callback_listener = .{ .done = frame };

    fn deinit(self: *Window) void {
        self.stopWorkers();
        self.assets.deinit();
        self.minimap.deinit();
        self.fonts.deinit();
        self.clipboard.deinit();
        self.ui.files=null; self.browser.deinit();
        c.mdf_buffer_free(self.startup_profile);
        self.external.deinit(); a.free(self.pending_fragment);
        a.free(self.path);
        input.mdf_keyboard_release(&self.keyboard_value);
        self.keys.deinit(a);
        if (self.keyboard) |value| wl.wl_keyboard_destroy(value);
        if (self.content) |content| {
            content.deinit();
            a.destroy(content);
        }
        if (self.canvas) |canvas| {
            canvas.deinit();
            a.destroy(canvas);
        }
        if (self.chrome) |canvas| {
            canvas.deinit();
            a.destroy(canvas);
        }
        self.cursors.deinit();
        if (self.pointer) |value| wl.wl_pointer_destroy(value);
        if (self.seat) |value| wl.wl_seat_destroy(value);
        if (self.callback) |value| wl.wl_callback_destroy(value);
        for (&self.buffers) |*buffer| buffer.deinit();
        if (self.toplevel) |value| wl.xdg_toplevel_destroy(value);
        if (self.xdg) |value| wl.xdg_surface_destroy(value);
        self.dpi.deinit();
        if (self.surface) |value| wl.wl_surface_destroy(value);
        if (self.wm) |value| wl.xdg_wm_base_destroy(value);
        if (self.shm) |value| wl.wl_shm_destroy(value);
        if (self.compositor) |value| wl.wl_compositor_destroy(value);
        if (self.registry) |value| wl.wl_registry_destroy(value);
        wl.wl_display_disconnect(self.display);
        _ = c.close(self.wake_fd);
    }
    fn stopWorkers(self: *Window) void {
        self.browser.stop();
        self.minimap.stop();
        self.assets.stop();
        self.fonts.stop();
        if (self.keyboard_worker) |worker| input.mdf_keyboard_destroy(worker);
        self.keyboard_worker = null;
    }
    fn open(self: *Window) !void {
        const timing=trace.begin(self.recording,@src(),"Initialize native Wayland window",0);
        defer timing.end();
        self.dpi.context = self; self.dpi.notify = scaleChanged;
        self.registry = wl.wl_display_get_registry(self.display) orelse return error.RegistryUnavailable;
        _ = wl.wl_registry_add_listener(self.registry, &registry_listener, self);
        {
            const roundtrip=trace.begin(self.recording,@src(),"Wayland registry roundtrip — wait and callbacks",0);
            defer roundtrip.end();
            if (wl.wl_display_roundtrip(self.display) < 0) return error.WaylandHandshakeFailed;
        }
        if (self.compositor == null or self.shm == null or self.wm == null) return error.MissingWaylandGlobals;
        self.surface = wl.wl_compositor_create_surface(self.compositor) orelse return error.SurfaceUnavailable;
        _ = wl.wl_surface_add_listener(self.surface, &wl_surface_listener, self);
        try self.dpi.attach(self.surface.?);
        self.xdg = wl.xdg_wm_base_get_xdg_surface(self.wm, self.surface) orelse return error.XdgSurfaceUnavailable;
        _ = wl.xdg_surface_add_listener(self.xdg, &surface_listener, self);
        self.toplevel = wl.xdg_surface_get_toplevel(self.xdg) orelse return error.ToplevelUnavailable;
        _ = wl.xdg_toplevel_add_listener(self.toplevel, &toplevel_listener, self);
        try self.updateTitle();
        wl.xdg_toplevel_set_app_id(self.toplevel, "mdf");
        if (self.full_ui) wl.xdg_toplevel_set_min_size(self.toplevel, 480, 240);
        if (self.initial_maximized) wl.xdg_toplevel_set_maximized(self.toplevel);
        wl.wl_surface_commit(self.surface);
        if (wl.wl_display_flush(self.display) < 0 and c.__errno_location().* != c.EAGAIN) return error.WaylandFlushFailed;
    }
    fn pollDocument(self: *Window) !void {
        const value = c.mdf_core_poll(self.core);
        if (value.ptr == null) return;
        if(self.scroll_profile and self.ready_ns!=0) {c.mdf_buffer_free(value);return error.DocumentChangedDuringScrollProfile;}
        try self.acceptDocument(value);
    }
    fn updateTitle(self:*Window) !void {
        if(self.toplevel==null) return;
        const title=try std.fmt.allocPrintSentinel(a,"{s}{s}Markdown FAST",.{if(self.path.len>0) std.fs.path.basename(self.path) else "",if(self.path.len>0) " - " else ""},0);
        defer a.free(title);
        wl.xdg_toplevel_set_title(self.toplevel,title);
    }
    /// Takes ownership of one packet, whether polled here or by the launcher.
    fn acceptDocument(self: *Window, value: c.Buffer) !void {
        const timing=trace.begin(self.recording,@src(),"Accept loaded document packet",0);
        defer timing.end();
        defer c.mdf_buffer_free(value);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, reader.bytes(value), .{});
        defer parsed.deinit();
        if (parsed.value.object.get("err")) |err| {
            a.free(self.pending_fragment); self.pending_fragment=&.{}; self.fragment_revision=0;
            self.ui.message(err.string);
            if(self.fail_load) return error.DocumentLoadFailed;
            self.document_ready = true;
            self.dirty = true;
            if (self.document_revision == 0) self.assets.finished = true;
            return;
        }
        const path = try a.dupe(u8, parsed.value.object.get("path").?.string);
        self.assets.reset();
        self.minimap.reset(); self.ui.preview_atlas=null; self.minimap_error_shown=false;
        self.fonts.resetRequest();
        self.font_document = 0;
        self.font_error_shown = false;
        self.asset_jump_done = false;
        if (parsed.value.object.get("automatic").?.bool) {
            self.automatic_reloads += 1;
            if (self.content) |content| {
                const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
                const view = c.mdf_viewport_view(content.viewport);
                const anchor = c.mdf_viewport_index_at(content.viewport, fields.scroll, content.layouts.len);
                self.restore_anchor = anchor;
                self.restore_delta = if (view.offset_count > 0) fields.scroll - view.offsets[anchor] else 0;
                self.restore_horizontal = fields.horizontal_scroll;
            }
        }
        a.free(self.path);
        self.path = path;
        self.document_revision = @intCast(parsed.value.object.get("revision").?.integer);
        self.read_ns=@intCast(parsed.value.object.get("read_ns").?.integer);
        self.parse_ns=@intCast(parsed.value.object.get("parse_ns").?.integer);
        self.source_bytes=@intCast(parsed.value.object.get("source_bytes").?.integer);
        // Layout results own their generated strings and geometry. Borrowed
        // document strings are not accessed while these results are destroyed.
        if (self.content) |content| {
            content.deinit();
            a.destroy(content);
            self.content = null;
        }
        self.document_ready = true;
        self.ui.toc_scroll = 0;
        self.ui.message("Document loaded");
        self.dirty = true;
        try self.updateTitle();
    }
    fn availableBuffer(self: *Window) ?usize {
        for (self.buffers, 0..) |buffer, index| if (!buffer.busy) return index;
        return null;
    }
    fn pollAssets(self: *Window) !void {
        if (self.flushed_ns == 0 or self.flushed_revision != self.document_revision or !self.document_ready or self.document_revision == 0) return;
        if (!self.assets.started and c.mdf_core_navigation_ready(self.core)) {
            self.assets_dark = self.ui.dark;
            self.assets.start(self.core, self.assets_dark, self.fonts.drawing, wake) catch |err| {
                self.ui.message(@errorName(err));
                self.dirty = true;
            };
        }
        if (try self.assets.poll()) {
            if (self.content) |content| try content.refreshImages();
            self.dirty = true;
        }
        if (self.assets.finished and c.mdf_core_navigation_ready(self.core) and (self.assets_dark != self.ui.dark or self.assets.needsFonts(self.fonts.drawing))) {
            self.assets_dark = self.ui.dark;
            self.assets.restart(self.core, self.assets_dark, self.fonts.drawing, wake) catch |err| {
                self.ui.message(@errorName(err));
            };
        }
        if (self.ready_mode and self.assets.finished and !self.asset_jump_done) {
            const anchor=if(self.capture_anchor.len>0) self.capture_anchor else if(c.getenv("MDF_NATIVE_TEST_ANCHOR")) |text| std.mem.span(text) else "";
            if (anchor.len>0) if (self.content) |content| {
                content.jump(anchor);
                self.anchor_painted = false;
                self.dirty = true;
            };
            self.asset_jump_done = true;
        }
    }
    fn pollFonts(self: *Window) !void {
        if (self.flushed_ns == 0 or self.flushed_revision != self.document_revision) return;
        const canvas = self.canvas orelse return;
        var extras:[20][]const u8=undefined;
        @memcpy(extras[0..4],&[_][]const u8{self.path,if(self.ui.modal==.open) self.ui.path[0..self.ui.path_len] else "",self.ui.status[0..self.ui.status_len],self.assets.glyph_text.items});
        var count:usize=4;
        if(self.ui.modal==.open) if(self.ui.files) |files| {
            extras[count]=files.path;count+=1;
            const first=@min(self.ui.file_first,files.entries.len);
            const end=@min(files.entries.len,first+shell.Shell.fileRows(self.width,self.height));
            for(files.entries[first..end]) |entry| {extras[count]=entry.name;count+=1;}
        };
        var hash: std.hash.Wyhash = .init(0);
        for (extras[0..count]) |text| for (text) |byte| if (byte >= 128) {
            hash.update(&.{byte});
        };
        const ui_hash = hash.final();
        if (self.font_document != self.document_revision or self.font_ui_hash != ui_hash or self.font_asset_version != self.assets.glyph_version) {
            self.font_document = self.document_revision;
            self.font_ui_hash = ui_hash;
            self.font_asset_version = self.assets.glyph_version;
            const projection = c.mdf_core_document_text(self.core);
            extras[count]=reader.bytes(projection.text);count+=1;
            self.fonts.request(try canvas.font(0), extras[0..count], projection.flags & 1 != 0, projection.styles, wake) catch |err| {
                self.fonts.resetRequest();
                self.ui.message(@errorName(err));
                self.dirty = true;
            };
        }
        const changed = self.fonts.poll() catch |err| failed: {
            self.fonts.resetRequest();
            self.ui.message(@errorName(err));
            self.dirty = true;
            break :failed false;
        };
        if (changed) {
            if (self.content) |content| try content.invalidate();
            self.dirty = true;
        }
        if (!self.font_error_shown and self.fonts.message().len > 0) {
            self.ui.message(self.fonts.message());
            self.font_error_shown = true;
            self.dirty = true;
        }
    }
    fn pollMinimap(self: *Window) !void {
        if (!self.running) return;
        if (!self.full_ui or !self.ui.preview or self.document_revision == 0) {
            _ = try self.minimap.update(self.core,null,self.fonts.drawing,wake); return;
        }
        // Assets copy their encoded input before a navigation reflow can
        // invalidate Core's borrowed preview/image views.
        if (self.flushed_revision != self.document_revision or self.flushed_ns == 0 or !self.assets.started) return;
        const content = self.content orelse return;
        const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
        const bounds = self.ui.layout(self.width,self.height);
        const body_style=c.mdf_text_style(0,0,0,false,content.zoom);
        const base_style=c.mdf_text_style(0,0,0,false,1);
        const advance=try content.canvas.measure(.{ .face=0,.size=base_style.size,.flags=0 },"m");
        const font_size: i32 = @intFromFloat(std.math.clamp(@round(@as(f32,@floatFromInt(body_style.size))*@as(f32,@floatFromInt(bounds.right))/@max(1,fields.content_width)),2,4));
        const tiny=try content.canvas.measure(.{ .face=0,.size=font_size,.flags=0 },"m");
        const palette=paint.Palette.preset(self.ui.dark,@backingInt(self.ui.theme));
        const config: Minimap.Config = .{ .tracing=self.recording,.revision=self.document_revision,.width=bounds.right,.height=@max(1,bounds.view_height-40),
            .content_width=fields.content_width,.zoom=content.zoom,.advance=advance.width,.font_size=font_size,
            .slot_height=@intFromFloat(@ceil(tiny.height)+2),.baseline=tiny.height-tiny.descent+1,
            .scale=self.dpi.factor(),.background=palette.panel,.foreground=palette.muted,.font_version=self.fonts.drawing.sans_version };
        if (try self.minimap.update(self.core,config,self.fonts.drawing,wake)) self.dirty=true;
        if (!self.minimap_error_shown and self.minimap.message().len > 0) {
            self.ui.message(self.minimap.message()); self.minimap_error_shown=true; self.dirty=true;
        }
    }
    fn pollClipboard(self: *Window) !void {
        self.clipboard.poll() catch |err| {
            if(self.test_clipboard or self.test_paste or self.test_drop) return err;
            self.ui.message(@errorName(err)); self.dirty=true; return;
        };
        const received=self.clipboard.take() orelse return;
        defer a.free(received.bytes);
        switch(received.kind) {
            .testing => {},
            .paste => if(self.ui.modal==.open) {
                const text=std.mem.trim(u8,received.bytes,"\r\n");
                if(text.len>self.ui.path.len or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfAny(u8,text,"\r\n\x00")!=null)
                    self.ui.message("Invalid pasted path")
                else {self.ui.file_focus=false;self.ui.file_selected=null;self.ui.insertPath(text);}
                self.dirty=true;
            },
            .drop => {
                const reply=c.mdf_drop_path(received.bytes.ptr,received.bytes.len);
                defer c.mdf_buffer_free(reply);
                const parsed=try std.json.parseFromSlice(std.json.Value,a,reader.bytes(reply),.{});
                defer parsed.deinit();
                if(parsed.value.object.get("err")) |err| self.ui.message(err.string)
                else try self.openDocument(parsed.value.object.get("path").?.string);
                self.dirty=true;
            },
        }
    }
    fn exercisePaste(self: *Window) !void {
        if(self.frame_ns==0 or self.frame_pending or self.last_serial==0) return;
        const path=std.mem.span(c.getenv("MDF_NATIVE_TEST_OPEN") orelse return error.PasteTestPathMissing);
        switch(self.paste_stage) {
            0 => {
                if(wl.wl_display_roundtrip(self.display)<0) return error.WaylandDispatchFailed;
                const copied=try std.mem.concat(a,u8,&.{path,"\r\n"});
                defer a.free(copied);
                try self.clipboard.publish(copied,self.last_serial);
                try self.command(.open);
                self.paste_stage=1;
            },
            1 => if(self.clipboard.canPaste()) {
                try self.keyAction(input.XKB_KEY_v,true);
                self.paste_stage=2;
            },
            2 => if(std.mem.eql(u8,self.ui.path[0..self.ui.path_len],path)) {
                try self.keyAction(input.XKB_KEY_Return,false);
                self.paste_stage=3;
            },
            3 => if(self.document_revision>=2 and self.painted_revision==self.document_revision) {
                self.paste_stage=4; self.running=false;
            },
            else => {},
        }
    }
    fn snapshot(self:*Window,filename:[*:0]const u8) !void {
        const buffer=&self.buffers[self.last_buffer];
        var image=try paint.Canvas.init(a,buffer.width,buffer.height,.{});
        defer image.deinit();
        @memcpy(std.mem.sliceAsBytes(image.surface.image_surface_argb.buf),@as([*]const u8,@ptrCast(buffer.memory.?))[0..buffer.size]);
        try image.png(filename);
    }
    fn fileTestClick(self:*Window,x:i32,y:i32,time:u32) void {
        self.mouse_x=@floatFromInt(x);self.mouse_y=@floatFromInt(y);self.click_time=time;
        self.pointerAction(0);self.pointerAction(2);
    }
    fn exerciseBrowser(self:*Window) !void {
        if(self.frame_ns==0 or self.frame_pending or self.ui.file_loading) return;
        const root=std.mem.span(c.getenv("MDF_NATIVE_TEST_BROWSE") orelse return error.BrowserTestPathMissing);
        const box=shell.Shell.fileBox(self.width,self.height);
        switch(self.browser_stage) {
            0=>{
                if(self.browser.jobs!=0) return error.BrowserStartedBeforeOpen;
                self.browser_base_revision=self.document_revision;
                try self.command(.open);self.browser_stage=1;
            },
            1=>{
                if(self.chrome) |canvas| {
                    self.mouse_x=@floatFromInt(box.x+28);self.mouse_y=@floatFromInt(box.y+79);
                    self.pointerAction(0);
                    if(self.ui.path_cursor!=0 or self.ui.file_focus) return error.BrowserTestPathCaretMissing;
                    self.mouse_x+= (try canvas.measure(.{.face=0,.size=16,.flags=0},self.ui.path[0..self.ui.path_len])).width+1;
                    self.pointerAction(1);self.pointerAction(2);
                    if(self.ui.selectedPath().len!=self.ui.path_len) return error.BrowserTestPathDragMissing;
                }
                try self.keyAction(input.XKB_KEY_l,true);
                self.ui.insertPath(root);
                try self.keyAction(input.XKB_KEY_Home,false);self.ui.insertPath("x");
                try self.keyAction(input.XKB_KEY_BackSpace,false);
                try self.keyAction(input.XKB_KEY_Delete,false);self.ui.insertPath("/");
                try self.keyAction(input.XKB_KEY_End,false);
                if(!std.mem.eql(u8,self.ui.path[0..self.ui.path_len],root)) return error.BrowserTestPathEditingBroken;
                try self.keyAction(input.XKB_KEY_Return,false);
                self.browser_stage=2;
            },
            2=>{
                const files=self.ui.files orelse return error.BrowserTestListingMissing;
                if(!std.mem.eql(u8,files.path,root)) return error.BrowserTestWrongDirectory;
                self.fileTestClick(box.x+230,box.y+119,100);self.browser_stage=3;
            },
            3=>{
                const files=self.ui.files orelse return error.BrowserTestListingMissing;
                var hidden=false;var sub:?usize=null;
                for(files.entries,0..) |entry,index| {
                    if(std.mem.eql(u8,entry.name,".hidden.md")) hidden=true;
                    if(std.mem.eql(u8,entry.name,"sub")) sub=index;
                }
                if(!hidden or sub==null) return error.BrowserTestEntriesMissing;
                const y=box.y+140+@as(i32,@intCast(sub.?))*24+12;
                self.fileTestClick(box.x+70,y,200);self.fileTestClick(box.x+70,y,300);
                self.browser_stage=4;
            },
            4=>{
                const files=self.ui.files orelse return error.BrowserTestListingMissing;
                if(!std.mem.eql(u8,std.fs.path.basename(files.path),"sub")) return error.BrowserTestDirectoryNotEntered;
                self.fileTestClick(box.x+55,box.y+119,500);self.browser_stage=5;
            },
            5=>{
                const files=self.ui.files orelse return error.BrowserTestListingMissing;
                if(!std.mem.eql(u8,files.path,root)) return error.BrowserTestParentNotEntered;
                self.fileTestClick(box.x+140,box.y+119,700);self.browser_stage=6;
            },
            6=>{
                const files=self.ui.files orelse return error.BrowserTestListingMissing;
                if(!std.mem.eql(u8,files.path,root)) return error.BrowserTestHomeNotEntered;
                pointerAxis(self,null,0,wl.WL_POINTER_AXIS_VERTICAL_SCROLL,2560);
                self.browser_scrolled=self.ui.file_first>0;
                if(!self.browser_scrolled) return error.BrowserTestDidNotScroll;
                try self.keyAction(input.XKB_KEY_Tab,false);
                try self.keyAction(input.XKB_KEY_End,false);self.browser_stage=7;
            },
            7=>{
                if(!self.fonts.finished() or self.painted_fonts!=self.fonts.drawing.version or self.dirty) return;
                if(!self.fonts.sans_requested or self.fonts.unresolved()!=0) return error.BrowserTestGlyphFallbackMissing;
                if(c.getenv("MDF_NATIVE_TEST_DIALOG_CAPTURE")) |path| try self.snapshot(@ptrCast(path));
                try self.keyAction(input.XKB_KEY_Return,false);self.browser_stage=8;
            },
            8=>if(self.document_revision>self.browser_base_revision and self.painted_revision==self.document_revision) {
                self.browser_stage=9;self.running=false;
            },
            else=>{},
        }
    }
    fn present(self: *Window) !void {
        const scroll_started=if(self.scroll_sampling) c.mdf_now_ns() else 0;
        const timing=trace.begin(self.recording,@src(),"Paint and submit native window",0);
        defer timing.end();
        const buffer_index = self.availableBuffer() orelse return error.NoReleasedBuffer;
        const buffer = &self.buffers[buffer_index];
        if (self.width <= 0 or self.height <= 0 or self.width > 16384 or self.height > 16384) return error.InvalidWindowSize;
        const bounds = self.ui.layout(self.width, self.height);
        const body_width = if (self.full_ui) bounds.width else self.width;
        const body_height = if (self.full_ui) bounds.height else self.height;
        var resized = false;
        if (self.canvas) |canvas| resized = try canvas.resizeScaled(body_width, body_height, self.dpi.factor());
        if (self.canvas == null) {
            const canvas = try a.create(paint.Canvas);
            canvas.* = paint.Canvas.initScaled(a, body_width, body_height, paint.Palette.init(self.full_ui and self.ui.dark), self.dpi.factor()) catch |err| {
                a.destroy(canvas);
                return err;
            };
            self.canvas = canvas;
            canvas.profiling=self.recording;
            canvas.system_fonts = &self.fonts.drawing;
        }
        if (self.content == null) {
            const content = try a.create(reader.Reader);
            content.* = reader.Reader.init(a, self.core, self.canvas.?) catch |err| {
                a.destroy(content);
                return err;
            };
            self.content = content;
            content.images = &self.assets.images;
        }
        if (self.full_ui) {
            self.canvas.?.palette = paint.Palette.preset(self.ui.dark, @backingInt(self.ui.theme));
            const content = self.content.?;
            const zoom = @as(f32, @floatFromInt(self.ui.points)) / 12;
            if (content.zoom != zoom or content.wrap != self.ui.wrap or content.width_mode != self.ui.width_mode or resized) {
                content.zoom = zoom;
                content.wrap = self.ui.wrap;
                content.width_mode = self.ui.width_mode;
                try content.invalidate();
            }
        } else if (resized) try self.content.?.invalidate();
        if (self.restore_anchor) |anchor| {
            const content = self.content.?;
            const view = c.mdf_viewport_view(content.viewport);
            const fields: *c.MdfViewportFields = c.mdf_viewport_fields(content.viewport);
            if (view.offset_count > 0) fields.scroll = view.offsets[@min(anchor, content.layouts.len -| 1)] + self.restore_delta;
            fields.horizontal_scroll = self.restore_horizontal;
            self.restore_anchor = null;
        }
        if(self.pending_fragment.len>0 and self.fragment_revision==self.document_revision) {
            self.content.?.jump(self.pending_fragment);
            a.free(self.pending_fragment); self.pending_fragment=&.{}; self.fragment_revision=0;
        }
        try self.content.?.draw();
        if (self.full_ui) {
            const overflow = self.ui.wrap and try self.content.?.horizontalTotal() > @as(f32, @floatFromInt(body_width));
            if (self.ui.horizontal_overflow != overflow) {
                self.ui.horizontal_overflow = overflow;
                // The bar consumes height only, so retain cached fonts, column
                // measurements and block geometry instead of reflowing again.
                _ = try self.canvas.?.resizeScaled(body_width, self.ui.layout(self.width, self.height).height, self.dpi.factor());
                try self.content.?.draw();
            }
        }
        var pixels = std.mem.sliceAsBytes(self.canvas.?.surface.image_surface_argb.buf);
        if (self.full_ui) {
            if (self.chrome == null) {
                const chrome = try a.create(paint.Canvas);
                chrome.* = paint.Canvas.initScaled(a, self.width, self.height, paint.Palette.init(self.ui.dark), self.dpi.factor()) catch |err| {
                    a.destroy(chrome);
                    return err;
                };
                self.chrome = chrome;
                chrome.profiling=self.recording;
                chrome.system_fonts = &self.fonts.drawing;
            }
            _ = try self.chrome.?.resizeScaled(self.width, self.height, self.dpi.factor());
            self.chrome.?.palette = paint.Palette.preset(self.ui.dark, @backingInt(self.ui.theme));
            self.ui.preview_atlas=if (self.minimap.atlas) |*atlas| atlas else null;
            try self.ui.draw(self.chrome.?, self.content.?);
            try window_frame.draw(self.chrome.?, std.fs.path.basename(self.path), self.constrained, self.frame_hover);
            pixels = std.mem.sliceAsBytes(self.chrome.?.surface.image_surface_argb.buf);
        }
        // A released buffer can be replaced; busy buffers stay intact until
        // the compositor sends release, even across several configure events.
        const physical = try paint.Canvas.physicalSize(self.width, self.height, self.dpi.factor());
        if (buffer.width != physical[0] or buffer.height != physical[1]) buffer.deinit();
        if (buffer.buffer == null) {
            buffer.width = physical[0];
            buffer.height = physical[1];
            buffer.fd = c.memfd_create("mdf-native-frame", c.MFD_CLOEXEC);
            if (buffer.fd < 0 or c.ftruncate(buffer.fd, @intCast(pixels.len)) != 0) return error.FrameMemoryFailed;
            buffer.size = pixels.len;
            buffer.memory = c.mmap(null, pixels.len, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, buffer.fd, 0);
            if (buffer.memory == c.MAP_FAILED or buffer.memory == null) {
                buffer.memory = null;
                return error.FrameMappingFailed;
            }
            const pool = wl.wl_shm_create_pool(self.shm, buffer.fd, @intCast(pixels.len)) orelse return error.FramePoolFailed;
            defer wl.wl_shm_pool_destroy(pool);
            buffer.buffer = wl.wl_shm_pool_create_buffer(pool, 0, buffer.width, buffer.height, buffer.width * 4, wl.WL_SHM_FORMAT_ARGB8888) orelse return error.FrameBufferFailed;
            _ = wl.wl_buffer_add_listener(buffer.buffer, &buffer_listener, buffer);
        }
        @memcpy(@as([*]u8, @ptrCast(buffer.memory.?))[0..pixels.len], pixels);
        self.callback = wl.wl_surface_frame(self.surface) orelse return error.FrameCallbackFailed;
        _ = wl.wl_callback_add_listener(self.callback, &frame_listener, self);
        wl.xdg_surface_set_window_geometry(self.xdg, 0, 0, self.width, self.height);
        self.dpi.prepare(self.surface.?, self.width, self.height);
        wl.wl_surface_attach(self.surface, buffer.buffer, 0, 0);
        if (wl.wl_proxy_get_version(@ptrCast(self.surface.?)) >= 4) wl.wl_surface_damage_buffer(self.surface, 0, 0, buffer.width, buffer.height)
        else wl.wl_surface_damage(self.surface, 0, 0, self.width, self.height);
        wl.wl_surface_commit(self.surface);
        if (self.committed_ns == 0) {
            self.committed_ns = c.mdf_now_ns();
            self.first_viewport_mono = self.fonts.drawing.mono != null;
            self.first_viewport_fallback = self.fonts.drawing.sans != null;
            self.first_viewport_scale = self.dpi.scale120;
            self.first_viewport_minimap = self.minimap.atlas != null;
            self.mark("First Markdown commit",self.committed_ns);
        }
        self.committed = true;
        self.painted_revision = self.document_revision;
        self.painted_width = self.width; self.painted_height = self.height; self.painted_scale = self.dpi.scale120;
        self.painted_assets = self.assets.images.version;
        self.painted_fonts = self.fonts.drawing.version;
        self.painted_minimap = self.minimap.version;
        self.anchor_painted = true;
        self.frame_pending = true;
        buffer.busy = true;
        self.last_buffer = buffer_index;
        self.dirty = false;
        self.paints += 1;
        if(scroll_started!=0) {
            self.scroll_values[self.scroll_count]=@as(f64,@floatFromInt(c.mdf_now_ns()-scroll_started))/std.time.ns_per_ms;
            self.scroll_count+=1;self.scroll_sampling=false;
        }
    }
    fn run(self: *Window) !void {
        const wayland_fd = wl.wl_display_get_fd(self.display);
        while (self.running or (self.committed and self.flushed_ns == 0)) {
            {
                const dispatch=trace.begin(self.recording,@src(),"Dispatch queued native Wayland events",0);
                defer dispatch.end();
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatchFailed;
            }
            try self.pollDocument();
            try self.pollBrowser();
            try self.pollKeyboard();
            try self.pollClipboard();
            if(self.test_paste) try self.exercisePaste();
            if(self.test_browser) try self.exerciseBrowser();
            if(self.test_drop and self.drop_stage==1 and self.document_revision>=2 and self.painted_revision==self.document_revision and
                !self.frame_pending and self.clipboard.test_drop_finished) { self.drop_stage=2; self.running=false; }
            if(self.external.poll()) { self.ui.message("The system link handler failed"); self.dirty=true; }
            if (self.test_clipboard and self.paints >= 1 and !self.frame_pending) {
                if (!self.clipboard_started and self.last_serial != 0) {
                    // Drain a previous application's clipboard offer before
                    // arming this test's receive path. This synchronization is
                    // only in the clipboard integration test, after frame one.
                    if (wl.wl_display_roundtrip(self.display) < 0) return error.WaylandDispatchFailed;
                    self.clipboard.testing = true;
                    self.content.?.selectAll();
                    try self.keyAction(input.XKB_KEY_c, true);
                    self.clipboard_started = true;
                }
                if (self.clipboard.test_done) self.running = false;
            }
            if (self.test_keyboard) try self.exerciseKeyboard();
            if (self.running and self.configured and self.document_ready and self.dirty and !self.frame_pending and self.availableBuffer() != null) try self.present();
            const flushed = wl.wl_display_flush(self.display);
            if (flushed >= 0 and self.committed and self.flushed_ns == 0) {
                self.flushed_ns = c.mdf_now_ns();
                self.mark("First Markdown viewport",self.flushed_ns);
            }
            if (flushed >= 0 and self.committed) self.flushed_revision = self.painted_revision;
            if (flushed < 0 and c.__errno_location().* != c.EAGAIN) return error.WaylandFlushFailed;
            try self.pollAssets();
            try self.pollFonts();
            try self.pollMinimap();
            self.checkReady();
            if (!self.running and (!self.committed or self.flushed_ns != 0)) break;
            if (!self.interactive and c.mdf_now_ns() - self.began > 30 * std.time.ns_per_s) {
                if (self.test_menu or self.test_frame or self.test_resize or self.test_links or self.test_paste or self.test_drop or self.test_browser) {
                    const diagnostic = try std.json.Stringify.valueAlloc(a, .{ .link_stage=self.link_stage,.external=self.external.launches,.children=self.external.children.items.len,
                        .painted_revision=self.painted_revision,.fragment=self.pending_fragment,.fragment_revision=self.fragment_revision,
                        .frame_stage = self.frame_stage, .resize_stage = self.resize_stage, .cursor_commits = self.cursors.commits,
                        .pointer = self.pointer != null, .pointer_inside = self.pointer_inside, .width = self.width, .height = self.height,
                        .normal_width = self.normal_width, .normal_height = self.normal_height, .constrained = self.constrained,
                        .browser_stage=self.browser_stage,.browser_loading=self.ui.file_loading,.browser_error=self.ui.file_message,.browser_first=self.ui.file_first,
                        .drop_stage=self.drop_stage,.drop_finished=self.clipboard.test_drop_finished,.paste_stage=self.paste_stage,.can_paste=self.clipboard.canPaste(),.receive_fd=self.clipboard.receiver.fd,
                        .menu_stage = self.menu_stage, .paints = self.paints, .revision = self.document_revision, .modal = self.ui.modal, .status = self.ui.status[0..self.ui.status_len], .path = self.path }, .{});
                    defer a.free(diagnostic);
                    _ = c.fwrite(diagnostic.ptr, 1, diagnostic.len, c.stderr);
                }
                return error.WindowTimeout;
            }
            var descriptors = [_]c.struct_pollfd{
                .{ .fd = wayland_fd, .events = @intCast(c.POLLIN | (if (flushed < 0) @as(c_int, c.POLLOUT) else 0)), .revents = 0 },
                .{ .fd = self.wake_fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.clipboard.receiver.fd, .events = c.POLLIN, .revents = 0 },
            };
            if (self.waits.poll(self.recording,&descriptors) < 0) {
                if (c.__errno_location().* == c.EINTR) continue;
                return error.PollFailed;
            }
            if (descriptors[1].revents & c.POLLIN != 0) {
                var value: u64 = 0;
                _ = c.read(self.wake_fd, &value, @sizeOf(u64));
            }
            if (descriptors[0].revents & c.POLLIN != 0) {
                const dispatch=trace.begin(self.recording,@src(),"Read and dispatch native Wayland events",0);
                defer dispatch.end();
                if(wl.wl_display_dispatch(self.display)<0) return error.WaylandDispatchFailed;
            }
            if (descriptors[0].revents & (c.POLLERR | c.POLLHUP) != 0) return error.WaylandDisconnected;
        }
    }
    fn checkReady(self: *Window) void {
        if (!self.ready_mode or !self.committed or self.frame_ns == 0 or self.frame_pending or self.dirty) return;
        if(self.keyboard!=null and !self.keyboard_failed and (self.keyboard_pending or self.keyboard_value.state==null)) return;
        if (!self.assets.finished or !self.fonts.finished() or !self.anchor_painted or
            self.assets_dark != self.ui.dark or self.assets.needsFonts(self.fonts.drawing) or
            self.painted_fonts != self.fonts.drawing.version or self.painted_assets != self.assets.images.version or
            self.painted_revision != self.document_revision or self.painted_scale != self.dpi.scale120) return;
        if (self.full_ui and self.ui.preview and (!self.minimap.finished or self.painted_minimap != self.minimap.version)) return;
        if (self.test_diagram and self.diagram_stage < 6) {
            self.exerciseDiagram() catch |err| { self.failure = err; self.running = false; };
            return;
        }
        if (self.test_minimap and !self.minimap_dragged) {
            const bounds=self.ui.layout(self.width,self.height);
            const track=@max(1,bounds.view_height-40);
            const thumb=shell.thumbHeight(bounds.view_height);
            self.mouse_x=@as(f32,@floatFromInt(self.width))-@as(f32,@floatFromInt(bounds.right))/2;
            self.mouse_y=94+@as(f32,@floatFromInt(thumb))/2;
            self.pointerAction(0);
            self.mouse_y=94+@as(f32,@floatFromInt(track-thumb))*0.8+@as(f32,@floatFromInt(thumb))/2;
            self.pointerAction(1); self.pointerAction(2);
            self.minimap_dragged=true; self.minimap_drag_jobs=self.minimap.jobs;
            return;
        }
        if (self.asset_theme_test and !self.asset_theme_done) {
            self.ui.apply(.theme); self.asset_theme_done = true; self.dirty = true;
        } else {
            if(self.ready_ns==0) {
                self.ready_ns=c.mdf_now_ns();
                self.mark("Native fully ready",self.ready_ns);
                self.startup_paints=self.paints;
                self.startup_font_styles=(if(self.canvas) |canvas| canvas.loaded_styles else @as(u32,0))|(if(self.chrome) |canvas| canvas.loaded_styles else @as(u32,0));
                if(self.profiling) {
                    self.ready_usage=c.mdf_get_profile_usage();
                    self.startup_profile=c.mdf_core_profile(self.core);
                    if(self.startup_profile.ptr==null) {self.failure=error.CannotCaptureStartupProfile;self.running=false;return;}
                }
                if(self.scroll_profile) {
                    self.scroll_revision=self.document_revision;
                    self.scroll_original=c.mdf_viewport_fields(self.content.?.viewport).*.scroll;
                    if(self.capture) |filename| {
                        self.snapshot(filename) catch |err| {self.failure=err;self.running=false;return;};
                        self.capture_done=true;
                    }
                    self.recording=false;self.assets.tracing=false;self.fonts.tracing=false;
                    if(self.canvas) |canvas| canvas.profiling=false;
                    if(self.chrome) |canvas| canvas.profiling=false;
                }
            }
            if(self.scroll_profile and self.scroll_count<self.scroll_values.len) {
                const content=self.content.?;
                const height:@TypeOf(@as(f32,0))=@floatFromInt(content.canvas.logical_height);
                const maximum=@max(0,c.mdf_viewport_total(content.viewport)-height);
                c.mdf_viewport_move(content.viewport,maximum*@as(f32,@floatFromInt(self.scroll_count))/@as(f32,@floatFromInt(self.scroll_values.len-1)),height);
                self.scroll_sampling=true;self.dirty=true;
            } else if(self.scroll_profile and !self.scroll_restore) {
                self.scroll_restore=true;
                c.mdf_viewport_move(self.content.?.viewport,self.scroll_original,@floatFromInt(self.content.?.canvas.logical_height));
                self.dirty=true;
            } else self.running=false;
        }
    }
};
fn evaluate(path: [*:0]const u8, capture: ?[*:0]const u8, mode: []const u8, startup: ?*c.struct_MdfStartup) !void {
    const began = if(startup) |value| value.origin_ns else c.mdf_now_ns();
    const wake_fd = c.eventfd(0, c.EFD_CLOEXEC | c.EFD_NONBLOCK);
    if (wake_fd < 0) return error.WakeFdFailed;
    const display = wl.wl_display_connect(null) orelse {
        _ = c.close(wake_fd);
        return error.WaylandUnavailable;
    };
    const use_preferences = std.mem.eql(u8, mode, "--interactive") or std.mem.eql(u8, mode, "--test-preferences") or std.mem.eql(u8, mode, "--test-load-preferences");
    const home: [*:0]const u8 = if (use_preferences) @ptrCast(c.getenv("HOME") orelse @as([*c]const u8, "")) else "";
    const core = (if(startup) |value| value.core else c.mdf_core_create(home, std.mem.len(home), false, 0, wake)) orelse {
        wl.wl_display_disconnect(display);
        _ = c.close(wake_fd);
        return error.CoreCreationFailed;
    };
    var window = Window{ .core = core, .display = display, .wake_fd = wake_fd, .capture = capture, .began = began, .interactive = std.mem.eql(u8, mode, "--interactive"), .test_scroll = std.mem.eql(u8, mode, "--test-scroll"), .test_selection = std.mem.eql(u8, mode, "--test-selection"), .test_details = std.mem.eql(u8, mode, "--test-details") };
    if(startup) |value| {
        window.capture_anchor=std.mem.span(value.options.anchor);
        window.fail_load=value.options.flags&(c.MDF_LAUNCH_PROFILE|c.MDF_LAUNCH_BENCHMARK)!=0;
        window.profiling=window.fail_load;
        window.recording=window.profiling;
        window.scroll_profile=value.options.flags&c.MDF_LAUNCH_SCROLL!=0;
        window.assets.tracing=window.profiling;
        window.fonts.tracing=window.profiling;
        trace.signal(window.profiling,@src(),"UI frontend entered",0);
    }
    window.test_keyboard = std.mem.eql(u8, mode, "--test-keyboard");
    window.test_clipboard = std.mem.eql(u8, mode, "--test-clipboard");
    window.test_paste=std.mem.eql(u8,mode,"--test-paste");
    window.test_browser=std.mem.eql(u8,mode,"--test-browser") or std.mem.eql(u8,mode,"--test-browser-empty");
    window.test_drop=std.mem.eql(u8,mode,"--test-drop");
    window.test_resize = std.mem.eql(u8, mode, "--test-resize");
    window.test_frame = std.mem.eql(u8, mode, "--test-frame");
    window.test_links = std.mem.eql(u8,mode,"--test-links");
    window.test_first_dirty = std.mem.eql(u8, mode, "--test-first-dirty");
    window.test_menu = std.mem.eql(u8, mode, "--test-menu");
    window.test_preferences = std.mem.eql(u8, mode, "--test-preferences");
    window.test_watch = std.mem.eql(u8, mode, "--test-watch");
    window.asset_theme_test = std.mem.eql(u8, mode, "--ready-theme");
    window.test_minimap=std.mem.eql(u8,mode,"--test-minimap");
    const show_dialog=std.mem.eql(u8,mode,"--show-dialog") or std.mem.eql(u8,mode,"--show-dialog-dark") or std.mem.eql(u8,mode,"--show-dialog-small");
    const ready_hidden=std.mem.eql(u8,mode,"--ready-ui-no-preview");
    window.ready_mode = window.asset_theme_test or window.test_minimap or ready_hidden or std.mem.eql(u8, mode, "--ready") or std.mem.eql(u8, mode, "--ready-ui");
    window.full_ui = window.asset_theme_test or use_preferences or window.test_menu or window.test_resize or window.test_watch or std.mem.eql(u8, mode, "--test-toolbar") or std.mem.eql(u8, mode, "--ui") or std.mem.eql(u8, mode, "--show-menu") or show_dialog;
    window.test_toolbar = std.mem.eql(u8, mode, "--test-toolbar");
    window.test_table = std.mem.eql(u8, mode, "--test-table");
    window.test_diagram = std.mem.eql(u8, mode, "--test-diagram") or std.mem.eql(u8, mode, "--test-diagram-dark");
    if (window.test_diagram) {
        window.ready_mode = true;
        window.full_ui = true;
        window.ui.dark = std.mem.eql(u8, mode, "--test-diagram-dark");
    }
    if (window.test_table) {
        window.full_ui = true;
        window.ui.toc = false;
        window.ui.preview = false;
    }
    window.full_ui = window.full_ui or window.test_browser or window.test_paste or window.test_drop or window.test_frame or window.test_links or window.test_minimap or ready_hidden or std.mem.eql(u8, mode, "--ready-ui");
    if(ready_hidden) window.ui.preview=false;
    if(startup) |value| if(value.options.flags&c.MDF_LAUNCH_READER!=0) { window.ui.toc=false; window.ui.preview=false; };
    if (window.full_ui) {
        window.width = 1040;
        window.height = 780;
    }
    if (window.test_resize or window.test_frame) {
        window.width = 800;
        window.height = 600;
    }
    if(std.mem.eql(u8,mode,"--show-dialog-small")) {window.width=480;window.height=240;}
    if(window.test_table) {window.width=480;window.height=780;}
    if(window.test_diagram) {window.width=480;window.height=780;}
    if(std.mem.eql(u8,mode,"--show-dialog-dark")) window.ui.dark=true;
    if (std.mem.eql(u8, mode, "--show-menu")) window.ui.menu.opened = .font;
    if (use_preferences) {
        const stored = c.mdf_core_settings(core);
        defer c.mdf_buffer_free(stored);
        const decoded = try std.json.parseFromSlice(shell.preferences.Values, a, reader.bytes(stored), .{});
        defer decoded.deinit();
        window.ui.load(decoded.value);
        window.width = decoded.value.window.width;
        window.height = decoded.value.window.height;
        window.initial_maximized = decoded.value.window.maximized;
    }
    active.store(&window, .release);
    defer {
        c.mdf_core_set_wake(core, null);
        window.stopWorkers();
        active.store(null, .release);
        window.deinit();
        if(startup==null) c.mdf_core_destroy(core);
    }
    c.mdf_core_set_wake(core, wake);
    if(startup) |value| {
        const packet=value.document;
        value.document=.{.ptr=null,.len=0};
        if(packet.ptr!=null) try window.acceptDocument(packet)
        else if(path[0]==0) { window.document_ready=true; window.assets.finished=true; }
    } else {
        if(path[0]==0) {window.document_ready=true;window.assets.finished=true;}
        else {const opened=c.mdf_core_open(core,path,std.mem.len(path));defer c.mdf_buffer_free(opened);}
    }
    if(show_dialog) try window.openFileDialog(std.mem.span(path));
    try window.open();
    window.backend_ns=c.mdf_now_ns();
    try window.run();
    if (window.failure) |err| return err;
    if(window.scroll_profile and window.scroll_count!=window.scroll_values.len) return error.ScrollProfileInterrupted;
    if (use_preferences) try window.updateSettings();
    if (window.frame_ns == 0) return error.NoPresentedFrame;
    // Capture after the measured commit/flush/frame callbacks.
    if(!window.capture_done) if (capture) |filename| try window.snapshot(filename);
    if(startup!=null and !window.profiling) return;
    const BodyInfo = struct { width: i32, height: i32, horizontal_scroll: f32, horizontal_extent: f32, horizontal_overflow: bool };
    const body: BodyInfo = if (window.content) |content| .{ .width = content.canvas.logical_width, .height = content.canvas.logical_height,
        .horizontal_scroll = c.mdf_viewport_fields(content.viewport).*.horizontal_scroll,
        .horizontal_extent = c.mdf_viewport_fields(content.viewport).*.horizontal_extent, .horizontal_overflow = window.ui.horizontal_overflow
    } else .{ .width = 0, .height = 0, .horizontal_scroll = 0, .horizontal_extent = 0, .horizontal_overflow = false };
    const code_style: paint.FontSpec = .{ .face = 0, .size = 17, .flags = 1 };
    const code_narrow = if (window.fonts.drawing.mono != null) (try window.canvas.?.measure(code_style, "iiii")).width else @as(f32, 0);
    const code_wide = if (window.fonts.drawing.mono != null) (try window.canvas.?.measure(code_style, "WWWW")).width else @as(f32, 0);
    const profile_packet=if(window.startup_profile.ptr!=null) window.startup_profile else c.mdf_core_profile(core);
    window.startup_profile=.{.ptr=null,.len=0};
    defer c.mdf_buffer_free(profile_packet);
    var profile: ?std.json.Parsed(std.json.Value)=if(profile_packet.ptr!=null) try std.json.parseFromSlice(std.json.Value,a,reader.bytes(profile_packet),.{}) else null;
    defer if(profile) |*value| value.deinit();
    if(profile) |*value| {
        const events=value.value.object.getPtr("events").?;
        try window.waits.annotate(events,value.arena.allocator(),began);
    }
    const report = try std.json.Stringify.valueAlloc(a, .{
        .renderer = "native Wayland/z2d evaluation",
        .bootstrapped=startup!=null,
        .file_browser=.{.jobs=window.browser.jobs,.stage=window.browser_stage,.initial_revision=window.browser_base_revision,.scrolled=window.browser_scrolled,
            .loading=window.ui.file_loading,.entries=if(window.ui.files) |files| files.entries.len else @as(usize,0)},
        .process_id=c.getpid(),.wayland_fd=wl.wl_display_get_fd(window.display),
        .mode=std.mem.span(c.mdf_core_mode()),.ui_mode=std.mem.span(c.mdf_core_mode()),
        .compiler=@import("builtin").zig_version_string,
        .backend_ms=@as(f64,@floatFromInt(window.backend_ns-began))/std.time.ns_per_ms,
        .read_ms=@as(f64,@floatFromInt(window.read_ns))/std.time.ns_per_ms,
        .parse_ms=@as(f64,@floatFromInt(window.parse_ns))/std.time.ns_per_ms,
        .source_bytes=window.source_bytes,.blocks=c.mdf_core_document_text(core).count,
        .startup_usage=window.ready_usage,
        .startup_paints=window.startup_paints,.startup_font_styles=window.startup_font_styles,
        .scroll_draw_ms=window.scroll_values[0..window.scroll_count],.scroll_frames=window.scroll_count,
        .scroll_scope="Native layout, rasterization, chrome and SHM submission; excludes compositor callback wait",
        .scroll_restored=window.scroll_restore,
        .ui_module_ready_ms=if(startup) |value| @as(f64,@floatFromInt(value.ui_ready_ns-began))/std.time.ns_per_ms else 0,
        .ui_module_bytes=if(startup) |value| value.ui_module_bytes else 0,
        .bundled_font_styles=(if(window.canvas) |canvas| canvas.loaded_styles else @as(u32,0))|(if(window.chrome) |canvas| canvas.loaded_styles else @as(u32,0)),
        .ready_ms=if(window.ready_ns>0) @as(f64,@floatFromInt(window.ready_ns-began))/std.time.ns_per_ms else 0,
        .dropped_wait_details=window.waits.dropped,
        .profile=if(profile) |value| value.value else .null,
        .main_started_ns = began,
        .width = window.painted_width,
        .height = window.painted_height,
        .pixel_width = window.buffers[window.last_buffer].width, .pixel_height = window.buffers[window.last_buffer].height,
        .scale120 = window.painted_scale, .requested_scale120 = window.dpi.scale120,
        .first_viewport_scale120 = window.first_viewport_scale, .fractional_viewport = window.dpi.viewport != null,
        .cursor_scale = window.cursors.scale,
        .links = .{ .stage=window.link_stage,.external=window.external.launches,.children=window.external.children.items.len },
        .minimap = .{ .finished=window.minimap.finished,.jobs=window.minimap.jobs,.version=window.minimap.version,
            .font_version=if(window.minimap.atlas) |atlas| atlas.config.font_version else @as(u64,0),
            .dragged=window.minimap_dragged,.drag_jobs=window.minimap_drag_jobs,.thumb_height=shell.thumbHeight(window.ui.layout(window.width,window.height).view_height),
            .lines=if (window.minimap.atlas) |atlas| atlas.lines.len else @as(usize,0),.first_viewport=window.first_viewport_minimap,
            .error_message=window.minimap.message(),.started_ms=if(window.minimap.started_ns>0) @as(f64,@floatFromInt(window.minimap.started_ns-began))/std.time.ns_per_ms else 0 },
        .paints = window.paints,
        .scroll = if (window.content) |content| c.mdf_viewport_fields(content.viewport).*.scroll else @as(f32, 0),
        .selected_bytes = if (window.content) |content| content.selected().len else @as(usize, 0),
        .details_preserved = if (window.detail_index) |index| window.content.?.details_open[index] == window.detail_initial and
            c.mdf_core_block(core, index).flags == window.detail_document_flags else false,
        .keyboard_ready = window.keyboard_value.state != null,
        .keyboard_test = window.keyboard_test_done,
        .clipboard_test = window.clipboard.test_done,
        .clipboard_bytes = window.clipboard.received.len,
        .paste_stage=window.paste_stage,
        .drop_stage=window.drop_stage,
        .drop_finished=window.clipboard.test_drop_finished,
        .resize_stage = window.resize_stage,
        .frame_stage = window.frame_stage, .cursor_commits = window.cursors.commits,
        .menu_test = window.menu_stage,
        .table_stage = window.table_stage,
        .diagram_stage = window.diagram_stage,
        .document_revision = window.document_revision,
        .document_path = window.path,
        .automatic_reloads = window.automatic_reloads,
        .status = window.ui.status[0..window.ui.status_len],
        .assets = .{ .finished = window.assets.finished, .worker_started = window.assets.had_jobs, .count = window.assets.images.values.count(), .threads_started = window.assets.threads_started, .font_version = window.assets.font_version, .counts = window.assets.counts(), .started_ms = if (window.assets.started_ns > 0) @as(f64, @floatFromInt(window.assets.started_ns - began)) / std.time.ns_per_ms else 0, .finished_ms = if (window.assets.finished_ns > 0) @as(f64, @floatFromInt(window.assets.finished_ns - began)) / std.time.ns_per_ms else 0, .svg_loaded = input.mdf_diagram_stats(input.MDF_MODULE_SVG).ready_ns != 0, .mermaid_loaded = input.mdf_diagram_stats(input.MDF_MODULE_MERMAID).ready_ns != 0 },
        .fonts = .{ .mono_requested = window.fonts.mono_requested, .sans_requested = window.fonts.sans_requested, .mono_ready = window.fonts.drawing.mono != null, .sans_ready = window.fonts.drawing.sans != null, .finished = window.fonts.finished(), .module_loaded = input.mdf_diagram_stats(input.MDF_MODULE_TEXT).ready_ns != 0, .first_viewport_mono = window.first_viewport_mono, .first_viewport_fallback = window.first_viewport_fallback, .mono_family = window.fonts.family(true), .sans_family = window.fonts.family(false), .requested_characters = window.fonts.characters.len, .unresolved = window.fonts.unresolved(), .error_message = window.fonts.message(), .version = window.fonts.drawing.version, .sans_version = window.fonts.drawing.sans_version, .code_widths = .{ .narrow = code_narrow, .wide = code_wide }, .started_ms = if (window.fonts.started_ns > 0) @as(f64, @floatFromInt(window.fonts.started_ns - began)) / std.time.ns_per_ms else 0 },
        .preferences = window.ui.values(.{ .width = window.width, .height = window.height, .maximized = window.constrained }),
        .resized_width = window.resized_width,
        .resized_height = window.resized_height,
        .zoom = if (window.content) |content| content.zoom else @as(f32, 1),
        .full_ui = window.full_ui,
        .ui = .{ .toc = window.ui.toc, .preview = window.ui.preview, .dark = window.ui.dark, .wrap = window.ui.wrap, .points = window.ui.points },
        .body = body,
        .configure_ms = @as(f64, @floatFromInt(window.configured_ns - began)) / std.time.ns_per_ms,
        .commit_ms = @as(f64, @floatFromInt(window.committed_ns - began)) / std.time.ns_per_ms,
        .flush_ms = @as(f64, @floatFromInt(window.flushed_ns - began)) / std.time.ns_per_ms,
        .frame_callback_ms = @as(f64, @floatFromInt(window.frame_ns - began)) / std.time.ns_per_ms,
    }, .{});
    defer a.free(report);
    const shared=if(window.profiling) try @import("profile.zig").report(a,report) else null;
    defer if(shared) |value| a.free(value);
    const output=shared orelse report;
    if (c.fwrite(output.ptr, 1, output.len, c.stdout) != output.len) return error.CannotWriteReport;
}
pub fn runStartup(startup: *c.struct_MdfStartup) !void {
    if(startup.abi!=c.MDF_FRONTEND_ABI or startup.size!=@sizeOf(c.struct_MdfStartup) or startup.core==null or
        startup.options.path==null or startup.options.capture==null or startup.options.anchor==null) return error.FrontendAbiMismatch;
    const profile=startup.options.flags&(c.MDF_LAUNCH_PROFILE|c.MDF_LAUNCH_BENCHMARK)!=0;
    try evaluate(@ptrCast(startup.options.path),if(startup.options.capture[0]!=0) @ptrCast(startup.options.capture) else null,
        if(profile) "--ready-ui" else "--interactive",startup);
}
pub fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    if (argc < 2) return 2;
    if (std.mem.eql(u8, std.mem.span(argv[1]), "--text-probe")) {
        @import("text-probe.zig").run(if (argc > 2) argv[2] else "native-text.png") catch |err| {
            const message = @errorName(err);
            _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
            return 1;
        };
        return 0;
    }
    evaluate(argv[1], if (argc > 2) argv[2] else null, if (argc > 3) std.mem.span(argv[3]) else "",null) catch |err| {
        const message = @errorName(err);
        _ = c.fwrite(message.ptr, 1, message.len, c.stderr);
        return 1;
    };
    return 0;
}
