const std = @import("std");
const release_package = @import("../release_package.zig");

fn assetNameParts(package: release_package.Package) ?struct { prefix: []const u8, suffix: []const u8 } {
    if (package.platform != .macos) return null;
    return .{
        .prefix = "wispterm-macos-",
        .suffix = ".dmg",
    };
}

pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    _ = allocator;
    _ = webview_enabled;
    return .{ .platform = .macos };
}

pub fn assetName(tag_name: []const u8, package: release_package.Package, buf: []u8) ![]const u8 {
    const parts = assetNameParts(package) orelse return error.UnsupportedReleasePackage;
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ parts.prefix, tag_name, parts.suffix });
}

pub fn matchesAssetName(name: []const u8, tag_name: []const u8, package: release_package.Package) bool {
    const parts = assetNameParts(package) orelse return false;
    return name.len == parts.prefix.len + tag_name.len + parts.suffix.len and
        std.mem.startsWith(u8, name, parts.prefix) and
        std.mem.endsWith(u8, name, parts.suffix) and
        std.mem.eql(u8, name[parts.prefix.len .. parts.prefix.len + tag_name.len], tag_name);
}

test "macOS update package reports the native platform package" {
    try std.testing.expectEqual(release_package.Platform.macos, (try currentPackage(std.testing.allocator, false)).platform);
}
