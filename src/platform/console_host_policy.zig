//! Pure policy for choosing which pseudo-console host implementation
//! services new terminal sessions. Platform-neutral so the config layer and
//! tests can use it without touching any OS API; the Windows loader consumes
//! the decision in platform/conpty_dll.zig.

const std = @import("std");

/// User preference from the `windows-conpty` config key.
pub const Preference = enum { auto, system };

/// Resolved implementation choice.
pub const Choice = enum { bundled, system };

/// `auto` uses the bundled console host only when both redistributable files
/// sit next to the executable; anything else stays on the OS inbox
/// implementation.
pub fn choose(pref: Preference, dll_present: bool, host_exe_present: bool) Choice {
    if (pref == .system) return .system;
    if (dll_present and host_exe_present) return .bundled;
    return .system;
}

pub fn parsePreference(value: []const u8) ?Preference {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "system")) return .system;
    return null;
}

test "console host policy uses bundled host only when fully present under auto" {
    try std.testing.expectEqual(Choice.bundled, choose(.auto, true, true));
    try std.testing.expectEqual(Choice.system, choose(.auto, true, false));
    try std.testing.expectEqual(Choice.system, choose(.auto, false, true));
    try std.testing.expectEqual(Choice.system, choose(.auto, false, false));
}

test "console host policy honors forced system preference" {
    try std.testing.expectEqual(Choice.system, choose(.system, true, true));
}

test "console host policy parses config values" {
    try std.testing.expectEqual(Preference.auto, parsePreference("auto").?);
    try std.testing.expectEqual(Preference.system, parsePreference("system").?);
    try std.testing.expect(parsePreference("bundled") == null);
    try std.testing.expect(parsePreference("") == null);
}
