//! XKB objects cross threads only through a completed, generation-tagged result.
const std = @import("std");
const c = @import("ui_native");
const profile = @import("ui-profile.zig");
const a = std.heap.c_allocator;
const Result = c.struct_MdfPreparedKeyboard;
const Notify = ?*const fn () callconv(.c) void;

fn release(value: *Result) void {
    if (value.compose) |compose| c.xkb_compose_state_unref(compose);
    if (value.state) |state| c.xkb_state_unref(state);
    if (value.keymap) |map| c.xkb_keymap_unref(map);
    if (value.context) |context| c.xkb_context_unref(context);
    value.* = std.mem.zeroes(Result);
}
const Worker = struct {
    mutex: c.pthread_mutex_t = undefined,
    changed: c.pthread_cond_t = undefined,
    thread: ?std.Thread = null,
    locale: [:0]u8,
    pending: ?[:0]u8 = null,
    requested: u64 = 0,
    finished: u64 = 0,
    stop: bool = false,
    failed: bool = false,
    result: Result = std.mem.zeroes(Result),
    notify: Notify,
    delay_ms: u32,
    tracing: bool,

    fn create(locale: []const u8, notify: Notify, delay: u32, tracing: bool) !*Worker {
        const self = try a.create(Worker);
        errdefer a.destroy(self);
        self.* = .{ .locale = try a.dupeSentinel(u8, locale, 0), .notify = notify, .delay_ms = delay, .tracing = tracing };
        errdefer a.free(self.locale);
        if (c.pthread_mutex_init(&self.mutex, null) != 0) return error.MutexFailed;
        errdefer _ = c.pthread_mutex_destroy(&self.mutex);
        if (c.pthread_cond_init(&self.changed, null) != 0) return error.ConditionFailed;
        errdefer _ = c.pthread_cond_destroy(&self.changed);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn destroy(self: *Worker) void {
        _ = c.pthread_mutex_lock(&self.mutex);
        self.stop = true;
        _ = c.pthread_cond_broadcast(&self.changed);
        _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.thread) |thread| thread.join();
        release(&self.result);
        if (self.pending) |pending| a.free(pending);
        a.free(self.locale);
        _ = c.pthread_cond_destroy(&self.changed);
        _ = c.pthread_mutex_destroy(&self.mutex);
        a.destroy(self);
    }
    fn submit(self: *Worker, bytes: []const u8) !u64 {
        const source = if (bytes.len > 0 and bytes[bytes.len - 1] == 0) bytes[0 .. bytes.len - 1] else bytes;
        const copy = try a.dupeSentinel(u8, source, 0);
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (self.pending) |pending| a.free(pending);
        self.pending = copy;
        self.requested +%= 1;
        if (self.requested == 0) self.requested = 1;
        _ = c.pthread_cond_broadcast(&self.changed);
        return self.requested;
    }
    fn take(self: *Worker, out: *Result, wait: bool) c_int {
        _ = c.pthread_mutex_lock(&self.mutex);
        defer _ = c.pthread_mutex_unlock(&self.mutex);
        if (wait) while (!self.stop and !(self.requested != 0 and self.finished == self.requested)) {
            _ = c.pthread_cond_wait(&self.changed, &self.mutex);
        };
        if (self.requested == 0 or self.finished != self.requested) return 0;
        if (self.failed) return -1;
        if (self.result.generation == 0) return 0;
        out.* = self.result;
        self.result = std.mem.zeroes(Result);
        return 1;
    }
    fn run(self: *Worker) void {
        _ = c.prctl(c.PR_SET_NAME, @as([*:0]const u8, "mdf-input"), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        var initial = std.mem.zeroes(Result);
        defer release(&initial);
        {
            const phase = profile.begin(self.tracing, @src(), "Prepare keyboard Compose resources", 6);
            defer phase.end();
            initial.context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
            if (initial.context) |context| {
                const compiling = profile.begin(self.tracing, @src(), "Compile deferred keyboard Compose table", 6);
                defer compiling.end();
                if (c.xkb_compose_table_new_from_locale(context, self.locale, c.XKB_COMPOSE_COMPILE_NO_FLAGS)) |table| {
                    initial.compose = c.xkb_compose_state_new(table, c.XKB_COMPOSE_STATE_NO_FLAGS);
                    c.xkb_compose_table_unref(table);
                }
                c.xkb_context_unref(context);
                initial.context = null;
            }
            initial.initial = 1;
        }
        while (true) {
            _ = c.pthread_mutex_lock(&self.mutex);
            while (!self.stop and self.requested <= self.finished) _ = c.pthread_cond_wait(&self.changed, &self.mutex);
            if (self.stop) {
                _ = c.pthread_mutex_unlock(&self.mutex);
                break;
            }
            const source = self.pending.?;
            self.pending = null;
            const generation = self.requested;
            _ = c.pthread_mutex_unlock(&self.mutex);
            defer a.free(source);
            var next = std.mem.zeroes(Result);
            defer release(&next);
            {
                const phase = profile.begin(self.tracing, @src(), "Prepare deferred keyboard keymap", 6);
                defer phase.end();
                if (self.delay_ms != 0) {
                    var remaining: c.struct_timespec = .{ .tv_sec = @intCast(self.delay_ms / 1000), .tv_nsec = @intCast((self.delay_ms % 1000) * std.time.ns_per_ms) };
                    while (c.nanosleep(&remaining, &remaining) != 0) {}
                }
                next.context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
                if (next.context) |context| {
                    const compiling = profile.begin(self.tracing, @src(), "Compile deferred keyboard keymap", 6);
                    defer compiling.end();
                    next.keymap = c.xkb_keymap_new_from_string(context, source, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS);
                    if (next.keymap) |map| next.state = c.xkb_state_new(map);
                }
                next.generation = generation;
            }
            var publish = false;
            _ = c.pthread_mutex_lock(&self.mutex);
            if (!self.stop and generation == self.requested) {
                // Replacing an unadopted first result must retain Compose.
                if (self.result.initial != 0) {
                    initial.compose = self.result.compose;
                    self.result.compose = null;
                    initial.initial = 1;
                }
                release(&self.result);
                if (initial.initial != 0 and next.state != null) {
                    next.compose = initial.compose;
                    initial.compose = null;
                    next.initial = 1;
                    initial.initial = 0;
                }
                self.result = next;
                next = std.mem.zeroes(Result);
                self.failed = self.result.state == null;
                self.finished = generation;
                publish = true;
                profile.signal(self.tracing, @src(), "Keyboard preparation ready", 6);
                _ = c.pthread_cond_broadcast(&self.changed);
            }
            _ = c.pthread_mutex_unlock(&self.mutex);
            if (publish) if (self.notify) |notify| notify();
        }
    }
};
export fn mdf_keyboard_create(locale: ?[*:0]const u8, notify: Notify, delay: c_uint, tracing: c_int) ?*Worker {
    const name = locale orelse return null;
    return Worker.create(std.mem.span(name), notify, delay, tracing != 0) catch null;
}
export fn mdf_keyboard_destroy(self: ?*Worker) void {
    if (self) |worker| worker.destroy();
}
export fn mdf_keyboard_submit(self: *Worker, bytes: ?[*]const u8, len: usize) u64 {
    const source = bytes orelse return 0;
    if (len == 0 or len > 32 * 1024 * 1024) return 0;
    return self.submit(source[0..len]) catch 0;
}
export fn mdf_keyboard_take(self: *Worker, out: *Result, wait: c_int) c_int {
    return self.take(out, wait != 0);
}
export fn mdf_keyboard_release(out: *Result) void {
    release(out);
}
