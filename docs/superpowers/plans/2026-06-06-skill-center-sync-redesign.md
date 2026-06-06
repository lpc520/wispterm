# Skill Center Redesign (local hub + push/pull) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the read-only N-server skill matrix with a two-pane local-hub panel — local on the left, one selected server on the right, rows aligned by `(provider, name)` — and add upload / download (tar-over-ssh) with an overwrite confirm and a SKILL.md diff.

**Architecture:** Reuse the existing scan / cache / threading / source-enumeration foundation untouched. Replace the modal `Matrix` (`skill_inventory.buildMatrix`) with a pairwise `skill_pairing` module (local vs the one selected server). Rewrite `skill_center_renderer` as a two-column aligned list. Add a transfer layer (`skill_transfer_cmd` pure + `skill_transfer` impure) built only on existing primitives (`remote_file.localPosixExec`, `scp.transfer`, `remote_file.sshExecCapture`). Add a pure `skill_diff` for the compare view. Demote hash to an internal drift flag.

**Tech Stack:** Zig (std only in pure modules), the project's pure/impure split, POSIX `tar` + OpenSSH `scp`/`ssh`. Spec: `docs/superpowers/specs/2026-06-06-skill-center-sync-redesign-design.md`.

---

## Conventions for every task

- **Inner-loop test command for a pure module:** `zig test src/<file>.zig` (these import only `std` + other pure leaves, so they link standalone and run in <1s).
- **Aggregated gate before each commit:** `zig build test` (runs `src/test_fast.zig`, which already lists every skill module). New pure modules MUST be registered there (Task 1 / 6 / 11 do this).
- **macOS link-gap fallback:** if `zig build test` fails to *link* on macOS (known pre-existing gap), still run the touched module directly with `zig test src/<file>.zig`; that is the authoritative per-module result.
- **Integration build sanity (Phase 2/3 tasks that touch `AppWindow.zig`/`input.zig`):** also run `zig build -Dtarget=aarch64-macos macos-app` once at the end of the task to confirm the GUI graph still compiles.
- Commit after every task. Branch is already `worktree-feat-skill-center`.

---

# Phase 1 — Pairing model + two-column view

Delivers the legibility fix on its own: real server names, two columns, no `?` noise, instant server switching. No transfer yet.

## Task 1: `skill_pairing.zig` — pairwise comparison (pure)

**Files:**
- Create: `src/skill_pairing.zig`
- Modify: `src/test_fast.zig` (register the module)

- [ ] **Step 1: Write the failing test file**

Create `src/skill_pairing.zig` with the full module below. It defines `Relation`, `PairRow`, `pair()`, and tests.

```zig
const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");

pub const Provider = scan.Provider;
pub const ServerScan = inv.ServerScan;

/// Relation of a single skill between the local hub and one selected server.
pub const Relation = enum {
    same, // present both sides, agg_hash equal
    differ, // present both sides, both hashable, agg_hash differ
    local_only, // present locally, server reachable and absent there
    remote_only, // absent locally, present on the server
    unknown, // present but a side has null hash, or the server is unreachable
};

/// One aligned row. All slices borrow from the input ServerScans — `pair()`
/// returns an owned *slice* but owns none of the strings; free with
/// `allocator.free(rows)` only (no per-element deinit).
pub const PairRow = struct {
    provider: Provider,
    name: []const u8,
    local_rel_path: ?[]const u8,
    remote_rel_path: ?[]const u8,
    relation: Relation,
};

fn lessThan(_: void, a: PairRow, b: PairRow) bool {
    if (a.provider != b.provider) return @intFromEnum(a.provider) < @intFromEnum(b.provider);
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn findRow(s: ServerScan, provider: Provider, name: []const u8) ?scan.SkillRow {
    for (s.rows) |r| {
        if (r.provider == provider and std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

fn alreadySeen(rows: []const PairRow, provider: Provider, name: []const u8) bool {
    for (rows) |p| {
        if (p.provider == provider and std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

/// Align `local` against `remote` into a sorted, deduped list of PairRow.
/// `remote_reachable` false (server offline) makes every row that exists
/// locally `unknown` on the remote side — "we couldn't check", never a false
/// `local_only`. Caller frees the returned slice with `allocator.free`.
pub fn pair(
    allocator: std.mem.Allocator,
    local: ServerScan,
    remote: ServerScan,
    remote_reachable: bool,
) ![]PairRow {
    var out: std.ArrayListUnmanaged(PairRow) = .empty;
    errdefer out.deinit(allocator);

    // Local skills first (the hub is the primary axis).
    for (local.rows) |lr| {
        if (alreadySeen(out.items, lr.provider, lr.name)) continue;
        const rr: ?scan.SkillRow = if (remote_reachable) findRow(remote, lr.provider, lr.name) else null;
        const relation: Relation = blk: {
            if (!remote_reachable) break :blk .unknown;
            const remote_row = rr orelse break :blk .local_only;
            const lh = lr.agg_hash orelse break :blk .unknown;
            const rh = remote_row.agg_hash orelse break :blk .unknown;
            break :blk if (std.mem.eql(u8, lh, rh)) .same else .differ;
        };
        try out.append(allocator, .{
            .provider = lr.provider,
            .name = lr.name,
            .local_rel_path = lr.rel_path,
            .remote_rel_path = if (rr) |r| r.rel_path else null,
            .relation = relation,
        });
    }

    // Remote-only skills (present on the server, absent locally).
    if (remote_reachable) {
        for (remote.rows) |rr| {
            if (alreadySeen(out.items, rr.provider, rr.name)) continue;
            if (findRow(local, rr.provider, rr.name) != null) continue;
            try out.append(allocator, .{
                .provider = rr.provider,
                .name = rr.name,
                .local_rel_path = null,
                .remote_rel_path = rr.rel_path,
                .relation = .remote_only,
            });
        }
    }

    const rows = try out.toOwnedSlice(allocator);
    std.sort.insertion(PairRow, rows, {}, lessThan);
    return rows;
}

// --- Tests ---

fn row(provider: Provider, name: []const u8, hash: ?[]const u8) scan.SkillRow {
    return .{
        .provider = provider,
        .name = @constCast(name),
        .rel_path = @constCast("x"),
        .agg_hash = if (hash) |h| @constCast(h) else null,
    };
}

test "skill_pairing: relations across both sides" {
    const allocator = std.testing.allocator;
    const local_rows = [_]scan.SkillRow{
        row(.claude, "same1", "h"),
        row(.claude, "diff1", "L"),
        row(.claude, "localonly", "h"),
        row(.claude, "noremotehash", "h"),
    };
    const remote_rows = [_]scan.SkillRow{
        row(.claude, "same1", "h"), // same
        row(.claude, "diff1", "R"), // differ
        row(.claude, "remoteonly", "h"), // remote_only
        row(.claude, "noremotehash", null), // unknown (remote null hash)
    };
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &local_rows };
    const remote: ServerScan = .{ .source_id = "ssh:web", .reachable = true, .rows = &remote_rows };

    const rows = try pair(allocator, local, remote, true);
    defer allocator.free(rows);

    // Sorted by name within provider: diff1, localonly, noremotehash, remoteonly, same1
    try std.testing.expectEqual(@as(usize, 5), rows.len);
    try std.testing.expectEqualStrings("diff1", rows[0].name);
    try std.testing.expectEqual(Relation.differ, rows[0].relation);
    try std.testing.expectEqual(Relation.local_only, rows[1].relation); // localonly
    try std.testing.expectEqual(Relation.unknown, rows[2].relation); // noremotehash
    try std.testing.expectEqual(Relation.remote_only, rows[3].relation); // remoteonly
    try std.testing.expectEqual(Relation.same, rows[4].relation); // same1
}

test "skill_pairing: unreachable remote makes every local row unknown" {
    const allocator = std.testing.allocator;
    const local_rows = [_]scan.SkillRow{ row(.claude, "a", "h"), row(.codex, "b", "h") };
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &local_rows };
    const remote: ServerScan = .{ .source_id = "ssh:off", .reachable = false, .rows = &.{} };

    const rows = try pair(allocator, local, remote, false);
    defer allocator.free(rows);

    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |r| try std.testing.expectEqual(Relation.unknown, r.relation);
}

test "skill_pairing: empty local with reachable remote yields remote_only" {
    const allocator = std.testing.allocator;
    const remote_rows = [_]scan.SkillRow{row(.claude, "x", "h")};
    const local: ServerScan = .{ .source_id = "local", .reachable = true, .rows = &.{} };
    const remote: ServerScan = .{ .source_id = "ssh:web", .reachable = true, .rows = &remote_rows };

    const rows = try pair(allocator, local, remote, true);
    defer allocator.free(rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(Relation.remote_only, rows[0].relation);
}
```

- [ ] **Step 2: Run the tests to verify they pass standalone**

Run: `zig test src/skill_pairing.zig`
Expected: PASS (3 tests).

- [ ] **Step 3: Register the module in the fast-test aggregator**

Modify `src/test_fast.zig` — add after the line `_ = @import("renderer/skill_center_renderer.zig");` (currently line 71):

