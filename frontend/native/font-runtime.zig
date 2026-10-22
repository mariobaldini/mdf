//! Optional font work belongs after the document's viewport flush.
const std = @import("std");
const profile=@import("ui_profile");
const c = @import("native");
const z2d = @import("z2d");
const coverage = @import("font-coverage.zig");
const a = std.heap.c_allocator;
const Api = c.struct_MdfTextApi;
const Notify = *const fn () callconv(.c) void;
const callbacks: c.struct_MdfTextHost = .{ .font = c.mdf_font_resource, .now = c.mdf_now_ns, .event = c.mdf_profile_event, .signal = c.mdf_profile_signal };
pub const Snapshot = struct {
    api: *const Api,
    value: *anyopaque,
    pub fn descriptors(self: Snapshot) []const c_int {
        const view = self.api.resources.?(self.value);
        return if (view.fd_count > 0) view.fds[0..view.fd_count] else &.{};
    }
    pub fn deinit(self: Snapshot) void {
        self.api.release_resources.?(self.value);
    }
};
pub const Drawing = struct {
    api: ?*const Api = null,
    mono: ?*anyopaque = null,
    sans: ?*anyopaque = null,
    version: u64 = 0,
    sans_version: u64 = 0,
    pub fn snapshot(self: Drawing) ?Snapshot {
        const api = self.api orelse return null;
        const value = api.retain_resources.?(self.sans orelse return null) orelse return null;
        return .{ .api = api, .value = value };
    }
};
const Boot = struct {
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    canceled: std.atomic.Value(bool) = .init(false),
    api: ?*const Api = null,
    error_buffer: [512]u8 = @splat(0),
    notify: Notify,
    mono: bool,
    fn cancel(context: ?*const anyopaque) callconv(.c) c_int {
        const self: *const Boot = @ptrCast(@alignCast(context.?));
        return @intFromBool(self.canceled.load(.monotonic));
    }
    fn run(self: *Boot) void {
        const api = c.mdf_text_renderer(&callbacks, if (self.mono) 2 else 5, cancel, self, 0, &self.error_buffer, self.error_buffer.len);
        if (api != null) self.api = @ptrCast(api);
        self.done.store(true, .release);
        self.notify();
    }
    fn destroy(self: *Boot) void {
        self.canceled.store(true, .monotonic);
        if (self.thread) |thread| thread.join();
        a.destroy(self);
    }
};
pub const Runtime = struct {
    tracing: bool = false,
    drawing: Drawing = .{},
    boot: ?*Boot = null,
    mono_job: ?*anyopaque = null,
    sans_job: ?*anyopaque = null,
    characters: []u32 = &.{},
    styles: u32 = 3,
    mono_styles: u32 = 0,
    sans_styles: u32 = 0,
    requested: bool = false,
    mono_requested: bool = false,
    sans_requested: bool = false,
    mono_finished: bool = true,
    sans_finished: bool = true,
    started_ns: u64 = 0,
    ready_ns: u64 = 0,
    error_buffer: [512]u8 = @splat(0),
    notify: ?Notify = null,

    pub fn stop(self: *Runtime) void {
        if (self.boot) |boot| boot.destroy();
        self.boot = null;
        if (self.drawing.api) |api| {
            if (self.mono_job) |job| api.stop.?(job);
            if (self.sans_job) |job| api.stop.?(job);
        }
        self.mono_job = null;
        self.sans_job = null;
    }
    pub fn deinit(self: *Runtime) void {
        self.stop();
        if (self.drawing.api) |api| {
            if (self.drawing.mono) |value| api.destroy.?(value);
            if (self.drawing.sans) |value| api.destroy.?(value);
        }
        a.free(self.characters);
    }
    pub fn message(self: *const Runtime) []const u8 {
        return std.mem.sliceTo(&self.error_buffer, 0);
    }
    fn failure(self: *Runtime, text: []const u8) void {
        @memset(&self.error_buffer, 0);
        const length = @min(text.len, self.error_buffer.len - 1);
        @memcpy(self.error_buffer[0..length], text[0..length]);
    }
    pub fn request(self: *Runtime, builtin: *const z2d.font.Font, texts: []const []const u8, mono: bool, styles: u32, notify: Notify) !void {
        const characters = try coverage.missingMany(a, builtin, texts);
        if (self.requested and self.mono_requested == mono and self.styles == (styles | 3) and
            std.mem.eql(u32, self.characters, characters)) {
            a.free(characters);
            return;
        }
        self.stop();
        a.free(self.characters);
        self.characters = characters;
        self.notify = notify;
        self.styles = styles | 3;
        self.requested = true;
        self.mono_requested = mono;
        self.sans_requested = self.characters.len > 0;
        self.mono_finished = !mono or (self.drawing.mono != null and self.styles & ~self.mono_styles == 0);
        self.sans_finished = self.characters.len == 0;
        if (!self.sans_finished) if (self.drawing.api) |api| if (self.drawing.sans) |sans| {
            self.sans_finished = self.styles & ~self.sans_styles == 0;
            for (self.characters) |ch| if (api.has_character.?(sans, ch) == 0) {
                self.sans_finished = false;
                break;
            };
        };
        self.ready_ns = 0;
        @memset(&self.error_buffer, 0);
        if (self.finished()) return;
        if (self.started_ns == 0) self.started_ns = c.mdf_now_ns();
        if(!self.mono_finished) profile.signal(self.tracing,@src(),"Request system monospace",0);
        if(!self.sans_finished) profile.signal(self.tracing,@src(),"Request system Sans fallback",0);
        if (self.drawing.api != null) try self.startJobs() else {
            const boot = try a.create(Boot);
            boot.* = .{ .notify = notify, .mono = mono };
            boot.thread = std.Thread.spawn(.{}, Boot.run, .{boot}) catch |err| {
                a.destroy(boot);
                return err;
            };
            self.boot = boot;
        }
    }
    fn startJobs(self: *Runtime) !void {
        const api = self.drawing.api orelse return;
        if (!self.mono_finished and self.mono_job == null) self.mono_job = api.start.?(1, null, 0, self.styles, self.notify, @intFromBool(self.tracing)) orelse return error.MonospaceWorkerFailed;
        if (!self.sans_finished and self.sans_job == null) self.sans_job = api.start.?(0, self.characters.ptr, self.characters.len, self.styles, self.notify, @intFromBool(self.tracing)) orelse return error.SansWorkerFailed;
    }
    fn adopt(self: *Runtime, mono: bool, job: *anyopaque) bool {
        const timing=if(mono) profile.begin(self.tracing,@src(),"Adopt system monospace",0) else profile.begin(self.tracing,@src(),"Adopt system Sans fallback",0);
        defer timing.end();
        defer if(mono) profile.signal(self.tracing,@src(),"System monospace adopted",0) else profile.signal(self.tracing,@src(),"System Sans fallback adopted",0);
        const api = self.drawing.api.?;
        const value = api.take.?(job);
        defer api.stop.?(job);
        if (value) |result| {
            const reason = api.@"error".?(result);
            const name = api.family.?(result);
            if (reason.length == 0 and name.length > 0) {
                if (mono) {
                    if (self.drawing.mono) |old| api.destroy.?(old);
                    self.drawing.mono = result;
                    self.mono_styles = self.styles;
                } else {
                    if (self.drawing.sans) |old| api.destroy.?(old);
                    self.drawing.sans = result;
                    self.sans_styles = self.styles;
                    self.drawing.sans_version +%= 1;
                }
                self.drawing.version +%= 1;
                return true;
            }
            self.failure(if (reason.length > 0) reason.data[0..reason.length] else "System font unavailable");
            api.destroy.?(result);
        } else self.failure("System font preparation failed");
        return false;
    }
    pub fn poll(self: *Runtime) !bool {
        if (self.boot) |boot| if (boot.done.load(.acquire)) {
            self.drawing.api = boot.api;
            if (boot.api == null) {
                self.failure(std.mem.sliceTo(&boot.error_buffer, 0));
                self.mono_finished = true;
                self.sans_finished = true;
            }
            boot.destroy();
            self.boot = null;
            try self.startJobs();
        };
        var changed = false;
        if (self.drawing.api) |api| {
            if (self.mono_job) |job| if (api.complete.?(job) != 0) {
                changed = self.adopt(true, job) or changed;
                self.mono_job = null;
                self.mono_finished = true;
            };
            if (self.sans_job) |job| if (api.complete.?(job) != 0) {
                changed = self.adopt(false, job) or changed;
                self.sans_job = null;
                self.sans_finished = true;
            };
            if (changed and self.drawing.mono != null and self.drawing.sans != null and
                api.add_fallback.?(self.drawing.mono, self.drawing.sans) == 0)
                self.failure("Cannot add missing glyphs to the monospace font map");
        }
        if (self.requested and self.finished() and self.ready_ns == 0) self.ready_ns = c.mdf_now_ns();
        return changed;
    }
    pub fn finished(self: *const Runtime) bool {
        return self.mono_finished and self.sans_finished and self.boot == null;
    }
    pub fn unresolved(self: *const Runtime) usize {
        const api = self.drawing.api orelse return self.characters.len;
        const sans = self.drawing.sans orelse return self.characters.len;
        var count: usize = 0;
        for (self.characters) |ch| if (api.has_character.?(sans, ch) == 0) {
            count += 1;
        };
        return count;
    }
    pub fn family(self: *const Runtime, mono: bool) []const u8 {
        const api = self.drawing.api orelse return "";
        const value = (if (mono) self.drawing.mono else self.drawing.sans) orelse return "";
        const name = api.family.?(value);
        return if (name.length > 0) name.data[0..name.length] else "";
    }
    pub fn resetRequest(self: *Runtime) void {
        self.stop();
        self.requested = false;
        self.mono_finished = true;
        self.sans_finished = true;
        self.started_ns = 0;
        self.ready_ns = 0;
    }
};
