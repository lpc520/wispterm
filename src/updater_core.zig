const std = @import("std");

pub const Options = struct {
    pid: u32,
    source: []const u8,
    target: []const u8,
    restart: bool,
};

pub const ManifestEntry = struct {
    path: []const u8,
    directory: bool = false,
    optional: bool = false,
};

pub const replacement_manifest = [_]ManifestEntry{
    .{ .path = "phantty.exe" },
    .{ .path = "phantty-updater.exe" },
    .{ .path = "version.txt" },
    .{ .path = "plugins", .directory = true },
    .{ .path = "WebView2Loader.dll", .optional = true },
};

pub const ArgError = error{
    MissingPid,
    MissingSource,
    MissingTarget,
    InvalidPid,
    UnknownArgument,
    SourceEqualsTarget,
    RelativeSource,
    RelativeTarget,
};

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var pid: ?u32 = null;
    var source: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var restart = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingPid;
            pid = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidPid;
        } else if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return error.MissingSource;
            source = args[i];
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTarget;
            target = args[i];
        } else if (std.mem.eql(u8, arg, "--restart")) {
            restart = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const options = Options{
        .pid = pid orelse return error.MissingPid,
        .source = source orelse return error.MissingSource,
        .target = target orelse return error.MissingTarget,
        .restart = restart,
    };
    try validateOptions(options);
    return options;
}

fn isAbsoluteWindowsOrNative(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

pub fn validateOptions(options: Options) ArgError!void {
    if (options.source.len == 0) return error.MissingSource;
    if (options.target.len == 0) return error.MissingTarget;
    if (std.mem.eql(u8, options.source, options.target)) return error.SourceEqualsTarget;
    if (!isAbsoluteWindowsOrNative(options.source)) return error.RelativeSource;
    if (!isAbsoluteWindowsOrNative(options.target)) return error.RelativeTarget;
}

fn joinAlloc(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ a, b });
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn deletePath(path: []const u8, directory: bool) !void {
    if (directory) {
        std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    try std.fs.makeDirAbsolute(target);
    var src_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try joinAlloc(allocator, source, entry.name);
        defer allocator.free(src_child);
        const dst_child = try joinAlloc(allocator, target, entry.name);
        defer allocator.free(dst_child);
        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_child, dst_child),
            .file => try std.fs.copyFileAbsolute(src_child, dst_child, .{}),
            else => {},
        }
    }
}

fn copyPath(allocator: std.mem.Allocator, source: []const u8, target: []const u8, directory: bool) !void {
    if (directory) {
        try copyDirRecursive(allocator, source, target);
    } else {
        try std.fs.copyFileAbsolute(source, target, .{});
    }
}

pub fn backupDirForSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(source) orelse return error.MissingSourceParent;
    return try std.fs.path.join(allocator, &.{ parent, "backup" });
}

pub fn backupCurrentPayload(allocator: std.mem.Allocator, target: []const u8, backup: []const u8) !void {
    std.fs.deleteTreeAbsolute(backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.makeDirAbsolute(backup);
    for (replacement_manifest) |entry| {
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        if (!pathExists(target_path)) {
            if (entry.optional) continue;
            return error.MissingTargetPayload;
        }
        const backup_path = try joinAlloc(allocator, backup, entry.path);
        defer allocator.free(backup_path);
        try copyPath(allocator, target_path, backup_path, entry.directory);
    }
}

pub fn copyNewPayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    for (replacement_manifest) |entry| {
        const source_path = try joinAlloc(allocator, source, entry.path);
        defer allocator.free(source_path);
        if (!pathExists(source_path)) {
            if (entry.optional) continue;
            return error.MissingSourcePayload;
        }
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        try deletePath(target_path, entry.directory);
        try copyPath(allocator, source_path, target_path, entry.directory);
    }
}

pub fn restoreBackup(allocator: std.mem.Allocator, backup: []const u8, target: []const u8) void {
    for (replacement_manifest) |entry| {
        const backup_path = joinAlloc(allocator, backup, entry.path) catch continue;
        defer allocator.free(backup_path);
        if (!pathExists(backup_path)) continue;
        const target_path = joinAlloc(allocator, target, entry.path) catch continue;
        defer allocator.free(target_path);
        deletePath(target_path, entry.directory) catch {};
        copyPath(allocator, backup_path, target_path, entry.directory) catch {};
    }
}

pub fn replacePayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    const backup = try backupDirForSource(allocator, source);
    defer allocator.free(backup);
    try backupCurrentPayload(allocator, target, backup);
    copyNewPayload(allocator, source, target) catch |err| {
        restoreBackup(allocator, backup, target);
        return err;
    };
}

pub fn targetExePath(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ target, "phantty.exe" });
}

test "updater_core: parses updater arguments" {
    const args = [_][]const u8{
        "phantty-updater.exe",
        "--pid",
        "123",
        "--source",
        "C:\\Temp\\payload",
        "--target",
        "C:\\Apps\\Phantty",
        "--restart",
    };

    const options = try parseArgs(args[1..]);
    try std.testing.expectEqual(@as(u32, 123), options.pid);
    try std.testing.expectEqualStrings("C:\\Temp\\payload", options.source);
    try std.testing.expectEqualStrings("C:\\Apps\\Phantty", options.target);
    try std.testing.expect(options.restart);
}

test "updater_core: manifest excludes portable user config" {
    for (replacement_manifest) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.path, "phantty.conf"));
    }
}

test "updater_core: rejects equal source and target paths" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "C:\\Apps\\Phantty",
        .target = "C:\\Apps\\Phantty",
        .restart = false,
    }));
}
