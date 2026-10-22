//! Deferred Zig UI workers share the launcher's recorder through its C API.
const std = @import("std");
extern fn mdf_now_ns() u64;
extern fn mdf_profile_event(u8, [*]const u8, usize, [*]const u8, usize, u32, u64, u64, usize, bool) void;
extern fn mdf_profile_signal(u8, [*]const u8, usize, [*]const u8, usize, u32, u64) void;
threadlocal var depth: usize = 0;

pub fn begin(enabled: bool, comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: u8) Span {
    const result = Span{ .start = if (enabled) mdf_now_ns() else 0, .source = src, .name = name, .track = track, .depth = depth };
    if (result.start != 0) depth += 1;
    return result;
}
pub fn signal(enabled: bool, comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: u8) void {
    if (enabled) mdf_profile_signal(track, name.ptr, name.len, src.file.ptr, src.file.len, src.line, mdf_now_ns());
}
pub fn nestingDepth() usize {
    return depth;
}
pub fn enter(caller_depth: usize) Nesting {
    const old = depth;
    depth = caller_depth;
    return .{ .previous = old };
}
pub const Nesting = struct {
    previous: usize,
    pub fn end(self: Nesting) void {
        depth = self.previous;
    }
};
pub fn wait(enabled: bool, comptime src: std.builtin.SourceLocation, comptime name: []const u8, track: u8) Span {
    var result = begin(enabled, src, name, track);
    result.waiting = true;
    return result;
}
pub const Span = struct {
    start: u64,
    source: std.builtin.SourceLocation,
    name: []const u8,
    track: u8,
    depth: usize,
    waiting: bool = false,
    pub fn end(self: Span) void {
        if (self.start == 0) return;
        const finish = mdf_now_ns();
        depth -= 1;
        mdf_profile_event(self.track, self.name.ptr, self.name.len, self.source.file.ptr, self.source.file.len,
            self.source.line, self.start, finish - self.start, self.depth, self.waiting);
    }
};
