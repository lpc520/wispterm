//! Native macOS UI smoke-test entry point.
//!
//! These tests exercise WispTerm's platform-facing UI interaction paths without
//! depending on external Accessibility or Screen Recording permissions.

const builtin = @import("builtin");

test {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    _ = @import("input.zig");
    _ = @import("renderer/overlays.zig");
}
