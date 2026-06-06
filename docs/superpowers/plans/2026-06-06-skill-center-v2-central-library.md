# Skill Center v2 (central library + machine×software targets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Reshape the Skill Center from "local-claude ⇆ remote (provider-locked)" into "a wispterm **library** (`<config>/skills/`) you deploy to / import from any **target = machine × software (claude/codex)**, chosen via a popup picker."

**Architecture:** Generalize the existing tar transfer + scan to take an explicit shell **root expression** per location (library = local `<config>/skills`; target = `$HOME/.claude/skills` or `$HOME/.codex/skills` on local or a server). The panel lists library skills; `d` deploys (picker → confirm/diff → tar), `i` imports (picker → target list → tar). Reuse `skill_diff`, the confirm overlay, and the tar/scp primitives. Spec: `docs/superpowers/specs/2026-06-06-skill-center-v2-central-library-design.md`.

**Tech Stack:** Zig (std-only pure modules), POSIX tar + OpenSSH scp/ssh, the project's pure/impure split + i18n.

---

## Conventions (same as v1.5)

- Pure module inner loop: `zig test src/<file>.zig`.
- Gate before each commit: `zig build test` (links on macOS now; ~838 tests pass before this work).
- Integration tasks (AppWindow/input): also `zig build -Dtarget=aarch64-macos macos-app` to confirm the GUI graph compiles+links.
- Commit after each task. Branch `worktree-feat-skill-center`.
- **Keep `SkillRow.provider`** (set to a constant in v2 scans) to avoid churning the cache/inventory serialization — v2 keys skills by **name** within a location and ignores provider in the UI.

---

## Task 1: Generalize `skill_transfer_cmd.zig` to an explicit root expression

The tar builders currently prefix `"$HOME"/<root_rel>`. v2 roots can be an absolute library path or a `$HOME`-relative target. Make the root a caller-supplied **shell expression** and take the skill **name** directly (no more `splitSkillPath` for transfer).

**Files:** Modify `src/skill_transfer_cmd.zig`.

- [ ] **Step 1: Replace the builders + tests.** Replace the bodies of `tarCreateCmd`/`tarExtractCmd` (currently `(allocator, root_rel, item, tmp)` that emit `-C "$HOME"/'<root_rel>'`) with versions taking a ready `root_expr` and the item name:

```zig
/// `tar -czf '<tmp>' -C <root_expr> '<name>'`. `root_expr` is a caller-built
/// shell expression for the skills root (e.g. `"$HOME"/.claude/skills` or a
/// single-quoted absolute library path). `name` is the skill dir/file name.
pub fn tarCreateCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "tar -czf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C ");
    try buf.appendSlice(allocator, root_expr);
    try buf.append(allocator, ' ');
    try appendQuoted(&buf, allocator, name);
    return buf.toOwnedSlice(allocator);
}

/// Stage-then-swap extract of <tmp> into <root_expr>, atomically replacing
/// <root_expr>/<name>. A failed extract leaves the live skill untouched.
pub fn tarExtractCmd(allocator: std.mem.Allocator, root_expr: []const u8, name: []const u8, tmp: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "D=");
    try buf.appendSlice(allocator, root_expr);
    try buf.appendSlice(allocator, "; mkdir -p \"$D\"; S=\"$D/.wisptmp.$$\"; rm -rf \"$S\"; mkdir -p \"$S\"; ");
    try buf.appendSlice(allocator, "tar -xzf ");
    try appendQuoted(&buf, allocator, tmp);
    try buf.appendSlice(allocator, " -C \"$S\" && rm -rf \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " && mv \"$S\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, " \"$D\"/");
    try appendQuoted(&buf, allocator, name);
    try buf.appendSlice(allocator, "; rm -rf \"$S\"");
    return buf.toOwnedSlice(allocator);
}
```

Add a helper to build the `$HOME`-relative target root expression (used by callers):

