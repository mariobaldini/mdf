//! Additional unit suites. The original source tests run as a separate suite.
test {
    _ = @import("mdf");
    _ = @import("unit/links.zig");
    _ = @import("unit/settings.zig");
    _ = @import("unit/themes.zig");
    _ = @import("unit/document.zig");
    _ = @import("unit/footnotes.zig");
    _ = @import("unit/layout.zig");
    _ = @import("unit/flow.zig");
    _ = @import("unit/text.zig");
    _ = @import("unit/viewport.zig");
    _ = @import("unit/measurement.zig");
    _ = @import("unit/block_layout.zig");
    _ = @import("unit/diagrams.zig");
    _ = @import("unit/navigation.zig");
    _ = @import("unit/files.zig");
    _ = @import("unit/json.zig");
    _ = @import("unit/profiling.zig");
    _ = @import("unit/fonts.zig");
    _ = @import("unit/compression.zig");
    _ = @import("unit/entities.zig");
}
