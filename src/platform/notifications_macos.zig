const platform_window = @import("window.zig");

extern fn wispterm_macos_notification_bell() void;
extern fn wispterm_macos_notification_request_attention(handle: ?*anyopaque) void;

pub fn bell() void {
    wispterm_macos_notification_bell();
}

pub fn requestAttention(handle: platform_window.NativeHandle) void {
    wispterm_macos_notification_request_attention(handle);
}