```zig
/// Shell expression for a target software root under $HOME, e.g.
/// homeRootExpr(".claude/skills") → `"$HOME"/'.claude/skills'`.
pub fn homeRootExpr(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "\"$HOME\"/");
    try appendQuoted(&buf, allocator, rel);
    return buf.toOwnedSlice(allocator);
}

/// Shell expression for an absolute root (the local library), single-quoted.
pub fn absRootExpr(allocator: std.mem.Allocator, abs: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendQuoted(&buf, allocator, abs);
    return buf.toOwnedSlice(allocator);
}
```

Keep `splitSkillPath` (still used to derive a `name` from a `rel_path` like `.../<name>/SKILL.md` when parsing scan output). Replace the tests:

```zig
test "skill_transfer_cmd: homeRootExpr + tarCreateCmd for a $HOME target" {
    const a = std.testing.allocator;
    const root = try homeRootExpr(a, ".claude/skills");
    defer a.free(root);
    try std.testing.expectEqualStrings("\"$HOME\"/'.claude/skills'", root);
    const cmd = try tarCreateCmd(a, root, "pdf", "/tmp/x.tgz");
    defer a.free(cmd);
    try std.testing.expectEqualStrings("tar -czf '/tmp/x.tgz' -C \"$HOME\"/'.claude/skills' 'pdf'", cmd);
}

test "skill_transfer_cmd: absRootExpr + tarExtractCmd for the local library" {
    const a = std.testing.allocator;
    const root = try absRootExpr(a, "/cfg/skills");
    defer a.free(root);
    const cmd = try tarExtractCmd(a, root, "pdf", "/tmp/x.tgz");
    defer a.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "D='/cfg/skills'") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "tar -xzf '/tmp/x.tgz' -C \"$S\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "mv \"$S\"/'pdf' \"$D\"/'pdf'") != null);
}

test "skill_transfer_cmd: splitSkillPath still derives a name" {
    const sp = splitSkillPath(".claude/skills/roundtable/SKILL.md").?;
    try std.testing.expectEqualStrings("roundtable", sp.item);
}
```

- [ ] **Step 2:** `zig test src/skill_transfer_cmd.zig` → PASS.
- [ ] **Step 3:** `zig build test` → PASS (transfer.zig will break until Task 2 — if so, do Tasks 1+2 before the gate; run the gate after Task 2). Note: it's fine to defer the aggregated gate to the end of Task 2 since `skill_transfer.zig` calls these.
- [ ] **Step 4: Commit** `git add src/skill_transfer_cmd.zig && git commit -m "refactor(skill-center): tar builders take an explicit root expression"`

---

## Task 2: Generalize `skill_transfer.zig` to location→location (local & remote)

The library is always local; the target is local or remote. Replace the `upload`/`download` pair with a single `transfer` over two endpoints, each `{ root_expr, is_local }`, where exactly the local↔local case skips the scp hop.

**Files:** Modify `src/skill_transfer.zig`.

- [ ] **Step 1: Replace `upload`/`download` with `transfer`.**

