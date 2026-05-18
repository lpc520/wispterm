const std = @import("std");

pub const Destination = enum {
    embedded_browser,
    system_browser,
};

pub fn destinationForUrlClick(embedded_browser_available: bool) Destination {
    return if (embedded_browser_available) .embedded_browser else .system_browser;
}

test "URL clicks use the system browser when embedded WebView is unavailable" {
    try std.testing.expectEqual(Destination.system_browser, destinationForUrlClick(false));
}

test "URL clicks use the embedded browser when it is available" {
    try std.testing.expectEqual(Destination.embedded_browser, destinationForUrlClick(true));
}
