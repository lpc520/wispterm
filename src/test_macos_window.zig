//! Native macOS AppKit window backend smoke-test entry point.

test {
    _ = @import("platform/window.zig");
    _ = @import("platform/window_backend.zig");
}
