/// Watches the config file directory for changes.
///
/// The app layer resolves WispTerm's config path. The platform layer owns the
/// OS-specific directory notification backend.
const std = @import("std");
const Config = @import("config.zig");
const platform_config_watcher = @import("platform/config_watcher.zig");

const ConfigWatcher = @This();

watcher: platform_config_watcher.DirectoryWatcher,
allocator: std.mem.Allocator,
config_path: []const u8,
last_mtime: ?i128,

/// Open the config directory and start watching for changes.
pub fn init(allocator: std.mem.Allocator) ?ConfigWatcher {
    const path = Config.configFilePath(allocator) catch |err| {
        std.debug.print("ConfigWatcher: failed to get config path: {}\n", .{err});
        return null;
    };

    const dir_path = std.fs.path.dirname(path) orelse {
        std.debug.print("ConfigWatcher: failed to get directory from path\n", .{});
        allocator.free(path);
        return null;
    };

    const watcher = platform_config_watcher.DirectoryWatcher.initPath(dir_path) orelse {
        allocator.free(path);
        return null;
    };
    std.debug.print("ConfigWatcher: watching {s}\\config\n", .{dir_path});
    return .{
        .watcher = watcher,
        .allocator = allocator,
        .config_path = path,
        .last_mtime = configMtime(path),
    };
}

/// Non-blocking check: has the config file changed?
pub fn hasChanged(self: *ConfigWatcher) bool {
    if (!self.watcher.hasChanged()) return false;
    const next_mtime = configMtime(self.config_path);
    if (optionalMtimeEql(self.last_mtime, next_mtime)) return false;
    self.last_mtime = next_mtime;
    return true;
}

pub fn deinit(self: *ConfigWatcher) void {
    self.watcher.deinit();
    self.allocator.free(self.config_path);
}

fn configMtime(path: []const u8) ?i128 {
    const stat = std.fs.cwd().statFile(path) catch return null;
    return stat.mtime;
}

fn optionalMtimeEql(a: ?i128, b: ?i128) bool {
    if (a) |av| {
        if (b) |bv| return av == bv;
        return false;
    }
    return b == null;
}

test "config watcher wraps platform directory watcher" {
    try std.testing.expect(@hasDecl(ConfigWatcher, "init"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "hasChanged"));
    try std.testing.expect(@hasDecl(ConfigWatcher, "deinit"));
}
