const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");
const inv_cache = @import("skill_inventory_cache.zig");

/// Source descriptor for a scan column. `id` is the stable column identity;
/// `name` is the display label.
pub const ScanSource = struct {
    id: []const u8,
    name: []const u8,
};

/// Seam that produces an `ExecHost` for a source (or errors -> unreachable
/// column). The integration layer supplies a real factory; tests use a fake.
pub const HostFactory = struct {
    ctx: *anyopaque,
    make: *const fn (*anyopaque, std.mem.Allocator, ScanSource) anyerror!scan.ExecHost,
};

/// Scan every source and return owned `[]inv.ServerScan` (free with
/// `inv_cache.freeServerScans` then free the slice). A source whose host cannot
/// be created, or whose scan reports unreachable, becomes an unreachable column
/// with no rows.
pub fn runScan(
    allocator: std.mem.Allocator,
    sources: []const ScanSource,
    factory: HostFactory,
) ![]inv.ServerScan {
    var out = try allocator.alloc(inv.ServerScan, sources.len);
    var built: usize = 0;
    errdefer {
        inv_cache.freeServerScans(allocator, out[0..built]);
        allocator.free(out);
    }

    for (sources, 0..) |src, i| {
        const id_copy = try allocator.dupe(u8, src.id);
        errdefer allocator.free(id_copy);

        const host = factory.make(factory.ctx, allocator, src) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };

        var outcome = scan.scanSource(allocator, scan.defaultTargets(), host) catch {
            out[i] = .{ .source_id = id_copy, .reachable = false, .rows = &.{} };
            built += 1;
            continue;
        };
        out[i] = .{ .source_id = id_copy, .reachable = outcome.reachable, .rows = outcome.rows };
        outcome.rows = &.{}; // ownership moved into the ServerScan
        built += 1;
    }

    return out;
}

// --- Tests ---

const ScriptHost = struct {
    fn make(_: *anyopaque, _: std.mem.Allocator, src: ScanSource) anyerror!scan.ExecHost {
        if (std.mem.eql(u8, src.id, "off")) return error.Unreachable;
        return .{ .ctx = @constCast(@ptrCast(src.id.ptr)), .exec = exec };
    }
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const id_ptr: [*]const u8 = @ptrCast(ctx);
        const id = id_ptr[0..5]; // "local" / "webxx"
        if (std.mem.startsWith(u8, id, "local")) {
            return allocator.dupe(u8, "claude\tpdf\t.claude/skills/pdf/SKILL.md\th1\n");
        }
        return allocator.dupe(u8, "claude\tpdf\t.claude/skills/pdf/SKILL.md\tDIFF\n");
    }
};

test "skill_center: runScan over sources builds a matrix" {
    const allocator = std.testing.allocator;
    const sources = [_]ScanSource{
        .{ .id = "local", .name = "Local" },
        .{ .id = "webxx", .name = "web" },
        .{ .id = "off", .name = "offline" },
    };
    var dummy: u8 = 0;
    const factory = HostFactory{ .ctx = &dummy, .make = ScriptHost.make };

    const servers = try runScan(allocator, &sources, factory);
    defer {
        inv_cache.freeServerScans(allocator, servers);
        allocator.free(servers);
    }

    try std.testing.expectEqual(@as(usize, 3), servers.len);
    try std.testing.expect(!servers[2].reachable); // off

    var m = try inv.buildMatrix(allocator, servers);
    defer m.deinit();
    try std.testing.expectEqual(@as(usize, 1), m.skills.len); // pdf
    try std.testing.expectEqual(inv.CellState.differ, m.cellAt(0, 0).state); // local h1 != ref(DIFF)
    try std.testing.expectEqual(inv.CellState.match, m.cellAt(0, 1).state); // web DIFF == ref
    try std.testing.expectEqual(inv.CellState.unknown, m.cellAt(0, 2).state); // off
}
