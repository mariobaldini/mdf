//! On-demand, bounded directory listings. The caller owns each completed result.
const std = @import("std");
const c = @import("native");
const Stop = std.atomic.Value(bool);
pub const Entry = struct { name: []u8, directory: bool };
pub const Listing = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    entries: []Entry,
    is_file: bool = false,
    truncated: bool = false,
    pub fn deinit(self: *Listing) void {
        for (self.entries) |entry| self.allocator.free(entry.name);
        self.allocator.free(self.entries);
        self.allocator.free(self.path);
        self.* = undefined;
    }
};
fn absolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.unicode.utf8ValidateSlice(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidDirectoryPath;
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    var buffer: [4096]u8 = undefined;
    const cwd = c.getcwd(&buffer, buffer.len) orelse return error.CurrentDirectoryUnavailable;
    return std.fs.path.resolve(allocator, &.{ std.mem.span(cwd), path });
}
fn before(_: void, left: Entry, right: Entry) bool {
    if (left.directory != right.directory) return left.directory;
    const order = std.ascii.orderIgnoreCase(left.name, right.name);
    return if (order == .eq) std.mem.lessThan(u8, left.name, right.name) else order == .lt;
}
pub fn read(allocator: std.mem.Allocator, path: []const u8, hidden: bool, allow_file: bool, stop: *const Stop, limit: usize) !Listing {
    if (stop.load(.acquire)) return error.Canceled;
    const resolved = try absolute(allocator, path);
    errdefer allocator.free(resolved);
    const terminated = try allocator.dupeSentinel(u8, resolved, 0);
    defer allocator.free(terminated);
    const fd = c.open(terminated.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) {
        const reason = c.__errno_location().*;
        if (allow_file and reason == c.ENOTDIR) return .{ .allocator = allocator, .path = resolved, .entries = &.{}, .is_file = true };
        return switch (reason) {
            c.ENOENT => error.DirectoryNotFound,
            c.ENOTDIR => error.NotDirectory,
            c.EACCES => error.AccessDenied,
            else => error.DirectoryOpenFailed,
        };
    }
    defer _ = c.close(fd);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
    var buffer: [16384]u8 align(8) = undefined;
    var truncated = false;
    outer: while (true) {
        if (stop.load(.acquire)) return error.Canceled;
        const size = std.os.linux.getdents64(fd, &buffer, buffer.len);
        switch (std.os.linux.errno(size)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.DirectoryReadFailed,
        }
        if (size == 0) break;
        var offset: usize = 0;
        while (offset < size) {
            if (stop.load(.acquire)) return error.Canceled;
            if (size - offset < @sizeOf(std.os.linux.dirent64)) return error.InvalidDirectoryRecord;
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&buffer[offset]);
            const record: usize = entry.reclen;
            if (record < @sizeOf(std.os.linux.dirent64) or record > size - offset) return error.InvalidDirectoryRecord;
            const bytes = buffer[offset + @offsetOf(std.os.linux.dirent64, "name") .. offset + record];
            offset += record;
            const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.InvalidDirectoryRecord;
            const name = bytes[0..end];
            if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or (!hidden and name[0] == '.') or
                !std.unicode.utf8ValidateSlice(name) or std.mem.indexOfAny(u8, name, "\r\n") != null) continue;
            var directory = entry.type == std.os.linux.DT.DIR;
            if (entry.type == std.os.linux.DT.LNK or entry.type == std.os.linux.DT.UNKNOWN) {
                var info: c.struct_stat = undefined;
                if (c.fstatat(fd, @ptrCast(name.ptr), &info, 0) != 0) continue;
                const kind = info.st_mode & c.S_IFMT;
                directory = kind == c.S_IFDIR;
                if (!directory and kind != c.S_IFREG) continue;
            } else if (!directory and entry.type != std.os.linux.DT.REG) continue;
            if (entries.items.len >= limit) {
                truncated = true;
                break :outer;
            }
            const owned = try allocator.dupe(u8, name);
            entries.append(allocator, .{ .name = owned, .directory = directory }) catch |err| {
                allocator.free(owned);
                return err;
            };
        }
    }
    std.mem.sort(Entry, entries.items, {}, before);
    return .{ .allocator = allocator, .path = resolved, .entries = try entries.toOwnedSlice(allocator), .truncated = truncated };
}
const Job = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    hidden: bool,
    allow_file: bool,
    notify: *const fn () callconv(.c) void,
    stop: Stop = .init(false),
    done: Stop = .init(false),
    thread: ?std.Thread = null,
    result: ?Listing = null,
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.result = read(self.allocator, self.path, self.hidden, self.allow_file, &self.stop, 10000) catch |err| failed: {
            self.failure = err;
            break :failed null;
        };
        self.done.store(true, .release);
        self.notify();
    }
    fn destroy(self: *Job) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.result) |*result| result.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};
pub const Browser = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    job: ?*Job = null,
    listing: ?Listing = null,
    jobs: usize = 0,
    failure: ?anyerror = null,
    pub fn stop(self: *Browser) void {
        if (self.job) |job| job.destroy();
        self.job = null;
    }
    pub fn deinit(self: *Browser) void {
        self.stop();
        if (self.listing) |*listing| listing.deinit();
        self.listing = null;
    }
    pub fn location(self:*const Browser) []const u8 {
        if(self.job) |job| return job.path;
        if(self.listing) |listing| return listing.path;
        return ".";
    }
    pub fn request(self: *Browser, path: []const u8, hidden: bool, allow_file: bool, notify: *const fn () callconv(.c) void) !void {
        // Navigation can pass a slice borrowed from the current listing.
        const owned=try self.allocator.dupe(u8,path);
        errdefer self.allocator.free(owned);
        self.deinit();
        self.failure = null;
        const job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = .{ .allocator = self.allocator, .path = owned, .hidden = hidden, .allow_file = allow_file, .notify = notify };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
        self.jobs += 1;
    }
    pub fn poll(self: *Browser) bool {
        const job = self.job orelse return false;
        if (!job.done.load(.acquire)) return false;
        self.failure = job.failure;
        self.listing = job.result;
        job.result = null;
        job.destroy();
        self.job = null;
        return true;
    }
};
