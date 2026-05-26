# AI Profile Management in Command Center + Default Profile in Settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface AI profile management in the Command Center (Ctrl+Shift+P) as per-profile launch rows plus a "Manage AI Profiles" entry that revives the existing New/Edit/Delete overlay, and let Settings pick the default AI profile via a cycle row.

**Architecture:** Phantty's command palette (`src/renderer/overlays.zig`) already mixes static commands with dynamic rows (SSH profiles, themes) through a `PaletteItem` union and `rebuildPaletteScratch`. We add an `ai_profile` variant the same way, a static "Manage AI Profiles" command that calls the orphaned `openAiList()` overlay, a config key `ai-default-profile` (resolved by name, falling back to the first profile), and a Settings row that cycles the default. Pure matching/resolution logic lives in `src/command_palette_model.zig` so it is unit-testable with `zig test`.

**Tech Stack:** Zig 0.15.2. Pure modules tested with `zig test src/<module>.zig`. The full GUI build (`zig build test`) targets x86_64-windows on this host and is **compile-only** (foreign-target test runs are skipped) — GUI wiring in `overlays.zig` and the table in `command_center_state.zig` are verified by compilation, runtime behavior confirmed manually.

---

## Testing notes (read first)

- `zig test src/command_palette_model.zig` — **executes** (pure module, std-only). Real red→green here.
- `zig test src/config.zig` — **executes** natively; `config.zig` pulls in unrelated modules. Use `--test-filter` to scope to the new test. (One pre-existing `markdown_text` test may fail in some environments; ignore it — only the filtered test matters.)
- `zig build test` — **compile-only** on this host (default target is foreign/windows; foreign test runs are skipped). Use it to prove `command_center_state.zig` and `overlays.zig` changes compile. The `command_center_state.zig` tests cannot run standalone with `zig test` because it imports `build_options.app_version`.

Commit messages end with the trailer:
```
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

---

## Task 1: Config key `ai-default-profile`

**Files:**
- Modify: `src/config.zig` (struct field near `shell` at :290; parse branch near :758; new test near the existing config tests)

- [ ] **Step 1: Write the failing test**

Add this test at the end of `src/config.zig` (after the last existing `test "..."` block):

```zig
test "config parses ai-default-profile" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);
    cfg.applyKeyValue(allocator, "ai-default-profile", "GPT-4o", ".");
    try std.testing.expectEqualStrings("GPT-4o", cfg.@"ai-default-profile");
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/config.zig --test-filter "ai-default-profile"`
Expected: compile error — `no field named 'ai-default-profile' in struct 'Config'`.

- [ ] **Step 3: Add the struct field**

In `src/config.zig`, immediately after the `shell` field (currently at :290):

```zig
shell: []const u8 = platform_pty_command.default_shell_name,