```zig
pub const Result = enum { ok, failed };

pub const Endpoint = struct {
    root_expr: []const u8, // shell root expression on its host
    is_local: bool,        // true → run via localExec; false → remoteExec + scp
};

pub const Ops = struct {
    ctx: *anyopaque,
    localExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    remoteExec: *const fn (*anyopaque, std.mem.Allocator, []const u8) bool,
    /// Copy the tarball between local and the remote endpoint.
    /// dir = .to_remote: local_tmp → remote_tmp; .to_local: remote_tmp → local_tmp.
    copy: *const fn (*anyopaque, std.mem.Allocator, CopyDir, []const u8, []const u8) bool,
};
pub const CopyDir = enum { to_remote, to_local };

const LOCAL_TMP = "/tmp/.wispterm-skill.tgz";
const REMOTE_TMP = "/tmp/.wispterm-skill.tgz";

/// Copy skill `name` from `from` to `to`. Exactly one of from/to may be remote
/// (the library is always local). Returns .ok only if every step succeeds.
pub fn transfer(allocator: std.mem.Allocator, ops: Ops, from: Endpoint, to: Endpoint, name: []const u8) Result {
    // create the tarball on the source host
    const src_tmp = if (from.is_local) LOCAL_TMP else REMOTE_TMP;
    const make = cmd.tarCreateCmd(allocator, from.root_expr, name, src_tmp) catch return .failed;
    defer allocator.free(make);
    const make_ok = if (from.is_local) ops.localExec(ops.ctx, allocator, make) else ops.remoteExec(ops.ctx, allocator, make);
    if (!make_ok) return .failed;

    // move the tarball to the dest host (only when crossing the local/remote boundary)
    const dst_tmp = if (to.is_local) LOCAL_TMP else REMOTE_TMP;
    if (from.is_local != to.is_local) {
        const copy_ok = if (to.is_local)
            ops.copy(ops.ctx, allocator, .to_local, LOCAL_TMP, REMOTE_TMP)
        else
            ops.copy(ops.ctx, allocator, .to_remote, LOCAL_TMP, REMOTE_TMP);
        if (!copy_ok) return .failed;
    }

    // extract on the dest host
    const extract = cmd.tarExtractCmd(allocator, to.root_expr, name, dst_tmp) catch return .failed;
    defer allocator.free(extract);
    const extract_ok = if (to.is_local) ops.localExec(ops.ctx, allocator, extract) else ops.remoteExec(ops.ctx, allocator, extract);
    if (!extract_ok) return .failed;

    // best-effort tmp cleanup
    _ = ops.localExec(ops.ctx, allocator, "rm -f '" ++ LOCAL_TMP ++ "'");
    if (!from.is_local or !to.is_local) _ = ops.remoteExec(ops.ctx, allocator, "rm -f '" ++ REMOTE_TMP ++ "'");
    return .ok;
}
```

> Note: when both endpoints are local, `src_tmp == dst_tmp == LOCAL_TMP` and no copy runs — a pure local tar+extract. When crossing, local uses LOCAL_TMP and remote uses REMOTE_TMP, bridged by `copy`.

- [ ] **Step 2: Replace the tests** (Recorder fake as before; add a local→local case and a local→remote case):

```zig
test "skill_transfer: local→local deploy does tar+extract, no copy" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    const to = Endpoint{ .root_expr = "\"$HOME\"/'.claude/skills'", .is_local = true };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 0), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[1], "tar -xzf") != null);
}

test "skill_transfer: local→remote deploy does create-local, copy, extract-remote" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    const to = Endpoint{ .root_expr = "\"$HOME\"/'.codex/skills'", .is_local = false };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.local_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.remote_cmds.items[0], "tar -xzf") != null);
}

test "skill_transfer: remote→local import does create-remote, copy, extract-local" {
    const a = std.testing.allocator;
    var rec = Recorder{ .allocator = a };
    defer rec.deinit();
    const from = Endpoint{ .root_expr = "\"$HOME\"/'.claude/skills'", .is_local = false };
    const to = Endpoint{ .root_expr = "'/cfg/skills'", .is_local = true };
    try std.testing.expectEqual(Result.ok, transfer(a, rec.ops(), from, to, "pdf"));
    try std.testing.expectEqual(@as(usize, 1), rec.copies);
    try std.testing.expect(std.mem.startsWith(u8, rec.remote_cmds.items[0], "tar -czf"));
    try std.testing.expect(std.mem.indexOf(u8, rec.local_cmds.items[0], "tar -xzf") != null);
}
```

The `Recorder` `copy` fn signature changes to `(ctx, allocator, CopyDir, []const u8, []const u8) bool`.

- [ ] **Step 3:** `zig test src/skill_transfer.zig` → PASS, no leaks.
- [ ] **Step 4:** `zig build test` → PASS (now both transfer modules compile).
- [ ] **Step 5: Commit** `git add src/skill_transfer.zig && git commit -m "refactor(skill-center): single transfer() over local/remote endpoints"`

