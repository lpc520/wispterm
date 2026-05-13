//! Thread spawn settings shared by Phantty-owned background threads.

const std = @import("std");

/// Conservative stack size for per-surface helper threads.
///
/// Zig's default thread stack size is 16 MiB on Windows. These surface helper
/// threads run small event/read loops and do not need the default stack.
pub const surface_thread_stack_size: usize = 1024 * 1024;

pub const surface_thread_spawn_config: std.Thread.SpawnConfig = .{
    .stack_size = surface_thread_stack_size,
};
