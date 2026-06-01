const std = @import("std");

pub const Layout = struct {
    left_x: f32,
    left_w: f32,
    list_x: f32,
    list_w: f32,
    detail_x: f32,
    detail_w: f32,
};

pub fn computeLayout(x: f32, width: f32) Layout {
    const available = @max(0, width);
    if (available == 0) {
        return .{
            .left_x = x,
            .left_w = 0,
            .list_x = x,
            .list_w = 0,
            .detail_x = x,
            .detail_w = 0,
        };
    }

    const min_left_w: f32 = 180;
    const min_list_w: f32 = 260;
    const min_detail_w: f32 = 120;
    const min_total = min_left_w + min_list_w + min_detail_w;
    const left_w = if (available < min_total)
        available * (min_left_w / min_total)
    else
        @min(@max(available * 0.20, min_left_w), 260);
    const list_w = if (available < min_total)
        available * (min_list_w / min_total)
    else
        @min(@max(available * 0.32, min_list_w), 420);
    const detail_w = available - left_w - list_w;
    return .{
        .left_x = x,
        .left_w = left_w,
        .list_x = x + left_w,
        .list_w = list_w,
        .detail_x = x + left_w + list_w,
        .detail_w = detail_w,
    };
}

pub fn render(session: anytype, window_width: f32, window_height: f32, titlebar_offset: f32, x: f32, width: f32) void {
    _ = session;
    _ = window_width;
    _ = window_height;
    _ = titlebar_offset;
    _ = computeLayout(x, width);
    // Placeholder in this task. Later tasks draw actual rows and transcript.
}

test "ai_history_renderer: layout keeps a readable detail column" {
    const layout = computeLayout(0, 1200);
    try std.testing.expect(layout.left_w >= 180);
    try std.testing.expect(layout.list_w >= 260);
    try std.testing.expect(layout.detail_w >= 120);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
}

test "ai_history_renderer: narrow layout stays inside available width" {
    const layout = computeLayout(10, 300);
    try std.testing.expect(layout.left_w >= 0);
    try std.testing.expect(layout.list_w >= 0);
    try std.testing.expect(layout.detail_w >= 0);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
    try std.testing.expect(layout.detail_x + layout.detail_w <= 310.001);
}

test "ai_history_renderer: zero width layout has no columns" {
    const layout = computeLayout(20, 0);
    try std.testing.expectEqual(@as(f32, 0), layout.left_w);
    try std.testing.expectEqual(@as(f32, 0), layout.list_w);
    try std.testing.expectEqual(@as(f32, 0), layout.detail_w);
    try std.testing.expectEqual(@as(f32, 20), layout.left_x);
    try std.testing.expectEqual(@as(f32, 20), layout.list_x);
    try std.testing.expectEqual(@as(f32, 20), layout.detail_x);
}
