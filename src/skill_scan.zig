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
