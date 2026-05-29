const platform_window = @import("window.zig");

extern fn wispterm_macos_global_hotkey_register(hwnd: ?*anyopaque, id: i32, modifiers: u32, key_code: u32) bool;
extern fn wispterm_macos_global_hotkey_unregister(hwnd: ?*anyopaque, id: i32) void;
extern fn wispterm_macos_global_hotkey_translate(modifiers: u32, key_code: u32, out_modifiers: ?*u32, out_key_code: ?*u32) bool;

pub fn register(hwnd: platform_window.NativeHandle, id: i32, modifiers: u32, key_code: u32) bool {
    return wispterm_macos_global_hotkey_register(hwnd, id, modifiers, key_code);
}

pub fn unregister(hwnd: platform_window.NativeHandle, id: i32) void {
    wispterm_macos_global_hotkey_unregister(hwnd, id);
}

pub fn canTranslateForTest(modifiers: u32, key_code: u32) bool {
    return wispterm_macos_global_hotkey_translate(modifiers, key_code, null, null);
}
