pub const default_dpi: u32 = 96;

extern fn wispterm_macos_display_point_on_any_screen(x: i32, y: i32) bool;

pub fn isPointOnAnyDisplay(x: i32, y: i32) bool {
    return wispterm_macos_display_point_on_any_screen(x, y);
}
