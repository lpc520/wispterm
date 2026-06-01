const std = @import("std");
const types = @import("ai_history_types.zig");
const source_mod = @import("ai_history_source.zig");
const session_persist = @import("session_persist.zig");

pub const LoadState = enum { idle, scanning, ready, failed };

pub const Session = struct {
    /// Allocator used for row storage. Do not change while rows are live.
    allocator: std.mem.Allocator,
    /// Borrowed when initialized with init; owned when initialized with initOwned.
    source: source_mod.Source,
    source_owned: bool = false,
    state: LoadState = .idle,
    /// Rows shallow-copy SessionMeta values. All string slices inside each row
    /// are borrowed and must outlive these rows until replacement or deinit.
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    selected: usize = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    status: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source: source_mod.Source) Session {
        return .{
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, source: source_mod.Source) !Session {
        return .{
            .allocator = allocator,
            .source = try cloneSource(allocator, source),
            .source_owned = true,
        };
    }

    pub fn deinit(self: *Session) void {
        self.rows.deinit(self.allocator);
        if (self.source_owned) {
            freeOwnedSource(self.allocator, &self.source);
        }
        self.* = undefined;
    }

    pub fn persistSnap(self: *const Session, allocator: std.mem.Allocator) !session_persist.AiHistorySnap {
        const source_id = try allocator.dupe(u8, self.source.id);
        errdefer allocator.free(source_id);

        const target_kind = try allocator.dupe(u8, switch (self.source.target) {
            .local => "local",
            .wsl => "wsl",
            .ssh => "ssh",
        });
        errdefer allocator.free(target_kind);

        const target_name = try allocator.dupe(u8, self.source.name);
        errdefer allocator.free(target_name);

        return .{
            .source_id = source_id,
            .target_kind = target_kind,
            .target_name = target_name,
        };
    }

    pub fn beginScan(self: *Session) void {
        self.state = .scanning;
        self.status = "Scanning";
    }

    /// Replaces rows with shallow copies of `rows`. SessionMeta string slices
    /// remain borrowed; callers must keep them alive until replacement/deinit.
    pub fn replaceRows(self: *Session, rows: []const types.SessionMeta) !void {
        var next: std.ArrayListUnmanaged(types.SessionMeta) = .empty;
        errdefer next.deinit(self.allocator);

        try next.appendSlice(self.allocator, rows);
        std.mem.sort(types.SessionMeta, next.items, {}, types.lessRecent);

        self.rows.deinit(self.allocator);
        self.rows = next;
        self.selected = 0;
        self.state = .ready;
        self.status = "Ready";
    }

    pub fn setFilter(self: *Session, text: []const u8) void {
        self.filter_len = @min(text.len, self.filter.len);
        @memcpy(self.filter[0..self.filter_len], text[0..self.filter_len]);
        self.selected = 0;
    }

    pub fn visibleCount(self: *const Session) usize {
        var count: usize = 0;
        const query = self.filter[0..self.filter_len];
        for (self.rows.items) |row| {
            if (types.metadataMatches(row, query)) count += 1;
        }
        return count;
    }

    /// Returns a shallow SessionMeta copy. Its string slices are borrowed from
    /// the stored rows and follow the same replacement/deinit lifetime.
    pub fn selectedVisible(self: *const Session) ?types.SessionMeta {
        const query = self.filter[0..self.filter_len];
        var visible_index: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, query)) continue;
            if (visible_index == self.selected) return row;
            visible_index += 1;
        }
        return null;
    }
};

fn cloneSource(allocator: std.mem.Allocator, source: source_mod.Source) !source_mod.Source {
    var cloned = source_mod.Source{
        .id = "",
        .name = "",
        .target = .local,
        .providers = source.providers,
        .codex_root_override = null,
        .claude_root_override = null,
        .extra_roots = &.{},
    };
    errdefer freeOwnedSource(allocator, &cloned);

    cloned.id = try cloneSlice(allocator, source.id);
    cloned.name = try cloneSlice(allocator, source.name);
    cloned.target = switch (source.target) {
        .local => .local,
        .wsl => |target| .{ .wsl = .{ .distro = try cloneSlice(allocator, target.distro) } },
        .ssh => |target| .{ .ssh = .{ .profile_name = try cloneSlice(allocator, target.profile_name) } },
    };
    cloned.codex_root_override = try cloneOptionalSlice(allocator, source.codex_root_override);
    cloned.claude_root_override = try cloneOptionalSlice(allocator, source.claude_root_override);
    cloned.extra_roots = try cloneProviderRoots(allocator, source.extra_roots);

    return cloned;
}

