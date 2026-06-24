const std = @import("std");
const settings_page = @import("settings_page.zig");
const toasts = @import("toasts.zig");
const confirm_modals = @import("confirm_modals.zig");

pub const OverlayState = struct {
    settings: settings_page.State = .{},
    toasts: toasts.State = .{},
    confirms: confirm_modals.State = .{},

    pub fn deinit(self: *OverlayState, allocator: std.mem.Allocator) void {
        self.settings.deinit(allocator);
    }
};

test "overlay state aggregates migrated overlay groups" {
    var state: OverlayState = .{};

    state.settings.open();
    state.toasts.copy.show("Copied", 10, 100);
    state.confirms.openRestoreDefaults();

    try std.testing.expect(state.settings.visible);
    try std.testing.expectEqualStrings("Copied", state.toasts.copy.text().?);
    try std.testing.expect(state.confirms.restore_defaults_visible);
}

test "overlay state deinit releases settings cache" {
    var state: OverlayState = .{};

    _ = state.settings.cfg(std.testing.allocator);
    state.deinit(std.testing.allocator);
}
