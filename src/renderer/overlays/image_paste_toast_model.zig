//! Pure layout model for the clipboard-image paste toast.

const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub fn layout(window_width: f32, window_height: f32, titlebar_h: f32, toast_w: f32, toast_h: f32) Rect {
    const margin: f32 = 16;
    const top_gap: f32 = 12;
    const w = @max(1.0, toast_w);
    const h = @max(1.0, toast_h);
    return .{
        .x = @round(@max(margin, window_width - w - margin)),
        .y = @round(@max(margin, window_height - @max(0.0, titlebar_h) - top_gap - h)),
        .w = w,
        .h = h,
    };
}

test "image paste toast anchors to top right under the titlebar" {
    const rect = layout(1200, 800, 36, 180, 32);

    try std.testing.expectApproxEqAbs(@as(f32, 1004), rect.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 720), rect.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), rect.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 32), rect.h, 0.01);
}
