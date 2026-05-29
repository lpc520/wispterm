# Built-in "Update Skills" Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in feature that downloads the latest skills from `xuzhougeng/phantty`'s `plugins/skills/` (main branch) into `<config>/plugins/skills`, reachable via the `/update-skills` slash command and a "Update Skills" Command Palette action, without updating the main program.

**Architecture:** A new pure-logic module `src/skill_update.zig` parses the GitHub Git Trees API response, maps remote paths to local install paths, and orchestrates the download/install (staging into a temp dir, then per-skill atomic replace). `App.zig` wraps the orchestration in a background thread mirroring the existing program-update download. The slash command reaches the App via a module-level trigger callback (same pattern as `ai_chat.configureAgent`/`setToolHost`); the Command Palette calls `app.requestSkillUpdate()` directly. Completion status is surfaced via a toast polled each frame, mirroring `pollUpdateCheck`.

**Tech Stack:** Zig, `std.http.Client`, `std.json`, existing helpers `update_install.downloadAsset` and `platform_dirs.pluginSkillsDir`.

---

## File Structure

- **Create** `src/skill_update.zig` — pure path/URL/JSON helpers + the `downloadAndInstall` orchestration. One responsibility: turning "the remote skills tree" into "installed local skills".
- **Modify** `src/test_main.zig` — register `skill_update.zig` so its tests run.
- **Modify** `src/ai_chat_composer.zig` — add the `update_skills` slash command enum value + entry.
- **Modify** `src/ai_chat.zig` — slash dispatch side-effect, output text, module-level trigger setter, public skill-suggestion reload.
- **Modify** `src/command_center_state.zig` — add the `update_skills` Command Palette action + entry.
- **Modify** `src/renderer/overlays.zig` — dispatch the new Command Palette action.
- **Modify** `src/App.zig` — background-thread wrapper: fields, `requestSkillUpdate`, thread main, `consumeSkillUpdateResult`, join helper.
- **Modify** `src/AppWindow.zig` — wire the trigger at startup, poll the result each frame, show toast, refresh active session suggestions.

Tests run natively with `zig build test` (project baseline).

---

## Task 1: Pure helpers in `skill_update.zig`

**Files:**
- Create: `src/skill_update.zig`
- Modify: `src/test_main.zig` (register module for tests)

- [ ] **Step 1: Create the module with state types and pure helpers**

Create `src/skill_update.zig`:

```zig
//! Built-in skill updater: pulls the latest skills from the phantty repo's
//! `plugins/skills/` directory into the user's `<config>/plugins/skills`.
//!
//! Pure helpers (path/URL/JSON mapping) live here and are unit-tested. The
//! network + disk orchestration (`downloadAndInstall`) is impure and validated
//! manually, consistent with the program-update flow.
const std = @import("std");
const platform_dirs = @import("platform/dirs.zig");
const update_install = @import("update_install.zig");

pub const skills_tree_api_url =
    "https://api.github.com/repos/xuzhougeng/phantty/git/trees/main?recursive=1";
pub const raw_base =
    "https://raw.githubusercontent.com/xuzhougeng/phantty/main/";
pub const skills_prefix = "plugins/skills/";

pub const State = enum { idle, downloading, done, failed };

pub const Outcome = struct {
    state: State,
    count: usize = 0,
};

/// Free a `[][]u8` list of owned strings.
pub fn freeStringList(allocator: std.mem.Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

/// Parse a GitHub Git Trees response (`?recursive=1`) and return owned paths
/// for every blob whose path is under `plugins/skills/`. Directory ("tree")
/// entries and paths outside the prefix are skipped.
pub fn parseSkillPaths(allocator: std.mem.Allocator, tree_json: []const u8) ![][]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tree_json, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidTree;
    const tree = root.object.get("tree") orelse return error.InvalidTree;
    if (tree != .array) return error.InvalidTree;

    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (tree.array.items) |item| {
        if (item != .object) continue;
        const type_val = item.object.get("type") orelse continue;
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "blob")) continue;
        const path_val = item.object.get("path") orelse continue;
        if (path_val != .string) continue;
        if (!std.mem.startsWith(u8, path_val.string, skills_prefix)) continue;
        // Skip the prefix dir itself with no file after it.
        if (path_val.string.len <= skills_prefix.len) continue;
        const owned = try allocator.dupe(u8, path_val.string);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}

/// `raw_base ++ path` (the raw.githubusercontent.com URL for a repo path).
pub fn rawUrlForPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ raw_base, path });
}

/// The path of a remote skill file relative to the skills root, i.e. the
/// remote path with the `plugins/skills/` prefix stripped. Returns null when
/// the path is not under the prefix.
pub fn installSubpath(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, skills_prefix)) return null;
    const sub = path[skills_prefix.len..];
    if (sub.len == 0) return null;
    return sub;
}

/// Deduplicated top-level skill directory names from a list of remote paths.
/// `plugins/skills/foo/SKILL.md` -> `foo`.
pub fn skillNamesFromPaths(allocator: std.mem.Allocator, paths: []const []const u8) ![][]u8 {
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (paths) |path| {
        const sub = installSubpath(path) orelse continue;
        const slash = std.mem.indexOfScalar(u8, sub, '/') orelse continue;
        const name = sub[0..slash];
        if (name.len == 0) continue;

        var already = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                already = true;
                break;
            }
        }
        if (already) continue;

        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try out.append(allocator, owned);
    }

    return out.toOwnedSlice(allocator);
}
```

