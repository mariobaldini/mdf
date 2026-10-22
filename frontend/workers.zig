//! Application-owned workers linked only into the deferred UI module.
comptime {
    _ = @import("keyboard.zig");
    _ = @import("image-worker.zig");
    _ = @import("font-worker.zig");
    _ = @import("system-text.zig");
    _ = @import("body-fonts.zig");
}
