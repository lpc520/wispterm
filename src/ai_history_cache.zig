const std = @import("std");
const types = @import("ai_history_types.zig");

pub const FileStamp = struct {
    size: u64,
    mtime_ns: i128,
};

pub const CacheRecord = struct {
    source_id: []const u8,
    provider: types.ProviderId,
    root_path: []const u8,
    source_path: []const u8,
    stamp: FileStamp,
    meta: types.SessionMeta,
};

pub fn stampMatches(record: CacheRecord, stamp: FileStamp) bool {
    return record.stamp.size == stamp.size and record.stamp.mtime_ns == stamp.mtime_ns;
}

test "ai_history_cache: cache stamp matches only exact size and mtime" {
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const record: CacheRecord = .{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    };
    try std.testing.expect(stampMatches(record, .{ .size = 10, .mtime_ns = 20 }));
    try std.testing.expect(!stampMatches(record, .{ .size = 11, .mtime_ns = 20 }));
    try std.testing.expect(!stampMatches(record, .{ .size = 10, .mtime_ns = 21 }));
}