fn cloneSlice(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0) return "";
    return try allocator.dupe(u8, value);
}

fn cloneOptionalSlice(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try cloneSlice(allocator, slice) else null;
}

fn cloneProviderRoots(allocator: std.mem.Allocator, roots: []const source_mod.ProviderRoot) ![]const source_mod.ProviderRoot {
    if (roots.len == 0) return &.{};

    const cloned_roots = try allocator.alloc(source_mod.ProviderRoot, roots.len);
    errdefer allocator.free(cloned_roots);

    var initialized: usize = 0;
    errdefer {
        for (cloned_roots[0..initialized]) |root| {
            freeSlice(allocator, root.path);
        }
    }

    for (roots, 0..) |root, idx| {
        cloned_roots[idx] = .{
            .provider = root.provider,
            .path = try cloneSlice(allocator, root.path),
        };
        initialized += 1;
    }

    return cloned_roots;
}

fn freeOwnedSource(allocator: std.mem.Allocator, source: *source_mod.Source) void {
    freeSlice(allocator, source.id);
    freeSlice(allocator, source.name);
    switch (source.target) {
        .local => {},
        .wsl => |target| freeSlice(allocator, target.distro),
        .ssh => |target| freeSlice(allocator, target.profile_name),
    }
    if (source.codex_root_override) |value| freeSlice(allocator, value);
    if (source.claude_root_override) |value| freeSlice(allocator, value);
    for (source.extra_roots) |root| {
        freeSlice(allocator, root.path);
    }
    if (source.extra_roots.len > 0) allocator.free(source.extra_roots);
}

fn freeSlice(allocator: std.mem.Allocator, value: []const u8) void {
    if (value.len > 0) allocator.free(value);
}

test "ai_history_session: replacing rows sorts by last active time" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "old",
            .title = "Old",
            .source_path = "old.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
        .{
            .provider = .codex,
            .session_id = "new",
            .title = "New",
            .source_path = "new.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try session.replaceRows(&rows);

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id);
}

test "ai_history_session: persistSnap duplicates source identity" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local-codex", .name = "Local", .target = .local });
    defer session.deinit();

    const snap = try session.persistSnap(allocator);
    defer {
        allocator.free(snap.source_id);
        allocator.free(snap.target_kind);
        allocator.free(snap.target_name);
    }

    try std.testing.expectEqualStrings("local-codex", snap.source_id);
    try std.testing.expectEqualStrings("local", snap.target_kind);
    try std.testing.expectEqualStrings("Local", snap.target_name);
    try std.testing.expect(snap.source_id.ptr != session.source.id.ptr);
    try std.testing.expect(snap.target_name.ptr != session.source.name.ptr);
}

test "ai_history_session: initOwned clones source identity and ssh roots" {
    const allocator = std.testing.allocator;
    var id_buf = [_]u8{ 's', 's', 'h', '-', 'h', 'i', 's', 't', 'o', 'r', 'y' };
    var name_buf = [_]u8{ 'B', 'u', 'i', 'l', 'd', ' ', 'B', 'o', 'x' };
    var profile_buf = [_]u8{ 'b', 'u', 'i', 'l', 'd', 'b', 'o', 'x' };
    var codex_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'c', 'o', 'd', 'e', 'x' };
    var claude_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'c', 'l', 'a', 'u', 'd', 'e' };
    var extra_path_buf = [_]u8{ '/', 't', 'm', 'p', '/', 'e', 'x', 't', 'r', 'a' };
    const extra_roots = [_]source_mod.ProviderRoot{
        .{ .provider = .codex, .path = extra_path_buf[0..] },
    };

    var session = try Session.initOwned(allocator, .{
        .id = id_buf[0..],
        .name = name_buf[0..],
        .target = .{ .ssh = .{ .profile_name = profile_buf[0..] } },
        .codex_root_override = codex_buf[0..],
        .claude_root_override = claude_buf[0..],
        .extra_roots = extra_roots[0..],
    });
    defer session.deinit();

    @memset(&id_buf, 'x');
    @memset(&name_buf, 'x');
    @memset(&profile_buf, 'x');
    @memset(&codex_buf, 'x');
    @memset(&claude_buf, 'x');
    @memset(&extra_path_buf, 'x');

    try std.testing.expectEqualStrings("ssh-history", session.source.id);
    try std.testing.expectEqualStrings("Build Box", session.source.name);
    try std.testing.expectEqualStrings("buildbox", session.source.target.ssh.profile_name);
    try std.testing.expectEqualStrings("/tmp/codex", session.source.codex_root_override.?);
    try std.testing.expectEqualStrings("/tmp/claude", session.source.claude_root_override.?);
    try std.testing.expectEqual(@as(usize, 1), session.source.extra_roots.len);
    try std.testing.expectEqualStrings("/tmp/extra", session.source.extra_roots[0].path);
    try std.testing.expect(session.source.id.ptr != id_buf[0..].ptr);
    try std.testing.expect(session.source.name.ptr != name_buf[0..].ptr);
    try std.testing.expect(session.source.target.ssh.profile_name.ptr != profile_buf[0..].ptr);
    try std.testing.expect(session.source.extra_roots.ptr != extra_roots[0..].ptr);
    try std.testing.expect(session.source.extra_roots[0].path.ptr != extra_path_buf[0..].ptr);
}