/// Name of the saved AI profile used as the default for startup auto-open,
/// remote auto-open, and the "New Agent" command. Empty falls back to the
/// first saved profile.
@"ai-default-profile": []const u8 = "",
```

- [ ] **Step 4: Add the parse branch**

In `applyKeyValue`, right after the `shell` branch (currently at :758-759):

```zig
    } else if (std.mem.eql(u8, key, "shell")) {
        self.shell = self.dupeString(allocator, value) orelse return;
    } else if (std.mem.eql(u8, key, "ai-default-profile")) {
        self.@"ai-default-profile" = self.dupeString(allocator, value) orelse return;
```

- [ ] **Step 5: Run test to verify it passes**

Run: `zig test src/config.zig --test-filter "ai-default-profile"`
Expected: the filtered test passes (`1 passed`). Ignore any unrelated `markdown_text` failure.

- [ ] **Step 6: Commit**

```bash
git add src/config.zig
git commit -m "$(cat <<'EOF'
feat(config): add ai-default-profile key

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Pure model helpers — `aiProfileLabelMatchesFilter` + `resolveDefaultIndex`

**Files:**
- Modify: `src/command_palette_model.zig` (add `ResultGroup.ai_profile`, two functions, tests)

- [ ] **Step 1: Write the failing tests**

Add these tests at the end of `src/command_palette_model.zig`:

```zig
test "ai profile label matches the ai token and the name" {
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "ai"));
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "deep"));
    try std.testing.expect(aiProfileLabelMatchesFilter("DeepSeek", "SEEK"));
}

test "ai profile label does not match unrelated filter and hides on empty" {
    try std.testing.expect(!aiProfileLabelMatchesFilter("DeepSeek", "gpt"));
    try std.testing.expect(!aiProfileLabelMatchesFilter("DeepSeek", ""));
}

test "resolve default index matches by name with fallback to first" {
    const names = [_][]const u8{ "DeepSeek", "GPT-4o", "Local" };
    try std.testing.expectEqual(@as(usize, 1), resolveDefaultIndex(&names, "GPT-4o"));
    try std.testing.expectEqual(@as(usize, 0), resolveDefaultIndex(&names, ""));
    try std.testing.expectEqual(@as(usize, 0), resolveDefaultIndex(&names, "missing"));
}

test "command palette model orders AI profiles between SSH and themes" {
    try std.testing.expect(resultGroupRank(.ssh_profile) < resultGroupRank(.ai_profile));
    try std.testing.expect(resultGroupRank(.ai_profile) < resultGroupRank(.theme));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig test src/command_palette_model.zig`
Expected: compile error — `aiProfileLabelMatchesFilter` / `resolveDefaultIndex` / `ResultGroup.ai_profile` undefined.

- [ ] **Step 3: Add `ai_profile` to the result-group enum and ranking**

Replace the `ResultGroup` enum and `resultGroupRank` (currently :3-17):

```zig
pub const ResultGroup = enum {
    command_title,
    command_secondary,
    ssh_profile,
    ai_profile,
    theme,
};

pub fn resultGroupRank(group: ResultGroup) u8 {
    return switch (group) {
        .command_title => 0,
        .command_secondary => 1,
        .ssh_profile => 2,
        .ai_profile => 3,
        .theme => 4,
    };
}
```

- [ ] **Step 4: Add the two helper functions**

Add after `sshProfileNameMatchesFilter` (currently ends :47):

```zig
/// True when a non-empty filter should surface an AI profile launch row.
/// Typing "ai" lists every profile; typing part of the name narrows.
pub fn aiProfileLabelMatchesFilter(name: []const u8, filter: []const u8) bool {
    if (filter.len == 0) return false;
    return containsIgnoreCase(name, filter) or containsIgnoreCase("ai", filter);
}

/// Index of the profile whose name equals `default_name`. Returns 0 when
/// `default_name` is empty or unmatched (caller guards the empty-list case).
pub fn resolveDefaultIndex(names: []const []const u8, default_name: []const u8) usize {
    if (default_name.len == 0) return 0;
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, default_name)) return i;
    }
    return 0;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `zig test src/command_palette_model.zig`
Expected: `All N tests passed.` (the four new tests plus the four pre-existing ones).

- [ ] **Step 6: Commit**

```bash
git add src/command_palette_model.zig
git commit -m "$(cat <<'EOF'
feat(palette): add AI profile match + default-index helpers

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Command Center "Manage AI Profiles" entry

**Files:**
- Modify: `src/command_center_state.zig` (add `manage_ai_profiles` to `CommandAction` :5-38; add command entry :47-80; add test near :244)

- [ ] **Step 1: Write the failing test**

Add this test in `src/command_center_state.zig` after the `test "command center includes New Agent action"` block (:244-246):

```zig
test "command center includes Manage AI Profiles action" {
    try std.testing.expectEqual(CommandAction.manage_ai_profiles, findCommandAction("Manage AI Profiles"));
}
```

- [ ] **Step 2: Verify it fails to compile**

Run: `zig build test`
Expected: compile error — `no member named 'manage_ai_profiles' in enum 'CommandAction'`.

- [ ] **Step 3: Add the enum member**

In the `CommandAction` enum, add after `select_agent_history` (:8):

```zig
    new_agent,
    manage_ai_profiles,
    select_agent_history,
```

- [ ] **Step 4: Add the command entry**

In `command_entries`, add after the "New Agent" entry (:49):

```zig
    .{ .title = "New Agent", .detail = "Open a new Agent tab with the default AI config", .shortcut = "", .action = .new_agent },
    .{ .title = "Manage AI Profiles", .detail = "Create, edit, or delete saved AI profiles", .shortcut = "", .action = .manage_ai_profiles },
```

- [ ] **Step 5: Verify it compiles**

Run: `zig build test`
Expected: build succeeds (no errors). On this host the test run is skipped (foreign target); a clean compile is the pass condition.

> NOTE: this step will still fail to compile until Task 4 Step 3 adds the matching `executeCommand` switch arm in `overlays.zig`, because Zig requires the switch over `CommandAction` to be exhaustive. If `zig build test` reports `switch must handle all possibilities` for `manage_ai_profiles`, proceed to Task 4 and re-run the build there. Commit this task's files together with Task 4 if needed.

- [ ] **Step 6: Commit**

```bash
git add src/command_center_state.zig
git commit -m "$(cat <<'EOF'
feat(command-center): add Manage AI Profiles command entry

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Default-profile resolution + revive `openAiList` from the command

**Files:**
- Modify: `src/renderer/overlays.zig`
  - Add default-name cache + `defaultAiProfileIndex()` near the AI profile helpers (after `spawnAiProfileWithAgentOverride`, :2579)
  - Add `.manage_ai_profiles` arm to `executeCommand` (:434)
  - Swap four hardcoded `0` default call sites (`openDefaultAiSession` :2554/:2550, `openDefaultAgentSessionFromCommandCenter` :2257, `openDefaultAgentSessionForStartup` :2272, `openDefaultAgentSessionForRemote` :2278)

- [ ] **Step 1: Add the default-name cache and resolver**

Insert immediately after `spawnAiProfileWithAgentOverride` (after its closing brace at :2579):

```zig
threadlocal var g_ai_default_name_buf: [AI_FIELD_MAX]u8 = undefined;
threadlocal var g_ai_default_name_len: usize = 0;
threadlocal var g_ai_default_loaded: bool = false;

/// Cached value of the `ai-default-profile` config key. Cached to avoid file
/// IO on every render frame; invalidated on in-app writes.
fn aiDefaultProfileName() []const u8 {
    if (!g_ai_default_loaded) {
        g_ai_default_loaded = true;
        g_ai_default_name_len = 0;
        const allocator = AppWindow.g_allocator orelse return "";
        var cfg = Config.load(allocator) catch return "";
        defer cfg.deinit(allocator);
        const name = cfg.@"ai-default-profile";
        const len = @min(name.len, g_ai_default_name_buf.len);
        @memcpy(g_ai_default_name_buf[0..len], name[0..len]);
        g_ai_default_name_len = len;
    }
    return g_ai_default_name_buf[0..g_ai_default_name_len];
}

fn invalidateAiDefaultName() void {
    g_ai_default_loaded = false;
}

/// Index of the default AI profile, resolved by name from config. Falls back
/// to the first profile. Returns 0 when no profiles exist (callers guard).
fn defaultAiProfileIndex() usize {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return 0;
    var names: [AI_PROFILE_MAX][]const u8 = undefined;
    for (0..g_ai_profile_count) |i| {
        names[i] = aiProfileField(&g_ai_profiles[i], .name);
    }
    return command_palette_model.resolveDefaultIndex(names[0..g_ai_profile_count], aiDefaultProfileName());
}
```

- [ ] **Step 2: Swap the four default call sites to use `defaultAiProfileIndex()`**

In `openDefaultAiSession` (:2244-2251), change the connect line:

```zig
fn openDefaultAiSession() void {
    loadAiProfiles();
    if (g_ai_profile_count == 0) {
        openAiFormNew();
        return;
    }
    connectAiProfile(defaultAiProfileIndex());
}
```

(Note: `openAiFormNewWithMode(.session_setup)` becomes `openAiFormNew()` after Task 7. If implementing Task 4 before Task 7, keep `openAiFormNewWithMode(.session_setup)` here and adjust in Task 7.)

In `openDefaultAgentSessionFromCommandCenter` (:2253-2259):

```zig
        .connect_default_profile_as_agent => connectAiProfileWithAgentOverride(defaultAiProfileIndex(), "true"),
```

In `openDefaultAgentSessionForStartup` (:2266-2273):

```zig
    return if (spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")) .opened else .failed;
```

In `openDefaultAgentSessionForRemote` (:2275-2279):

```zig
    return if (spawnAiProfileWithAgentOverride(defaultAiProfileIndex(), "true")) .opened else .failed;
```

- [ ] **Step 3: Wire the `manage_ai_profiles` command**

In `executeCommand` (:433), add an arm after `.new_agent`:

```zig
        .new_agent => openDefaultAgentSessionFromCommandCenter(),
        .manage_ai_profiles => openAiList(),
```

(The palette is already closed by `commandPaletteExecuteSelected` / `commandPaletteExecuteAt` before this runs, so `openAiList()` cleanly shows the overlay.)

- [ ] **Step 4: Verify it compiles**

Run: `zig build test`
Expected: clean compile (foreign test run skipped). The `manage_ai_profiles` switch arm now makes Task 3's enum exhaustive.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/overlays.zig src/command_center_state.zig
git commit -m "$(cat <<'EOF'
feat(ai): resolve default profile by name; revive manage overlay

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: AI profile launch rows in the command palette

**Files:**
- Modify: `src/renderer/overlays.zig`
  - `PaletteItem` union (:184-188)
  - `rebuildPaletteScratch` — inject AI rows after SSH loop (:721)
  - `executePaletteItem` (:730-736)
  - palette row rendering — add `.ai_profile` branch (:1279-1313)

- [ ] **Step 1: Add the `ai_profile` variant to the union**

Replace `PaletteItem` (:184-188):

```zig
const PaletteItem = union(enum) {
    command: usize,
    ssh_profile: usize,
    ai_profile: usize,
    theme: usize,
};
```

- [ ] **Step 2: Inject AI profile rows in `rebuildPaletteScratch`**

In `rebuildPaletteScratch`, after the SSH-profile loop (the block ending at :721, right before the `for (&themes_embed.entries, 0..)` theme loop), insert:

```zig
    loadAiProfiles();
    for (0..g_ai_profile_count) |ai_idx| {
        if (g_palette_scratch_len >= COMMAND_PALETTE_MAX_VISIBLE_ROWS) break;
        const profile = &g_ai_profiles[ai_idx];
        if (!command_palette_model.aiProfileLabelMatchesFilter(aiProfileField(profile, .name), filter)) continue;
        g_palette_scratch[g_palette_scratch_len] = .{ .ai_profile = ai_idx };
        g_palette_scratch_len += 1;
    }
```

- [ ] **Step 3: Execute launch rows**

Replace `executePaletteItem` (:730-736):

```zig
fn executePaletteItem(item: PaletteItem) void {
    switch (item) {
        .command => |cmd_idx| executeCommand(COMMAND_ENTRIES[cmd_idx].action),
        .ssh_profile => |profile_idx| connectSshProfile(profile_idx),
        .ai_profile => |profile_idx| _ = spawnAiProfileWithAgentOverride(profile_idx, null),
        .theme => |ti| applyEmbeddedThemeFromPalette(ti),
    }
}
```

(`null` makes the launched tab use the profile's own stored `agent` field. `spawnAiProfileWithAgentOverride` internally calls `sessionLauncherClose()`, which is harmless here.)

- [ ] **Step 4: Render the launch rows**

In the palette row-rendering switch (:1279-1313), add an `.ai_profile` branch after the `.ssh_profile` branch:

```zig
                    .ai_profile => |profile_idx| {
                        if (profile_idx >= g_ai_profile_count) continue;
                        const profile = &g_ai_profiles[profile_idx];
                        var title_buf: [AI_FIELD_MAX + 8]u8 = undefined;
                        const ai_title = std.fmt.bufPrint(title_buf[0..], "AI: {s}", .{aiProfileField(profile, .name)}) catch "AI";
                        var tag_buf: [24]u8 = undefined;
                        const mode = aiProfileModeLabel(profile);
                        const tag = if (profile_idx == defaultAiProfileIndex())
                            (std.fmt.bufPrint(tag_buf[0..], "{s} · default", .{mode}) catch mode)
                        else
                            mode;
                        const tag_w = measureTitlebarText(tag);
                        const tag_left = @round(layout.box_x + layout.box_w - pad_x - tag_w);
                        renderTitlebarText(tag, tag_left, text_y, shortcut_color);
                        renderTitlebarTextLimited(ai_title, title_x, text_y, row_title_color, @max(1.0, tag_left - title_x - 18));
                    },
```

- [ ] **Step 5: Verify it compiles**

Run: `zig build test`
Expected: clean compile.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "$(cat <<'EOF'
feat(command-center): add AI profile launch rows

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `(default)` marker in the manage list + clear default on delete

**Files:**
- Modify: `src/renderer/overlays.zig`
  - `renderAiProfileRow` (:3063-3067)
  - `deleteAiProfile` (:2478-2488)

- [ ] **Step 1: Show the default marker in the manage list**

Replace `renderAiProfileRow` (:3063-3067):

```zig
fn renderAiProfileRow(layout: SessionLayout, window_height: f32, row: usize, profile: *const AiProfile, selected: bool) void {
    const name = aiProfileField(profile, .name);
    const mode = aiProfileModeLabel(profile);
    var detail_buf: [24]u8 = undefined;
    const detail = if (row == defaultAiProfileIndex())
        (std.fmt.bufPrint(detail_buf[0..], "{s} · default", .{mode}) catch mode)
    else
        mode;
    renderSessionRow(layout, window_height, row, name, detail, selected);
}
```

(In `.manage` mode the list row index equals the profile index — the render loop iterates `&g_ai_profiles[row]` — so `row == defaultAiProfileIndex()` is the correct comparison.)

- [ ] **Step 2: Clear the default key when the default profile is deleted**

Replace `deleteAiProfile` (:2478-2488):

```zig
fn deleteAiProfile(idx: usize) void {
    if (g_ai_profile_count == 0) return;
    if (idx >= g_ai_profile_count) return;
    const deleted_is_default = std.mem.eql(u8, aiProfileField(&g_ai_profiles[idx], .name), aiDefaultProfileName());
    var i = idx;
    while (i + 1 < g_ai_profile_count) : (i += 1) {
        g_ai_profiles[i] = g_ai_profiles[i + 1];
    }
    g_ai_profile_count -= 1;
    g_ai_list_selected = @min(g_ai_list_selected, aiListRowCount() - 1);
    if (deleted_is_default) {
        if (AppWindow.g_allocator) |allocator| Config.setConfigValue(allocator, "ai-default-profile", "") catch {};
        invalidateAiDefaultName();
    }
    if (AppWindow.g_allocator) |allocator| saveAiProfiles(allocator);
}
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build test`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "$(cat <<'EOF'
feat(ai): mark default profile and clear it on delete

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Settings "Default AI" cycle row + remove the settings edit-form path

**Files:**
- Modify: `src/renderer/overlays.zig`
  - `SettingsAction` enum (:3230-3241)
  - `settingsHitTest` row map (:3377)
  - `runSettingsFocusPrimary` row map (:3425)
  - `executeSettingsAction` arm (:3403)
  - `renderSettingsPage` AI row (:3623-3626)
  - Add `nextDefaultAiProfileName()` helper
  - Remove `openAiSettings` (:2281-2288) and the `AiFormMode` `.settings` path (enum :1386-1389, var :1448, resets :1526 & :3269, `openAiForm*` :2309-2343, `saveAiFormOnly` :2495-2501, `cancelAiFormOrLauncher` :2503-2509, `runAiFormFocusAction` :2511-2521)

- [ ] **Step 1: Replace the settings action enum member**

In `SettingsAction` (:3230-3241), replace `open_ai_settings` with `cycle_default_ai_profile`:

```zig
const SettingsAction = enum {
    font_size_minus,
    font_size_plus,
    cycle_theme,
    cycle_cursor_style,
    toggle_cursor_blink,
    toggle_focus_follows_mouse,
    cycle_shell,
    cycle_default_ai_profile,
    open_raw_config,
    close,
};
```

- [ ] **Step 2: Add the next-default helper**

Add next to `defaultAiProfileIndex()` (from Task 4):

```zig
/// Name of the profile after the current default, wrapping around. Empty when
/// no profiles exist.
fn nextDefaultAiProfileName() []const u8 {
    loadAiProfiles();
    if (g_ai_profile_count == 0) return "";
    const next = (defaultAiProfileIndex() + 1) % g_ai_profile_count;
    return aiProfileField(&g_ai_profiles[next], .name);
}
```

- [ ] **Step 3: Update the hit-test and keyboard row maps**

In `settingsHitTest` (:3372-3381), change row 4:

```zig
    return switch (row - SETTINGS_CONTROL_ROW_START) {
        0 => .cycle_cursor_style,
        1 => .toggle_cursor_blink,
        2 => .toggle_focus_follows_mouse,
        3 => .cycle_shell,
        4 => .cycle_default_ai_profile,
        5 => .open_raw_config,
        6 => .close,
        else => null,
    };
```

In `runSettingsFocusPrimary` (:3425), change the row-4 arm:

```zig
        SETTINGS_CONTROL_ROW_START + 4 => executeSettingsAction(.cycle_default_ai_profile),
```

- [ ] **Step 4: Replace the execute arm**

In `executeSettingsAction` (:3403), replace the `.open_ai_settings` arm:

```zig
        .cycle_default_ai_profile => {
            loadAiProfiles();
            if (g_ai_profile_count > 0) {
                const next_name = nextDefaultAiProfileName();
                Config.setConfigValue(allocator, "ai-default-profile", next_name) catch {};
                invalidateAiDefaultName();
            }
        },
```

(`nextDefaultAiProfileName()` reads the still-current default before the write; the `invalidate` makes the next render reflect the new default.)

- [ ] **Step 5: Update the settings row rendering**

Replace the AI row block in `renderSettingsPage` (:3623-3626):

```zig
    loadAiProfiles();
    const ai_default_value = if (g_ai_profile_count > 0)
        aiProfileField(&g_ai_profiles[defaultAiProfileIndex()], .name)
    else
        "(none)";
    const ai_default_hint = if (g_ai_profile_count > 0)
        aiProfileModeLabel(&g_ai_profiles[defaultAiProfileIndex()])
    else
        "Add profiles via Command Center";
    renderSettingsRow(layout, window_height, SETTINGS_CONTROL_ROW_START + 4, "Default AI", ai_default_value, ai_default_hint, true, g_settings_focus == SETTINGS_CONTROL_ROW_START + 4);
```

- [ ] **Step 6: Remove `openAiSettings`**

Delete the entire `openAiSettings` function (:2281-2288).

- [ ] **Step 7: Collapse `AiFormMode` to a single path**

7a. Delete the `AiFormMode` enum (:1386-1389).

7b. Delete the `g_ai_form_mode` declaration (:1448) and the reset line in `sessionLauncherClose` (:1526 — remove `g_ai_form_mode = .session_setup;`).

7c. In `settingsPageOpen` (:3269), remove the line `g_ai_form_mode = .session_setup;`.

7d. Replace the `openAiForm*` cluster (:2309-2343) with mode-free versions:

```zig
fn openAiFormNew() void {
    clearAiForm();
    g_ai_edit_index = AI_PROFILE_NONE;
    openAiForm();
}

fn openAiFormEdit(index: usize) void {
    if (index >= g_ai_profile_count) return;
    clearAiForm();
    for (0..AI_FIELD_COUNT) |i| {
        g_ai_lens[i] = @min(g_ai_profiles[index].lens[i], AI_FIELD_MAX);
        @memcpy(g_ai_bufs[i][0..g_ai_lens[i]], g_ai_profiles[index].fields[i][0..g_ai_lens[i]]);
    }
    g_ai_edit_index = index;
    openAiForm();
}

fn openAiForm() void {
    g_ssh_list_visible = false;
    g_ssh_form_visible = false;
    g_ai_list_visible = false;
    g_session_launcher_visible = false;
    g_settings_visible = false;
    g_ai_form_visible = true;
    g_ai_focus = @intFromEnum(AiField.name);
}
```

7e. Replace `saveAiFormOnly` (:2495-2501):

```zig
fn saveAiFormOnly() void {
    _ = saveAiFormProfile() orelse return;
    sessionLauncherClose();
}
```

7f. Replace `cancelAiFormOrLauncher` (:2503-2509):

```zig
fn cancelAiFormOrLauncher() void {
    sessionLauncherClose();
}
```

7g. Replace `runAiFormFocusAction` (:2511-2521):

```zig
fn runAiFormFocusAction() void {
    if (g_ai_focus < AI_FIELD_COUNT) {
        g_ai_focus = (g_ai_focus + 1) % (AI_FIELD_COUNT + 3);
        return;
    }
    switch (g_ai_focus - AI_FIELD_COUNT) {
        0 => connectAiFromForm(),
        1 => saveAiFormOnly(),
        else => cancelAiFormOrLauncher(),
    }
}
```

7h. If Task 4 Step 2 left `openAiFormNewWithMode(.session_setup)` in `openDefaultAiSession`, change it to `openAiFormNew()` now. Also check `openDefaultAgentSessionForStartup` (:2269) which calls `openAiFormNewWithMode(.session_setup)` — change to `openAiFormNew()`.

- [ ] **Step 8: Verify no stale references remain**

Run: `rtk proxy grep -rn "AiFormMode\|g_ai_form_mode\|open_ai_settings\|openAiSettings\|openAiFormNewWithMode\|openAiFormEditWithMode\|openAiFormWithMode" src/renderer/overlays.zig`
Expected: no matches.

- [ ] **Step 9: Verify it compiles**

Run: `zig build test`
Expected: clean compile.

- [ ] **Step 10: Commit**

```bash
git add src/renderer/overlays.zig
git commit -m "$(cat <<'EOF'
feat(settings): cycle default AI profile; drop settings edit-form path

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Full build verification + manual check

**Files:** none (verification only)

- [ ] **Step 1: Run the pure module tests**

Run: `zig test src/command_palette_model.zig`
Expected: `All N tests passed.`

Run: `zig test src/config.zig --test-filter "ai-default-profile"`
Expected: the filtered test passes.

- [ ] **Step 2: Compile the full suite**

Run: `zig build test`
Expected: clean compile (foreign test run skipped on this host).

- [ ] **Step 3: Manual verification checklist (record results)**

Document these in the task notes when run on a real build:

1. Ctrl+Shift+P → type `ai` → each saved profile appears as `AI: <name>` with an `Agent`/`Chat` tag; the default shows `· default`. Enter launches it (agent profiles open as agents, chat profiles as chat).
2. Ctrl+Shift+P → `Manage AI Profiles` → overlay opens with profiles + New / Edit / Delete / Cancel. New adds a profile; Edit opens the form for a chosen profile; Delete removes a chosen profile. Esc/Cancel returns.
3. Delete the current default profile → `ai-default-profile` is cleared; default falls back to the first remaining profile (verify the `· default` marker moves).
4. Settings → `Default AI` row shows the current default name; Enter/Right/click cycles to the next saved profile and persists (reopen Settings to confirm). With zero profiles it shows `(none)`.
5. Restart with a default set by name → startup auto-opens that profile (not necessarily index 0).

- [ ] **Step 4: Final commit (only if any verification fix was needed)**

```bash
git add -A
git commit -m "$(cat <<'EOF'
test: verify AI profile command-center + default flows

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage:**
- §1 default resolution (config key + helper + 4 call-site swaps) → Tasks 1, 2 (`resolveDefaultIndex`), 4. ✓
- §2 command center (`PaletteItem.ai_profile`, "Manage AI Profiles", matcher, execute, render, `manage_ai_profiles`) → Tasks 2, 3, 4 (command wiring), 5. ✓
- §3 manage overlay (revive + `(default)` marker + delete clears default) → Tasks 4 (revive), 6. ✓
- §4 settings (cycle row, remove `open_ai_settings`/`openAiSettings`/`.settings` form mode) → Task 7. ✓
- §5 tests (model matcher + resolveDefaultIndex; "Manage AI Profiles" entry; config parse) → Tasks 2, 3, 1. ✓

**Deviation from spec (intentional):** `resolveDefaultIndex` lives in `command_palette_model.zig` (not `command_center_state.zig` as the spec drafted) so it runs under `zig test` — `command_center_state.zig` can't run standalone (needs `build_options.app_version`). Logic and call sites are unchanged.

**Placeholder scan:** No TBD/TODO; every code step shows full code; the one cross-task ordering caveat (Task 3 exhaustive-switch / Task 4) is called out explicitly. ✓

**Type consistency:** `defaultAiProfileIndex()`, `aiDefaultProfileName()`, `invalidateAiDefaultName()`, `nextDefaultAiProfileName()`, `aiProfileLabelMatchesFilter()`, `resolveDefaultIndex()`, `PaletteItem.ai_profile`, `CommandAction.manage_ai_profiles`, `SettingsAction.cycle_default_ai_profile` are named identically across all tasks that reference them. ✓