```zig
    _ = @import("skill_pairing.zig");
```

- [ ] **Step 4: Run the aggregated gate**

Run: `zig build test`
Expected: PASS (includes the new pairing tests).

- [ ] **Step 5: Commit**

```bash
git add src/skill_pairing.zig src/test_fast.zig
git commit -m "feat(skill-center): pairwise local-vs-server pairing module"
```

---

## Task 2: PanelModel — add pairing + selected server (keep matrix temporarily)

`PanelModel` keeps building the matrix (so the old renderer still compiles) AND now also builds a pairing for the selected server. Selection becomes row-only; `sel_server` indexes the remote servers.

**Files:**
- Modify: `src/skill_center.zig` (`PanelModel`)
- Test: `src/skill_center.zig` (add tests at the bottom)

- [ ] **Step 1: Write the failing test**

Add at the end of `src/skill_center.zig` (before the final closing of the file's test block region; place after the existing `test "skill_center: Session.finishScan discards..."`):

```zig
test "skill_center: model builds pairing for the selected server" {
    const allocator = std.testing.allocator;
    var model = PanelModel.init(allocator);
    defer model.deinit();

    const local_rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const web_rows = [_]scan.SkillRow{
        .{ .provider = .claude, .name = @constCast("a"), .rel_path = @constCast(".claude/skills/a/SKILL.md"), .agg_hash = @constCast("DIFF") },
        .{ .provider = .claude, .name = @constCast("b"), .rel_path = @constCast(".claude/skills/b/SKILL.md"), .agg_hash = @constCast("h") },
    };
    const s = try allocator.alloc(inv.ServerScan, 2);
    s[0] = .{ .source_id = try allocator.dupe(u8, "local"), .reachable = true, .rows = try dupRows(allocator, &local_rows) };
    s[1] = .{ .source_id = try allocator.dupe(u8, "ssh:web"), .reachable = true, .rows = try dupRows(allocator, &web_rows) };
    model.setServers(s);

    try std.testing.expect(model.pairing != null);
    // local 'a' differs from web 'a'; web 'b' is remote_only -> 2 rows.
    try std.testing.expectEqual(@as(usize, 2), model.pairing.?.len);
    try std.testing.expectEqual(@as(usize, 0), model.sel_server); // first (only) remote
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/skill_center.zig`
Expected: FAIL — `model.pairing` / `model.sel_server` don't exist.

- [ ] **Step 3: Add the fields + rebuild logic**

In `src/skill_center.zig`, add the import near the top (after `const inv = @import("skill_inventory.zig");`):

```zig
const pairing = @import("skill_pairing.zig");
```

Replace the `PanelModel` struct field block (currently `servers`, `matrix`, `sel_row`, `sel_col`, `scroll`, `stale`) with:

```zig
    allocator: std.mem.Allocator,
    servers: ?[]inv.ServerScan = null,
    matrix: ?inv.Matrix = null,
    /// Aligned local-vs-selected-server view (rows borrow from `servers`).
    pairing: ?[]pairing.PairRow = null,
    /// Index into the remote servers (everything except source_id == "local").
    sel_server: usize = 0,
    sel_row: usize = 0,
    sel_col: usize = 0,
    scroll: usize = 0,
    stale: bool = false,
```

Add these methods to `PanelModel` (place after `setServers`):

```zig
    /// Index in `servers` of the local hub ("local"); null if none present.
    fn localIndex(self: *const PanelModel) ?usize {
        const servers = self.servers orelse return null;
        for (servers, 0..) |s, i| {
            if (std.mem.eql(u8, s.source_id, "local")) return i;
        }
        return null;
    }

    /// Count of selectable remote servers (all non-local columns).
    pub fn remoteCount(self: *const PanelModel) usize {
        const servers = self.servers orelse return 0;
        const li = self.localIndex();
        var n: usize = 0;
        for (servers, 0..) |_, i| {
            if (li != null and i == li.?) continue;
            n += 1;
        }
        return n;
    }

    /// Resolve `sel_server` (an index over remote servers) to an index in
    /// `servers`; null when there are no remote servers.
    pub fn selectedServerIndex(self: *const PanelModel) ?usize {
        const servers = self.servers orelse return null;
        const li = self.localIndex();
        var n: usize = 0;
        for (servers, 0..) |_, i| {
            if (li != null and i == li.?) continue;
            if (n == self.sel_server) return i;
            n += 1;
        }
        return null;
    }

    /// Rebuild `pairing` from the local hub vs the selected server. Frees any
    /// prior pairing slice (rows borrow from `servers`, so only the slice).
    pub fn rebuildPairing(self: *PanelModel) void {
        if (self.pairing) |p| {
            self.allocator.free(p);
            self.pairing = null;
        }
        const servers = self.servers orelse return;
        const local: inv.ServerScan = if (self.localIndex()) |li|
            servers[li]
        else
            .{ .source_id = "local", .reachable = false, .rows = &.{} };
        const remote_idx = self.selectedServerIndex() orelse {
            // No remote: pairing is just local skills, all local_only-ish shown
            // as unknown (no server to compare against).
            self.pairing = pairing.pair(self.allocator, local, .{ .source_id = "", .reachable = false, .rows = &.{} }, false) catch null;
            self.clampSelection();
            return;
        };
        const remote = servers[remote_idx];
        self.pairing = pairing.pair(self.allocator, local, remote, remote.reachable) catch null;
        self.clampSelection();
    }
```

In `setServers`, after `self.matrix = inv.buildMatrix(...) catch null;` add:

```zig
        self.rebuildPairing();
```

Update `clampSelection` to also clamp against the pairing length and `sel_server`:

```zig
    fn clampSelection(self: *PanelModel) void {
        const rows = if (self.pairing) |p| p.len else 0;
        if (rows == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= rows) {
            self.sel_row = rows - 1;
        }
        const rc = self.remoteCount();
        if (rc == 0) {
            self.sel_server = 0;
        } else if (self.sel_server >= rc) {
            self.sel_server = rc - 1;
        }
    }
```

Update `freeServers` to also free the pairing slice (rows are borrowed, so free only the slice) — add at the top of `freeServers`:

```zig
        if (self.pairing) |p| {
            self.allocator.free(p);
            self.pairing = null;
        }
```

Update `deinit` is unchanged (it calls `freeServers`). The matrix `deinit` stays.

- [ ] **Step 4: Run tests to verify pass**

Run: `zig test src/skill_center.zig`
Expected: PASS (new pairing test + all existing model tests).

- [ ] **Step 5: Aggregated gate + commit**

Run: `zig build test` → PASS

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): PanelModel builds pairing + selected-server state"
```

---

## Task 3: Rewrite the renderer as a two-column aligned list

Rewrite `skill_center_renderer.zig` to render `pairing` in two fixed columns (local + selected server name). Update its sole caller `AppWindow.renderSkillCenterFrame` in the same task so the build stays green.

**Files:**
- Modify: `src/renderer/skill_center_renderer.zig` (View + render + glyph/legend)
- Modify: `src/AppWindow.zig:833-840` (View construction)
- Test: `src/renderer/skill_center_renderer.zig` (glyph + capacity tests)

- [ ] **Step 1: Write the failing test**

Replace the existing `test "skill_center_renderer: glyphForState maps cell states"` with relation-based glyph tests, and add a column-glyph test:

```zig
test "skill_center_renderer: relation glyphs" {
    try std.testing.expectEqualStrings("✓", localGlyph(.same));
    try std.testing.expectEqualStrings("✓", localGlyph(.local_only));
    try std.testing.expectEqualStrings("—", localGlyph(.remote_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.same));
    try std.testing.expectEqualStrings("≠", remoteGlyph(.differ));
    try std.testing.expectEqualStrings("—", remoteGlyph(.local_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.remote_only));
    try std.testing.expectEqualStrings("?", remoteGlyph(.unknown));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/renderer/skill_center_renderer.zig`
Expected: FAIL — `localGlyph` / `remoteGlyph` undefined.

- [ ] **Step 3: Rewrite the renderer**

Replace the whole body of `src/renderer/skill_center_renderer.zig` with:

```zig
const std = @import("std");
const pairing = @import("../skill_pairing.zig");
const ai_history_renderer = @import("ai_history_renderer.zig");

pub const DrawContext = ai_history_renderer.DrawContext;

const HEADER_H: f32 = 54;
const COLHEAD_H: f32 = 40;
const ROW_H: f32 = 30;
const PAD_X: f32 = 16;
const LEGEND_H: f32 = 36;
/// Left band: provider tag + skill name. Two status columns follow it.
const NAME_W: f32 = 320;
const COL_W: f32 = 120;
const SMALL_GAP: f32 = 6;

pub const View = struct {
    rows: []const pairing.PairRow,
    local_name: []const u8,
    server_name: []const u8, // selected server display name, or "" if none
    server_reachable: bool,
    sel_row: usize,
    scroll: usize,
    stale: bool,
    status: []const u8,
};

fn localGlyph(rel: pairing.Relation) []const u8 {
    return switch (rel) {
        .same, .differ, .local_only, .unknown => "✓",
        .remote_only => "—",
    };
}

fn remoteGlyph(rel: pairing.Relation) []const u8 {
    return switch (rel) {
        .same, .remote_only => "✓",
        .differ => "≠",
        .local_only => "—",
        .unknown => "?",
    };
}

fn hintFor(rel: pairing.Relation) []const u8 {
    return switch (rel) {
        .same => "已一致",
        .differ => "不同 → 对比/覆盖",
        .local_only => "仅本地 → 可上传",
        .remote_only => "仅远程 → 可下载",
        .unknown => "无法校验",
    };
}

fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}
fn colHeaderHeight(cell_h: f32) f32 {
    return @max(COLHEAD_H, cell_h + 14);
}
fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h + 12);
}
fn legendHeight(cell_h: f32) f32 {
    return @max(LEGEND_H, cell_h + 18);
}

pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const header_h = headerHeight(cell_h) + colHeaderHeight(cell_h);
    const usable = content_h - header_h - legendHeight(cell_h);
    if (usable <= 0) return 0;
    return @intFromFloat(@max(0.0, @floor(usable / rowHeight(cell_h))));
}

fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}
fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const c = @max(0.0, @min(1.0, t));
    return .{ a[0] + (b[0] - a[0]) * c, a[1] + (b[1] - a[1]) * c, a[2] + (b[2] - a[2]) * c };
}

fn colorForRelation(rel: pairing.Relation, fg: [3]f32, muted: [3]f32) [3]f32 {
    return switch (rel) {
        .same => .{ 0.36, 0.74, 0.42 },
        .differ => .{ 0.86, 0.70, 0.28 },
        .local_only => fg,
        .remote_only => .{ 0.42, 0.62, 0.88 },
        .unknown => muted,
    };
}

pub fn render(
    draw: DrawContext,
    view: View,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
) void {
    _ = window_width;
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    draw.fillQuad(content_x, 0, content_w, content_h, bg);

    // --- Header: title + "本地 ⇆ <server>" + counts + status. ---
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(content_x, yFromTop(window_height, top, header_h), content_w, header_h, panel_strong, 0.9);
    draw.fillQuad(content_x, yFromTop(window_height, top + header_h, 1), content_w, 1, line);

    const title_y = yTextFromTop(draw, window_height, top + 11);
    const title_end = draw.renderTextLimited("Skill Center", content_x + PAD_X, title_y, fg, content_w - PAD_X * 2);

    var sub_buf: [160]u8 = undefined;
    const sub = if (view.server_name.len == 0)
        std.fmt.bufPrint(&sub_buf, "本地（无服务器）", .{}) catch ""
    else if (view.stale)
        std.fmt.bufPrint(&sub_buf, "本地 ⇆ {s}（缓存）", .{view.server_name}) catch ""
    else
        std.fmt.bufPrint(&sub_buf, "本地 ⇆ {s}", .{view.server_name}) catch "";
    const sub_x = title_end + 16;
    _ = draw.renderTextLimited(sub, sub_x, title_y, muted, @max(0, content_x + content_w - PAD_X - sub_x));

    if (view.status.len > 0) {
        const status_w: f32 = 220;
        const status_x = content_x + content_w - PAD_X - status_w;
        if (status_x > sub_x) _ = draw.renderTextLimited(view.status, status_x, title_y, accent, status_w);
    }

    // --- Column header row: 本地 | <server>. ---
    const colhead_h = colHeaderHeight(draw.cell_h);
    const colhead_top = top + header_h;
    draw.fillQuadAlpha(content_x, yFromTop(window_height, colhead_top, colhead_h), content_w, colhead_h, mixColor(bg, fg, 0.04), 0.95);
    draw.fillQuad(content_x, yFromTop(window_height, colhead_top + colhead_h, 1), content_w, 1, line);

    const col0_x = content_x + PAD_X + NAME_W;
    const col1_x = col0_x + COL_W;
    const colhead_text_y = yTextFromTop(draw, window_height, colhead_top + (colhead_h - draw.cell_h) / 2);
    _ = draw.renderTextLimited("本地", col0_x, colhead_text_y, fg, COL_W - SMALL_GAP);
    const server_col_color = if (view.server_reachable) fg else muted;
    const server_label = if (view.server_name.len == 0) "—" else view.server_name;
    _ = draw.renderTextLimited(server_label, col1_x, colhead_text_y, server_col_color, COL_W - SMALL_GAP);

    // --- Empty state. ---
    if (view.rows.len == 0) {
        _ = draw.renderTextLimited(
            "No skills found. Scanning…",
            content_x + PAD_X,
            yTextFromTop(draw, window_height, colhead_top + colhead_h + 24),
            muted,
            content_w - PAD_X * 2,
        );
        renderLegend(draw, content_x, content_w, muted, line);
        return;
    }

    // --- Body rows. ---
    const row_h = rowHeight(draw.cell_h);
    const body_top = colhead_top + colhead_h;
    const cap = bodyVisibleCapacity(window_height, top, draw.cell_h);
    const scroll = clampScroll(view.scroll, view.rows.len, cap);

    var rendered: usize = 0;
    var ri: usize = scroll;
    while (ri < view.rows.len and rendered < cap) : (ri += 1) {
        const row_top_px = body_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);

        if (ri == view.sel_row) {
            draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.55);
            draw.fillQuad(content_x, row_y, 3, row_h, accent);
        }
        draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.4);

        const pr = view.rows[ri];
        const text_y = yTextFromTop(draw, window_height, row_top_px + (row_h - draw.cell_h) / 2);

        const tag = pr.provider.toString();
        const tag_end = draw.renderTextLimited(tag, content_x + PAD_X, text_y, accent, 70);
        const name_x = tag_end + 8;
        _ = draw.renderTextLimited(pr.name, name_x, text_y, fg, @max(0, col0_x - name_x - 8));

        _ = draw.renderTextLimited(localGlyph(pr.relation), col0_x, text_y, colorForRelation(if (pr.relation == .remote_only) .remote_only else .local_only, fg, muted), COL_W - SMALL_GAP);
        _ = draw.renderTextLimited(remoteGlyph(pr.relation), col1_x, text_y, colorForRelation(pr.relation, fg, muted), COL_W - SMALL_GAP);

        // Hint after the two columns.
        const hint_x = col1_x + COL_W;
        _ = draw.renderTextLimited(hintFor(pr.relation), hint_x, text_y, muted, @max(0, content_x + content_w - PAD_X - hint_x));

        rendered += 1;
    }

    renderLegend(draw, content_x, content_w, muted, line);
}

fn renderLegend(draw: DrawContext, content_x: f32, content_w: f32, muted: [3]f32, line: [3]f32) void {
    const legend_h = legendHeight(draw.cell_h);
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_y = (legend_h - draw.cell_h) / 2;
    const legend = "✓ 存在   ≠ 内容不同   — 不存在   ? 无法校验      [⏎]预览/对比  [u]上传  [d]下载  [s]换服务器";
    _ = draw.renderTextLimited(legend, content_x + PAD_X, text_y, muted, content_w - PAD_X * 2);
}

// --- Tests ---

test "skill_center_renderer: relation glyphs" {
    try std.testing.expectEqualStrings("✓", localGlyph(.same));
    try std.testing.expectEqualStrings("✓", localGlyph(.local_only));
    try std.testing.expectEqualStrings("—", localGlyph(.remote_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.same));
    try std.testing.expectEqualStrings("≠", remoteGlyph(.differ));
    try std.testing.expectEqualStrings("—", remoteGlyph(.local_only));
    try std.testing.expectEqualStrings("✓", remoteGlyph(.remote_only));
    try std.testing.expectEqualStrings("?", remoteGlyph(.unknown));
}

test "skill_center_renderer: clampScroll keeps scroll within range" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10));
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10));
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10));
}

test "skill_center_renderer: bodyVisibleCapacity grows with height" {
    const cell_h: f32 = 16;
    try std.testing.expect(bodyVisibleCapacity(800, 40, cell_h) >= bodyVisibleCapacity(200, 40, cell_h));
    try std.testing.expectEqual(@as(usize, 0), bodyVisibleCapacity(40, 40, cell_h));
}
```

- [ ] **Step 4: Update the renderer's caller in AppWindow**

In `src/AppWindow.zig`, replace the `View` construction inside `renderSkillCenterFrame` (currently lines 833-840) with:

```zig
        const sel_idx = session.model.selectedServerIndex();
        const server_name: []const u8 = if (sel_idx) |i| serverDisplayName(session.model.servers.?[i].source_id) else "";
        const server_reachable = if (sel_idx) |i| session.model.servers.?[i].reachable else false;
        const view: skill_center_renderer.View = .{
            .rows = if (session.model.pairing) |p| p else &.{},
            .local_name = "local",
            .server_name = server_name,
            .server_reachable = server_reachable,
            .sel_row = session.model.sel_row,
            .scroll = session.model.scroll,
            .stale = session.model.stale,
            .status = session.status,
        };
