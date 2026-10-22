//! Cursor buffers never change after commit, so compositor ownership is simple.
const c = @import("native");
const wl = @import("wayland");
pub const pixels = @import("cursor-pixels.zig");
const Buffer = struct {
    buffer: ?*wl.wl_buffer = null,
    memory: ?*anyopaque = null,
    fd: c_int = -1,
    size: usize = 0,
    fn deinit(self: *Buffer) void {
        if (self.buffer) |buffer| wl.wl_buffer_destroy(buffer);
        if (self.memory) |memory| _ = c.munmap(memory, self.size);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.* = .{};
    }
    fn create(shm: *wl.wl_shm, kind: pixels.Kind, scale: u32) !Buffer {
        var self: Buffer = .{};
        errdefer self.deinit();
        const side: i32 = pixels.size * @as(i32, @intCast(scale));
        const bytes: usize = @as(usize, @intCast(side * side)) * 4;
        self.size = bytes;
        self.fd = c.memfd_create("mdf-cursor", c.MFD_CLOEXEC);
        if (self.fd < 0 or c.ftruncate(self.fd, @intCast(bytes)) != 0) return error.CursorMemoryFailed;
        self.memory = c.mmap(null, bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, self.fd, 0);
        if (self.memory == null or self.memory == c.MAP_FAILED) {
            self.memory = null;
            return error.CursorMappingFailed;
        }
        var mask: [pixels.size * pixels.size]u32 = undefined;
        pixels.render(kind, &mask);
        const output: [*]u32 = @ptrCast(@alignCast(self.memory.?));
        const width: usize = @intCast(side);
        for (0..width * width) |i| output[i] = mask[(i / width / scale) * pixels.size + (i % width / scale)];
        const pool = wl.wl_shm_create_pool(shm, self.fd, @intCast(bytes)) orelse return error.CursorPoolFailed;
        defer wl.wl_shm_pool_destroy(pool);
        self.buffer = wl.wl_shm_pool_create_buffer(pool, 0, side, side, side * 4, wl.WL_SHM_FORMAT_ARGB8888) orelse return error.CursorBufferFailed;
        return self;
    }
};
pub const Set = struct {
    surface: ?*wl.wl_surface = null,
    buffers: [pixels.count * 8]Buffer = @splat(.{}),
    scale: u32 = 1,
    kind: ?pixels.Kind = null,
    serial: u32 = 0,
    commits: usize = 0,
    pub fn leave(self: *Set) void {
        self.serial = 0;
        self.kind = null;
    }
    pub fn deinit(self: *Set) void {
        if (self.surface) |surface| wl.wl_surface_destroy(surface);
        for (&self.buffers) |*buffer| buffer.deinit();
        self.* = .{};
    }
    pub fn apply(self: *Set, compositor: *wl.wl_compositor, shm: *wl.wl_shm, pointer: *wl.wl_pointer, serial: u32, kind: pixels.Kind, requested_scale: u32) !void {
        if (requested_scale == 0 or requested_scale > 8) return error.InvalidCursorScale;
        const scale: u32 = if (wl.wl_proxy_get_version(@ptrCast(compositor)) >= 3) requested_scale else 1;
        if (serial != 0) self.serial = serial;
        if (self.serial == 0 or (serial == 0 and self.kind == kind and self.scale == scale)) return;
        if (self.surface == null) self.surface = wl.wl_compositor_create_surface(compositor) orelse return error.CursorSurfaceFailed;
        const buffer = &self.buffers[(scale - 1) * pixels.count + @backingInt(kind)];
        if (buffer.buffer == null) buffer.* = try Buffer.create(shm, kind, scale);
        const hotspot = pixels.hotspot(kind);
        wl.wl_pointer_set_cursor(pointer, self.serial, self.surface, hotspot[0], hotspot[1]);
        if (wl.wl_proxy_get_version(@ptrCast(compositor)) >= 3) wl.wl_surface_set_buffer_scale(self.surface, @intCast(scale));
        wl.wl_surface_attach(self.surface, buffer.buffer, 0, 0);
        wl.wl_surface_damage(self.surface, 0, 0, pixels.size, pixels.size);
        wl.wl_surface_commit(self.surface);
        self.kind = kind;
        self.scale = scale;
        self.commits += 1;
    }
};
