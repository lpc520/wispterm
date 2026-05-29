//! Native macOS platform-service smoke-test entry point.

const std = @import("std");

const clipboard = @import("platform/clipboard.zig");
const config_watcher = @import("platform/config_watcher.zig");
const cursor = @import("platform/cursor.zig");
const display = @import("platform/display.zig");
const file_dialog = @import("platform/file_dialog.zig");
const global_hotkey = @import("platform/global_hotkey.zig");
const global_hotkey_macos = @import("platform/global_hotkey_macos.zig");
const notifications = @import("platform/notifications.zig");
const open_url = @import("platform/open_url.zig");
const text = @import("platform/text.zig");
const update_package = @import("platform/update_package.zig");

test "macOS services select native or supported platform backends" {
    try std.testing.expectEqualStrings("macos", @tagName(clipboard.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(file_dialog.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(cursor.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(notifications.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(global_hotkey.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(config_watcher.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(display.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(text.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(open_url.backendForOs(.macos)));
    try std.testing.expectEqualStrings("macos", @tagName(update_package.backendForOs(.macos)));
}

test "macOS clipboard round-trips UTF-8 text through NSPasteboard" {
    const owner = clipboard.windowOwner(0);
    try std.testing.expect(clipboard.writeText(std.testing.allocator, owner, "wispterm mac clipboard"));
    const text_value = clipboard.readText(std.testing.allocator, owner) orelse return error.ExpectedClipboardText;
    defer std.testing.allocator.free(text_value);
    try std.testing.expectEqualStrings("wispterm mac clipboard", text_value);
}

test "macOS display and text services return native answers" {
    try std.testing.expect(display.isPointOnAnyDisplay(0, 0));
    try std.testing.expectEqual(@as(?bool, true), text.nativeOrdinalIgnoreCaseUtf8Equal("WispTerm", "wispterm"));
    try std.testing.expectEqual(@as(?bool, false), text.nativeOrdinalIgnoreCaseUtf8Equal("WispTerm", "Ghostty"));
}

test "macOS config watcher observes directory changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const real_dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(real_dir);

    var watcher = config_watcher.DirectoryWatcher.initPath(real_dir) orelse return error.ExpectedConfigWatcher;
    defer watcher.deinit();
    try std.testing.expect(!watcher.hasChanged());

    {
        var file = try tmp.dir.createFile("config", .{ .truncate = true });
        defer file.close();
        try file.writeAll("font-family = Menlo\n");
    }

    var observed = false;
    for (0..20) |_| {
        if (watcher.hasChanged()) {
            observed = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(observed);
}

test "macOS noninteractive service calls are safe" {
    cursor.set(.arrow);
    notifications.bell();

    const trigger = global_hotkey.Trigger{ .ctrl = true, .key_code = 'P' };
    try std.testing.expect(global_hotkey.modifiersForTrigger(trigger) != 0);
    try std.testing.expect(global_hotkey_macos.canTranslateForTest(
        global_hotkey.modifiersForTrigger(.{ .ctrl = true, .key_code = 0xC0 }),
        0xC0,
    ));
    try std.testing.expect(global_hotkey_macos.canTranslateForTest(
        global_hotkey.modifiersForTrigger(.{ .ctrl = true, .shift = true, .alt = true, .win = true, .key_code = 0x82 }),
        0x82,
    ));
}

test {
    _ = file_dialog;
    _ = open_url;
    _ = update_package;
}
