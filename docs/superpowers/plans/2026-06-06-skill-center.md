# Skill Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only, cross-server **Skill Center** panel that inventories Claude Code / Codex skills across local + WSL + SSH sources as an aggregate matrix (skill × server) showing presence and version-consistency, with SKILL.md preview.

**Architecture:** Three pure, fully-tested modules — `skill_scan.zig` (remote scan command + output parser + per-source scan), `skill_inventory.zig` (the skill×server matrix model + cell-state rule), `skill_inventory_cache.zig` (persisted last scan) — plus an impure `skill_center.zig` (background scan worker + panel model) that mirrors the existing `ai_history_*` Sessions browser. The scan reuses the `RemoteExecHost.exec` seam already used by Sessions; one `find + sha256sum` shell command per server.

**Tech Stack:** Zig (std 0.15 idioms, matching `src/skill_registry.zig`); POSIX shell for the remote scan; `std.json` for the cache. Tests are in-file `test "..."` blocks driven by fake exec hosts, the same pattern as `src/ai_history_session.zig`.

**Spec:** `docs/superpowers/specs/2026-06-06-skill-center-design.md`

**Refinement vs spec:** The remote scan emits `provider⇥name⇥rel_path⇥hash` (tab-separated) only — no frontmatter/base64 description (it was fragile in shell). `name` = skill directory basename (skill_md) or file stem (prompt_md), which is the stable cross-server row identity. The description is shown only in the preview pane (full SKILL.md), not as a matrix column.

---

## File Structure

| File | Responsibility | Layer |
|---|---|---|
| `src/skill_scan.zig` (new) | `Provider`, `Format`, `ScanTarget`, `defaultTargets`, `SkillRow`, `ExecHost`, `buildScanCommand`, `parseScanOutput`, `scanSource` | pure |
| `src/skill_inventory.zig` (new) | `ServerScan`, `CellState`, `Cell`, `RowKey`, `Matrix`, `buildMatrix` | pure |
| `src/skill_inventory_cache.zig` (new) | persist/load `[]ServerScan` in config dir | pure (disk) |
| `src/skill_center.zig` (new) | background scan worker + panel model (selection/scroll/status), mirrors `AiHistoryScanJob` + `agent_history` panel | impure |
| `src/renderer/skill_center_renderer.zig` (new) | draw the matrix, mirrors `src/renderer/ai_history_renderer.zig` | impure (GUI) |
| `src/AppWindow.zig` (modify) | new tab kind `.skill_center`, open/render/key routing, mirrors `.ai_history` wiring | impure |
| `src/command_center_state.zig` (modify) | command-center entry to open Skill Center | impure |
| `src/i18n.zig` (modify) | `sl_skill_center` + detail keys (en + zh-CN) | data |
| `src/test_fast.zig`, `src/test_main.zig` (modify) | register the 3 pure modules | test wiring |

Dependency direction: `skill_scan` ← `skill_inventory` ← `skill_inventory_cache`; `skill_center` imports all three plus `ai_history_session` (real exec hosts), `ssh_connection`, `remote_file`. `skill_scan` defines its own `ExecHost` (structurally identical to `ai_history_session.RemoteExecHost`) so the pure leaf does not import the 156 KB session module.

---

## Phase 1 — `skill_scan.zig` (pure: command + parser + scan)

### Task 1: SkillRow / Provider / Format / ScanTarget types + defaultTargets

**Files:**
- Create: `src/skill_scan.zig`
- Modify: `src/test_fast.zig` (add import), `src/test_main.zig` (add import)

- [ ] **Step 1: Create `src/skill_scan.zig` with types and `defaultTargets`**

```zig
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
```

- [ ] **Step 2: Register the module for tests**

In `src/test_fast.zig`, after line `_ = @import("ai_history_cache.zig");` (~L66) add:

```zig
    _ = @import("skill_scan.zig");
```

In `src/test_main.zig`, after `_ = @import("skill_registry.zig");` (~L720) add:

```zig
    _ = @import("skill_scan.zig");
```

- [ ] **Step 3: Run the fast suite to confirm it compiles**

Run: `zig build test 2>&1 | tail -5`
Expected: builds and passes (no tests in skill_scan yet, but the import must compile).

- [ ] **Step 4: Commit**

```bash
git add src/skill_scan.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(skill-center): skill_scan types + default scan targets"
```

### Task 2: `parseScanOutput`

**Files:**
- Modify: `src/skill_scan.zig`

- [ ] **Step 1: Write the failing test (append to `src/skill_scan.zig`)**

```zig
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | tail -15`
Expected: FAIL — `parseScanOutput` not defined.

- [ ] **Step 3: Implement `parseScanOutput` (add to `src/skill_scan.zig`)**

```zig
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
```