```

Add this small helper near `renderSkillCenterFrame` (e.g. right after it, before `renderAiCopilotPanel`):

```zig
/// Display name for a skill-center source id: strip the "ssh:" prefix.
fn serverDisplayName(source_id: []const u8) []const u8 {
    if (std.mem.startsWith(u8, source_id, "ssh:")) return source_id["ssh:".len..];
    return source_id;
}
```

- [ ] **Step 5: Run tests + build, then commit**

Run: `zig test src/renderer/skill_center_renderer.zig` → PASS
Run: `zig build test` → PASS
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds (GUI graph compiles)

```bash
git add src/renderer/skill_center_renderer.zig src/AppWindow.zig
git commit -m "feat(skill-center): two-column local-vs-server renderer"
```

---

## Task 4: Selection + server switching keys

Make ↑/↓ move the pairing row, ←/→ switch the selected server, and add `s` as an explicit "next server". Update `skillCenterMoveSelection` to be pairing-aware and add `skillCenterSwitchServer`.

**Files:**
- Modify: `src/AppWindow.zig:958-980` (`skillCenterMoveSelection`) + add `skillCenterSwitchServer`
- Modify: `src/input.zig:1482-1508` (key dispatch)

- [ ] **Step 1: Rewrite `skillCenterMoveSelection`**

Replace `skillCenterMoveSelection` (lines 958-980) with a row-only mover plus a server switcher:

```zig
/// Move the selected pairing row by `drow`, clamping. Returns false if no tab.
pub fn skillCenterMoveSelection(drow: isize, dcol: isize) bool {
    _ = dcol; // columns are fixed (local | server); kept for the input.zig arity
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const rows = if (session.model.pairing) |p| p.len else 0;
    if (rows > 0) {
        const cur: isize = @intCast(session.model.sel_row);
        const next = std.math.clamp(cur + drow, 0, @as(isize, @intCast(rows - 1)));
        session.model.sel_row = @intCast(next);
    }
    markUiDirty();
    return true;
}

/// Cycle the selected server by `delta` (wraps) and rebuild the pairing.
pub fn skillCenterSwitchServer(delta: isize) bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    const rc = session.model.remoteCount();
    if (rc == 0) return true;
    const cur: isize = @intCast(session.model.sel_server);
    var next = @rem(cur + delta, @as(isize, @intCast(rc)));
    if (next < 0) next += @intCast(rc);
    session.model.sel_server = @intCast(next);
    session.model.sel_row = 0;
    session.model.scroll = 0;
    session.model.rebuildPairing();
    markUiDirty();
    return true;
}
```

- [ ] **Step 2: Wire the keys in input.zig**

In `src/input.zig`, within the `if (AppWindow.activeSkillCenter() != null)` block at lines 1482-1508, change the left/right arrows to switch servers and add `s`. Replace the left/right cases:

```zig
                .left => {
                    _ = AppWindow.skillCenterSwitchServer(-1);
                },
                .right => {
                    _ = AppWindow.skillCenterSwitchServer(1);
                },
```

And add an `s` key case alongside the existing `r` (rescan) case. Find the char/keysym handling in this block; add (matching how `r` is matched — by character):

```zig
                .s => {
                    _ = AppWindow.skillCenterSwitchServer(1);
                },
```

> Note: match the exact key-enum style already used for `r` in this block. If `r` is matched as a character literal rather than a keysym enum, mirror that for `s`. Read lines 1482-1510 first and follow the existing pattern verbatim.

- [ ] **Step 3: Build + manual sanity**

Run: `zig build test` → PASS
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds

- [ ] **Step 4: Commit**

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "feat(skill-center): row selection + ←/→/s server switching"
```

---

## Task 5: Retire the modal matrix

The renderer and model no longer read the matrix. Remove `Matrix`/`buildMatrix`/`Cell`/`CellState`/`ServerCol`/`RowKey` from `skill_inventory.zig` (keep `ServerScan`, `Provider`, `SkillRow` — cache + pairing depend on them), and drop the now-dead matrix fields/usage from `PanelModel`.

**Files:**
- Modify: `src/skill_inventory.zig` (delete matrix machinery + its tests)
- Modify: `src/skill_center.zig` (drop `matrix`, `sel_col`)

- [ ] **Step 1: Remove matrix from PanelModel**

In `src/skill_center.zig`:
- Delete the `matrix: ?inv.Matrix = null,` and `sel_col: usize = 0,` fields.
- In `setServers`, delete the two lines `if (self.matrix) |*m| m.deinit();` and `self.matrix = inv.buildMatrix(self.allocator, servers) catch null;`.
- In `deinit`, delete `if (self.matrix) |*m| m.deinit();`.
- Delete the now-obsolete tests that assert on `model.matrix` (`"seedFromCache loads persisted scan and marks stale"` asserts `model.matrix != null` — change those assertions to `model.pairing != null`; `"PanelModel setServers rebuilds matrix and clamps selection"` and `"Session.finishScan publishes..."`/`"discards..."` assert `model.matrix` — switch those to `model.pairing`). Also the top-of-file `test "skill_center: runScan over sources builds a matrix"` uses `inv.buildMatrix`; rewrite it to use `pairing.pair` instead, or delete it (pairing has its own coverage in Task 1) — delete it for simplicity.

Concretely, in `test "skill_center: seedFromCache loads persisted scan and marks stale"` replace:
```zig
    try std.testing.expect(model.matrix != null);
    try std.testing.expectEqual(@as(usize, 1), model.matrix.?.skills.len);
```
with:
```zig
    try std.testing.expect(model.pairing != null);
    try std.testing.expectEqual(@as(usize, 1), model.pairing.?.len);
```

In `test "skill_center: PanelModel setServers rebuilds matrix and clamps selection"` replace each `model.matrix.?.skills.len` with `model.pairing.?.len` and the title's "matrix" with "pairing".

In `test "skill_center: Session.finishScan publishes a current-generation result"` replace:
```zig
    try std.testing.expect(session.model.matrix != null);
    try std.testing.expectEqual(@as(usize, 1), session.model.matrix.?.skills.len);
```
with:
```zig
    try std.testing.expect(session.model.pairing != null);
    try std.testing.expectEqual(@as(usize, 1), session.model.pairing.?.len);
```

In `test "skill_center: Session.finishScan discards a stale-generation result (no leak)"` replace `session.model.matrix == null` with `session.model.pairing == null` (servers stays null too).

Delete `test "skill_center: runScan over sources builds a matrix"` and the `ScriptHost` struct it uses if unused elsewhere.

- [ ] **Step 2: Remove matrix machinery from skill_inventory.zig**

In `src/skill_inventory.zig` delete: `CellState`, `Cell`, `RowKey`, `ServerCol`, `Matrix`, `rowKeyLessThan`, `findRow`, `referenceHash`, `buildMatrix`, `sameKey`, `makeRow`, and all four `test "skill_inventory: ..."` tests. Keep the imports, `Provider`, `SkillRow`, and `ServerScan`. The file should shrink to roughly:

```zig
const std = @import("std");
const scan = @import("skill_scan.zig");

pub const Provider = scan.Provider;
pub const SkillRow = scan.SkillRow;

/// One server's scan result: the unit stored by the cache and compared by
/// `skill_pairing`. `rows` are borrowed by consumers (no ownership transfer).
pub const ServerScan = struct {
    source_id: []const u8,
    reachable: bool,
    rows: []const SkillRow,
};
```

- [ ] **Step 3: Build + test**

Run: `zig build test` → PASS (no references to the removed symbols remain — `grep -rn "buildMatrix\|CellState\|\.matrix" src` should return nothing in skill files).
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds

- [ ] **Step 4: Commit**

```bash
git add src/skill_inventory.zig src/skill_center.zig
git commit -m "refactor(skill-center): retire modal matrix in favor of pairing"
```

**Phase 1 done:** the panel is now legible and switchable. Verify by hand: `zig build -Dtarget=aarch64-macos macos-app`, open Skill Center, confirm two columns with real server names and ←/→/s switching.

---

# Phase 2 — Upload / download (tar-over-ssh)

## Task 6: `skill_transfer_cmd.zig` — pure shell-command builders

**Files:**
- Create: `src/skill_transfer_cmd.zig`
- Modify: `src/test_fast.zig` (register)

- [ ] **Step 1: Write the module + tests**

Create `src/skill_transfer_cmd.zig`:

