const std = @import("std");

extern fn phantty_macos_workspace_open_url(url: [*:0]const u8) bool;
extern fn phantty_macos_workspace_open_path(path: [*:0]const u8, reveal: bool) bool;

pub fn open(allocator: std.mem.Allocator, request: anytype) bool {
    const url = allocator.dupeZ(u8, request.url) catch return false;
    defer allocator.free(url);
    return phantty_macos_workspace_open_url(url.ptr);
}

pub fn reveal(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    return phantty_macos_workspace_open_path(path_z.ptr, true);
}
