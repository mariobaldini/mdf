//! Launch baseline: no libc, graphics, allocator, files, or linked libraries.
const std = @import("std");
const linux = std.os.linux;

pub fn main() void {
    reachPoint();
}

pub fn reachPoint() void {
    var ts: linux.timespec = undefined;
    // Use the syscall directly: the bare-entry control has no initialized
    // auxiliary vector for std's first-call vDSO discovery.
    if (linux.syscall2(.clock_gettime, 1, @intFromPtr(&ts)) != 0) linux.exit_group(1);
    const reached_ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    var buffer: [64]u8 = undefined;
    const output = std.fmt.bufPrint(&buffer, "{d}\nHello, world!\n", .{reached_ns}) catch unreachable;
    if (linux.write(1, output.ptr, output.len) != output.len) linux.exit_group(2);
}
