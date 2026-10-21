//! Lower-bound control: enter Linux directly, without Zig's normal startup.
const linux = @import("std").os.linux;
const hello = @import("launch-hello.zig");

pub export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\xorl %%ebp, %%ebp
        \\andq $-16, %%rsp
        \\callq %[entry:P]
        :
        : [entry] "X" (&enter),
    );
}

fn enter() callconv(.c) noreturn {
    hello.reachPoint();
    linux.exit_group(0);
}