test "ai_history_session: initOwned clones wsl distro" {
    const allocator = std.testing.allocator;
    var distro_buf = [_]u8{ 'U', 'b', 'u', 'n', 't', 'u' };

    var session = try Session.initOwned(allocator, .{
        .id = "wsl",
        .name = "WSL",
        .target = .{ .wsl = .{ .distro = distro_buf[0..] } },
    });
    defer session.deinit();

    @memset(&distro_buf, 'x');

    try std.testing.expectEqualStrings("Ubuntu", session.source.target.wsl.distro);
    try std.testing.expect(session.source.target.wsl.distro.ptr != distro_buf[0..].ptr);
}

test "ai_history_session: persistSnap frees partial duplicates on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var session = Session.init(failing_allocator.allocator(), .{ .id = "local-codex", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectError(error.OutOfMemory, session.persistSnap(failing_allocator.allocator()));
    try std.testing.expect(failing_allocator.has_induced_failure);
}

test "ai_history_session: metadata filter controls visible rows" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
        .{
            .provider = .claude,
            .session_id = "b",
            .title = "Docs",
            .project_dir = "/repo/docs",
            .source_path = "b.jsonl",
            .resume_kind = .claude_resume,
        },
    };

    try session.replaceRows(&rows);
    session.setFilter("docs");

    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    const selected = session.selectedVisible() orelse return error.ExpectedSelectedSession;
    try std.testing.expectEqualStrings("b", selected.session_id);
}

test "ai_history_session: replace rows preserves existing state on allocation failure" {
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 1,
    });
    var session = Session.init(failing_allocator.allocator(), .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    const existing = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "kept",
            .title = "Kept",
            .source_path = "kept.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 10,
        },
    };
    try session.replaceRows(&existing);
    session.status = "Existing";

    const replacement = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "new-a",
            .title = "New A",
            .source_path = "new-a.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 30,
        },
        .{
            .provider = .codex,
            .session_id = "new-b",
            .title = "New B",
            .source_path = "new-b.jsonl",
            .resume_kind = .codex_resume,
            .last_active_at_ms = 20,
        },
    };

    try std.testing.expectError(error.OutOfMemory, session.replaceRows(&replacement));

    try std.testing.expect(failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), session.rows.items.len);
    try std.testing.expectEqualStrings("kept", session.rows.items[0].session_id);
    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("Existing", session.status);
}

test "ai_history_session: selected visible returns null when selection is unavailable" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try std.testing.expectEqual(null, session.selectedVisible());

    const rows = [_]types.SessionMeta{
        .{
            .provider = .codex,
            .session_id = "a",
            .title = "Renderer",
            .source_path = "a.jsonl",
            .resume_kind = .codex_resume,
        },
    };
    try session.replaceRows(&rows);

    session.setFilter("missing");
    try std.testing.expectEqual(@as(usize, 0), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());

    session.setFilter("");
    session.selected = 1;
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    try std.testing.expectEqual(null, session.selectedVisible());
}

test "ai_history_session: filter truncates to fixed buffer length" {
    var session = Session.init(std.testing.allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    var long_filter: [130]u8 = undefined;
    @memset(&long_filter, 'x');
    long_filter[128] = 'y';
    long_filter[129] = 'z';

    session.setFilter(&long_filter);

    try std.testing.expectEqual(@as(usize, 128), session.filter_len);
    try std.testing.expectEqualSlices(u8, long_filter[0..128], session.filter[0..session.filter_len]);
}