```zig
//! Pure builders for the POSIX shell strings used by the skill transfer runner.
//! Names are single-quote-escaped; "$HOME" stays expandable. No I/O here so the
//! quoting/path logic is unit-testable in isolation.
const std = @import("std");

/// Split a scan rel_path into the tar root and the item under it.
/// - skill_md:  ".claude/skills/<name>/SKILL.md" -> root ".claude/skills", item "<name>"
/// - prompt_md: ".codex/prompts/<name>.md"       -> root ".codex/prompts", item "<name>.md"
pub const SkillPath = struct { root_rel: []const u8, item: []const u8 };

pub fn splitSkillPath(rel_path: []const u8) ?SkillPath {
    if (std.mem.endsWith(u8, rel_path, "/SKILL.md")) {
        const dir = rel_path[0 .. rel_path.len - "/SKILL.md".len]; // ".../<name>"
        const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return null;
        return .{ .root_rel = dir[0..slash], .item = dir[slash + 1 ..] };
    }
    const slash = std.mem.lastIndexOfScalar(u8, rel_path, '/') orelse return null;
    return .{ .root_rel = rel_path[0..slash], .item = rel_path[slash + 1 ..] };
}

fn appendQuoted(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') try buf.appendSlice(allocator, "'\\''") else try buf.append(allocator, c);
    }
    try buf.append(allocator, '\'');
}

/// `tar -czf '<tmp>' -C "$HOME"/'<root>' '<item>'` — package a skill into <tmp>.
pub fn tarCreateCmd(allocator: std.mem.Allocator, root_rel: []const u8, item: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "tar -czf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$HOME\"/");
    try appendQuoted(&buf, allocator, root_rel);
    try buf.append(allocator, ' ');
    try appendQuoted(&buf, allocator, item);
    return buf.toOwnedSlice(allocator);
}

/// Stage-then-swap extract: extract <tmp> into a staging dir under the root,
/// then atomically replace "$HOME/<root>/<item>". A failed extract leaves the
/// live skill untouched. Uses $$ for staging uniqueness.
pub fn tarExtractCmd(allocator: std.mem.Allocator, root_rel: []const u8, item: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    // D="$HOME"/'<root>'
    try buf.appendSlice(allocator, "D=\"$HOME\"/");
    try appendQuoted(&buf, allocator, root_rel);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"; S=\"$D/.wisptmp.$$\"; rm -rf \"$S\"; mkdir -p \"$S\"; ");
    // tar -xzf '<tmp>' -C "$S" && rm -rf "$D"/'<item>' && mv "$S"/'<item>' "$D"/'<item>'; rm -rf "$S"
    try buf.appendSlice(allocator, "tar -xzf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$S\" && rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, " && mv \"$S\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, " \"$D\"/");
    try appendQuoted(&buf, allocator, item);
    try buf.appendSlice(allocator, "; rm -rf \"$S\"");
    return buf.toOwnedSlice(allocator);
}

// --- Tests ---

test "skill_transfer_cmd: splitSkillPath for skill_md and prompt_md" {
    const a = splitSkillPath(".claude/skills/roundtable/SKILL.md").?;
    try std.testing.expectEqualStrings(".claude/skills", a.root_rel);
    try std.testing.expectEqualStrings("roundtable", a.item);
    const b = splitSkillPath(".codex/prompts/foo.md").?;
    try std.testing.expectEqualStrings(".codex/prompts", b.root_rel);
    try std.testing.expectEqualStrings("foo.md", b.item);
}

test "skill_transfer_cmd: tarCreateCmd shape + quoting" {
    const allocator = std.testing.allocator;
    const cmd = try tarCreateCmd(allocator, ".claude/skills", "a'b", "/tmp/x.tgz");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings(
        "tar -czf '/tmp/x.tgz' -C \"$HOME\"/'.claude/skills' 'a'\\''b'",
        cmd,
    );
}

test "skill_transfer_cmd: tarExtractCmd stages then swaps" {
    const allocator = std.testing.allocator;
    const cmd = try tarExtractCmd(allocator, ".claude/skills", "pdf", "/tmp/x.tgz");
    defer allocator.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, ".wisptmp.$$") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "tar -xzf '/tmp/x.tgz' -C \"$S\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mv \"$S\"/'pdf' \"$D\"/'pdf'") != null);
    // The live dir is only removed inside the && chain, after a successful extract.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "&& rm -rf \"$D\"/'pdf'") != null);
}
```

- [ ] **Step 2: Run + register + gate**

Run: `zig test src/skill_transfer_cmd.zig` → PASS
Modify `src/test_fast.zig`: add `_ = @import("skill_transfer_cmd.zig");` after the pairing import.
Run: `zig build test` → PASS

- [ ] **Step 3: Commit**

```bash
git add src/skill_transfer_cmd.zig src/test_fast.zig
git commit -m "feat(skill-center): pure tar create/extract command builders"
```

---

## Task 7: `skill_transfer.zig` — transfer runner with a testable seam

The runner does the temp-file tar dance through three injected function pointers (local exec, remote exec, file copy) so it is unit-testable with fakes and has no direct platform import.

**Files:**
- Create: `src/skill_transfer.zig`
- Modify: `src/test_fast.zig` (register)

- [ ] **Step 1: Write the module + tests**

Create `src/skill_transfer.zig`:

```zig
//! Skill transfer runner: upload (local hub -> server) and download
//! (server -> local hub) of one skill, via a temp-file tar dance over existing
//! primitives. The three operations are injected so this stays platform-neutral
//! and unit-testable:
//!   - localExec(cmd): run a POSIX command locally, return ok
//!   - remoteExec(cmd): run a POSIX command on the server, return ok
//!   - copy(direction, local_path, remote_path): scp the temp tarball
const std = @import("std");
const cmd = @import("skill_transfer_cmd.zig");

pub const Result = enum { ok, failed };
pub const Direction = enum { upload, download };

pub const Ops = struct {
    ctx: *anyopaque,
    /// Run `command` locally; return true on success.
    localExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Run `command` on the server; return true on success.
    remoteExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Copy the tarball. `dir == .upload`: local_tmp -> remote_tmp.
    /// `dir == .download`: remote_tmp -> local_tmp. Return true on success.
    copy: *const fn (*anyopaque, std.mem.Allocator, Direction, []const u8, []const u8) bool,
};

const LOCAL_TMP = "/tmp/.wispterm-skill.tgz";
const REMOTE_TMP = "/tmp/.wispterm-skill.tgz";

/// Upload the skill at `rel_path` from the local hub to the server.
pub fn upload(allocator: std.mem.Allocator, ops: Ops, rel_path: []const u8) Result {
    const sp = cmd.splitSkillPath(rel_path) orelse return .failed;
    const make = cmd.tarCreateCmd(allocator, sp.root_rel, sp.item, LOCAL_TMP) catch return .failed;
    defer allocator.free(make);
    if (!ops.localExec(ops.ctx, allocator, make)) return .failed;

    if (!ops.copy(ops.ctx, allocator, .upload, LOCAL_TMP, REMOTE_TMP)) return .failed;

    const extract = cmd.tarExtractCmd(allocator, sp.root_rel, sp.item, REMOTE_TMP) catch return .failed;
    defer allocator.free(extract);
    const cleanup = std.fmt.allocPrint(allocator, "{s}; rm -f '{s}'", .{ extract, REMOTE_TMP }) catch return .failed;
    defer allocator.free(cleanup);
    if (!ops.remoteExec(ops.ctx, allocator, cleanup)) return .failed;

    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    return .ok;
}

/// Download the skill at `rel_path` from the server into the local hub.
pub fn download(allocator: std.mem.Allocator, ops: Ops, rel_path: []const u8) Result {
    const sp = cmd.splitSkillPath(rel_path) orelse return .failed;
    const make = cmd.tarCreateCmd(allocator, sp.root_rel, sp.item, REMOTE_TMP) catch return .failed;
    defer allocator.free(make);
    if (!ops.remoteExec(ops.ctx, allocator, make)) return .failed;

    if (!ops.copy(ops.ctx, allocator, .download, LOCAL_TMP, REMOTE_TMP)) return .failed;

    const extract = cmd.tarExtractCmd(allocator, sp.root_rel, sp.item, LOCAL_TMP) catch return .failed;
    defer allocator.free(extract);
    if (!ops.localExec(ops.ctx, allocator, extract)) return .failed;

    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    _ = ops.remoteExec(ops.ctx, allocator, "rm -f '" ++ REMOTE_TMP ++ "'");
    return .ok;
}

// --- Tests ---

const Recorder = struct {
    local_cmds: std.ArrayListUnmanaged([]u8) = .empty,
    remote_cmds: std.ArrayListUnmanaged([]u8) = .empty,
    copies: usize = 0,
    fail_copy: bool = false,
    allocator: std.mem.Allocator,

    fn deinit(self: *Recorder) void {
        for (self.local_cmds.items) |c| self.allocator.free(c);
        for (self.remote_cmds.items) |c| self.allocator.free(c);
        self.local_cmds.deinit(self.allocator);
        self.remote_cmds.deinit(self.allocator);
    }
    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.local_cmds.append(allocator, allocator.dupe(u8, command) catch return false) catch return false;
        return true;
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.remote_cmds.append(allocator, allocator.dupe(u8, command) catch return false) catch return false;
        return true;
    }
    fn copy(ctx: *anyopaque, _: std.mem.Allocator, _: Direction, _: []const u8, _: []const u8) bool {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        if (self.fail_copy) return false;
        self.copies += 1;
        return true;
    }
    fn ops(self: *Recorder) Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
};

test "skill_transfer: upload runs tar-create local, copy, extract remote" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator };
    defer rec.deinit();
    try std.testing.expectEqual(Result.ok, upload(allocator, rec.ops(), ".claude/skills/pdf/SKILL.md"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: download runs tar-create remote, copy, extract local" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator };
    defer rec.deinit();
    try std.testing.expectEqual(Result.ok, download(allocator, rec.ops(), ".codex/prompts/foo.md"));
    try std.testing.expect(std.mem.startsWith(u8, rec.remote_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: copy failure aborts with failed" {
    const allocator = std.testing.allocator;
    var rec = Recorder{ .allocator = allocator, .fail_copy = true };
    defer rec.deinit();
    try std.testing.expectEqual(Result.failed, upload(allocator, rec.ops(), ".claude/skills/pdf/SKILL.md"));
}
```