---

## Task 3: `skill_scan.zig` — scan one location by root expression

**Files:** Modify `src/skill_scan.zig`.

- [ ] **Step 1: Add a location scan command + runner.** Add (keep existing functions intact):

```zig
/// Build a command that lists+hashes skill dirs directly under `root_expr`,
/// printing `name \t <name>/SKILL.md \t hash` per skill. Same hash recipe as the
/// skill_md target block, so a library skill and a target skill with identical
/// content hash equal. Missing root prints nothing.
pub fn buildLocationScanCommand(allocator: std.mem.Allocator, root_expr: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\HASHCMD="";
        \\if command -v sha256sum >/dev/null 2>&1; then HASHCMD="sha256sum";
        \\elif command -v shasum >/dev/null 2>&1; then HASHCMD="shasum -a 256"; fi;
        \\R={s};
        \\if [ -d "$R" ]; then for d in "$R"/*/; do
        \\[ -f "${{d}}SKILL.md" ] || continue;
        \\n=$(basename "$d");
        \\if [ -n "$HASHCMD" ]; then h=$(cd "$d" && find . -type f | LC_ALL=C sort | xargs $HASHCMD | $HASHCMD | cut -d' ' -f1); else h=""; fi;
        \\printf '%s\t%s/SKILL.md\t%s\n' "$n" "$n" "$h";
        \\done; fi;
        \\
    , .{root_expr});
}

/// Parse `name \t rel \t hash` lines into rows (provider forced to .claude — v2
/// keys by name; provider is unused). Blank/short lines skipped; empty hash → null.
pub fn parseLocationOutput(allocator: std.mem.Allocator, bytes: []const u8) ![]SkillRow {
    var rows: std.ArrayListUnmanaged(SkillRow) = .empty;
    errdefer { for (rows.items) |*r| r.deinit(allocator); rows.deinit(allocator); }
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse continue;
        const rel = f.next() orelse continue;
        const hash = f.next() orelse continue;
        if (name.len == 0 or rel.len == 0) continue;
        const name_c = try allocator.dupe(u8, name);
        errdefer allocator.free(name_c);
        const rel_c = try allocator.dupe(u8, rel);
        errdefer allocator.free(rel_c);
        const hash_c: ?[]u8 = if (hash.len == 0) null else try allocator.dupe(u8, hash);
        try rows.append(allocator, .{ .provider = .claude, .name = name_c, .rel_path = rel_c, .agg_hash = hash_c });
    }
    return rows.toOwnedSlice(allocator);
}

/// Run the location scan on a host. exec error → reachable=false.
pub fn scanLocation(allocator: std.mem.Allocator, root_expr: []const u8, host: ExecHost) !ScanOutcome {
    const command = try buildLocationScanCommand(allocator, root_expr);
    defer allocator.free(command);
    const out = host.exec(host.ctx, allocator, command) catch return .{ .reachable = false, .rows = &.{} };
    defer allocator.free(out);
    const rows = try parseLocationOutput(allocator, out);
    return .{ .reachable = true, .rows = rows };
}
```

- [ ] **Step 2: Tests:**

```zig
test "skill_scan: buildLocationScanCommand roots at the expression" {
    const a = std.testing.allocator;
    const cmd = try buildLocationScanCommand(a, "'/cfg/skills'");
    defer a.free(cmd);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "R='/cfg/skills';") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "SKILL.md") != null);
}

test "skill_scan: parseLocationOutput parses name/rel/hash" {
    const a = std.testing.allocator;
    const rows = try parseLocationOutput(a, "pdf\tpdf/SKILL.md\tabc\n\ngarbage\nfoo\tfoo/SKILL.md\t\n");
    defer freeRows(a, rows);
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("pdf", rows[0].name);
    try std.testing.expectEqualStrings("abc", rows[0].agg_hash.?);
    try std.testing.expectEqual(@as(?[]u8, null), rows[1].agg_hash);
}
```

