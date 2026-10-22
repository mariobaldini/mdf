const std = @import("std");
const c = @import("native");
const wl = @import("wayland");
const Writer = @import("transfer.zig").Writer;
const Reader = @import("receive.zig").Reader;
const a = std.heap.c_allocator;
pub const Clipboard = struct {
    manager: ?*wl.wl_data_device_manager = null,
    device: ?*wl.wl_data_device = null,
    source: ?*wl.wl_data_source = null,
    text: []const u8 = "",
    offers: std.ArrayList(Offer) = .empty,
    writers: std.ArrayList(*Writer) = .empty,
    testing: bool = false,
    receiver: Reader = .{ .allocator = a },
    received: []u8 = &.{},
    receive_kind: Kind = .testing,
    ready: bool = false,
    selection_offer: ?*wl.wl_data_offer = null,
    drag_offer: ?*wl.wl_data_offer = null,
    receive_offer: ?*wl.wl_data_offer = null,
    test_done: bool = false,
    test_drop_finished: bool = false,
    failure: ?anyerror = null,
    pub const Kind = enum { testing, paste, drop };
    pub const Received = struct { kind: Kind, bytes: []u8 };
    const Offer = struct { value: *wl.wl_data_offer, utf8: bool = false, plain: bool = false, uri: bool = false, action: u32 = 0 };
    fn findOffer(self: *Clipboard, value: ?*wl.wl_data_offer) ?Offer {
        for (self.offers.items) |entry| if (entry.value == value) return entry;
        return null;
    }
    fn prune(self: *Clipboard) void {
        var i: usize = 0;
        while (i < self.offers.items.len) {
            const value = self.offers.items[i].value;
            if (value != self.selection_offer and value != self.drag_offer and value != self.receive_offer) {
                wl.wl_data_offer_destroy(value);
                _ = self.offers.swapRemove(i);
            } else i += 1;
        }
    }
    pub fn canPaste(self: *Clipboard) bool {
        const selected = self.findOffer(self.selection_offer) orelse return false;
        return selected.utf8 or selected.plain;
    }
    pub fn paste(self: *Clipboard) !void {
        try self.begin(.paste, self.selection_offer orelse return error.ClipboardUnavailable);
    }
    pub fn take(self: *Clipboard) ?Received {
        if (!self.ready) return null;
        self.ready = false;
        const bytes = self.received;
        self.received = &.{};
        return .{ .kind = self.receive_kind, .bytes = bytes };
    }
    fn begin(self: *Clipboard, kind: Kind, value: *wl.wl_data_offer) !void {
        const selected = self.findOffer(value) orelse return error.ClipboardUnavailable;
        const mime: [*:0]const u8 = if (kind == .drop and selected.uri) "text/uri-list" else if (kind != .drop and selected.utf8) "text/plain;charset=utf-8" else if (kind != .drop and selected.plain) "text/plain" else return error.UnsupportedClipboardType;
        self.receiver.cancel();
        self.receive_offer = null;
        self.prune();
        a.free(self.received);
        self.received = &.{};
        self.ready = false;
        var pipe: [2]c_int = undefined;
        if (c.pipe2(&pipe, c.O_CLOEXEC | c.O_NONBLOCK) != 0) return error.ClipboardPipeFailed;
        defer _ = c.close(pipe[1]);
        try self.receiver.adopt(pipe[0]);
        self.receive_offer = value;
        self.receive_kind = kind;
        wl.wl_data_offer_receive(value, mime, pipe[1]);
    }

    pub fn attach(self: *Clipboard, seat: ?*wl.wl_seat) void {
        if (self.manager != null and seat != null and self.device == null) {
            self.device = wl.wl_data_device_manager_get_data_device(self.manager, seat);
            _ = wl.wl_data_device_add_listener(self.device, &device_listener, self);
        }
    }
    pub fn publish(self: *Clipboard, text: []const u8, serial: u32) !void {
        if (text.len == 0) return;
        if (self.manager == null or self.device == null or serial == 0) return error.ClipboardUnavailable;
        const copy = try a.dupe(u8, text);
        errdefer a.free(copy);
        const source = wl.wl_data_device_manager_create_data_source(self.manager) orelse return error.ClipboardUnavailable;
        if (self.source) |old| wl.wl_data_source_destroy(old);
        a.free(self.text);
        self.text = copy;
        self.source = source;
        _ = wl.wl_data_source_add_listener(source, &source_listener, self);
        wl.wl_data_source_offer(source, "text/plain;charset=utf-8");
        wl.wl_data_source_offer(source, "text/plain");
        wl.wl_data_device_set_selection(self.device, source, serial);
    }
    /// Integration-test source; the destination uses the ordinary drop handlers.
    pub fn testDrop(self: *Clipboard, surface: *wl.wl_surface, serial: u32, text: []const u8) !void {
        if (self.manager == null or self.device == null or serial == 0) return error.ClipboardUnavailable;
        const copy = try a.dupe(u8, text);
        errdefer a.free(copy);
        const source = wl.wl_data_device_manager_create_data_source(self.manager) orelse return error.ClipboardUnavailable;
        if (self.source) |old| wl.wl_data_source_destroy(old);
        a.free(self.text);
        self.text = copy;
        self.source = source;
        _ = wl.wl_data_source_add_listener(source, &source_listener, self);
        wl.wl_data_source_offer(source, "text/uri-list");
        wl.wl_data_source_set_actions(source, wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
        wl.wl_data_device_start_drag(self.device, source, surface, null, serial);
    }
    fn target(_: ?*anyopaque, _: ?*wl.wl_data_source, _: [*c]const u8) callconv(.c) void {}
    fn sourceDone(_: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {}
    fn sourceFinished(data: ?*anyopaque, _: ?*wl.wl_data_source) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        self.test_drop_finished = true;
    }
    fn sourceAction(_: ?*anyopaque, _: ?*wl.wl_data_source, _: u32) callconv(.c) void {}
    fn sourceActions(_: ?*anyopaque, _: ?*wl.wl_data_offer, _: u32) callconv(.c) void {}
    fn offerAction(data: ?*anyopaque, value: ?*wl.wl_data_offer, action: u32) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        for (self.offers.items) |*entry| if (entry.value == value) {
            entry.action = action;
            break;
        };
    }
    fn send(data: ?*anyopaque, _: ?*wl.wl_data_source, mime: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        const kind = std.mem.span(mime);
        if (!std.mem.eql(u8, kind, "text/plain") and !std.mem.eql(u8, kind, "text/plain;charset=utf-8") and !std.mem.eql(u8, kind, "text/uri-list")) {
            _ = c.close(fd);
            return;
        }
        self.reap();
        if (self.writers.items.len >= 8) {
            _ = c.close(fd);
            return;
        }
        const writer = Writer.create(a, fd, self.text) catch |err| {
            self.failure = err;
            return;
        };
        self.writers.append(a, writer) catch |err| {
            writer.destroy();
            self.failure = err;
        };
    }
    fn cancelled(data: ?*anyopaque, source: ?*wl.wl_data_source) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        if (source == self.source) {
            wl.wl_data_source_destroy(source);
            self.source = null;
            a.free(self.text);
            self.text = "";
        }
    }
    fn dataOffer(data: ?*anyopaque, _: ?*wl.wl_data_device, value: ?*wl.wl_data_offer) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        const offer = value orelse return;
        if (self.offers.items.len >= 16) {
            self.failure = error.TooManyClipboardOffers;
            wl.wl_data_offer_destroy(offer);
            return;
        }
        self.offers.append(a, .{ .value = offer }) catch |err| {
            self.failure = err;
            wl.wl_data_offer_destroy(offer);
            return;
        };
        _ = wl.wl_data_offer_add_listener(offer, &offer_listener, self);
    }
    fn offered(data: ?*anyopaque, offer: ?*wl.wl_data_offer, mime: [*c]const u8) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        const name = std.mem.span(mime);
        for (self.offers.items) |*entry| if (entry.value == offer) {
            if (std.mem.eql(u8, name, "text/plain;charset=utf-8")) entry.utf8 = true;
            if (std.mem.eql(u8, name, "text/plain")) entry.plain = true;
            if (std.mem.eql(u8, name, "text/uri-list")) entry.uri = true;
            break;
        };
    }
    fn selection(data: ?*anyopaque, _: ?*wl.wl_data_device, offer: ?*wl.wl_data_offer) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        self.selection_offer = offer;
        self.prune();
        if (self.testing and self.canPaste() and self.receiver.fd < 0 and !self.test_done)
            self.begin(.testing, offer.?) catch |err| {
                self.failure = err;
            };
    }
    fn enter(data: ?*anyopaque, _: ?*wl.wl_data_device, serial: u32, _: ?*wl.wl_surface, _: i32, _: i32, value: ?*wl.wl_data_offer) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        self.drag_offer = value;
        self.prune();
        if (value) |selected| {
            const entry = self.findOffer(selected) orelse return;
            wl.wl_data_offer_accept(selected, serial, if (entry.uri) "text/uri-list" else null);
            if (wl.wl_proxy_get_version(@ptrCast(selected)) >= 3)
                wl.wl_data_offer_set_actions(selected, if (entry.uri) wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY else 0, if (entry.uri) wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY else 0);
        }
    }
    fn leave(data: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        self.drag_offer = null;
        self.prune();
    }
    fn motion(_: ?*anyopaque, _: ?*wl.wl_data_device, _: u32, _: i32, _: i32) callconv(.c) void {}
    fn drop(data: ?*anyopaque, _: ?*wl.wl_data_device) callconv(.c) void {
        const self: *Clipboard = @ptrCast(@alignCast(data.?));
        if (self.drag_offer) |value| self.begin(.drop, value) catch |err| {
            self.failure = err;
        };
    }
    pub fn poll(self: *Clipboard) !void {
        if (self.failure) |err| {
            self.failure = null;
            return err;
        }
        self.reap();
        const result = self.receiver.poll() catch |err| {
            self.receive_offer = null;
            self.prune();
            return err;
        };
        const bytes = result orelse return;
        a.free(self.received);
        self.received = bytes;
        if (self.receive_kind == .drop) if (self.receive_offer) |value| {
            const entry = self.findOffer(value) orelse return error.DropOfferMissing;
            if (wl.wl_proxy_get_version(@ptrCast(value)) >= 3 and entry.action == wl.WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY)
                wl.wl_data_offer_finish(value);
        };
        self.receive_offer = null;
        self.prune();
        if (self.receive_kind == .testing) {
            if (!std.mem.eql(u8, self.received, self.text) or self.text.len == 0) return error.ClipboardMismatch;
            self.test_done = true;
        } else self.ready = true;
    }
    fn reap(self: *Clipboard) void {
        var index: usize = 0;
        while (index < self.writers.items.len) {
            if (self.writers.items[index].done.load(.acquire)) self.writers.swapRemove(index).destroy() else index += 1;
        }
    }
    pub fn deinit(self: *Clipboard) void {
        for (self.writers.items) |writer| writer.stop.store(true, .release);
        for (self.writers.items) |writer| writer.destroy();
        self.writers.deinit(a);
        self.receiver.cancel();
        a.free(self.received);
        for (self.offers.items) |entry| wl.wl_data_offer_destroy(entry.value);
        self.offers.deinit(a);
        if (self.source) |source| wl.wl_data_source_destroy(source);
        a.free(self.text);
        if (self.device) |device| {
            if (wl.wl_proxy_get_version(@ptrCast(device)) >= 2) wl.wl_data_device_release(device) else wl.wl_data_device_destroy(device);
        }
        if (self.manager) |manager| wl.wl_data_device_manager_destroy(manager);
    }
    const source_listener: wl.wl_data_source_listener = listener: {
        var value = std.mem.zeroes(wl.wl_data_source_listener);
        value.target = target;
        value.send = send;
        value.cancelled = cancelled;
        value.dnd_drop_performed = sourceDone;
        value.dnd_finished = sourceFinished;
        value.action = sourceAction;
        break :listener value;
    };
    const device_listener: wl.wl_data_device_listener = .{ .data_offer = dataOffer, .enter = enter, .leave = leave, .motion = motion, .drop = drop, .selection = selection };
    const offer_listener: wl.wl_data_offer_listener = listener: {
        var value = std.mem.zeroes(wl.wl_data_offer_listener);
        value.offer = offered;
        value.source_actions = sourceActions;
        value.action = offerAction;
        break :listener value;
    };
};
