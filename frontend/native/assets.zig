//! Deferred pixels reuse the application's Zig worker and private module ABI.
//! Encoded input is copied before the worker starts, independent of Core's next
//! document/navigation replacement. No work starts before the viewport flush.
const std = @import("std");
const profile=@import("ui_profile");
const c = @import("native");
const api = @import("input");
const storage = @import("image-store.zig");
const fonts = @import("font-runtime.zig");
const a = std.heap.c_allocator;
pub const Assets = struct {
    pub const Counts = struct { raster: usize = 0, svg: usize = 0, mermaid: usize = 0, failures: usize = 0 };
    tracing: bool = false,
    images: storage.Store = .{},
    worker: ?*anyopaque = null,
    sources: std.ArrayList([]u8) = .empty,
    started: bool = false,
    finished: bool = false,
    had_jobs: bool = false,
    threads_started: usize = 0,
    started_ns: u64 = 0,
    finished_ns: u64 = 0,
    font_snapshot: ?fonts.Snapshot = null,
    font_version: u64 = 0,
    glyph_text: std.ArrayList(u8) = .empty,
    glyphs: std.AutoHashMapUnmanaged(u21, void) = .empty,
    glyph_version: u64 = 0,

    pub fn counts(self: *const Assets) Counts {
        var result: Counts = .{};
        var images = self.images.values.valueIterator();
        while (images.next()) |image| {
            if (image.pixels.data == null) result.failures += 1 else if (image.svg) result.svg += 1 else if (image.diagram) result.mermaid += 1 else result.raster += 1;
        }
        return result;
    }

    fn builtin(style: u32) callconv(.c) api.struct_MdfFontData {
        const font = c.mdf_font_resource(0, style);
        return .{ .data = font.ptr, .length = font.len };
    }
    pub fn stop(self: *Assets) void {
        if (self.worker) |worker| api.mdf_image_worker_destroy(worker);
        self.worker = null;
        // The image worker borrows these descriptors until it has joined.
        if (self.font_snapshot) |snapshot| snapshot.deinit();
        self.font_snapshot = null;
        for (self.sources.items) |source| a.free(source);
        self.sources.clearRetainingCapacity();
    }
    pub fn reset(self: *Assets) void {
        self.stop();
        self.images.reset();
        self.started = false;
        self.finished = false;
        self.had_jobs = false;
        self.threads_started = 0;
        self.started_ns = 0;
        self.finished_ns = 0;
        self.font_version = 0;
        self.glyph_text.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.glyph_version = 0;
    }
    pub fn deinit(self: *Assets) void {
        self.stop();
        self.images.deinit();
        self.sources.deinit(a);
        self.glyph_text.deinit(a);
        self.glyphs.deinit(a);
    }
    pub fn start(self: *Assets, core: *c.MdfCore, dark: bool, drawing: fonts.Drawing, notify: *const fn () callconv(.c) void) !void {
        if (self.started) return;
        errdefer {
            self.stop();
            self.started = true;
            self.finished = true;
        }
        var inputs: std.ArrayList(api.struct_MdfImageInput) = .empty;
        defer inputs.deinit(a);
        var diagrams = false;
        const count = c.mdf_core_document_text(core).count;
        for (0..count) |index| {
            const block = c.mdf_core_block(core, index);
            if (std.mem.eql(u8, bytes(block.kind), "code") and std.ascii.eqlIgnoreCase(bytes(block.language), "mermaid")) {
                var source: std.ArrayList(u8) = .empty;
                defer source.deinit(a);
                for (0..block.spans) |span| try source.appendSlice(a, bytes(c.mdf_core_span(core, index, -1, span).text));
                const owned = try source.toOwnedSlice(a);
                self.sources.append(a, owned) catch |err| {
                    a.free(owned);
                    return err;
                };
                diagrams = true;
                try inputs.append(a, .{ .index = @intCast(index), .kind = 1, .bytes = owned.ptr, .length = owned.len, .fallback = @intFromBool(drawing.sans != null) });
            } else if (block.image_src.len > 0) {
                if (self.images.values.getPtr(index)) |existing| if (!existing.diagram and existing.pixels.data != null) continue;
                const encoded = c.mdf_core_image(core, index);
                if (encoded.ptr == null or encoded.len < 4) continue;
                const owned = try a.dupe(u8, bytes(encoded));
                self.sources.append(a, owned) catch |err| {
                    a.free(owned);
                    return err;
                };
                const svg = api.mdf_svg_image(owned.ptr, owned.len);
                diagrams = diagrams or svg;
                try inputs.append(a, .{ .index = @intCast(index), .kind = if (svg) 2 else 0, .bytes = owned.ptr, .length = owned.len, .fallback = @intFromBool(drawing.sans != null) });
            }
        }
        self.started = true;
        self.font_version = drawing.sans_version;
        self.started_ns = c.mdf_now_ns();
        if (inputs.items.len == 0) {
            self.finished = true;
            self.finished_ns = self.started_ns;
            return;
        }
        if (diagrams and drawing.sans != null)
            self.font_snapshot = drawing.snapshot() orelse return error.FontResourcesUnavailable;
        const fds: []const c_int = if (self.font_snapshot) |snapshot| snapshot.descriptors() else &.{};
        profile.signal(self.tracing,@src(),"Request image decoding",0);
        self.worker = api.mdf_image_worker_create(inputs.items.ptr, inputs.items.len, 128 * 1024 * 1024, notify, @intFromBool(dark), fds.ptr, fds.len, 1, builtin, @intFromBool(self.tracing)) orelse return error.ImageWorkerCreationFailed;
        self.had_jobs = true;
        self.threads_started += 1;
    }
    pub fn needsFonts(self: *const Assets, drawing: fonts.Drawing) bool {
        if (self.font_version == drawing.sans_version) return false;
        var images = self.images.values.valueIterator();
        while (images.next()) |image| if (image.diagram) return true;
        return false;
    }
    pub fn restart(self: *Assets, core: *c.MdfCore, dark: bool, drawing: fonts.Drawing, notify: *const fn () callconv(.c) void) !void {
        self.stop();
        self.started = false;
        self.finished = false;
        try self.start(core, dark, drawing, notify);
    }
    pub fn poll(self: *Assets) !bool {
        const worker = self.worker orelse return false;
        if (api.mdf_image_worker_complete(worker) == 0) return false;
        const timing=profile.begin(self.tracing,@src(),"Adopt decoded image pixels",0);
        defer timing.end();
        profile.signal(self.tracing,@src(),"Accept images",0);
        defer {
            self.stop();
            self.finished = true;
            self.finished_ns = c.mdf_now_ns();
        }
        if (api.mdf_image_worker_join(worker) < 0) return error.ImagePreparationFailed;
        var prepared = std.mem.zeroes(api.struct_MdfPreparedImage);
        while (api.mdf_image_worker_pop(worker, &prepared) != 0) {
            defer c.free(@constCast(prepared.missing_glyphs.data));
            if (prepared.index < 0) {
                c.free(prepared.pixels.data);
                continue;
            }
            self.rememberGlyphs(if (prepared.missing_glyphs.length > 0) prepared.missing_glyphs.data[0..prepared.missing_glyphs.length] else "") catch |err| {
                c.free(prepared.pixels.data); return err;
            };
            try self.images.put(@intCast(prepared.index), .{ .pixels = .{ .data = prepared.pixels.data, .width = prepared.pixels.width, .height = prepared.pixels.height, .channels = prepared.pixels.channels }, .diagram = prepared.diagram != 0, .svg = prepared.svg != 0, .logical_width = prepared.logical_width, .logical_height = prepared.logical_height, .failure = prepared.@"error" });
        }
        self.images.version +%= 1;
        return true;
    }
    fn rememberGlyphs(self: *Assets, text: []const u8) !void {
        var iterator = (try std.unicode.Utf8View.init(text)).iterator();
        var changed = false;
        while (iterator.nextCodepointSlice()) |encoded| {
            const ch = try std.unicode.utf8Decode(encoded);
            if (self.glyphs.contains(ch)) continue;
            if (self.glyphs.count() >= 65536) return error.TooManySvgGlyphs;
            try self.glyph_text.appendSlice(a, encoded);
            try self.glyphs.put(a, ch, {});
            changed = true;
        }
        if (changed) self.glyph_version +%= 1;
    }
};
fn bytes(value: c.Buffer) []const u8 {
    return if (value.ptr != null) value.ptr[0..value.len] else "";
}