- [ ] **Step 3:** `zig test src/skill_scan.zig` → PASS. **Step 4:** `zig build test` → PASS. **Step 5: Commit** `git add src/skill_scan.zig && git commit -m "feat(skill-center): scan one location by root expression"`

---

## Task 4: v2 model in `skill_center.zig`

Replace the pairing/server model with a **library list** + a **target picker** + per-action decision logic. Keep `Session`/`ScanWork` threading and the confirm fields.

**Files:** Modify `src/skill_center.zig`.

- [ ] **Step 1: Define the v2 types + model.** Replace `PanelModel`'s server/pairing fields with:

```zig
const scan = @import("skill_scan.zig");

pub const Software = enum {
    claude,
    codex,
    pub fn rootRel(self: Software) []const u8 {
        return switch (self) { .claude => ".claude/skills", .codex => ".codex/skills" };
    }
};

/// A deploy/import destination = a machine × a software root.
pub const Target = struct {
    machine_id: []const u8, // "local" or "ssh:<profile>"  (owned)
    machine_label: []const u8, // display (owned)
    software: Software,
    is_local: bool,
};

pub const LibrarySkill = struct {
    name: []u8,
    rel_path: []u8,
    agg_hash: ?[]u8,
    pub fn deinit(self: *LibrarySkill, a: std.mem.Allocator) void {
        a.free(self.name); a.free(self.rel_path); if (self.agg_hash) |h| a.free(h); self.* = undefined;
    }
};

pub const Decision = enum { direct, confirm, noop };
/// Given the target's existing hash for a name (null = absent) vs the source
/// hash, decide. null source hash or null target hash with presence → confirm.
pub fn overwriteDecision(target_present: bool, target_hash: ?[]const u8, src_hash: ?[]const u8) Decision {
    if (!target_present) return .direct;
    const th = target_hash orelse return .confirm;
    const sh = src_hash orelse return .confirm;
    return if (std.mem.eql(u8, th, sh)) .noop else .confirm;
}
```

`PanelModel` v2 fields: `allocator`, `library: ?[]LibrarySkill = null`, `sel_row`, `scroll`, plus the existing `confirm_text/confirm_dir(replace with a v2 pending-action)/confirm_rel_path` → generalize the confirm to carry a pending `{ Target, name, is_import }`. Keep `setLibrary`/`freeLibrary`/`clampSelection`/`deinit` analogous to the old `setServers`/`freeServers`. Write tests for `overwriteDecision` (absent→direct, equal→noop, differ→confirm, null hash→confirm) and `setLibrary`/clamp.

> The picker/import-list overlay STATE lives in the model too, but its data (the candidate target list, the scanned import list) is built by AppWindow and handed in; the model just holds the current overlay enum + selection index. Define:
> `pub const Overlay = union(enum) { none, picker: PickerState, import_list: ImportState, confirm: ConfirmState, busy: []const u8 };` where `PickerState = struct { entries: [][]u8 (owned labels), sel: usize, purpose: enum{deploy,import} }` and `ImportState = struct { target: Target, rows: []ImportRow, sel: usize }`, `ImportRow = struct { name, marker: enum{new,same,differ} }`. Provide `setOverlay`/`clearOverlay` that free owned overlay data. Test set/clear frees cleanly (no leaks under testing allocator).

- [ ] **Step 2:** `zig test src/skill_center.zig` → PASS (rewrite/adapt the existing tests that referenced pairing/servers to the library model; delete obsolete pairing-based model tests).
- [ ] **Step 3:** `zig build test` → may fail until renderer+AppWindow updated (Tasks 5-7). Run `zig test src/skill_center.zig` as the authoritative check here; defer the full gate to Task 7.
- [ ] **Step 4: Commit** `git add src/skill_center.zig && git commit -m "feat(skill-center): v2 library model + target/overwrite logic"`

---

## Task 5: Rewrite the renderer (library list + overlays + i18n)

**Files:** Modify `src/renderer/skill_center_renderer.zig`.

