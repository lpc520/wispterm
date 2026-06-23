const std = @import("std");
const agent_history = @import("agent_history.zig");

pub const MAX_INDEX_BYTES = 32 * 1024 * 1024;
const MIGRATION_MAX_BYTES = 1 << 30;

pub const MetaStore = struct {
    allocator: std.mem.Allocator,
    dir: []u8,
    entries: std.ArrayListUnmanaged(agent_history.IndexEntry) = .empty,
    pending: std.ArrayListUnmanaged(agent_history.SessionRecord) = .empty,
    index_dirty: bool = false,

    pub fn open(allocator: std.mem.Allocator, dir_in: []const u8) !MetaStore {
        var self = MetaStore{ .allocator = allocator, .dir = try allocator.dupe(u8, dir_in) };
        errdefer self.deinit();
        try std.fs.cwd().makePath(self.dir);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        try std.fs.cwd().makePath(sessions);
        return self;
    }

    pub fn deinit(self: *MetaStore) void {
        for (self.entries.items) |*e| agent_history.freeOwnedIndexEntry(self.allocator, e);
        self.entries.deinit(self.allocator);
        for (self.pending.items) |*r| agent_history.freeOwnedRecord(self.allocator, r);
        self.pending.deinit(self.allocator);
        self.allocator.free(self.dir);
        self.* = undefined;
    }

    fn sessionsDirPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "sessions" });
    }

    fn indexPath(self: *const MetaStore, allocator: std.mem.Allocator) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.dir, "index.json" });
    }

    fn sessionFilePath(self: *const MetaStore, allocator: std.mem.Allocator, session_id: []const u8) ![]u8 {
        const fname = try agent_history.sanitizeSessionFileName(allocator, session_id);
        defer allocator.free(fname);
        const sessions = try self.sessionsDirPath(allocator);
        defer allocator.free(sessions);
        return std.fs.path.join(allocator, &.{ sessions, fname });
    }

    pub fn buildRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildRowsFromEntries(allocator, self.entries.items);
    }

    pub fn buildCopilotRows(self: *const MetaStore, allocator: std.mem.Allocator) ![]agent_history.Row {
        return agent_history.buildCopilotRowsFromEntries(allocator, self.entries.items);
    }

    fn entryIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.session_id, session_id)) return i;
        }
        return null;
    }

    fn pendingIndex(self: *const MetaStore, session_id: []const u8) ?usize {
        for (self.pending.items, 0..) |r, i| {
            if (std.mem.eql(u8, r.session_id, session_id)) return i;
        }
        return null;
    }
};

test "MetaStore: open empty dir yields no rows" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}
