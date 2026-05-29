const std = @import("std");

extern fn wispterm_macos_text_case_insensitive_equal(a: [*:0]const u8, b: [*:0]const u8) i32;

pub fn nativeOrdinalIgnoreCaseUtf8Equal(a: []const u8, b: []const u8) ?bool {
    var a_buf: [4096:0]u8 = undefined;
    var b_buf: [4096:0]u8 = undefined;
    if (a.len >= a_buf.len or b.len >= b_buf.len) return null;
    @memcpy(a_buf[0..a.len], a);
    @memcpy(b_buf[0..b.len], b);
    a_buf[a.len] = 0;
    b_buf[b.len] = 0;
    return switch (wispterm_macos_text_case_insensitive_equal(&a_buf, &b_buf)) {
        1 => true,
        0 => false,
        else => null,
    };
}

test "macOS text comparison handles ASCII case folding through Foundation" {
    try std.testing.expectEqual(@as(?bool, true), nativeOrdinalIgnoreCaseUtf8Equal("A", "a"));
    try std.testing.expectEqual(@as(?bool, false), nativeOrdinalIgnoreCaseUtf8Equal("A", "B"));
}
