const std = @import("std");

const win32_backend = @import("apprt/win32.zig");

pub fn terminalArrowSequence(ev: win32_backend.KeyEvent, cursor_keys: bool) ?[]const u8 {
    const modifier: u8 = 1 +
        @as(u8, if (ev.shift) 1 else 0) +
        @as(u8, if (ev.alt) 2 else 0) +
        @as(u8, if (ev.ctrl) 4 else 0);

    inline for (terminal_arrow_sequences) |entry| {
        if (ev.vk == entry.vk) {
            return if (modifier == 1) cursorModeSequence(entry, cursor_keys) else entry.modified[modifier - 2];
        }
    }
    return null;
}

fn cursorModeSequence(entry: TerminalArrowSequence, cursor_keys: bool) []const u8 {
    return if (cursor_keys) entry.application else entry.normal;
}

const TerminalArrowSequence = struct {
    vk: usize,
    normal: []const u8,
    application: []const u8,
    modified: [7][]const u8,
};

const terminal_arrow_sequences = [_]TerminalArrowSequence{
    .{ .vk = win32_backend.VK_UP, .normal = "\x1b[A", .application = "\x1bOA", .modified = .{ "\x1b[1;2A", "\x1b[1;3A", "\x1b[1;4A", "\x1b[1;5A", "\x1b[1;6A", "\x1b[1;7A", "\x1b[1;8A" } },
    .{ .vk = win32_backend.VK_DOWN, .normal = "\x1b[B", .application = "\x1bOB", .modified = .{ "\x1b[1;2B", "\x1b[1;3B", "\x1b[1;4B", "\x1b[1;5B", "\x1b[1;6B", "\x1b[1;7B", "\x1b[1;8B" } },
    .{ .vk = win32_backend.VK_RIGHT, .normal = "\x1b[C", .application = "\x1bOC", .modified = .{ "\x1b[1;2C", "\x1b[1;3C", "\x1b[1;4C", "\x1b[1;5C", "\x1b[1;6C", "\x1b[1;7C", "\x1b[1;8C" } },
    .{ .vk = win32_backend.VK_LEFT, .normal = "\x1b[D", .application = "\x1bOD", .modified = .{ "\x1b[1;2D", "\x1b[1;3D", "\x1b[1;4D", "\x1b[1;5D", "\x1b[1;6D", "\x1b[1;7D", "\x1b[1;8D" } },
};

test "terminal arrow sequence handles modifiers" {
    try std.testing.expectEqualStrings(
        "\x1b[A",
        terminalArrowSequence(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = false }, false).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOA",
        terminalArrowSequence(.{ .vk = win32_backend.VK_UP, .ctrl = false, .shift = false, .alt = false }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1bOD",
        terminalArrowSequence(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = false }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;3D",
        terminalArrowSequence(.{ .vk = win32_backend.VK_LEFT, .ctrl = false, .shift = false, .alt = true }, true).?,
    );
    try std.testing.expectEqualStrings(
        "\x1b[1;5C",
        terminalArrowSequence(.{ .vk = win32_backend.VK_RIGHT, .ctrl = true, .shift = false, .alt = false }, false).?,
    );
    try std.testing.expect(terminalArrowSequence(.{ .vk = 0x41, .ctrl = false, .shift = false, .alt = true }, false) == null);
}
