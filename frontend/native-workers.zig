//! Eager native UI workers. Font discovery and shaping stay in the optional text module.
comptime {
    _=@import("keyboard.zig");
    _=@import("image-worker.zig");
}
