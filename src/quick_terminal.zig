const std = @import("std");

pub const HOTKEY_ID: i32 = 0x5154; // "QT"

pub const Position = enum {
    top,
};

pub const Settings = struct {
    enabled: bool = true,
    position: Position = .top,
    height_percent: u8 = 50,
};

pub const WorkArea = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const Frame = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const FrameRequest = struct {
    work_area: WorkArea,
    position: Position = .top,
    height_percent: u8 = 50,
};

pub fn defaultSettings() Settings {
    return .{};
}

pub fn calculateFrame(request: FrameRequest) Frame {
    const work_width = @max(1, request.work_area.right - request.work_area.left);
    const work_height = @max(1, request.work_area.bottom - request.work_area.top);
    const percent: i32 = @intCast(@min(100, @max(10, request.height_percent)));

    return switch (request.position) {
        .top => .{
            .x = request.work_area.left,
            .y = request.work_area.top,
            .width = work_width,
            .height = @max(1, @divTrunc(work_height * percent, 100)),
        },
    };
}

pub fn frameIntersectsWorkArea(frame: Frame, work_area: WorkArea) bool {
    if (frame.width <= 0 or frame.height <= 0) return false;

    const frame_left: i64 = frame.x;
    const frame_top: i64 = frame.y;
    const frame_right = frame_left + frame.width;
    const frame_bottom = frame_top + frame.height;
    const work_left: i64 = work_area.left;
    const work_top: i64 = work_area.top;
    const work_right: i64 = work_area.right;
    const work_bottom: i64 = work_area.bottom;

    return frame_right > work_left and
        frame_bottom > work_top and
        frame_left < work_right and
        frame_top < work_bottom;
}

test "quick terminal defaults are enabled" {
    const defaults = defaultSettings();

    try std.testing.expect(defaults.enabled);
}

test "quick terminal top frame uses full work area width and half height" {
    const frame = calculateFrame(.{
        .work_area = .{ .left = 100, .top = 50, .right = 2020, .bottom = 1130 },
        .height_percent = 50,
    });

    try std.testing.expectEqual(Frame{ .x = 100, .y = 50, .width = 1920, .height = 540 }, frame);
}

test "quick terminal cached frame must intersect work area" {
    const work_area = WorkArea{ .left = 100, .top = 50, .right = 2020, .bottom = 1130 };

    try std.testing.expect(frameIntersectsWorkArea(
        .{ .x = 100, .y = 50, .width = 1920, .height = 540 },
        work_area,
    ));
    try std.testing.expect(frameIntersectsWorkArea(
        .{ .x = 1900, .y = 1000, .width = 400, .height = 300 },
        work_area,
    ));
    try std.testing.expect(!frameIntersectsWorkArea(
        .{ .x = -500, .y = 50, .width = 100, .height = 100 },
        work_area,
    ));
    try std.testing.expect(!frameIntersectsWorkArea(
        .{ .x = 100, .y = 50, .width = 0, .height = 100 },
        work_area,
    ));
}
