//! Shared types for the memory digest pipeline. Spec:
//! docs/superpowers/specs/2026-07-07-ai-memory-digest-design.md
const std = @import("std");
const ai_types = @import("../terminal_agents/sessions/types.zig");

pub const SCHEMA_VERSION: u32 = 1;

/// Providers the digest scans. Superset of the AI-history browser's
/// ProviderId: adds WispTerm's own copilot history.
pub const DigestProvider = enum {
    wispterm,
    claude,
    codex,
    reasonix,
};

/// One session carrying only the messages that are new since the last run.
/// All slices are owned by the collector's arena.
pub const CollectedSession = struct {
    provider: DigestProvider,
    source_id: []const u8, // "local" | "wsl:<distro>" | "ssh:<profile>"
    session_id: []const u8,
    title: []const u8,
    /// cwd of the session; "" = unknown → UNASSIGNED_SLUG.
    project_path: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    total_messages: u32,
    new_messages: []ai_types.TranscriptMessage,
    source_file: []const u8,
};

pub const UNASSIGNED_SLUG = "unassigned";

/// Derive a project slug from a cwd path: last path component, lowercased,
/// [a-z0-9._-] kept, everything else mapped to '-'. Empty → "unassigned".
/// ponytail: two different paths with the same dirname share a slug; hash
/// suffix disambiguation lands with project.json in M2 (spec §10).
pub fn projectSlug(path: []const u8, buf: []u8) []const u8 {
    const trimmed = std.mem.trimRight(u8, path, "/\\");
    if (trimmed.len == 0) return UNASSIGNED_SLUG;
    const base = if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |i|
        trimmed[i + 1 ..]
    else
        trimmed;
    if (base.len == 0) return UNASSIGNED_SLUG;
    const n = @min(base.len, buf.len);
    for (base[0..n], 0..) |c, i| {
        const lower = std.ascii.toLower(c);
        buf[i] = if (std.ascii.isAlphanumeric(lower) or lower == '.' or lower == '_' or lower == '-')
            lower
        else
            '-';
    }
    return buf[0..n];
}

test "memory_digest_types: slug takes last component lowercased" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("phantty", projectSlug("/Users/me/Documents/Code/Phantty", &buf));
}

test "memory_digest_types: slug handles windows paths and trailing separators" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("proj", projectSlug("C:\\code\\Proj\\", &buf));
    try std.testing.expectEqualStrings("proj", projectSlug("/home/me/proj///", &buf));
}

test "memory_digest_types: slug maps unsafe chars and empty to unassigned" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my-dir-1-", projectSlug("/tmp/My Dir(1)", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("", &buf));
    try std.testing.expectEqualStrings("unassigned", projectSlug("///", &buf));
}