- [ ] **Step 2: Add unit tests at the bottom of `src/skill_update.zig`**

```zig
const testing = std.testing;

const sample_tree =
    \\{"sha":"abc","tree":[
    \\{"path":"plugins/skills","type":"tree"},
    \\{"path":"plugins/skills/foo","type":"tree"},
    \\{"path":"plugins/skills/foo/SKILL.md","type":"blob"},
    \\{"path":"plugins/skills/foo/scripts/run.py","type":"blob"},
    \\{"path":"plugins/skills/bar/SKILL.md","type":"blob"},
    \\{"path":"src/main.zig","type":"blob"},
    \\{"path":"README.md","type":"blob"}
    \\],"truncated":false}
;

test "skill_update: parseSkillPaths keeps only plugins/skills blobs" {
    const paths = try parseSkillPaths(testing.allocator, sample_tree);
    defer freeStringList(testing.allocator, paths);

    try testing.expectEqual(@as(usize, 3), paths.len);
    try testing.expectEqualStrings("plugins/skills/foo/SKILL.md", paths[0]);
    try testing.expectEqualStrings("plugins/skills/foo/scripts/run.py", paths[1]);
    try testing.expectEqualStrings("plugins/skills/bar/SKILL.md", paths[2]);
}

test "skill_update: rawUrlForPath joins the raw base" {
    const url = try rawUrlForPath(testing.allocator, "plugins/skills/foo/SKILL.md");
    defer testing.allocator.free(url);
    try testing.expectEqualStrings(
        "https://raw.githubusercontent.com/xuzhougeng/phantty/main/plugins/skills/foo/SKILL.md",
        url,
    );
}

test "skill_update: installSubpath strips the prefix" {
    try testing.expectEqualStrings("foo/SKILL.md", installSubpath("plugins/skills/foo/SKILL.md").?);
    try testing.expectEqual(@as(?[]const u8, null), installSubpath("src/main.zig"));
    try testing.expectEqual(@as(?[]const u8, null), installSubpath("plugins/skills/"));
}

test "skill_update: skillNamesFromPaths dedups top-level names" {
    const paths = [_][]const u8{
        "plugins/skills/foo/SKILL.md",
        "plugins/skills/foo/scripts/run.py",
        "plugins/skills/bar/SKILL.md",
        "plugins/skills/baz", // no file segment -> skipped
    };
    const names = try skillNamesFromPaths(testing.allocator, &paths);
    defer freeStringList(testing.allocator, names);

    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("foo", names[0]);
    try testing.expectEqualStrings("bar", names[1]);
}
```

- [ ] **Step 3: Register the module so its tests run**

In `src/test_main.zig`, find the import list near line 653:

```zig
    _ = @import("update_check.zig");
    _ = @import("update_install.zig");
```

Add immediately below:

