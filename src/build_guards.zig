//! Compile-time guard data and logic for `build.zig`, kept in a standalone
//! module so the guard behavior can be unit-tested. `build.zig`'s own `test`
//! blocks are never executed by `zig build test` (that step is rooted at
//! `src/test_main.zig`), so guards living inline in `build.zig` could regress
//! unnoticed.
//!
//! `build.zig` embeds its own source and runs `firstLeak` over it inside a
//! `comptime` block on every build, so the core/host boundary cannot be quietly
//! re-broken by adding target-OS booleans or Windows-specific names to the build
//! script's app-facing options. `test_main.zig` imports this module so the
//! checks below run as ordinary unit tests.

const std = @import("std");

pub const LeakCheck = struct {
    /// Any of these substrings appearing in the build-script source triggers
    /// the leak and fails the build with `message`.
    patterns: []const []const u8,
    message: []const u8,
};

pub const app_leak_checks = [_]LeakCheck{
    .{
        .patterns = &.{
            "supports_winhttp_remote_transport",
            "platform_supports_winhttp_remote_transport",
        },
        .message = "build.zig must expose remote transport as a platform capability, not a WinHTTP-specific build option",
    },
    .{
        .patterns = &.{
            "addOption(bool, \"target_is_windows\"",
            "addOption(bool, \"platform_supports_",
        },
        .message = "build.zig must keep platform feature gates inside the build script instead of exposing target booleans to app modules",
    },
    .{
        .patterns = &.{
            "supports_win32_resources",
            "supports_windows_subsystem",
        },
        .message = "build.zig platform capability names must describe artifact roles instead of concrete Windows implementation names",
    },
    .{
        .patterns = &.{
            "is_windows: bool",
            ".is_windows",
        },
        .message = "build.zig platform feature gates must expose artifact capabilities, not target OS booleans",
    },
};

/// Returns the message of the first leak check whose pattern appears in
/// `source`, or null when the build-script source is clean.
pub fn firstLeak(source: []const u8) ?[]const u8 {
    for (app_leak_checks) |check| {
        for (check.patterns) |pattern| {
            if (std.mem.indexOf(u8, source, pattern) != null) return check.message;
        }
    }
    return null;
}

test "firstLeak passes a clean build script" {
    const clean =
        \\const target = b.standardTargetOptions(.{});
        \\const platform = PlatformFeatures.forOs(target.result.os.tag);
        \\const webview = b.option(bool, "webview", "Enable the embedded browser panel");
    ;
    try std.testing.expect(firstLeak(clean) == null);
}

test "firstLeak flags target-OS boolean feature gate fields" {
    try std.testing.expectEqualStrings(
        "build.zig platform feature gates must expose artifact capabilities, not target OS booleans",
        firstLeak("    is_windows: bool,").?,
    );
    try std.testing.expectEqualStrings(
        "build.zig platform feature gates must expose artifact capabilities, not target OS booleans",
        firstLeak("if (platform.is_windows) {").?,
    );
}

test "firstLeak flags target-OS boolean build options" {
    try std.testing.expectEqualStrings(
        "build.zig must keep platform feature gates inside the build script instead of exposing target booleans to app modules",
        firstLeak("app_options.addOption(bool, \"target_is_windows\", true);").?,
    );
    try std.testing.expectEqualStrings(
        "build.zig must keep platform feature gates inside the build script instead of exposing target booleans to app modules",
        firstLeak("app_options.addOption(bool, \"platform_supports_browser\", true);").?,
    );
}

test "firstLeak flags WinHTTP-specific remote transport capability" {
    try std.testing.expectEqualStrings(
        "build.zig must expose remote transport as a platform capability, not a WinHTTP-specific build option",
        firstLeak("supports_winhttp_remote_transport: bool,").?,
    );
}

test "firstLeak flags Windows-specific capability names" {
    try std.testing.expectEqualStrings(
        "build.zig platform capability names must describe artifact roles instead of concrete Windows implementation names",
        firstLeak("supports_win32_resources: bool,").?,
    );
    try std.testing.expectEqualStrings(
        "build.zig platform capability names must describe artifact roles instead of concrete Windows implementation names",
        firstLeak("supports_windows_subsystem: bool,").?,
    );
}
