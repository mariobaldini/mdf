//! Standalone native evaluation entry; the packed UI uses the launcher ABI.
pub export fn main(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return @import("native_window").main(argc, argv);
}
