pub const core = @import("core.zig");
pub const document = @import("document.zig");
pub const loader = @import("loader.zig");
pub const layout = @import("layout.zig");
pub const links = @import("links.zig");
pub const settings = @import("settings.zig");
pub const profiling = @import("profiling.zig");
pub const navigation = @import("navigation.zig");
pub const footnotes = @import("footnotes.zig");
pub const native = @import("native");

test {
    _ = @import("core.zig");
    _ = @import("document.zig");
    _ = @import("loader.zig");
    _ = @import("layout.zig");
    _ = @import("links.zig");
    _ = @import("settings.zig");
    _ = @import("profiling.zig");
    _ = @import("navigation.zig");
    _ = footnotes;
}