- [ ] **Step 2: Run + register + gate**

Run: `zig test src/skill_transfer.zig` → PASS
Modify `src/test_fast.zig`: add `_ = @import("skill_transfer.zig");`.
Run: `zig build test` → PASS

- [ ] **Step 3: Commit**

```bash
git add src/skill_transfer.zig src/test_fast.zig
git commit -m "feat(skill-center): transfer runner (upload/download) with fakeable ops"
```

---

## Task 8: Overwrite-decision helper (pure)

Decide, for a selected pairing row + a direction, whether the action is a no-op, a direct transfer, or needs an overwrite confirm.

**Files:**
- Modify: `src/skill_center.zig` (add a pure `transferDecision`)

- [ ] **Step 1: Write the failing test**

Add to `src/skill_center.zig` tests:

```zig
test "skill_center: transferDecision" {
    // upload: local must exist; same -> noop; differ/unknown -> confirm; remote absent -> direct
    try std.testing.expectEqual(TransferDecision.noop, transferDecision(.upload, .same));
    try std.testing.expectEqual(TransferDecision.confirm, transferDecision(.upload, .differ));
    try std.testing.expectEqual(TransferDecision.confirm, transferDecision(.upload, .unknown));
    try std.testing.expectEqual(TransferDecision.direct, transferDecision(.upload, .local_only));
    try std.testing.expectEqual(TransferDecision.invalid, transferDecision(.upload, .remote_only));
    // download: remote must exist; same -> noop; differ/unknown -> confirm; local absent -> direct
    try std.testing.expectEqual(TransferDecision.noop, transferDecision(.download, .same));
    try std.testing.expectEqual(TransferDecision.confirm, transferDecision(.download, .differ));
    try std.testing.expectEqual(TransferDecision.direct, transferDecision(.download, .remote_only));
    try std.testing.expectEqual(TransferDecision.invalid, transferDecision(.download, .local_only));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig test src/skill_center.zig`
Expected: FAIL — `TransferDecision` / `transferDecision` undefined.

- [ ] **Step 3: Implement**

Add near the top of `src/skill_center.zig` (after the imports), referencing the transfer Direction type:

```zig
const transfer = @import("skill_transfer.zig");

pub const TransferDecision = enum { direct, confirm, noop, invalid };

/// Decide what a transfer of the selected row implies, given the relation.
/// `invalid` = the source side is absent (nothing to send).
pub fn transferDecision(dir: transfer.Direction, rel: pairing.Relation) TransferDecision {
    return switch (dir) {
        .upload => switch (rel) {
            .local_only => .direct, // remote absent
            .same => .noop,
            .differ, .unknown => .confirm,
            .remote_only => .invalid, // nothing local to upload
        },
        .download => switch (rel) {
            .remote_only => .direct, // local absent
            .same => .noop,
            .differ, .unknown => .confirm,
            .local_only => .invalid, // nothing remote to download
        },
    };
}
```

- [ ] **Step 4: Run + gate + commit**

Run: `zig test src/skill_center.zig` → PASS
Run: `zig build test` → PASS

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): pure overwrite/transfer decision helper"
```

---

## Task 9: Confirm overlay state + rendering

Add an overlay to the model (`none` / `confirm`) and render a confirm bar. Keep it minimal: a one-line bar over the legend.

**Files:**
- Modify: `src/skill_center.zig` (`PanelModel.overlay`)
- Modify: `src/renderer/skill_center_renderer.zig` (View gains overlay text; draw a confirm bar)
- Modify: `src/AppWindow.zig` (pass overlay into the View)

- [ ] **Step 1: Add overlay state to the model**

In `src/skill_center.zig`, add to `PanelModel`:

```zig
    /// Pending overwrite confirmation text (owned), or null. When set, u/d are
    /// captured by the confirm (Enter = proceed, Esc = cancel).
    confirm_text: ?[]u8 = null,
    /// What the confirm will execute on Enter.
    confirm_dir: transfer.Direction = .upload,
    confirm_rel_path: ?[]u8 = null,
```

Add helpers:

```zig
    pub fn setConfirm(self: *PanelModel, text: []const u8, dir: transfer.Direction, rel_path: []const u8) void {
        self.clearConfirm();
        self.confirm_text = self.allocator.dupe(u8, text) catch null;
        self.confirm_rel_path = self.allocator.dupe(u8, rel_path) catch null;
        self.confirm_dir = dir;
    }
    pub fn clearConfirm(self: *PanelModel) void {
        if (self.confirm_text) |t| self.allocator.free(t);
        if (self.confirm_rel_path) |p| self.allocator.free(p);
        self.confirm_text = null;
        self.confirm_rel_path = null;
    }
```

Call `self.clearConfirm();` at the start of `freeServers` and in `deinit` (before `freeServers`). Add a test:

```zig
test "skill_center: confirm set/clear" {
    const allocator = std.testing.allocator;
    var model = PanelModel.init(allocator);
    defer model.deinit();
    model.setConfirm("覆盖 web 上的 pdf？", .upload, ".claude/skills/pdf/SKILL.md");
    try std.testing.expect(model.confirm_text != null);
    model.clearConfirm();
    try std.testing.expect(model.confirm_text == null);
}
```

- [ ] **Step 2: Render the confirm bar**

In `src/renderer/skill_center_renderer.zig`, add to `View`:

```zig
    confirm_text: []const u8, // "" when no confirm pending
```

At the end of `render`, before `renderLegend`, add:

```zig
    if (view.confirm_text.len > 0) {
        const bar_h = rowHeight(draw.cell_h);
        const bar_y = legendHeight(draw.cell_h);
        draw.fillQuadAlpha(content_x, bar_y, content_w, bar_h, mixColor(bg, accent, 0.22), 0.97);
        const t_y = bar_y + (bar_h - draw.cell_h) / 2;
        _ = draw.renderTextLimited(view.confirm_text, content_x + PAD_X, t_y, fg, content_w - PAD_X * 2);
        return; // confirm replaces the legend line while active
    }
```

- [ ] **Step 3: Pass overlay through AppWindow**

In `src/AppWindow.zig` `renderSkillCenterFrame`, add to the `View` literal:

```zig
            .confirm_text = if (session.model.confirm_text) |t| t else "",
```

- [ ] **Step 4: Build + test + commit**

Run: `zig build test` → PASS
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds

```bash
git add src/skill_center.zig src/renderer/skill_center_renderer.zig src/AppWindow.zig
git commit -m "feat(skill-center): overwrite-confirm overlay state + bar"
```

---

## Task 10: Wire upload/download keys + transfer worker

Resolve the local hub + selected server connection, run the transfer off-thread, then rescan. Handle the confirm flow: `u`/`d` either act directly, no-op with a toast, or arm the confirm; Enter while armed proceeds, Esc cancels.

**Files:**
- Modify: `src/AppWindow.zig` (add `skillCenterUpload`/`skillCenterDownload`/`skillCenterConfirmProceed`/`skillCenterConfirmCancel` + a transfer worker)
- Modify: `src/input.zig` (keys `u`/`d`; Enter/Esc honor the confirm)

- [ ] **Step 1: Add the transfer driver to AppWindow**

Add near the other skill-center functions in `src/AppWindow.zig`. This reuses `scp` + `remote_file` to implement the `skill_transfer.Ops`, and runs on a detached thread (mirrors how the scan worker isolates blocking I/O). After success it calls `startSkillCenterScan` to refresh.

```zig
const skill_transfer = @import("skill_transfer.zig");
const skill_transfer_cmd = @import("skill_transfer_cmd.zig");
const scp = @import("scp.zig");

