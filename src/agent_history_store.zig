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

    pub fn upsertRecord(self: *MetaStore, input: anytype) !void {
        var cloned = try agent_history.cloneRecord(self.allocator, input);
        errdefer agent_history.freeOwnedRecord(self.allocator, &cloned);
        var new_entry = try agent_history.recordToIndexEntry(self.allocator, cloned);
        errdefer agent_history.freeOwnedIndexEntry(self.allocator, &new_entry);

        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.pending.ensureUnusedCapacity(self.allocator, 1);

        if (self.entryIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedIndexEntry(self.allocator, &self.entries.items[i]);
            self.entries.items[i] = new_entry;
        } else {
            self.entries.appendAssumeCapacity(new_entry);
        }
        if (self.pendingIndex(cloned.session_id)) |i| {
            agent_history.freeOwnedRecord(self.allocator, &self.pending.items[i]);
            self.pending.items[i] = cloned;
        } else {
            self.pending.appendAssumeCapacity(cloned);
        }
        self.index_dirty = true;
    }

    pub fn cloneRecordBySessionId(
        self: *const MetaStore,
        allocator: std.mem.Allocator,
        session_id: []const u8,
    ) !?agent_history.SessionRecord {
        if (self.pendingIndex(session_id)) |i| {
            return try agent_history.cloneRecord(allocator, self.pending.items[i]);
        }
        const path = try self.sessionFilePath(allocator, session_id);
        defer allocator.free(path);
        const bytes = std.fs.cwd().readFileAlloc(allocator, path, MAX_INDEX_BYTES) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return null,
        };
        defer allocator.free(bytes);
        return try agent_history.recordFromJson(allocator, bytes);
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

test "MetaStore: upsert is visible via rows and clone before flush (pending)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    var store = try MetaStore.open(allocator, root);
    defer store.deinit();
    try store.upsertRecord(.{
        .session_id = "s1", .title = "T", .base_url = "https://api.example.com", .api_key = "k", .model = "m",
        .system_prompt = "sys", .thinking_enabled = false, .reasoning_effort = "low", .stream = true,
        .agent_enabled = true, .created_at = 1, .updated_at = 2,
        .messages = &[_]agent_history.MessageRecord{.{ .role = .user, .content = "hi" }},
    });
    const rows = try store.buildRows(allocator);
    defer agent_history.freeRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("s1", rows[0].session_id);
    var rec = (try store.cloneRecordBySessionId(allocator, "s1")) orelse return error.Missing;
    defer agent_history.freeOwnedRecord(allocator, &rec);
    try std.testing.expectEqualStrings("hi", rec.messages[0].content);
    try std.testing.expect((try store.cloneRecordBySessionId(allocator, "nope")) == null);
}
