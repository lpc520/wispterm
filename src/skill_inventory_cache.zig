//! Persisted cache of the last Skill Center scan, so reopening the panel shows
//! prior results instantly (offline servers as last-known) before the live
//! rescan lands. Stored as JSON at `<config>/skill-inventory-cache.json`.
const std = @import("std");
const dirs = @import("platform/dirs.zig");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");

const CACHE_BASENAME = "skill-inventory-cache.json";
const MAX_CACHE_BYTES = 4 * 1024 * 1024;

// JSON-facing mirror types (plain strings, owned by std.json on parse).
const JsonRow = struct {
    provider: []const u8,
    name: []const u8,
    rel_path: []const u8,
    agg_hash: ?[]const u8 = null,
};
const JsonServer = struct {
    source_id: []const u8,
    reachable: bool,
    rows: []JsonRow,
};
const JsonRoot = struct {
    servers: []JsonServer,
};

pub fn save(allocator: std.mem.Allocator, servers: []const inv.ServerScan) !void {
    var jservers = try allocator.alloc(JsonServer, servers.len);
    defer allocator.free(jservers);
    var built: usize = 0;
    defer for (jservers[0..built]) |js| allocator.free(js.rows);
    for (servers, 0..) |s, i| {
        const jrows = try allocator.alloc(JsonRow, s.rows.len);
        for (s.rows, 0..) |r, j| {
            jrows[j] = .{
                .provider = r.provider.toString(),
                .name = r.name,
                .rel_path = r.rel_path,
                .agg_hash = r.agg_hash,
            };
        }
        jservers[i] = .{ .source_id = s.source_id, .reachable = s.reachable, .rows = jrows };
        built += 1;
    }

    const json = try std.json.Stringify.valueAlloc(allocator, JsonRoot{ .servers = jservers }, .{});
    defer allocator.free(json);

    const path = try dirs.pathInConfigDir(allocator, CACHE_BASENAME);
    defer allocator.free(path);

    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    } else {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
    }
}

/// Load the cached scans as owned `[]inv.ServerScan` (deep-copied; caller frees
/// with `freeServerScans` then frees the slice). Returns an empty slice when no
/// cache exists.
pub fn load(allocator: std.mem.Allocator) ![]inv.ServerScan {
    const path = try dirs.pathInConfigDir(allocator, CACHE_BASENAME);
    defer allocator.free(path);

    const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_CACHE_BYTES) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(inv.ServerScan, 0),
        else => return err,
    };
    defer allocator.free(bytes);

    // alloc_always: parsed strings must not alias `bytes`, which we free here.
    var parsed = std.json.parseFromSlice(JsonRoot, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return allocator.alloc(inv.ServerScan, 0);
    defer parsed.deinit();

    var out = try allocator.alloc(inv.ServerScan, parsed.value.servers.len);
    var built: usize = 0;
    errdefer {
        freeServerScans(allocator, out[0..built]);
        allocator.free(out);
    }
    for (parsed.value.servers, 0..) |js, i| {
        const rows = try allocator.alloc(scan.SkillRow, js.rows.len);
        var rbuilt: usize = 0;
        errdefer {
            for (rows[0..rbuilt]) |*r| r.deinit(allocator);
            allocator.free(rows);
        }
        for (js.rows, 0..) |jr, j| {
            const provider = scan.Provider.fromString(jr.provider) orelse scan.Provider.claude;
            rows[j] = .{
                .provider = provider,
                .name = try allocator.dupe(u8, jr.name),
                .rel_path = try allocator.dupe(u8, jr.rel_path),
                .agg_hash = if (jr.agg_hash) |h| try allocator.dupe(u8, h) else null,
            };
            rbuilt += 1;
        }
        out[i] = .{
            .source_id = try allocator.dupe(u8, js.source_id),
            .reachable = js.reachable,
            .rows = rows,
        };
        built += 1;
    }
    return out;
}

pub fn freeServerScans(allocator: std.mem.Allocator, servers: []inv.ServerScan) void {
    for (servers) |s| {
        for (s.rows) |*r| {
            var row = r.*;
            row.deinit(allocator);
        }
        allocator.free(@constCast(s.rows));
        allocator.free(@constCast(s.source_id));
    }
}

test "skill_inventory_cache: save then load round-trips" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    dirs.setTestConfigDirForCurrentThread(tmp_path);
    defer dirs.clearTestConfigDirForCurrentThread();

    const rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("pdf"), .rel_path = @constCast(".claude/skills/pdf/SKILL.md"), .agg_hash = @constCast("h1") },
        .{ .provider = .codex, .name = @constCast("foo"), .rel_path = @constCast(".codex/prompts/foo.md"), .agg_hash = null },
    };
    const servers = [_]inv.ServerScan{
        .{ .source_id = "local", .reachable = true, .rows = &rows },
        .{ .source_id = "off", .reachable = false, .rows = &.{} },
    };

    try save(allocator, &servers);
    const loaded = try load(allocator);
    defer {
        freeServerScans(allocator, loaded);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("local", loaded[0].source_id);
    try std.testing.expect(loaded[0].reachable);
    try std.testing.expectEqual(@as(usize, 2), loaded[0].rows.len);
    try std.testing.expectEqualStrings("pdf", loaded[0].rows[0].name);
    try std.testing.expectEqualStrings("h1", loaded[0].rows[0].agg_hash.?);
    try std.testing.expectEqual(@as(?[]u8, null), loaded[0].rows[1].agg_hash);
    try std.testing.expect(!loaded[1].reachable);
    try std.testing.expectEqual(@as(usize, 0), loaded[1].rows.len);
}

test "skill_inventory_cache: load returns empty when no cache file" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    dirs.setTestConfigDirForCurrentThread(tmp_path);
    defer dirs.clearTestConfigDirForCurrentThread();

    const loaded = try load(allocator);
    defer allocator.free(loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}