/// Owns everything the transfer thread needs (UI-thread snapshot).
const SkillTransferJob = struct {
    allocator: std.mem.Allocator,
    conn: ssh_connection.SshConnection,
    rel_path: []u8,
    dir: skill_transfer.Direction,

    fn localExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        _ = ctx;
        const out = remote_file.localPosixExec(allocator, command, 4 * 1024 * 1024) catch return false;
        allocator.free(out);
        return true;
    }
    fn remoteExec(ctx: *anyopaque, allocator: std.mem.Allocator, command: []const u8) bool {
        const self: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        const out = remote_file.sshExecCapture(allocator, self.conn, command) catch return false;
        allocator.free(out);
        return true;
    }
    fn copy(ctx: *anyopaque, allocator: std.mem.Allocator, dir: skill_transfer.Direction, local_tmp: []const u8, remote_tmp: []const u8) bool {
        const self: *SkillTransferJob = @ptrCast(@alignCast(ctx));
        var buf: [512]u8 = undefined;
        const remote_spec = scp.remoteSpec(&buf, &self.conn, remote_tmp);
        const result = switch (dir) {
            .upload => scp.transfer(allocator, &self.conn, local_tmp, remote_spec),
            .download => scp.transfer(allocator, &self.conn, remote_spec, local_tmp),
        };
        return result == .ok;
    }
    fn ops(self: *SkillTransferJob) skill_transfer.Ops {
        return .{ .ctx = self, .localExec = localExec, .remoteExec = remoteExec, .copy = copy };
    }
    fn threadMain(self: *SkillTransferJob) void {
        const result = switch (self.dir) {
            .upload => skill_transfer.upload(self.allocator, self.ops(), self.rel_path),
            .download => skill_transfer.download(self.allocator, self.ops(), self.rel_path),
        };
        if (result == .ok) {
            overlays.showStatusToast("Skill 同步完成");
            if (g_allocator) |a| {
                if (activeSkillCenter()) |s| startSkillCenterScan(a, s);
            }
        } else {
            overlays.showStatusToast("Skill 同步失败");
        }
        markUiDirty();
        const a = self.allocator;
        a.free(self.rel_path);
        a.destroy(self);
    }
};

/// Resolve the SshConnection for the model's selected server (by "ssh:<name>").
fn skillCenterSelectedConn(model: *const skill_center.PanelModel) ?ssh_connection.SshConnection {
    const idx = model.selectedServerIndex() orelse return null;
    const servers = model.servers orelse return null;
    const id = servers[idx].source_id;
    if (!std.mem.startsWith(u8, id, "ssh:")) return null;
    return overlays.aiHistorySshConnection(id["ssh:".len..]);
}

fn skillCenterStartTransfer(dir: skill_transfer.Direction, rel_path: []const u8) void {
    const allocator = g_allocator orelse return;
    const session = activeSkillCenter() orelse return;
    const conn = blk: {
        session.mutex.lock();
        defer session.mutex.unlock();
        break :blk skillCenterSelectedConn(&session.model);
    } orelse {
        overlays.showStatusToast("无法连接所选服务器");
        return;
    };
    const job = allocator.create(SkillTransferJob) catch return;
    job.* = .{
        .allocator = allocator,
        .conn = conn,
        .rel_path = allocator.dupe(u8, rel_path) catch {
            allocator.destroy(job);
            return;
        },
        .dir = dir,
    };
    overlays.showStatusToast(if (dir == .upload) "上传中…" else "下载中…");
    const t = std.Thread.spawn(.{}, SkillTransferJob.threadMain, .{job}) catch {
        allocator.free(job.rel_path);
        allocator.destroy(job);
        overlays.showStatusToast("无法启动同步");
        return;
    };
    t.detach();
}

/// Handle a u/d keypress: decide direct / confirm / noop / invalid.
fn skillCenterRequestTransfer(dir: skill_transfer.Direction) bool {
    const session = activeSkillCenter() orelse return false;
    var rel_owned: ?[]u8 = null;
    var decision: skill_center.TransferDecision = .invalid;
    var confirm_msg_buf: [256]u8 = undefined;
    var confirm_msg: []const u8 = "";
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const rows = session.model.pairing orelse return true;
        if (session.model.sel_row >= rows.len) return true;
        const pr = rows[session.model.sel_row];
        decision = skill_center.transferDecision(dir, pr.relation);
        const rel_path = switch (dir) {
            .upload => pr.local_rel_path,
            .download => pr.remote_rel_path,
        } orelse return true;
        if (decision == .confirm) {
            const verb = if (dir == .upload) "上传覆盖" else "下载覆盖";
            confirm_msg = std.fmt.bufPrint(&confirm_msg_buf, "{s} {s}（内容不同）？ [⏎ 确认] [esc 取消]", .{ verb, pr.name }) catch "覆盖？ [⏎ 确认] [esc 取消]";
            session.model.setConfirm(confirm_msg, dir, rel_path);
        } else if (decision == .direct) {
            rel_owned = (g_allocator orelse return true).dupe(u8, rel_path) catch null;
        }
    }
    switch (decision) {
        .noop => overlays.showStatusToast("已一致，无需同步"),
        .invalid => overlays.showStatusToast(if (dir == .upload) "本地没有该 skill" else "服务器没有该 skill"),
        .confirm => markUiDirty(),
        .direct => {
            if (rel_owned) |rp| {
                defer (g_allocator orelse return true).free(rp);
                skillCenterStartTransfer(dir, rp);
            }
        },
    }
    return true;
}

pub fn skillCenterUpload() bool {
    return skillCenterRequestTransfer(.upload);
}
pub fn skillCenterDownload() bool {
    return skillCenterRequestTransfer(.download);
}

/// True if a confirm is armed (so Enter/Esc are captured by it).
pub fn skillCenterConfirmActive() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    return session.model.confirm_text != null;
}

pub fn skillCenterConfirmProceed() bool {
    const session = activeSkillCenter() orelse return false;
    var dir: skill_transfer.Direction = .upload;
    var rel_owned: ?[]u8 = null;
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        if (session.model.confirm_text == null) return false;
        dir = session.model.confirm_dir;
        if (session.model.confirm_rel_path) |p| rel_owned = (g_allocator orelse return false).dupe(u8, p) catch null;
        session.model.clearConfirm();
    }
    if (rel_owned) |rp| {
        defer (g_allocator orelse return true).free(rp);
        skillCenterStartTransfer(dir, rp);
    }
    markUiDirty();
    return true;
}

pub fn skillCenterConfirmCancel() bool {
    const session = activeSkillCenter() orelse return false;
    session.mutex.lock();
    defer session.mutex.unlock();
    if (session.model.confirm_text == null) return false;
    session.model.clearConfirm();
    markUiDirty();
    return true;
}
```

> If `ssh_connection` / `overlays` / `g_allocator` aren't already imported/visible in `AppWindow.zig`, they are (the file already uses `overlays.aiHistorySshConnection`, `ssh_connection.SshConnection` in `SkillCenterTarget`, and `g_allocator`). Reuse the existing import names; do not add duplicates. Verify `scp` isn't already imported before adding it.

- [ ] **Step 2: Wire keys in input.zig**

In the skill-center key block (`src/input.zig` ~1482), add `u`/`d`, and make Enter/Esc honor an armed confirm. Before the existing Enter→preview case, branch on confirm:

```zig
                .u => {
                    _ = AppWindow.skillCenterUpload();
                },
                .d => {
                    _ = AppWindow.skillCenterDownload();
                },
```

For Enter (the case currently calling `skillCenterPreviewSelected`): change to

```zig
                .enter => {
                    if (AppWindow.skillCenterConfirmActive()) {
                        _ = AppWindow.skillCenterConfirmProceed();
                    } else {
                        _ = AppWindow.skillCenterPreviewSelected();
                    }
                },
```

For Esc handling of this panel: find where Esc closes the skill-center tab (search the block / line 1019 area). Make Esc first cancel an armed confirm, then fall through to close. Insert at the start of the Esc path for skill center:

```zig
                    if (AppWindow.skillCenterConfirmActive()) {
                        _ = AppWindow.skillCenterConfirmCancel();
                        return true; // consumed; do not close the panel
                    }
```

> Match the exact key matching style already used in this block (character vs keysym). Read the surrounding cases first and mirror them.

- [ ] **Step 3: Build + manual test + commit**

Run: `zig build test` → PASS
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds
Manual: open Skill Center, select a `仅本地` row → `u` → transfers (toast), row flips to `✓` after rescan; select a `不同` row → `u` → confirm bar → Enter proceeds, Esc cancels.

```bash
git add src/AppWindow.zig src/input.zig
git commit -m "feat(skill-center): upload/download keys + transfer worker + confirm flow"
```

---

# Phase 3 — Diff / compare view

## Task 11: `skill_diff.zig` — minimal line diff (pure)

**Files:**
- Create: `src/skill_diff.zig`
- Modify: `src/test_fast.zig` (register)

- [ ] **Step 1: Write the module + tests**

Create `src/skill_diff.zig`:

```zig
//! Minimal line-level diff for the SKILL.md compare view. LCS over lines, then
//! emit a unified-ish list of ops. Pure; caller frees the returned slice and
//! each op's `text` is borrowed from the inputs (free the slice only).
const std = @import("std");

pub const Op = enum { context, add, del };
pub const Line = struct { op: Op, text: []const u8 };

fn splitLines(allocator: std.mem.Allocator, s: []const u8) ![][]const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |ln| try out.append(allocator, ln);
    return out.toOwnedSlice(allocator);
}

