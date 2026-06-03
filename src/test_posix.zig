//! Native posix-target test aggregator.
//!
//! These tests exercise the libc-backed posix PTY paths (the socketpair-based
//! virtual PTY and the tmux pane I/O bridge), so they need both libc and a real
//! posix target. They cannot run in the fast suite (no libc) nor in the app
//! test binary (`test_main.zig`), which `build.zig` builds only for the windows
//! app target — where the `!= .windows` registration guards exclude them.
//! `build.zig` runs this binary directly against the native host when that host
//! is posix, so `zig build test-full` actually executes them.

test {
    _ = @import("platform/pty_virtual_test.zig");
    _ = @import("tmux/pane_io_test.zig");
}