```zig
    _ = @import("skill_update.zig");
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; the four `skill_update:` tests pass (no failures introduced).

- [ ] **Step 5: Commit**

```bash
git add src/skill_update.zig src/test_main.zig
git commit -m "feat(skill_update): pure helpers for parsing/mapping remote skills"
```

---

## Task 2: Orchestration `downloadAndInstall`

**Files:**
- Modify: `src/skill_update.zig`

No unit test (network + disk), consistent with the program-update flow. Verified by `zig build test` compiling and by manual run.

- [ ] **Step 1: Add the tree fetch + orchestration above the test block**

In `src/skill_update.zig`, add these functions after `skillNamesFromPaths` (before the `const testing = std.testing;` line):

```zig
/// GET the Git Trees API and return the owned response body. Caller frees.
fn fetchTreeJson(allocator: std.mem.Allocator) ![]u8 {
    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = skills_tree_api_url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "phantty" } },
        .response_writer = &body.writer,
    });
    if (response.status != .ok) return error.TreeFetchFailed;

    var list = body.toArrayList();
    errdefer list.deinit(allocator);
    return list.toOwnedSlice(allocator);
}

/// Fetch the remote skills tree, download each skill file into a temp staging
/// dir under `<config>/plugins/skills/.update-tmp`, then atomically replace
/// each same-named local skill directory. On any failure the staging dir is
/// removed and local skills are left unchanged. Returns the number of skills
/// installed (0 means "nothing to update", treated as success).
pub fn downloadAndInstall(allocator: std.mem.Allocator) Outcome {
    const skills_dir = platform_dirs.pluginSkillsDir(allocator) catch return .{ .state = .failed };
    defer allocator.free(skills_dir);

    const tree_json = fetchTreeJson(allocator) catch return .{ .state = .failed };
    defer allocator.free(tree_json);

    const paths = parseSkillPaths(allocator, tree_json) catch return .{ .state = .failed };
    defer freeStringList(allocator, paths);

    if (paths.len == 0) return .{ .state = .done, .count = 0 };

    const names = skillNamesFromPaths(allocator, paths) catch return .{ .state = .failed };
    defer freeStringList(allocator, names);

    const tmp_dir = std.fs.path.join(allocator, &.{ skills_dir, ".update-tmp" }) catch
        return .{ .state = .failed };
    defer allocator.free(tmp_dir);

    // Clear any leftover staging dir from a previous interrupted run.
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Stage every file into the temp dir.
    for (paths) |path| {
        const sub = installSubpath(path) orelse continue;
        const url = rawUrlForPath(allocator, path) catch return .{ .state = .failed };
        defer allocator.free(url);
        const dest = std.fs.path.join(allocator, &.{ tmp_dir, sub }) catch
            return .{ .state = .failed };
        defer allocator.free(dest);
        update_install.downloadAsset(allocator, url, dest) catch return .{ .state = .failed };
    }

    // Per-skill atomic replace: drop the old dir, move the staged one in.
    for (names) |name| {
        const final = std.fs.path.join(allocator, &.{ skills_dir, name }) catch
            return .{ .state = .failed };
        defer allocator.free(final);
        const staged = std.fs.path.join(allocator, &.{ tmp_dir, name }) catch
            return .{ .state = .failed };
        defer allocator.free(staged);

        std.fs.deleteTreeAbsolute(final) catch {};
        std.fs.renameAbsolute(staged, final) catch return .{ .state = .failed };
    }

    return .{ .state = .done, .count = names.len };
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; Task 1 tests still pass.

- [ ] **Step 3: Commit**

```bash
git add src/skill_update.zig
git commit -m "feat(skill_update): downloadAndInstall orchestration (fetch + stage + replace)"
```

---

## Task 3: App-level background thread wrapper

**Files:**
- Modify: `src/App.zig`

- [ ] **Step 1: Import the module**

Near the other imports at the top of `src/App.zig` (where `update_check`/`update_install` are imported), add:

```zig
const skill_update = @import("skill_update.zig");
```

- [ ] **Step 2: Add state fields to the App struct**

Find the update/download fields block (around line 112-122, near `pending_download_update` and `download_thread`). Add after `download_worker_running`:

```zig
skill_update_thread: ?std.Thread,
skill_update_in_flight: bool,
skill_update_result: skill_update.Outcome,
```

- [ ] **Step 3: Initialize the new fields**

In the struct initializer (around line 239-249, where `.download_worker_running = false` is set), add:

```zig
        .skill_update_thread = null,
        .skill_update_in_flight = false,
        .skill_update_result = .{ .state = .idle },
```

- [ ] **Step 4: Add the request/thread/consume functions**

Add these methods near the existing `requestUpdateDownload` / `consumeUpdateResult` functions (the `update_mutex` already exists and is reused here):

```zig
fn joinFinishedSkillUpdateThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (!self.skill_update_in_flight and self.skill_update_thread != null) {
            thread = self.skill_update_thread;
            self.skill_update_thread = null;
        }
    }
    if (thread) |t| t.join();
}

pub fn requestSkillUpdate(self: *App) void {
    self.joinFinishedSkillUpdateThread();

    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (self.skill_update_in_flight) return;
        self.skill_update_in_flight = true;
        self.skill_update_result = .{ .state = .downloading };
    }

    const thread = std.Thread.spawn(.{}, skillUpdateThreadMain, .{self}) catch |err| {
        std.debug.print("Skill update: failed to spawn thread: {}\n", .{err});
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        self.skill_update_in_flight = false;
        self.skill_update_result = .{ .state = .failed };
        return;
    };

    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.skill_update_thread = thread;
}

fn skillUpdateThreadMain(app: *App) void {
    const outcome = skill_update.downloadAndInstall(app.allocator);
    app.update_mutex.lock();
    defer app.update_mutex.unlock();
    app.skill_update_result = outcome;
    app.skill_update_in_flight = false;
}

/// Returns the latest skill-update outcome and resets it to idle. While a
/// download is still running this returns `.downloading` without resetting.
pub fn consumeSkillUpdateResult(self: *App) skill_update.Outcome {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();

    const result = self.skill_update_result;
    if (result.state == .idle or result.state == .downloading) return result;
    self.skill_update_result = .{ .state = .idle };
    return result;
}
```

- [ ] **Step 5: Build to verify it compiles**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; all tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/App.zig
git commit -m "feat(app): background-thread wrapper for skill updates"
```

---

## Task 4: Slash command `/update-skills`

**Files:**
- Modify: `src/ai_chat_composer.zig`
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Update the failing test first (enum coverage)**

In `src/ai_chat.zig`, find the slash-command parse test (around line 4262):

```zig
    try std.testing.expect(parseSlashCommand("/reload-skills").? == .reload_skills);
    try std.testing.expect(parseSlashCommand("/unknown").? == .unknown);
```

Add after the `/reload-skills` assertion:

```zig
    try std.testing.expect(parseSlashCommand("/update-skills").? == .update_skills);
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — `update_skills` is not a member of `SlashCommand` (compile error).

- [ ] **Step 3: Add the enum value and slash entry**

In `src/ai_chat_composer.zig`, change the enum:

```zig
pub const SlashCommand = enum { skills, commands, reload_skills, update_skills, unknown };
```

And add to `slash_command_entries` (after the `reload_skills` entry):

```zig
    .{
        .suggestion = .{ .command = "/update-skills", .description = "download latest skills from GitHub" },
        .action = .update_skills,
    },
```

- [ ] **Step 4: Add the module-level trigger + public reload + dispatch in `ai_chat.zig`**

Near the other module-level globals (e.g. `g_session_id_counter` around line 315), add:

```zig
var g_skill_update_trigger: ?*const fn () void = null;

/// Wire the callback that the `/update-skills` slash command fires. Set once at
/// startup by the app layer (mirrors `configureAgent` / `setToolHost`).
pub fn setSkillUpdateTrigger(cb: *const fn () void) void {
    g_skill_update_trigger = cb;
}
```

Add a public wrapper next to the private `freeSkillSuggestions` (around line 906), inside the `Session` struct:

```zig
    pub fn reloadSkillSuggestions(self: *Session) void {
        self.freeSkillSuggestions();
    }
```

In `slashCommandOutput` (around line 356), add the `.update_skills` arm:

```zig
        .update_skills => allocator.dupe(u8, "Downloading the latest skills from GitHub in the background..."),
```

In the `submit` dispatch (around line 1372, where `if (command == .reload_skills) self.freeSkillSuggestions();` is), add right after that line:

```zig
            if (command == .update_skills) {
                if (g_skill_update_trigger) |trigger| trigger();
            }
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS — the `/update-skills` assertion passes; all other tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_composer.zig src/ai_chat.zig
git commit -m "feat(ai_chat): /update-skills slash command"
```

---

## Task 5: Command Palette action "Update Skills"

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Add the action and entry**

In `src/command_center_state.zig`, add `update_skills` to the `CommandAction` enum (after `open_latest_release`):

```zig
    open_latest_release,
    update_skills,
};
```

Add to `command_entries` (after the `Open Latest Release` entry):

```zig
    .{ .title = "Update Skills", .detail = "Download the latest skills from GitHub", .shortcut = "", .action = .update_skills },
```

- [ ] **Step 2: Dispatch the action**

In `src/renderer/overlays.zig`, find the `CommandAction` switch (the `.open_latest_release => openLatestRelease(),` arm, ~line 484). Add a new arm after it:

```zig
        .update_skills => {
            if (AppWindow.g_app) |app| {
                showStatusToast("Updating skills...");
                app.requestSkillUpdate();
            } else {
                showStatusToast("Update Skills unavailable");
            }
        },
```

(`showStatusToast` is already used throughout this file, e.g. in `connectWeixinDirect`.)

- [ ] **Step 3: Build to verify it compiles**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; all tests pass. (The Zig compiler will error if any `CommandAction` switch elsewhere is non-exhaustive — if so, add an `.update_skills` arm there mirroring how `open_latest_release` is handled.)

- [ ] **Step 4: Commit**

```bash
git add src/command_center_state.zig src/renderer/overlays.zig
git commit -m "feat(command-palette): Update Skills action"
```

---

## Task 6: Wire the trigger + poll completion in `AppWindow.zig`

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add the trigger function and register it at startup**

Add a small free function near the other AppWindow helpers (e.g. above `pollUpdateCheck`, ~line 1512):

```zig
fn triggerSkillUpdate() void {
    if (g_app) |app| app.requestSkillUpdate();
}
```

Register it where `g_app` is set at startup (around line 92-93, right after `g_app = app;`):

```zig
    g_app = app;
    ai_chat.setSkillUpdateTrigger(triggerSkillUpdate);
    app.maybeStartStartupUpdateCheck();
```

- [ ] **Step 2: Add the poll function**

Add next to `pollUpdateCheck` (~line 1512):

```zig
fn pollSkillUpdate(app: *App) void {
    const result = app.consumeSkillUpdateResult();
    switch (result.state) {
        .idle, .downloading => {},
        .done => {
            if (result.count == 0) {
                overlays.showStatusToast("Skills already up to date");
            } else {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Skills updated ({d})", .{result.count}) catch "Skills updated";
                overlays.showStatusToast(msg);
            }
            if (activeAiChat()) |session| session.reloadSkillSuggestions();
        },
        .failed => overlays.showStatusToast("Skill update failed"),
    }
}
```

- [ ] **Step 3: Call the poll each frame**

Find where `pollUpdateCheck(self.app)` is called (~line 3782) and add immediately after it:

```zig
        pollUpdateCheck(self.app);
        pollSkillUpdate(self.app);
```

- [ ] **Step 4: Build and run the full test suite**

Run: `zig build test 2>&1 | tail -20`
Expected: build succeeds; all tests pass (matches the green baseline).

- [ ] **Step 5: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(appwindow): wire skill-update trigger and completion toast"
```

---

## Manual verification (after all tasks)

1. Build and launch phantty; open an AI Agent tab.
2. Type `/update-skills` and submit. Expect a tool message ("Downloading the latest skills...") and, shortly after, a status toast ("Skills updated (N)" or "Skills already up to date").
3. Confirm `<config>/plugins/skills/` now contains the repo's skills (e.g. `phantty-diagnostics/SKILL.md`).
4. Open the Command Palette, run "Update Skills"; expect the "Updating skills..." then completion toast.
5. Disconnect from the network and run again; expect "Skill update failed" with local skills intact.

`<config>` resolves via `platform_dirs.pluginSkillsDir` (Windows `%APPDATA%\phantty\plugins\skills`, macOS/Linux `~/.config/phantty/plugins/skills`).