/// Diff `a` (local) vs `b` (remote). `del` = present in a not b; `add` = in b not a.
pub fn diff(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]Line {
    const la = try splitLines(allocator, a);
    defer allocator.free(la);
    const lb = try splitLines(allocator, b);
    defer allocator.free(lb);

    // LCS length table.
    const n = la.len;
    const m = lb.len;
    const table = try allocator.alloc(usize, (n + 1) * (m + 1));
    defer allocator.free(table);
    @memset(table, 0);
    const idx = struct {
        fn at(i: usize, j: usize, cols: usize) usize {
            return i * cols + j;
        }
    };
    const cols = m + 1;
    var i: usize = n;
    while (i > 0) : (i -= 1) {
        var j: usize = m;
        while (j > 0) : (j -= 1) {
            if (std.mem.eql(u8, la[i - 1], lb[j - 1])) {
                table[idx.at(i - 1, j - 1, cols)] = table[idx.at(i, j, cols)] + 1;
            } else {
                table[idx.at(i - 1, j - 1, cols)] = @max(table[idx.at(i, j - 1, cols)], table[idx.at(i - 1, j, cols)]);
            }
        }
    }

    var out: std.ArrayListUnmanaged(Line) = .empty;
    errdefer out.deinit(allocator);
    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, la[i], lb[j])) {
            try out.append(allocator, .{ .op = .context, .text = la[i] });
            i += 1;
            j += 1;
        } else if (table[idx.at(i + 1, j, cols)] >= table[idx.at(i, j + 1, cols)]) {
            try out.append(allocator, .{ .op = .del, .text = la[i] });
            i += 1;
        } else {
            try out.append(allocator, .{ .op = .add, .text = lb[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try out.append(allocator, .{ .op = .del, .text = la[i] });
    while (j < m) : (j += 1) try out.append(allocator, .{ .op = .add, .text = lb[j] });
    return out.toOwnedSlice(allocator);
}

pub fn hasChanges(lines: []const Line) bool {
    for (lines) |l| if (l.op != .context) return true;
    return false;
}

// --- Tests ---

test "skill_diff: identical inputs -> no changes" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "a\nb\nc", "a\nb\nc");
    defer allocator.free(lines);
    try std.testing.expect(!hasChanges(lines));
}

test "skill_diff: add and delete" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "a\nb\nc", "a\nx\nc");
    defer allocator.free(lines);
    try std.testing.expect(hasChanges(lines));
    // Expect: context a, del b, add x, context c
    try std.testing.expectEqual(Op.context, lines[0].op);
    var saw_del = false;
    var saw_add = false;
    for (lines) |l| {
        if (l.op == .del and std.mem.eql(u8, l.text, "b")) saw_del = true;
        if (l.op == .add and std.mem.eql(u8, l.text, "x")) saw_add = true;
    }
    try std.testing.expect(saw_del and saw_add);
}

test "skill_diff: empty vs non-empty is all add" {
    const allocator = std.testing.allocator;
    const lines = try diff(allocator, "", "x\ny");
    defer allocator.free(lines);
    var adds: usize = 0;
    for (lines) |l| {
        if (l.op == .add) adds += 1;
    }
    try std.testing.expect(adds >= 2);
}
```

- [ ] **Step 2: Run + register + gate**

Run: `zig test src/skill_diff.zig` → PASS
Modify `src/test_fast.zig`: add `_ = @import("skill_diff.zig");`.
Run: `zig build test` → PASS

- [ ] **Step 3: Commit**

```bash
git add src/skill_diff.zig src/test_fast.zig
git commit -m "feat(skill-center): pure line-diff for SKILL.md compare"
```

---

## Task 12: Diff/preview view on Enter

On Enter for a non-confirm row, fetch the SKILL.md content(s) and show them in the markdown preview path. For a both-present (`same`/`differ`/`unknown`) row, fetch both and render the diff; for one-sided rows, preview that side.

**Files:**
- Modify: `src/AppWindow.zig` (`skillCenterPreviewSelected` → real fetch + render)

- [ ] **Step 1: Implement the preview/diff fetch**

Replace `skillCenterPreviewSelected` (currently the toast stub at lines 991-999) with a worker that reads the SKILL.md from the relevant side(s) and renders. Reuse `skill_center.previewCommand` to build the `cat`, `remote_file.localPosixExec` for the local side, `remote_file.sshExecCapture` for the remote side, and `skill_diff.diff` to format. Render into the existing markdown preview (follow how `aiHistoryPreviewSelectedTranscript` feeds the markdown preview path — mirror that call).

```zig
pub fn skillCenterPreviewSelected() bool {
    const session = activeSkillCenter() orelse return false;
    const allocator = g_allocator orelse return false;

    // Snapshot the selected row + the server conn under the lock.
    var local_rel: ?[]u8 = null;
    var remote_rel: ?[]u8 = null;
    var conn: ?ssh_connection.SshConnection = null;
    var name_buf: [128]u8 = undefined;
    var name: []const u8 = "";
    {
        session.mutex.lock();
        defer session.mutex.unlock();
        const rows = session.model.pairing orelse return true;
        if (session.model.sel_row >= rows.len) return true;
        const pr = rows[session.model.sel_row];
        name = std.fmt.bufPrint(&name_buf, "{s}", .{pr.name}) catch "";
        if (pr.local_rel_path) |p| local_rel = allocator.dupe(u8, p) catch null;
        if (pr.remote_rel_path) |p| remote_rel = allocator.dupe(u8, p) catch null;
        conn = skillCenterSelectedConn(&session.model);
    }
    defer if (local_rel) |p| allocator.free(p);
    defer if (remote_rel) |p| allocator.free(p);

    // Fetch local content.
    var local_text: ?[]u8 = null;
    defer if (local_text) |t| allocator.free(t);
    if (local_rel) |rp| {
        const cmd = skill_center.previewCommand(allocator, rp) catch null;
        if (cmd) |c| {
            defer allocator.free(c);
            local_text = remote_file.localPosixExec(allocator, c, 1024 * 1024) catch null;
        }
    }
    // Fetch remote content.
    var remote_text: ?[]u8 = null;
    defer if (remote_text) |t| allocator.free(t);
    if (remote_rel) |rp| {
        if (conn) |cn| {
            const cmd = skill_center.previewCommand(allocator, rp) catch null;
            if (cmd) |c| {
                defer allocator.free(c);
                remote_text = remote_file.sshExecCapture(allocator, cn, c) catch null;
            }
        }
    }

    // Build the markdown to show: a diff when both exist, else the one side.
    var md: std.ArrayListUnmanaged(u8) = .empty;
    defer md.deinit(allocator);
    if (local_text != null and remote_text != null) {
        md.appendSlice(allocator, "```diff\n") catch {};
        const lines = skill_diff.diff(allocator, local_text.?, remote_text.?) catch &[_]skill_diff.Line{};
        defer if (lines.len > 0) allocator.free(lines);
        for (lines) |l| {
            const prefix = switch (l.op) {
                .context => " ",
                .add => "+",
                .del => "-",
            };
            md.appendSlice(allocator, prefix) catch {};
            md.appendSlice(allocator, l.text) catch {};
            md.append(allocator, '\n') catch {};
        }
        md.appendSlice(allocator, "```\n") catch {};
    } else if (local_text) |t| {
        md.appendSlice(allocator, t) catch {};
    } else if (remote_text) |t| {
        md.appendSlice(allocator, t) catch {};
    } else {
        overlays.showStatusToast("无法读取 SKILL.md");
        return true;
    }

    showMarkdownPreview(md.items); // <-- use the project's existing preview entry point
    markUiDirty();
    return true;
}
```

> `showMarkdownPreview` is a placeholder for the project's existing markdown-preview entry. Find the real function used by `aiHistoryPreviewSelectedTranscript` (grep for `markdown_preview` in `AppWindow.zig`) and call that with `md.items` (and whatever title arg it takes). Do not invent a new preview pipeline.

- [ ] **Step 2: Build + manual test**

Run: `zig build test` → PASS
Run: `zig build -Dtarget=aarch64-macos macos-app` → builds
Manual: select a `不同` row → Enter → diff shows in the preview pane; select a `仅本地`/`仅远程` row → Enter → that side's SKILL.md shows.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): Enter previews/diffs the selected skill's SKILL.md"
```

---

## Self-review notes (already reconciled)

- **Spec coverage:** two-pane local-vs-server (Tasks 2-4), real server names (Task 3), pairing replaces modal matrix (Tasks 1,5), upload/download tar-over-ssh (Tasks 6-7,10), overwrite confirm w/ stage-then-swap atomicity (Tasks 6,9,10), diff of SKILL.md (Tasks 11-12), hash demoted to internal drift flag (pairing uses `agg_hash` only to pick `same`/`differ`), no persisted assignment (none added), ad-hoc target selection (server switch, no storage). All covered.
- **Type consistency:** `Relation`, `PairRow`, `pair()` (Task 1) are used unchanged in Tasks 2-4,8-10,12; `transfer.Direction`/`Ops`/`upload`/`download` (Task 7) used in Tasks 8,10; `TransferDecision`/`transferDecision` (Task 8) used in Task 10; `splitSkillPath`/`tarCreateCmd`/`tarExtractCmd` (Task 6) used in Task 7.
- **Out of scope (unchanged from spec):** WSL transfer targets, per-file (non-SKILL.md) diff, bulk "整机对齐", three-way merge, persisted assignment.
- **Known integration unknowns flagged inline (must be resolved by reading the surrounding code, not guessed):** exact key-enum matching style in `input.zig`; the real markdown-preview entry point in `AppWindow.zig`; whether `scp` is already imported.