- [ ] **Step 4: Run it to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/skill_scan.zig
git commit -m "feat(skill-center): parseScanOutput tab-separated scan rows"
```

### Task 3: `buildScanCommand`

**Files:**
- Modify: `src/skill_scan.zig`

- [ ] **Step 1: Write the failing test**

```zig
test "skill_scan: buildScanCommand probes hash tool and covers all targets" {
    const allocator = std.testing.allocator;
    const cmd = try buildScanCommand(allocator, defaultTargets());
    defer allocator.free(cmd);

    // Probes for a hash tool.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "sha256sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "shasum -a 256") != null);
    // Covers each default root, anchored at $HOME.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.claude/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.codex/skills") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "$HOME/.codex/prompts") != null);
    // skill_md uses SKILL.md guard; prompt_md globs *.md.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "SKILL.md") != null);
    // Emits provider-tagged printf rows.
    try std.testing.expect(std.mem.indexOf(u8, cmd, "printf 'claude\\t") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "printf 'codex\\t") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | tail -15`
Expected: FAIL — `buildScanCommand` not defined.

- [ ] **Step 3: Implement `buildScanCommand`**

```zig
const hash_probe =
    \\HASHCMD="";
    \\if command -v sha256sum >/dev/null 2>&1; then HASHCMD="sha256sum";
    \\elif command -v shasum >/dev/null 2>&1; then HASHCMD="shasum -a 256"; fi;
    \\
;

/// Build a single POSIX-shell command that discovers skills under every target
/// root (relative to $HOME) and prints one `provider\tname\trel_path\thash`
/// line per skill. Missing roots are skipped; when no hash tool exists the hash
/// field is empty. Caller frees.
pub fn buildScanCommand(allocator: std.mem.Allocator, targets: []const ScanTarget) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, hash_probe);

    for (targets) |t| {
        const prov = t.provider.toString();
        switch (t.format) {
            .skill_md => {
                const block = try std.fmt.allocPrint(allocator,
                    \\R="$HOME/{s}";
                    \\if [ -d "$R" ]; then for d in "$R"/*/; do
                    \\[ -f "${{d}}SKILL.md" ] || continue;
                    \\n=$(basename "$d");
                    \\if [ -n "$HASHCMD" ]; then h=$(cd "$d" && find . -type f | LC_ALL=C sort | xargs -r $HASHCMD | $HASHCMD | cut -d' ' -f1); else h=""; fi;
                    \\printf '{s}\t%s\t{s}/%s/SKILL.md\t%s\n' "$n" "$n" "$h";
                    \\done; fi;
                    \\
                , .{ t.root_rel, prov, t.root_rel });
                defer allocator.free(block);
                try buf.appendSlice(allocator, block);
            },
            .prompt_md => {
                const block = try std.fmt.allocPrint(allocator,
                    \\R="$HOME/{s}";
                    \\if [ -d "$R" ]; then for f in "$R"/*.md; do
                    \\[ -f "$f" ] || continue;
                    \\n=$(basename "$f" .md);
                    \\if [ -n "$HASHCMD" ]; then h=$($HASHCMD "$f" | cut -d' ' -f1); else h=""; fi;
                    \\printf '{s}\t%s\t{s}/%s.md\t%s\n' "$n" "$n" "$h";
                    \\done; fi;
                    \\
                , .{ t.root_rel, prov, t.root_rel });
                defer allocator.free(block);
                try buf.appendSlice(allocator, block);
            },
        }
    }

    return buf.toOwnedSlice(allocator);
}
```

> Note for the implementer: in a Zig multiline string literal (`\\`), a literal
> `\t` / `\n` stays the two characters backslash+t / backslash+n, which is
> exactly what the shell `printf` format needs and what the test asserts
> (`"printf 'claude\\t"` in the Zig test source is the 2-char sequence). `{{`
> and `}}` are the escaped braces required inside `allocPrint`.

- [ ] **Step 4: Run it to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/skill_scan.zig
git commit -m "feat(skill-center): buildScanCommand remote find+sha256 pipeline"
```

### Task 4: `ExecHost` + `scanSource`

**Files:**
- Modify: `src/skill_scan.zig`

- [ ] **Step 1: Write the failing test**

```zig
const FakeHost = struct {
    output: ?[]const u8, // null => simulate exec failure (offline)
    fn exec(ctx: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]u8 {
        const self: *FakeHost = @ptrCast(@alignCast(ctx));
        const out = self.output orelse return error.RemoteExecFailed;
        return allocator.dupe(u8, out);
    }
    fn host(self: *FakeHost) ExecHost {
        return .{ .ctx = self, .exec = exec };
    }
};

test "skill_scan: scanSource parses reachable output" {
    const allocator = std.testing.allocator;
    var fake = FakeHost{ .output = "claude\tpdf\t.claude/skills/pdf/SKILL.md\thh\n" };
    var outcome = try scanSource(allocator, defaultTargets(), fake.host());
    defer outcome.deinit(allocator);

    try std.testing.expect(outcome.reachable);
    try std.testing.expectEqual(@as(usize, 1), outcome.rows.len);
    try std.testing.expectEqualStrings("pdf", outcome.rows[0].name);
}

test "skill_scan: scanSource marks offline host unreachable" {
    const allocator = std.testing.allocator;
    var fake = FakeHost{ .output = null };
    var outcome = try scanSource(allocator, defaultTargets(), fake.host());
    defer outcome.deinit(allocator);

    try std.testing.expect(!outcome.reachable);
    try std.testing.expectEqual(@as(usize, 0), outcome.rows.len);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `zig build test 2>&1 | tail -15`
Expected: FAIL — `ExecHost` / `scanSource` not defined.

- [ ] **Step 3: Implement `ExecHost`, `ScanOutcome`, `scanSource`**

```zig
/// Structurally identical to `ai_history_session.RemoteExecHost`; defined here
/// so this pure leaf does not import the large session module. The integration
/// layer adapts the real local/WSL/SSH exec functions into this shape.
pub const ExecFn = *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8;
pub const ExecHost = struct {
    ctx: *anyopaque,
    exec: ExecFn,
};

pub const ScanOutcome = struct {
    reachable: bool,
    rows: []SkillRow,

    pub fn deinit(self: *ScanOutcome, allocator: std.mem.Allocator) void {
        freeRows(allocator, self.rows);
        self.* = undefined;
    }
};

/// Run the scan command on one host and parse the result. An exec error
/// (offline / auth failure) yields `{ reachable = false, rows = &.{} }` rather
/// than propagating — one bad server must not abort the whole inventory.
pub fn scanSource(allocator: std.mem.Allocator, targets: []const ScanTarget, host: ExecHost) !ScanOutcome {
    const cmd = try buildScanCommand(allocator, targets);
    defer allocator.free(cmd);

    const out = host.exec(host.ctx, allocator, cmd) catch {
        return .{ .reachable = false, .rows = &.{} };
    };
    defer allocator.free(out);

    const rows = try parseScanOutput(allocator, out);
    return .{ .reachable = true, .rows = rows };
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/skill_scan.zig
git commit -m "feat(skill-center): scanSource via ExecHost seam (offline-safe)"
```

---

## Phase 2 — `skill_inventory.zig` (pure: the matrix)

### Task 5: `ServerScan` + matrix types

**Files:**
- Create: `src/skill_inventory.zig`
- Modify: `src/test_fast.zig`, `src/test_main.zig` (register import)

- [ ] **Step 1: Create `src/skill_inventory.zig` with types**

```zig
const std = @import("std");
const scan = @import("skill_scan.zig");

pub const Provider = scan.Provider;
pub const SkillRow = scan.SkillRow;

/// One server's scan result, the input to `buildMatrix`. `rows` are borrowed
/// for the duration of the build (the matrix copies what it needs).
pub const ServerScan = struct {
    source_id: []const u8,
    reachable: bool,
    rows: []const SkillRow,
};

pub const CellState = enum { match, differ, absent, unknown };

pub const Cell = struct { state: CellState };

pub const RowKey = struct {
    provider: Provider,
    name: []u8,

    pub fn deinit(self: *RowKey, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub const ServerCol = struct {
    source_id: []u8,
    reachable: bool,

    pub fn deinit(self: *ServerCol, allocator: std.mem.Allocator) void {
        allocator.free(self.source_id);
        self.* = undefined;
    }
};

pub const Matrix = struct {
    allocator: std.mem.Allocator,
    skills: []RowKey, // sorted rows
    servers: []ServerCol, // columns, in input order
    cells: []Cell, // row-major: cells[row * servers.len + col]

    pub fn cellAt(self: *const Matrix, row: usize, col: usize) Cell {
        return self.cells[row * self.servers.len + col];
    }

    pub fn deinit(self: *Matrix) void {
        for (self.skills) |*s| s.deinit(self.allocator);
        self.allocator.free(self.skills);
        for (self.servers) |*c| c.deinit(self.allocator);
        self.allocator.free(self.servers);
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};
```

- [ ] **Step 2: Register the module**

In `src/test_fast.zig` after the `skill_scan.zig` import add `_ = @import("skill_inventory.zig");`.
In `src/test_main.zig` after the `skill_scan.zig` import add `_ = @import("skill_inventory.zig");`.

- [ ] **Step 3: Run the fast suite to confirm it compiles**

Run: `zig build test 2>&1 | tail -5`
Expected: builds and passes.

- [ ] **Step 4: Commit**

```bash
git add src/skill_inventory.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(skill-center): skill_inventory matrix types"
```

### Task 6: `buildMatrix` — union rows + cell-state rule

**Files:**
- Modify: `src/skill_inventory.zig`

- [ ] **Step 1: Write the failing tests**

```zig
fn row(provider: Provider, name: []const u8, hash: ?[]const u8) SkillRow {
    return .{
        .provider = provider,
        .name = @constCast(name),
        .rel_path = @constCast("x"),
        .agg_hash = if (hash) |h| @constCast(h) else null,
    };
}

test "skill_inventory: buildMatrix unions skills and applies cell rule" {
    const allocator = std.testing.allocator;

    const local_rows = [_]SkillRow{
        row(.claude, "pdf", "h1"),
        row(.claude, "brainstorm", "hb"),
    };
    const web_rows = [_]SkillRow{
        row(.claude, "pdf", "h1"), // matches reference
        row(.claude, "brainstorm", "DIFF"), // differs
        row(.claude, "extra", "hx"), // only on web
    };
    const gpu_rows = [_]SkillRow{
        row(.claude, "pdf", null), // present, no hash -> unknown
    };

    const servers = [_]ServerScan{
        .{ .source_id = "local", .reachable = true, .rows = &local_rows },
        .{ .source_id = "web", .reachable = true, .rows = &web_rows },
        .{ .source_id = "gpu", .reachable = true, .rows = &gpu_rows },
        .{ .source_id = "off", .reachable = false, .rows = &.{} },
    };

    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();

    // Rows are the union, sorted: brainstorm, extra, pdf (claude).
    try std.testing.expectEqual(@as(usize, 3), m.skills.len);
    try std.testing.expectEqualStrings("brainstorm", m.skills[0].name);
    try std.testing.expectEqualStrings("extra", m.skills[1].name);
    try std.testing.expectEqualStrings("pdf", m.skills[2].name);
    try std.testing.expectEqual(@as(usize, 4), m.servers.len);

    // pdf row (index 2): local match, web match (h1 is modal), gpu unknown, off unknown.
    try std.testing.expectEqual(CellState.match, m.cellAt(2, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(2, 1).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(2, 2).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(2, 3).state);

    // brainstorm row (index 0): only local(hb) & web(DIFF) present, single each ->
    // modal tie broken lexicographically: "DIFF" < "hb", so DIFF is reference.
    try std.testing.expectEqual(CellState.differ, m.cellAt(0, 0).state); // local hb != DIFF
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 1).state); // web DIFF == ref
    try std.testing.expectEqual(CellState.absent, m.cellAt(0, 2).state); // gpu reachable, absent
    try std.testing.expectEqual(CellState.unknown, m.cellAt(0, 3).state); // off unreachable

    // extra row (index 1): only on web -> web match, others absent / off unknown.
    try std.testing.expectEqual(CellState.absent, m.cellAt(1, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(1, 1).state);
    try std.testing.expectEqual(CellState.absent, m.cellAt(1, 2).state);
    try std.testing.expectEqual(CellState.unknown, m.cellAt(1, 3).state);
}

test "skill_inventory: uniform row is all match" {
    const allocator = std.testing.allocator;
    const a = [_]SkillRow{row(.codex, "x", "same")};
    const b = [_]SkillRow{row(.codex, "x", "same")};
    const servers = [_]ServerScan{
        .{ .source_id = "a", .reachable = true, .rows = &a },
        .{ .source_id = "b", .reachable = true, .rows = &b },
    };
    var m = try buildMatrix(allocator, &servers);
    defer m.deinit();
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 0).state);
    try std.testing.expectEqual(CellState.match, m.cellAt(0, 1).state);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | tail -15`
Expected: FAIL — `buildMatrix` not defined.

- [ ] **Step 3: Implement `buildMatrix` and helpers**

```zig
fn rowKeyLessThan(_: void, a: RowKey, b: RowKey) bool {
    if (a.provider != b.provider) return @intFromEnum(a.provider) < @intFromEnum(b.provider);
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn sameKey(provider: Provider, name: []const u8, r: SkillRow) bool {
    return r.provider == provider and std.mem.eql(u8, r.name, name);
}

/// Find a server's row for (provider,name); null if absent.
fn findRow(server: ServerScan, provider: Provider, name: []const u8) ?SkillRow {
    for (server.rows) |r| {
        if (sameKey(provider, name, r)) return r;
    }
    return null;
}

/// Modal non-null hash among present servers for one skill; ties broken by the
/// lexicographically smallest hash for determinism. Null if no server has a hash.
fn referenceHash(servers: []const ServerScan, provider: Provider, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_count: usize = 0;
    for (servers) |candidate_server| {
        const cand = findRow(candidate_server, provider, name) orelse continue;
        const ch = cand.agg_hash orelse continue;
        var count: usize = 0;
        for (servers) |s| {
            const r = findRow(s, provider, name) orelse continue;
            const h = r.agg_hash orelse continue;
            if (std.mem.eql(u8, h, ch)) count += 1;
        }
        const replace = best == null or count > best_count or
            (count == best_count and std.mem.order(u8, ch, best.?) == .lt);
        if (replace) {
            best = ch;
            best_count = count;
        }
    }
    return best;
}

pub fn buildMatrix(allocator: std.mem.Allocator, servers: []const ServerScan) !Matrix {
    // 1. Union of (provider,name) keys.
    var keys: std.ArrayListUnmanaged(RowKey) = .empty;
    errdefer {
        for (keys.items) |*k| k.deinit(allocator);
        keys.deinit(allocator);
    }
    for (servers) |s| {
        for (s.rows) |r| {
            var seen = false;
            for (keys.items) |k| {
                if (sameKey(k.provider, k.name, r)) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            const name_copy = try allocator.dupe(u8, r.name);
            errdefer allocator.free(name_copy);
            try keys.append(allocator, .{ .provider = r.provider, .name = name_copy });
        }
    }
    std.sort.insertion(RowKey, keys.items, {}, rowKeyLessThan);

    // 2. Columns.
    const cols = try allocator.alloc(ServerCol, servers.len);
    var cols_init: usize = 0;
    errdefer {
        for (cols[0..cols_init]) |*c| c.deinit(allocator);
        allocator.free(cols);
    }
    for (servers, 0..) |s, i| {
        cols[i] = .{ .source_id = try allocator.dupe(u8, s.source_id), .reachable = s.reachable };
        cols_init += 1;
    }

    // 3. Cells.
    const cells = try allocator.alloc(Cell, keys.items.len * servers.len);
    errdefer allocator.free(cells);
    for (keys.items, 0..) |k, ri| {
        const ref = referenceHash(servers, k.provider, k.name);
        for (servers, 0..) |s, ci| {
            const state: CellState = blk: {
                const r = findRow(s, k.provider, k.name) orelse {
                    break :blk if (s.reachable) .absent else .unknown;
                };
                const h = r.agg_hash orelse break :blk .unknown;
                const reference = ref orelse break :blk .unknown;
                break :blk if (std.mem.eql(u8, h, reference)) .match else .differ;
            };
            cells[ri * servers.len + ci] = .{ .state = state };
        }
    }

    const skills = try keys.toOwnedSlice(allocator);
    return .{ .allocator = allocator, .skills = skills, .servers = cols, .cells = cells };
}
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (both new tests).

- [ ] **Step 5: Commit**

```bash
git add src/skill_inventory.zig
git commit -m "feat(skill-center): buildMatrix union rows + modal-hash cell rule"
```

---

## Phase 3 — `skill_inventory_cache.zig` (persisted last scan)

### Task 7: save/load `[]ServerScan` in the config dir

**Files:**
- Create: `src/skill_inventory_cache.zig`
- Modify: `src/test_fast.zig`, `src/test_main.zig` (register import)

- [ ] **Step 1: Create `src/skill_inventory_cache.zig`**

```zig
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
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

/// Load the cached scans as owned `[]inv.ServerScan` (deep-copied; caller frees
/// with `freeServerScans`). Returns an empty slice when no cache exists.
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
```

> Note: `inv.ServerScan.rows` is `[]const SkillRow` and `source_id` is
> `[]const u8`; `freeServerScans` owns the loaded copies, hence the
> `@constCast` before `free`. The `references the parseFromSlice alias UAF`
> hazard (project memory) is why `load` uses `.allocate = .alloc_always`.

- [ ] **Step 2: Write the failing test (append to `src/skill_inventory_cache.zig`)**

```zig
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
```

- [ ] **Step 3: Register the module**

In `src/test_fast.zig` and `src/test_main.zig` add `_ = @import("skill_inventory_cache.zig");` after the `skill_inventory.zig` import.

- [ ] **Step 4: Run to verify pass**

Run: `zig build test 2>&1 | tail -10`
Expected: PASS. (If `setTestConfigDirForCurrentThread` resolves the cache path differently than `std.fs.cwd()` expects, confirm `pathInConfigDir` returns an absolute path and adjust the `writeFile`/`readFileAlloc` to use it directly — it already does.)

- [ ] **Step 5: Commit**

```bash
git add src/skill_inventory_cache.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(skill-center): persisted scan cache (alloc_always load)"
```

---

## Phase 4 — `skill_center.zig` (scan worker + panel model)

This phase mirrors `AiHistoryScanJob` (background scan, mutex + generation) and the `agent_history` panel model. The orchestration core is a pure `runScan` testable with fake hosts; the threading + real exec-host construction is the thin impure wrapper.

### Task 8: `runScan` over multiple sources (pure orchestration)

**Files:**
- Create: `src/skill_center.zig`
- Modify: `src/test_fast.zig`, `src/test_main.zig`

- [ ] **Step 1: Create `src/skill_center.zig` with `HostFactory` + `runScan`**

```zig
const std = @import("std");
const scan = @import("skill_scan.zig");
const inv = @import("skill_inventory.zig");

/// Source descriptor for a scan column. `id` is the stable column identity;
/// `name` is the display label. `make` returns an `ExecHost` for this source or
/// an error (→ unreachable column). `ctx` is passed back to `make`.
pub const ScanSource = struct {
    id: []const u8,
    name: []const u8,
};

pub const HostFactory = struct {
    ctx: *anyopaque,
    make: *const fn (*anyopaque, std.mem.Allocator, ScanSource) anyerror!scan.ExecHost,
};

/// Scan every source and return owned `[]inv.ServerScan` (free with
/// `skill_inventory_cache.freeServerScans` + free the slice). A source whose
/// host cannot be created, or whose scan reports unreachable, becomes an
/// unreachable column with no rows.
pub fn runScan(
    allocator: std.mem.Allocator,
    sources: []const ScanSource,
    factory: HostFactory,
) ![]inv.ServerScan {
    var out = try allocator.alloc(inv.ServerScan, sources.len);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |s| {
            for (s.rows) |*r| {
                var row = r.*;
                row.deinit(allocator);
            }
            allocator.free(@constCast(s.rows));
            allocator.free(@constCast(s.source_id));
        }
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
        // Transfer ownership of outcome.rows into the ServerScan.
        out[i] = .{ .source_id = id_copy, .reachable = outcome.reachable, .rows = outcome.rows };
        outcome.rows = &.{}; // prevent double-free; ownership moved
        built += 1;
    }

    return out;
}
```

- [ ] **Step 2: Write the failing end-to-end test (append)**

```zig
const inv_cache = @import("skill_inventory_cache.zig");

const ScriptHost = struct {
    // maps source id -> canned output (or null for offline)
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
    // local h1 is modal (single each: h1 vs DIFF -> tie, "DIFF" < "h1" wins as ref)
    try std.testing.expectEqual(inv.CellState.differ, m.cellAt(0, 0).state); // local h1 != DIFF
    try std.testing.expectEqual(inv.CellState.match, m.cellAt(0, 1).state); // web DIFF == ref
    try std.testing.expectEqual(inv.CellState.unknown, m.cellAt(0, 2).state); // off
}
```

> The `ScriptHost` is intentionally crude (uses the 5-char id as a tag). Keep
> source ids in the test exactly 5 chars (`local`, `webxx`) so the slice is valid.

- [ ] **Step 3: Register + run to verify failure then pass**

Add `_ = @import("skill_center.zig");` to `src/test_main.zig` (NOT `test_fast.zig` — `skill_center` will later import `ai_history_session`/threads, which belong in the full suite). For now it only imports the pure modules, so the fast suite would also work, but keep it in `test_main` to avoid churn when the impure worker lands.

Run: `zig build test-full 2>&1 | tail -15`
Expected: FAIL first (no `runScan`), then PASS after Step 1.

- [ ] **Step 4: Commit**

```bash
git add src/skill_center.zig src/test_main.zig
git commit -m "feat(skill-center): runScan orchestration + matrix end-to-end test"
```

### Task 9: Real `HostFactory` (local/WSL/SSH) + background worker + panel model

**Files:**
- Modify: `src/skill_center.zig`

This task has no new unit tests (it wires real connections + threads, validated by build + manual GUI). Mirror these existing symbols:

- **Exec hosts:** `src/ai_history_session.zig` builds `RemoteExecHost` for local (`remote_file` local exec), WSL (`remote_file.wslExec`), and SSH (`remote_file.sshExecCapture` over `ssh_connection.SshConnection`). `scan.ExecHost` is the same shape `{ ctx, exec }` — adapt each by wrapping the same exec fn pointer. The real `HostFactory.make` switches on the source's `ai_history_source.Target` and returns the matching `scan.ExecHost`.
- **Source enumeration:** reuse the same builder the Sessions panel uses to list local + WSL distros + SSH profiles (the code path feeding `ai_history_source.Source`). Map each to a `ScanSource { id = Source.id, name = Source.name }`.
- **Background worker:** copy the shape of `AiHistoryScanJob` in `src/ai_history_session.zig` (search `ScanJob`): a struct holding `allocator`, `mutex: std.Thread.Mutex`, `closing: bool`, `generation: u64`, and the result `[]inv.ServerScan`. Spawn a thread that calls `runScan`, then under the mutex (if generation unchanged and not closing) swaps in the new results, rebuilds the `Matrix`, and persists via `inv_cache.save`. `deinit` sets `closing`, joins the thread, frees results + matrix.

- [ ] **Step 1: Add `PanelModel`**

```zig
const inv_cache = @import("skill_inventory_cache.zig");

pub const PanelModel = struct {
    allocator: std.mem.Allocator,
    servers: []inv.ServerScan = &.{},
    matrix: ?inv.Matrix = null,
    sel_row: usize = 0,
    sel_col: usize = 0,
    scroll: usize = 0,
    status: []u8 = &.{}, // e.g. "Scanning… 2/5"
    stale: bool = false, // true while showing cache before first live scan lands

    pub fn init(allocator: std.mem.Allocator) PanelModel {
        return .{ .allocator = allocator };
    }

    /// Seed from cache so the panel renders immediately; mark stale.
    pub fn seedFromCache(self: *PanelModel) void {
        const cached = inv_cache.load(self.allocator) catch return;
        if (cached.len == 0) {
            self.allocator.free(cached);
            return;
        }
        self.setServers(cached);
        self.stale = true;
    }

    /// Take ownership of a fresh `[]inv.ServerScan`, rebuild the matrix.
    pub fn setServers(self: *PanelModel, servers: []inv.ServerScan) void {
        self.freeServers();
        self.servers = servers;
        if (self.matrix) |*m| m.deinit();
        self.matrix = inv.buildMatrix(self.allocator, servers) catch null;
        self.clampSelection();
    }

    fn clampSelection(self: *PanelModel) void {
        const m = self.matrix orelse return;
        if (m.skills.len == 0) {
            self.sel_row = 0;
        } else if (self.sel_row >= m.skills.len) {
            self.sel_row = m.skills.len - 1;
        }
        if (m.servers.len == 0) {
            self.sel_col = 0;
        } else if (self.sel_col >= m.servers.len) {
            self.sel_col = m.servers.len - 1;
        }
    }

    fn freeServers(self: *PanelModel) void {
        if (self.servers.len != 0) {
            inv_cache.freeServerScans(self.allocator, self.servers);
            self.allocator.free(self.servers);
            self.servers = &.{};
        }
    }

    pub fn deinit(self: *PanelModel) void {
        if (self.matrix) |*m| m.deinit();
        self.freeServers();
        if (self.status.len != 0) self.allocator.free(self.status);
        self.* = undefined;
    }
};
```

- [ ] **Step 2: Add the worker struct mirroring `AiHistoryScanJob`**

Implement `ScanJob` per the bullet above. (Read `AiHistoryScanJob` first and copy its mutex/closing/generation discipline verbatim, substituting `runScan` for the history scan and `PanelModel.setServers` for the row sink.) The job, on completion, also calls `inv_cache.save(allocator, servers)` and clears `model.stale`.

- [ ] **Step 3: Build**

Run: `zig build 2>&1 | tail -15`
Expected: compiles. Run `zig build test-full 2>&1 | tail -5` — still green.

- [ ] **Step 4: Commit**

```bash
git add src/skill_center.zig
git commit -m "feat(skill-center): real host factory, scan worker, panel model"
```

---

## Phase 5 — UI: renderer, AppWindow wiring, entry point, i18n

These tasks are GUI integration; verify by build + `test-full` (logic) and manual GUI check (no Linux GUI backend, so GUI verify is on macOS/Windows, consistent with prior features).

### Task 10: `skill_center_renderer.zig`

**Files:**
- Create: `src/renderer/skill_center_renderer.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1:** Read `src/renderer/ai_history_renderer.zig` and mirror its `DrawContext` + `render` entry. Render: a header (`N servers · M skills`, stale badge, status string), a column header row of server names (truncated/abbreviated), then one row per `matrix.skills[i]` with a `provider` tag + name, and one glyph per server cell: `match→✓`, `differ→≠`, `absent→✗`, `unknown→?`. Highlight the focused cell (`sel_row`,`sel_col`). Draw a legend line. Reuse the same glyph/color helpers the history renderer uses.

- [ ] **Step 2:** Build: `zig build 2>&1 | tail -15` — compiles.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/skill_center_renderer.zig src/AppWindow.zig
git commit -m "feat(skill-center): matrix renderer"
```

### Task 11: AppWindow tab kind + open/render/key routing

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1:** Mirror every `.ai_history` touch-point for a new `.skill_center` tab kind:
  - Add the tab-kind enum case + a `skill_center_model: ?*skill_center.PanelModel` field on `TabState` (cf. `ai_history_session: ?*...` at `AppWindow.zig:409`, init at the struct's defaults).
  - `openSkillCenter()`: create the tab, init `PanelModel`, call `seedFromCache`, spawn the `ScanJob`. Model after the function that opens AI History.
  - `renderSkillCenterFrame(...)`: clone `renderAiHistoryFrame` (`AppWindow.zig:772`) → call `skill_center_renderer.render`.
  - Add `activeSkillCenter()` mirroring `activeAiHistory()` (`AppWindow.zig:900`).
  - Key routing: arrows move `sel_row`/`sel_col`, `Enter` opens the preview (next task), `r` triggers a manual rescan (new `ScanJob`, bump generation). Mirror the AI History key handlers (`AppWindow.zig:907-940`).
  - `deinit` path: free the `PanelModel` + join the job where the tab is torn down (mirror the `ai_history_session` cleanup).

- [ ] **Step 2:** Build + full suite: `zig build && zig build test-full 2>&1 | tail -5` — green.

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(skill-center): AppWindow tab kind, open, render, key routing"
```

### Task 12: Cell preview (cat SKILL.md from the focused cell's server)

**Files:**
- Modify: `src/skill_center.zig`, `src/AppWindow.zig`

- [ ] **Step 1:** Add `pub fn previewCommand(allocator, rel_path) ![]u8` to `skill_center.zig` returning `cat '<rel_path-from-$HOME>'` — specifically `std.fmt.allocPrint(allocator, "cat \"$HOME/{s}\"", .{rel_path})`. Add a unit test asserting the string. (`rel_path` is the row's path for the *focused server's* copy — look it up via `findRow`-style match on `servers[sel_col]`.)

```zig
test "skill_center: previewCommand cats the rel path under HOME" {
    const allocator = std.testing.allocator;
    const cmd = try previewCommand(allocator, ".claude/skills/pdf/SKILL.md");
    defer allocator.free(cmd);
    try std.testing.expectEqualStrings("cat \"$HOME/.claude/skills/pdf/SKILL.md\"", cmd);
}
```

- [ ] **Step 2:** In `AppWindow.zig`, on `Enter` over a present cell, run `previewCommand` through the same `ExecHost` for `servers[sel_col]` and show the result in the existing markdown preview panel (reuse the path Sessions uses to preview a transcript / the `markdown_preview_panel`). For an `absent`/`unknown` cell, no-op (optionally a toast).

- [ ] **Step 3:** Build + test-full: `zig build && zig build test-full 2>&1 | tail -5` — green (incl. the new preview test).

- [ ] **Step 4: Commit**

```bash
git add src/skill_center.zig src/AppWindow.zig
git commit -m "feat(skill-center): preview focused cell's SKILL.md"
```

### Task 13: Command-center entry + i18n

**Files:**
- Modify: `src/command_center_state.zig`, `src/i18n.zig`, `src/AppWindow.zig`

- [ ] **Step 1:** Add i18n keys to `src/i18n.zig` (en + zh-CN), following the `sl_sessions`/`sl_sessions_detail` pattern (project memory: "Copilot + Sessions rename"):
  - `sl_skill_center` = "Skill Center" / "技能中心"
  - `sl_skill_center_detail` = "Inventory Claude Code / Codex skills across servers" / "盘点各服务器上的 Claude Code / Codex 技能"

- [ ] **Step 2:** Add a command-center launcher row that calls `AppWindow.openSkillCenter()`, mirroring the AI History row (`command_center_state.zig:106` `SESSION_LAUNCHER_ROW_AI_HISTORY` and its visibility flags). Wire its action in `AppWindow.zig` where other launcher rows dispatch.

- [ ] **Step 3:** Build + both suites: `zig build && zig build test 2>&1 | tail -3 && zig build test-full 2>&1 | tail -3` — green.

- [ ] **Step 4: Commit**

```bash
git add src/command_center_state.zig src/i18n.zig src/AppWindow.zig
git commit -m "feat(skill-center): command-center entry + i18n keys"
```

---

## Phase 6 — Final verification

### Task 14: Full build + suites + manual smoke

- [ ] **Step 1:** `zig build 2>&1 | tail -5` — clean build.
- [ ] **Step 2:** `zig build test 2>&1 | tail -5` — fast suite green.
- [ ] **Step 3:** `zig build test-full 2>&1 | tail -5` — full suite green, 0 failed.
- [ ] **Step 4 (cross-compile sanity, matches project habit):** `zig build -Dtarget=x86_64-windows-gnu 2>&1 | tail -5` — compiles.
- [ ] **Step 5 (manual, GUI host):** open Skill Center from the command center; confirm: cached results show instantly, `Scanning… N/M` advances, matrix shows `✓/≠/✗/?`, an offline SSH profile renders `?` columns, `Enter` on a present cell previews its SKILL.md, `r` rescans.
- [ ] **Step 6: Commit** any fixups found during smoke.

```bash
git add -A
git commit -m "test(skill-center): final verification fixups"
```

---

## Self-Review notes (addressed)

- **Spec coverage:** matrix view (Task 6), all-known-sources columns (Task 9), Claude+Codex targets incl. `.codex/prompts` (Task 1), whole-dir aggregate hash (Task 3), modal ✓/≠ + `?`≠`✗` rule (Task 6), background-async + persisted cache (Tasks 3/7/9), `sha256sum`-absent → presence-only (Tasks 3 hash field empty → null → `?`), preview (Task 12), entry+i18n (Task 13). Out-of-scope items (pull/push/sync) intentionally absent.
- **Type consistency:** `SkillRow{provider,name,rel_path,agg_hash}` used identically in scan/inventory/cache/center; `CellState{match,differ,absent,unknown}`; `ServerScan{source_id,reachable,rows}`; `ExecHost{ctx,exec}` shared shape with `ai_history_session.RemoteExecHost`.
- **Known v1 limitations (acceptable):** skill names with spaces/newlines break the `find|sort|xargs` aggregate hash (rare); description not shown in the matrix (only in preview); project/plugin skill dirs out of scope.
