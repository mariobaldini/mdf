//! Additional unit suites. The original source tests run as a separate suite.
test {
    _ = @import("mdf");
    _ = @import("unit/links.zig");
    _ = @import("unit/settings.zig");
    _ = @import("unit/document.zig");
    _ = @import("unit/footnotes.zig");
    _ = @import("unit/layout.zig");
    _ = @import("unit/navigation.zig");
    _ = @import("unit/files.zig");
    _ = @import("unit/json.zig");
    _ = @import("unit/profiling.zig");
}
