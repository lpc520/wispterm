//! State and layout math for the right-side AI copilot sidebar.
//!
//! Mirrors browser_panel's right-dock width model, but the conversation lives
//! per-tab in TabState.copilot_session — this module owns only visibility and
//! width. Kept free of tab/AppWindow imports so the math runs in the fast test
//! suite; the "only on terminal tabs" gate is applied by the caller (AppWindow).

const std = @import("std");

pub const DEFAULT_WIDTH: f32 = 480;
pub const MIN_WIDTH: f32 = 320;
pub const MAX_WIDTH: f32 = 1200;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// Global visibility flag (the active terminal tab's session is what renders).
pub threadlocal var g_visible: bool = false;
/// Shared width across tabs; not persisted across restarts (design decision).
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

/// Set the panel width, clamped to [MIN_WIDTH, maxWidthForWindow]. Returns true
/// if the value changed.
pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

/// Width the panel should occupy for a given window, leaving MIN_CONTENT_WIDTH
/// for the terminal. Assumes the panel is visible; the caller gates visibility.
pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    const win_w: f32 = @floatFromInt(window_width);
    const max_width = @max(MIN_WIDTH, @min(MAX_WIDTH, win_w - left_offset - right_offset - MIN_CONTENT_WIDTH));
    return @max(MIN_WIDTH, @min(g_width, max_width));
}

/// Pixel bounds of the panel (right-docked). Assumes visible; caller gates.
pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    const win_w: f32 = @floatFromInt(window_width);
    const win_h: f32 = @floatFromInt(window_height);
    const panel_w = panelWidthForWindow(window_width, left_offset, right_offset);
    const right = @max(0, win_w - right_offset);
    const left = @max(left_offset, right - panel_w);
    const top = @max(0, titlebar_height);
    const bottom = @max(top, win_h);
    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(right)),
        .bottom = @intFromFloat(@round(bottom)),
    };
}

pub fn show() void {
    g_visible = true;
}
pub fn hide() void {
    g_visible = false;
}
pub fn toggle() void {
    g_visible = !g_visible;
}

test "panelWidthForWindow clamps to g_width when it fits" {
    g_width = 480;
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(1600, 0, 0), 0.001);
}

test "panelWidthForWindow shrinks to keep MIN_CONTENT_WIDTH" {
    g_width = 1200;
    // 800 - 0 - 0 - 320 = 480 available; clamped down from 1200.
    try std.testing.expectApproxEqAbs(@as(f32, 480), panelWidthForWindow(800, 0, 0), 0.001);
}

test "panelWidthForWindow never goes below MIN_WIDTH" {
    g_width = 320;
    // Even a tiny window keeps at least MIN_WIDTH.
    try std.testing.expectApproxEqAbs(MIN_WIDTH, panelWidthForWindow(300, 0, 0), 0.001);
}

test "setWidth clamps and reports change" {
    g_width = DEFAULT_WIDTH;
    try std.testing.expect(setWidth(10_000, 1600)); // clamped to maxWidthForWindow, changed
    try std.testing.expectApproxEqAbs(maxWidthForWindow(1600), g_width, 0.001);
    try std.testing.expect(!setWidth(g_width, 1600)); // no change
    g_width = DEFAULT_WIDTH; // restore for other tests
}

test "boundsForWindow right-docks the panel" {
    g_width = 480;
    const b = boundsForWindow(1600, 900, 30, 0, 0);
    try std.testing.expectEqual(@as(i32, 1600), b.right);
    try std.testing.expectEqual(@as(i32, 1120), b.left); // 1600 - 480
    try std.testing.expectEqual(@as(i32, 30), b.top);
    try std.testing.expectEqual(@as(i32, 900), b.bottom);
}

test "toggle flips visibility" {
    g_visible = false;
    toggle();
    try std.testing.expect(g_visible);
    toggle();
    try std.testing.expect(!g_visible);
}
