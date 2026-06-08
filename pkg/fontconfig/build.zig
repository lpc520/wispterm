const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const module = b.addModule("fontconfig", .{
        .root_source_file = b.path("fontconfig.zig"),
        .target = target,
    });
    // pkg-config (the default for linkSystemLibrary) supplies fontconfig's include
    // dirs and link flags, so the @cImport resolves wherever fontconfig is installed
    // — no hardcoded prefix. The parent threads the resolved target via
    // b.lazyDependency("fontconfig", .{ .target = target }).
    module.linkSystemLibrary("fontconfig", .{});
    // On Debian/Ubuntu the fontconfig headers live under /usr/include which is not
    // emitted by pkg-config --cflags (it is implicit for native gcc but Zig's
    // translate-c needs it explicit when the module is compiled in isolation).
    module.addIncludePath(.{ .cwd_relative = "/usr/include" });
}
