//! Optional Wayland scale protocols. No extra startup roundtrip is required.
const std = @import("std");
const wl = @import("wayland");
const policy = @import("scale-policy.zig");
const a = std.heap.c_allocator;
const Output = struct {
    owner: *Scale,
    proxy: *wl.wl_output,
    name: u32,
    factor: u32 = 1,
    entered: bool = false,
    fn destroy(self: *Output) void {
        if (wl.wl_proxy_get_version(@ptrCast(self.proxy)) >= 3) wl.wl_output_release(self.proxy) else wl.wl_output_destroy(self.proxy);
        a.destroy(self);
    }
    fn geometry(_: ?*anyopaque, _: ?*wl.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
    fn mode(_: ?*anyopaque, _: ?*wl.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn done(_: ?*anyopaque, _: ?*wl.wl_output) callconv(.c) void {}
    fn label(_: ?*anyopaque, _: ?*wl.wl_output, _: [*c]const u8) callconv(.c) void {}
    fn scale(data: ?*anyopaque, _: ?*wl.wl_output, factor: i32) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(data.?));
        if (factor < 1 or factor > 8) return;
        self.factor = @intCast(factor);
        self.owner.recompute();
    }
    const listener: wl.wl_output_listener = .{ .geometry = geometry, .mode = mode, .done = done, .scale = scale, .name = label, .description = label };
};
pub const Scale = struct {
    viewport_manager: ?*wl.wp_viewporter = null,
    fractional_manager: ?*wl.wp_fractional_scale_manager_v1 = null,
    viewport: ?*wl.wp_viewport = null,
    fractional: ?*wl.wp_fractional_scale_v1 = null,
    outputs: [16]?*Output = @splat(null),
    state: policy.Policy = .{},
    scale120: u32 = 120,
    context: ?*anyopaque = null,
    notify: ?*const fn (?*anyopaque) void = null,

    pub fn factor(self: *const Scale) f32 {
        return @as(f32, @floatFromInt(self.scale120)) / 120;
    }
    pub fn cursorScale(self: *const Scale) u32 {
        return @max(1, (self.scale120 + 119) / 120);
    }
    pub fn bind(self: *Scale, registry: *wl.wl_registry, name: u32, kind: []const u8, version: u32) void {
        if (std.mem.eql(u8, kind, "wp_viewporter") and self.viewport_manager == null) {
            self.viewport_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wp_viewporter_interface, 1));
        } else if (std.mem.eql(u8, kind, "wp_fractional_scale_manager_v1") and self.fractional_manager == null) {
            self.fractional_manager = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wp_fractional_scale_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, kind, "wl_output")) {
            for (&self.outputs) |*slot| if (slot.* == null) {
                const output = a.create(Output) catch return;
                const proxy: *wl.wl_output = @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_output_interface, @min(version, 4)) orelse {
                    a.destroy(output);
                    return;
                });
                output.* = .{ .owner = self, .proxy = proxy, .name = name };
                slot.* = output;
                _ = wl.wl_output_add_listener(proxy, &Output.listener, output);
                return;
            };
        }
    }
    pub fn remove(self: *Scale, name: u32) void {
        for (&self.outputs) |*slot| if (slot.*) |output| if (output.name == name) {
            output.destroy();
            slot.* = null;
            self.recompute();
            return;
        };
    }
    pub fn enter(self: *Scale, proxy: ?*wl.wl_output, entered: bool) void {
        for (self.outputs) |slot| if (slot) |output| if (output.proxy == proxy) {
            output.entered = entered;
        };
        self.recompute();
    }
    pub fn preferred(self: *Scale, factor_value: i32) void {
        if (factor_value < 1 or factor_value > 8) return;
        self.state.preferred = @intCast(factor_value);
        self.recompute();
    }
    fn fractionalScale(data: ?*anyopaque, _: ?*wl.wp_fractional_scale_v1, units: u32) callconv(.c) void {
        const self: *Scale = @ptrCast(@alignCast(data.?));
        if (units == 0 or units > 960) return;
        self.state.fractional = units;
        self.recompute();
    }
    const fractional_listener: wl.wp_fractional_scale_v1_listener = .{ .preferred_scale = fractionalScale };
    fn recompute(self: *Scale) void {
        self.state.output = 1;
        for (self.outputs) |slot| if (slot) |output| if (output.entered) {
            self.state.output = @max(self.state.output, output.factor);
        };
        const value = self.state.units();
        if (self.scale120 != value) {
            self.scale120 = value;
            if (self.notify) |notify| notify(self.context);
        }
    }
    pub fn attach(self: *Scale, surface: *wl.wl_surface) !void {
        self.state.buffer_scale = wl.wl_proxy_get_version(@ptrCast(surface)) >= 3;
        if (self.viewport_manager != null and self.fractional_manager != null) {
            self.viewport = wl.wp_viewporter_get_viewport(self.viewport_manager, surface) orelse return error.ViewportUnavailable;
            self.fractional = wl.wp_fractional_scale_manager_v1_get_fractional_scale(self.fractional_manager, surface) orelse return error.FractionalScaleUnavailable;
            self.state.viewport = true;
            _ = wl.wp_fractional_scale_v1_add_listener(self.fractional, &fractional_listener, self);
        }
        self.recompute();
    }
    pub fn prepare(self: *Scale, surface: *wl.wl_surface, width: i32, height: i32) void {
        if (self.state.buffer_scale) wl.wl_surface_set_buffer_scale(surface, if (self.viewport != null) 1 else @intCast(self.scale120 / 120));
        if (self.viewport) |viewport| wl.wp_viewport_set_destination(viewport, width, height);
    }
    pub fn deinit(self: *Scale) void {
        if (self.fractional) |object| wl.wp_fractional_scale_v1_destroy(object);
        if (self.viewport) |object| wl.wp_viewport_destroy(object);
        if (self.fractional_manager) |object| wl.wp_fractional_scale_manager_v1_destroy(object);
        if (self.viewport_manager) |object| wl.wp_viewporter_destroy(object);
        for (self.outputs) |output| if (output) |object| object.destroy();
        self.* = .{};
    }
};
