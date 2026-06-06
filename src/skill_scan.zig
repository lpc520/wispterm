const std = @import("std");

pub const Provider = enum {
    claude,
    codex,

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex => "codex",
        };
    }

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "claude")) return .claude;
        if (std.mem.eql(u8, s, "codex")) return .codex;
        return null;
    }
};

pub const Format = enum { skill_md, prompt_md };

/// A directory on each server to scan. `root_rel` is relative to `$HOME`.
pub const ScanTarget = struct {
    provider: Provider,
    root_rel: []const u8,
    format: Format,
};

/// v1 default scan targets. Roots that don't exist on a server are skipped.
pub fn defaultTargets() []const ScanTarget {
    return &[_]ScanTarget{
        .{ .provider = .claude, .root_rel = ".claude/skills", .format = .skill_md },
        .{ .provider = .codex, .root_rel = ".codex/skills", .format = .skill_md },
        .{ .provider = .codex, .root_rel = ".codex/prompts", .format = .prompt_md },
    };
}

/// One skill discovered on one server. `agg_hash == null` means the server
/// could not hash (no sha256sum/shasum) — presence is known, version is not.
pub const SkillRow = struct {
    provider: Provider,
    name: []u8,
    rel_path: []u8,
    agg_hash: ?[]u8,

    pub fn deinit(self: *SkillRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.rel_path);
        if (self.agg_hash) |h| allocator.free(h);
        self.* = undefined;
    }
};

pub fn freeRows(allocator: std.mem.Allocator, rows: []SkillRow) void {
    for (rows) |*r| r.deinit(allocator);
    allocator.free(rows);
}

/// Parse the tab-separated scan output into owned rows. Each valid line is
/// `provider\tname\trel_path\thash`. Lines that are blank, have fewer than 4
/// fields, have an empty name, or an unknown provider are skipped. An empty
/// hash field yields `agg_hash = null`.
pub fn parseScanOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]SkillRow {
    var rows: std.ArrayListUnmanaged(SkillRow) = .empty;
    errdefer {
        for (rows.items) |*r| r.deinit(allocator);
        rows.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const prov_str = fields.next() orelse continue;
        const name = fields.next() orelse continue;
        const rel_path = fields.next() orelse continue;
        const hash = fields.next() orelse continue;

        const provider = Provider.fromString(prov_str) orelse continue;
        if (name.len == 0 or rel_path.len == 0) continue;

        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);
        const rel_copy = try allocator.dupe(u8, rel_path);
        errdefer allocator.free(rel_copy);
        const hash_copy: ?[]u8 = if (hash.len == 0) null else try allocator.dupe(u8, hash);
        errdefer if (hash_copy) |h| allocator.free(h);

        try rows.append(allocator, .{
            .provider = provider,
            .name = name_copy,
            .rel_path = rel_copy,
            .agg_hash = hash_copy,
        });
    }

    return rows.toOwnedSlice(allocator);
}

test "skill_scan: parseScanOutput parses good rows and skips garbage" {
    const allocator = std.testing.allocator;
    const out =
        "claude\tpdf-tools\t.claude/skills/pdf-tools/SKILL.md\tabc123\n" ++
        "codex\tfoo\t.codex/prompts/foo.md\t\n" ++ // empty hash -> null
        "\n" ++ // blank line skipped
        "garbage-without-tabs\n" ++ // skipped
        "bogusprov\tx\t.x/x\thash\n"; // unknown provider skipped

    const rows = try parseScanOutput(allocator, out);
    defer freeRows(allocator, rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(Provider.claude, rows[0].provider);
    try std.testing.expectEqualStrings("pdf-tools", rows[0].name);
    try std.testing.expectEqualStrings(".claude/skills/pdf-tools/SKILL.md", rows[0].rel_path);
    try std.testing.expectEqualStrings("abc123", rows[0].agg_hash.?);
    try std.testing.expectEqual(Provider.codex, rows[1].provider);
    try std.testing.expectEqualStrings("foo", rows[1].name);
    try std.testing.expectEqual(@as(?[]u8, null), rows[1].agg_hash);
}
