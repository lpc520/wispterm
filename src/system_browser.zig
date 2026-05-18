//! Open URLs with the Windows default browser.

const std = @import("std");
const win32 = @import("apprt/win32.zig");

const SW_SHOWNORMAL: win32.INT = 1;
const SHELL_EXECUTE_ERROR_MAX: usize = 32;

pub fn openUrl(allocator: std.mem.Allocator, hwnd: ?win32.HWND, url: []const u8) bool {
    const url_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, url) catch return false;
    defer allocator.free(url_w);

    const result = win32.ShellExecuteW(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        url_w.ptr,
        null,
        null,
        SW_SHOWNORMAL,
    );
    if (!shellExecuteSucceeded(result)) {
        std.debug.print("System browser open failed for {s}: ShellExecuteW returned {d}\n", .{ url, result });
        return false;
    }
    return true;
}

pub fn shellExecuteSucceeded(result: usize) bool {
    return result > SHELL_EXECUTE_ERROR_MAX;
}

test "ShellExecuteW return values at or below 32 are failures" {
    try std.testing.expect(!shellExecuteSucceeded(0));
    try std.testing.expect(!shellExecuteSucceeded(2));
    try std.testing.expect(!shellExecuteSucceeded(31));
    try std.testing.expect(!shellExecuteSucceeded(32));
}

test "ShellExecuteW return values above 32 are success" {
    try std.testing.expect(shellExecuteSucceeded(33));
}