- [ ] **Step 1: New `View` + render.** The View carries the library rows, selection, header counts, and a rendered overlay description (so the renderer stays pure — AppWindow flattens overlay data into display strings):

```zig
pub const View = struct {
    skills: []const Row,        // Row { name: []const u8 }
    sel_row: usize,
    scroll: usize,
    status: []const u8,
    overlay: Overlay,           // none | list | confirm
};
pub const Row = struct { name: []const u8 };
pub const Overlay = union(enum) {
    none,
    /// A generic selectable list (used for the target picker AND the import list).
    list: struct { title: []const u8, items: []const ListItem, sel: usize },
    confirm: []const u8, // confirm bar text
};
pub const ListItem = struct { label: []const u8, marker: []const u8 }; // marker "" for picker
```

Render: header `i18n.s().sl_skill_center` + ` · ` + library count; the skill list (single column of names, selection highlight, scroll); the legend (`i18n.s().sc_legend_v2` — see Task 6); and when `overlay != .none`, draw a centered panel over the list: a titled box with the items (selection highlight + optional marker), or the confirm bar. Reuse `mixColor`, height helpers, `clampScroll`, `bodyVisibleCapacity` (rename/keep). Add `localGlyph`/`remoteGlyph`/`hintFor`/`colorForRelation`/provider color — **remove** (no longer used).

- [ ] **Step 2: Tests** for the pure helpers you keep (clampScroll, bodyVisibleCapacity) and a small marker→glyph mapping if any. Keep them runnable via `zig build test`.
- [ ] **Step 3:** `zig build test` (after Task 7 it's green; for now `zig test` can't run this file standalone due to the `../i18n.zig` import — rely on the Task 7 gate). **Step 4: Commit** with AppWindow in Task 7, OR commit renderer alone if it compiles in isolation via the app build. Prefer committing renderer + AppWindow together in Task 7 to keep the build green.

> Because the renderer's only caller is AppWindow and the View shape changes, **do Tasks 5, 6, 7 as one green commit** (the renderer can't compile-gate alone). Implement 5+6+7, then run `zig build test` + `macos-app`, then commit once.

---

## Task 6: i18n keys for v2

**Files:** Modify `src/i18n.zig`.

- [ ] **Step 1:** Add (struct + both `en` and `zh_CN`): `sc_legend_v2` (e.g. en "[⏎] preview   [d] deploy   [i] import   [r] rescan", zh "[⏎] 预览   [d] 部署   [i] 导入   [r] 重新扫描"); `sc_pick_machine` ("Pick a machine" / "选择机器"); `sc_pick_software` ("Pick software" / "选择软件"); `sc_import_pick` ("Pick a skill to import" / "选择要导入的技能"); `sc_sw_claude` ("Claude Code"); `sc_sw_codex` ("Codex"); `sc_local_machine` ("local" / "本地"); `sc_marker_new`/`sc_marker_same`/`sc_marker_differ` ("new"/"same"/"differs" ; "新"/"一致"/"不同"); `sc_deployed`/`sc_imported` toasts. Reuse the existing `sc_toast_*`, `sc_overwrite_*`, `sc_confirm_suffix`, `sc_local` where still apt; **remove** any v1.5 keys that are now unused (`sc_hint_*`, `sc_legend`, `sc_no_server`, `sc_offline`, `sc_cached`) only if nothing references them — grep first.
- [ ] **Step 2:** (gate runs in Task 7).

---

## Task 7: AppWindow wiring + input (the integration)

**Files:** Modify `src/AppWindow.zig`, `src/input.zig`. Build green here.

- [ ] **Step 1: Library scan.** Replace `buildSkillCenterSources`/`SkillCenterScanJob` with a **library scan**: root = `skill_transfer_cmd.absRootExpr(dirs.pathInConfigDir("skills"))`, exec = local; run `skill_scan.scanLocation` on the worker thread; publish into `model.library`. Keep the `Session`/`scanAsync`/`finishScan` shape (rename `finishScan` payload to `[]LibrarySkill`). On open, scan the library.

