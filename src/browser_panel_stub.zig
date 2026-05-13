//! No-op browser panel used for pure terminal-core builds.

const std = @import("std");
const win32 = @import("apprt/win32.zig");
const Surface = @import("Surface.zig");

pub const DEFAULT_WIDTH: f32 = 720;
pub const MIN_WIDTH: f32 = 360;
pub const MAX_WIDTH: f32 = 1280;
pub const MIN_CONTENT_WIDTH: f32 = 320;
pub const RESIZE_HIT_WIDTH: f32 = 12;
pub const URL_BAR_HEIGHT: f32 = 42;
pub const URL_BAR_MARGIN: f32 = 8;
pub const DEFAULT_URL = "http://localhost:3000";

pub const Bounds = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_last_error: win32.HRESULT = 0;

pub fn urlBarBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const bottom = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bottom <= bounds.top) return null;
    return .{
        .left = left,
        .top = bounds.top,
        .right = bounds.right,
        .bottom = bottom,
    };
}

pub fn contentBounds(bounds: Bounds) ?Bounds {
    const grip: i32 = @intFromFloat(@round(RESIZE_HIT_WIDTH));
    const left = @min(bounds.right, bounds.left + grip);
    const top = @min(bounds.bottom, bounds.top + @as(i32, @intFromFloat(@round(URL_BAR_HEIGHT))));
    if (bounds.right <= left or bounds.bottom <= top) return null;
    return .{
        .left = left,
        .top = top,
        .right = bounds.right,
        .bottom = bounds.bottom,
    };
}

pub fn width() f32 {
    return 0;
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    _ = w;
    _ = window_width;
    return false;
}

pub fn panelWidthForWindow(window_width: i32, left_offset: f32, right_offset: f32) f32 {
    _ = window_width;
    _ = left_offset;
    _ = right_offset;
    return 0;
}

pub fn open(parent: ?win32.HWND, url: []const u8) void {
    _ = parent;
    _ = url;
    g_visible = false;
}

pub fn openForSurface(allocator: std.mem.Allocator, parent: ?win32.HWND, url: []const u8, surface: ?*const Surface) bool {
    _ = allocator;
    _ = parent;
    _ = url;
    _ = surface;
    g_visible = false;
    return false;
}

pub fn toggle(parent: ?win32.HWND) void {
    _ = parent;
    g_visible = false;
}

pub fn toggleForSurface(allocator: std.mem.Allocator, parent: ?win32.HWND, surface: ?*const Surface) bool {
    _ = allocator;
    _ = parent;
    _ = surface;
    g_visible = false;
    return false;
}

pub fn close() void {
    g_visible = false;
}

pub fn focus() void {}

pub fn isReady() bool {
    return false;
}

pub fn lastError() win32.HRESULT {
    return g_last_error;
}

pub fn sync(parent: win32.HWND, window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) void {
    _ = parent;
    _ = window_width;
    _ = window_height;
    _ = titlebar_height;
    _ = left_offset;
    _ = right_offset;
}

pub fn deinit() void {
    g_visible = false;
}

pub fn currentUrl() []const u8 {
    return DEFAULT_URL;
}

pub fn urlBarFocused() bool {
    return false;
}

pub fn urlBarText() []const u8 {
    return DEFAULT_URL;
}

pub fn urlBarSelectAll() bool {
    return false;
}

pub fn focusUrlBar() void {}

pub fn blurUrlBar() void {}

pub fn insertUrlBarChar(codepoint: u21) void {
    _ = codepoint;
}

pub fn appendUrlBarText(text: []const u8) void {
    _ = text;
}

pub fn backspaceUrlBar() void {}

pub fn clearUrlBar() void {}

pub fn submitUrlBar(allocator: std.mem.Allocator, parent: ?win32.HWND, surface: ?*const Surface) bool {
    _ = allocator;
    _ = parent;
    _ = surface;
    return false;
}

pub fn selectAllUrlBar() void {}

pub fn boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32) Bounds {
    _ = window_width;
    _ = right_offset;
    const win_h: f32 = @floatFromInt(window_height);
    const left = @max(0, left_offset);
    const top = @max(0, titlebar_height);
    return .{
        .left = @intFromFloat(@round(left)),
        .top = @intFromFloat(@round(top)),
        .right = @intFromFloat(@round(left)),
        .bottom = @intFromFloat(@round(@max(top, win_h))),
    };
}
