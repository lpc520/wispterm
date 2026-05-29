extern fn wispterm_macos_cursor_set(shape: u32) void;

pub fn set(shape: anytype) void {
    wispterm_macos_cursor_set(switch (shape) {
        .arrow => 0,
        .ibeam => 1,
        .size_we => 2,
        .size_ns => 3,
        .size_all => 4,
    });
}
