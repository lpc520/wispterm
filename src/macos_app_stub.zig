//! Minimal native macOS app-bundle entrypoint for Phase D0 build plumbing.
//!
//! D2 replaces this with the real AppKit host/event loop. For now this proves
//! the bundle links the native frameworks and can initialize the Metal seam.

const std = @import("std");

const build_options = @import("build_options");
const metal = @import("renderer/gpu/metal/api.zig");

pub fn main() !void {
    try metal.Context.init(null);
    defer metal.Context.deinit();

    if (!metal.Context.isInitialized()) return error.MetalContextUnavailable;

    const writer = std.fs.File.stdout().deprecatedWriter();
    try writer.print("Phantty macOS app skeleton {s}\n", .{build_options.app_version});
}