- [ ] **Step 2: Target enumeration + picker.** `skillCenterTargets(allocator) -> [][]u8` builds picker labels: for each machine in {local, each ssh profile} × each software {Claude Code, Codex} → a label like `"local · Claude Code"`. Store the parallel `[]Target` for resolution. `d` opens the picker overlay (purpose=deploy); `i` opens it (purpose=import). Picker keys (`↑/↓/⏎/esc`) handled via new `skillCenterOverlayMove/Select/Cancel` fns.

- [ ] **Step 3: Deploy flow.** On picker-select with purpose=deploy: resolve `Target`; scan that one target (`scanLocation` with the software root on the machine's exec) to get its hash for the selected library skill; `overwriteDecision`; then noop-toast / direct-transfer / arm confirm. Transfer = `skill_transfer.transfer(ops, from=library endpoint(local), to=target endpoint, name)` synchronously (UI thread, like v1.5), then rescan library. The `Ops` adapter = the v1.5 `SkillTransferCtx` generalized: `localExec=localPosixExecOk`, `remoteExec` via `sshExecCapture` against the target conn (only used when target remote), `copy` via `scp.transfer`. For a **local** target, `is_local=true` and no conn/scp is needed.

- [ ] **Step 4: Import flow.** On picker-select with purpose=import: scan the target; build the import-list overlay (each target skill marked new/same/differ vs the library by name+hash); on select: `transfer(ops, from=target endpoint, to=library endpoint(local), name)` with overwrite-confirm if the library has a differing same-name; rescan library.

- [ ] **Step 5: Preview.** `skillCenterPreviewSelected` → `cat` the selected **library** skill's SKILL.md (root = library, name) via `localPosixExec`, `markdown_preview_panel.open(.markdown, name, "SKILL.md", text)`. (No remote side; library is local.)

- [ ] **Step 6: input.zig keys.** In the skill-center block: `↑/↓` move (list or overlay depending on overlay state); `⏎` = overlay-select if overlay active else preview; `esc` = overlay-cancel; `d`=0x44 deploy; `i`=0x49 import; `r`=0x52 rescan. (Drop `s`/`u`. Confirm proceed/cancel reuse the existing confirm fns, now triggered from the confirm overlay.)

- [ ] **Step 7: Verify + commit (renderer+i18n+AppWindow+input together).**
  - `zig build test` → PASS.
  - `zig build -Dtarget=aarch64-macos macos-app` → exit 0.
  - `git add -A && git commit -m "feat(skill-center): v2 library panel — deploy/import via target picker"`

---

## Self-review notes

- **Spec coverage:** library at `<config>/skills` (T7), target = machine×software (T4 Target, T7 picker), deploy with overwrite-confirm+diff (T7 deploy + reused confirm/skill_diff), import (T7), preview library skill (T7), provider-agnostic/no lock (T3 forces provider, T5 drops tag), i18n all strings (T6), reuse tar/diff/confirm (T1/T2 reuse, skill_diff untouched). Codex prompts / WSL / remote↔remote / status-matrix all out of scope per spec.
- **Type consistency:** `Endpoint{root_expr,is_local}` (T2) fed by `homeRootExpr`/`absRootExpr` (T1); `Software.rootRel` (T4) → `homeRootExpr` for targets; `Target.is_local` → `Endpoint.is_local`; `overwriteDecision` (T4) consumes target/src hashes from `scanLocation` (T3).
- **Build-green ordering:** T1+T2 land together (transfer compiles); T3 standalone; T4 model standalone (test via `zig test`); **T5+T6+T7 land as one commit** (renderer can't gate alone; View shape change ripples to AppWindow).
- **Carry-over correctness:** stage-then-swap (T1) preserved; exit-checked local exec (`localPosixExecOk`) reused (T7); synchronous transfer on UI thread reused (T7); diff at confirm time reused.
