# OpenSSH Config Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a first-run and Command Center path that imports compatible `~/.ssh/config` entries into WispTerm SSH profiles.

**Architecture:** Keep OpenSSH parsing in a pure module that can run in the fast test suite. Keep UI state, profile merging, profile persistence, and tab launching in `src/renderer/overlays.zig`, where WispTerm already owns SSH profile storage and New Session behavior. Add a small platform-dir helper for the default OpenSSH config path so Windows uses `%USERPROFILE%\.ssh\config` while POSIX uses `$HOME/.ssh/config`.

**Tech Stack:** Zig 0.15.2, WispTerm custom overlay renderer, existing `renderer/overlays/profile_codec.zig` SSH profile storage, existing `platform/dirs.zig`, `zig build test`, `zig build test-full`.

---

## File Structure

- Create `src/openssh_config_import.zig`: pure OpenSSH config parser. It returns fixed-buffer import candidates and has no renderer/AppWindow imports.
- Modify `src/test_fast.zig`: add the parser to the fast test aggregate.
- Modify `src/test_main.zig`: add the parser to full-suite compile coverage.
- Modify `src/platform/dirs.zig`: add `openSshConfigPath()` and `openSshConfigPathFromEnvForOs()` with unit tests.
- Modify `src/command_center_state.zig`: add the static `Load OpenSSH Config` command action and tests.
- Modify `src/i18n.zig`: add Chinese command title/detail cases so the new command switch remains exhaustive and searchable under Chinese UI.
- Modify `src/renderer/overlays.zig`: add the command execution route, SSH manage-list import row, OpenSSH import/merge/persist logic, row mapping tests, and merge tests.
- Modify `docs/configuration.md`: document the Command Center import entry.

## Task 1: Add The Pure OpenSSH Config Parser

**Files:**
- Create: `src/openssh_config_import.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Register the missing module in the fast test aggregate**

In `src/test_fast.zig`, add this import inside the existing `test { ... }` block near the SSH modules:

```zig
    _ = @import("openssh_config_import.zig");
```

In `src/test_main.zig`, add this import inside the existing `comptime { ... }` block near `command_center_state.zig` and `command_palette_model.zig`:

```zig
    _ = @import("openssh_config_import.zig");
```

- [ ] **Step 2: Create parser tests and stubs**

Create `src/openssh_config_import.zig` with this test-first skeleton:

```zig
const std = @import("std");

pub const FIELD_MAX: usize = 128;
pub const MAX_ALIASES_PER_HOST: usize = 16;

pub const Candidate = struct {
    name_buf: [FIELD_MAX]u8 = undefined,
    name_len: usize = 0,
    host_buf: [FIELD_MAX]u8 = undefined,
    host_len: usize = 0,
    user_buf: [FIELD_MAX]u8 = undefined,
    user_len: usize = 0,
    port_buf: [FIELD_MAX]u8 = undefined,
    port_len: usize = 0,
    proxy_jump_buf: [FIELD_MAX]u8 = undefined,
    proxy_jump_len: usize = 0,

    pub fn name(self: *const Candidate) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn host(self: *const Candidate) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    pub fn user(self: *const Candidate) []const u8 {
        return self.user_buf[0..self.user_len];
    }

    pub fn port(self: *const Candidate) []const u8 {
        return self.port_buf[0..self.port_len];
    }

    pub fn proxyJump(self: *const Candidate) []const u8 {
        return self.proxy_jump_buf[0..self.proxy_jump_len];
    }
};

pub fn parseCandidates(_: []const u8, _: []Candidate) []Candidate {
    return &.{};
}

test "openssh config import: parses a basic host block" {
    const config =
        \\Host lab
        \\  HostName 192.0.2.10
        \\  User alice
        \\  Port 2222
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("lab", rows[0].name());
    try std.testing.expectEqualStrings("192.0.2.10", rows[0].host());
    try std.testing.expectEqualStrings("alice", rows[0].user());
    try std.testing.expectEqualStrings("2222", rows[0].port());
}

test "openssh config import: defaults host from alias and port to 22" {
    const config =
        \\Host staging
        \\  User deploy
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("staging", rows[0].host());
    try std.testing.expectEqualStrings("22", rows[0].port());
}

test "openssh config import: parses proxy jump" {
    const config =
        \\Host prod
        \\  HostName prod.internal
        \\  User root
        \\  ProxyJump jumpuser@bastion:22
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("jumpuser@bastion:22", rows[0].proxyJump());
}

test "openssh config import: splits aliases and skips wildcard aliases" {
    const config =
        \\Host gpu gpu-* ?bad [group] *
        \\  HostName gpu.example
        \\  User xzg
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("gpu", rows[0].name());
}

test "openssh config import: ignores comments blank lines and unsupported blocks" {
    const config =
        \\# comment
        \\
        \\Host nouser
        \\  HostName 192.0.2.11
        \\
        \\Host ok # inline comment
        \\  HostName ok.example
        \\  User bob
        \\  IdentityFile ~/.ssh/id_ed25519
        \\
    ;
    var out: [8]Candidate = undefined;
    const rows = parseCandidates(config, &out);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("ok", rows[0].name());
    try std.testing.expectEqualStrings("ok.example", rows[0].host());
}
```

- [ ] **Step 3: Run the fast test and verify it fails for the missing behavior**

Run:

```bash
zig build test
```

Expected: FAIL. At least the parser tests fail because `parseCandidates()` returns an empty slice.

- [ ] **Step 4: Implement the parser**

Replace the stub with these helpers and implementation in `src/openssh_config_import.zig`:

```zig
const PendingBlock = struct {
    alias_bufs: [MAX_ALIASES_PER_HOST][FIELD_MAX]u8 = undefined,
    alias_lens: [MAX_ALIASES_PER_HOST]usize = .{0} ** MAX_ALIASES_PER_HOST,
    alias_count: usize = 0,
    host_buf: [FIELD_MAX]u8 = undefined,
    host_len: usize = 0,
    user_buf: [FIELD_MAX]u8 = undefined,
    user_len: usize = 0,
    port_buf: [FIELD_MAX]u8 = undefined,
    port_len: usize = 0,
    proxy_jump_buf: [FIELD_MAX]u8 = undefined,
    proxy_jump_len: usize = 0,

    fn reset(self: *PendingBlock) void {
        self.* = .{};
    }

    fn addAlias(self: *PendingBlock, alias_raw: []const u8) void {
        const alias = std.mem.trim(u8, alias_raw, " \t\r\n");
        if (!isImportableAlias(alias)) return;
        if (self.alias_count >= MAX_ALIASES_PER_HOST) return;
        copyInto(&self.alias_bufs[self.alias_count], &self.alias_lens[self.alias_count], alias);
        self.alias_count += 1;
    }
};

fn copyInto(buf: *[FIELD_MAX]u8, len: *usize, value_raw: []const u8) void {
    const value = std.mem.trim(u8, value_raw, " \t\r\n");
    const n = @min(value.len, FIELD_MAX);
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

fn isImportableAlias(alias: []const u8) bool {
    if (alias.len == 0) return false;
    if (std.mem.eql(u8, alias, "*")) return false;
    for (alias) |ch| {
        if (ch == '*' or ch == '?' or ch == '[' or ch == ']') return false;
    }
    return true;
}

fn stripComment(line: []const u8) []const u8 {
    const hash = std.mem.indexOfScalar(u8, line, '#') orelse return line;
    return line[0..hash];
}

fn splitKeywordValue(line_raw: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const line = std.mem.trim(u8, stripComment(line_raw), " \t\r\n");
    if (line.len == 0) return null;
    var i: usize = 0;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
    const key = line[0..i];
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return .{ .key = key, .value = line[i..] };
}

fn flushBlock(block: *const PendingBlock, out: []Candidate, count: *usize) void {
    if (block.alias_count == 0 or block.user_len == 0) return;
    for (0..block.alias_count) |idx| {
        if (count.* >= out.len) return;
        var row = Candidate{};
        const alias = block.alias_bufs[idx][0..block.alias_lens[idx]];
        copyInto(&row.name_buf, &row.name_len, alias);
        if (block.host_len > 0) {
            copyInto(&row.host_buf, &row.host_len, block.host_buf[0..block.host_len]);
        } else {
            copyInto(&row.host_buf, &row.host_len, alias);
        }
        copyInto(&row.user_buf, &row.user_len, block.user_buf[0..block.user_len]);
        if (block.port_len > 0) {
            copyInto(&row.port_buf, &row.port_len, block.port_buf[0..block.port_len]);
        } else {
            copyInto(&row.port_buf, &row.port_len, "22");
        }
        copyInto(&row.proxy_jump_buf, &row.proxy_jump_len, block.proxy_jump_buf[0..block.proxy_jump_len]);
        out[count.*] = row;
        count.* += 1;
    }
}

pub fn parseCandidates(text: []const u8, out: []Candidate) []Candidate {
    var block = PendingBlock{};
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const parsed = splitKeywordValue(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(parsed.key, "Host")) {
            flushBlock(&block, out, &count);
            block.reset();
            var aliases = std.mem.tokenizeAny(u8, parsed.value, " \t");
            while (aliases.next()) |alias| block.addAlias(alias);
            continue;
        }
        if (block.alias_count == 0) continue;
        if (std.ascii.eqlIgnoreCase(parsed.key, "HostName")) {
            copyInto(&block.host_buf, &block.host_len, parsed.value);
        } else if (std.ascii.eqlIgnoreCase(parsed.key, "User")) {
            copyInto(&block.user_buf, &block.user_len, parsed.value);
        } else if (std.ascii.eqlIgnoreCase(parsed.key, "Port")) {
            copyInto(&block.port_buf, &block.port_len, parsed.value);
        } else if (std.ascii.eqlIgnoreCase(parsed.key, "ProxyJump")) {
            copyInto(&block.proxy_jump_buf, &block.proxy_jump_len, parsed.value);
        }
    }
    flushBlock(&block, out, &count);
    return out[0..count];
}
```

- [ ] **Step 5: Run the fast test and verify the parser passes**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit parser work**

Run:

```bash
git add src/openssh_config_import.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: parse openssh config imports"
```

## Task 2: Add Default OpenSSH Config Path Resolution

**Files:**
- Modify: `src/platform/dirs.zig`

- [ ] **Step 1: Write path-resolution tests**

Add this test near the existing platform dirs path tests:

```zig
test "platform dirs resolve openssh config path per OS" {
    const allocator = std.testing.allocator;

    const windows = try openSshConfigPathFromEnvForOs(allocator, .windows, .{
        .userprofile = "C:/Users/alice",
        .home = "/ignored",
    });
    defer allocator.free(windows);
    const expected_windows = try std.fs.path.join(allocator, &.{ "C:/Users/alice", ".ssh", "config" });
    defer allocator.free(expected_windows);
    try std.testing.expectEqualStrings(expected_windows, windows);

    const linux = try openSshConfigPathFromEnvForOs(allocator, .linux, .{
        .home = "/home/alice",
    });
    defer allocator.free(linux);
    const expected_linux = try std.fs.path.join(allocator, &.{ "/home/alice", ".ssh", "config" });
    defer allocator.free(expected_linux);
    try std.testing.expectEqualStrings(expected_linux, linux);

    try std.testing.expectError(error.NoOpenSshConfigPath, openSshConfigPathFromEnvForOs(allocator, .linux, .{}));
}
```

- [ ] **Step 2: Run the fast test and verify it fails**

Run:

```bash
zig build test
```

Expected: FAIL with an undeclared `openSshConfigPathFromEnvForOs` symbol.

- [ ] **Step 3: Implement path helpers**

In `src/platform/dirs.zig`, add these functions near `sshHostsPath()`:

```zig
pub fn openSshConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const userprofile = envVarOwned(allocator, "USERPROFILE");
    defer if (userprofile) |value| allocator.free(value);
    const home = envVarOwned(allocator, "HOME");
    defer if (home) |value| allocator.free(value);
    return openSshConfigPathFromEnvForOs(allocator, builtin.os.tag, .{
        .userprofile = userprofile,
        .home = home,
    });
}

pub fn openSshConfigPathFromEnvForOs(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    env: Env,
) ![]const u8 {
    const base = switch (os_tag) {
        .windows => nonEmpty(env.userprofile) orelse nonEmpty(env.home) orelse return error.NoOpenSshConfigPath,
        else => nonEmpty(env.home) orelse return error.NoOpenSshConfigPath,
    };
    return std.fs.path.join(allocator, &.{ base, ".ssh", "config" });
}
```

- [ ] **Step 4: Run the fast test and verify path helpers pass**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit path helper work**

Run:

```bash
git add src/platform/dirs.zig
git commit -m "feat: resolve openssh config path"
```

## Task 3: Add SSH Profile Import And New Session Row

**Files:**
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Add failing overlay tests for row mapping and password-preserving merge**

Append these tests near the existing SSH list tests in `src/renderer/overlays.zig`:

```zig
test "overlays: SSH manage list includes Load OpenSSH config action" {
    const saved_count = g_ssh_profile_count;
    const saved_mode = g_ssh_list_mode;
    defer {
        g_ssh_profile_count = saved_count;
        g_ssh_list_mode = saved_mode;
    }

    g_ssh_profile_count = 0;
    g_ssh_list_mode = .manage;
    try std.testing.expectEqual(@as(usize, 5), sshListRowCount());
    try std.testing.expectEqual(SshManageAction.load_openssh_config, sshManageActionForRow(0, sshVisibleProfileCount()));
    try std.testing.expectEqual(SshManageAction.new_ssh, sshManageActionForRow(1, sshVisibleProfileCount()));

    g_ssh_profile_count = 1;
    g_ssh_profiles[0] = makeSshProfile("GPU", "10.0.0.1", "user", "22");
    try std.testing.expectEqual(@as(usize, 6), sshListRowCount());
    try std.testing.expectEqual(SshManageAction.profile, sshManageActionForRow(0, sshVisibleProfileCount()));
    try std.testing.expectEqual(SshManageAction.load_openssh_config, sshManageActionForRow(1, sshVisibleProfileCount()));
}

test "overlays: OpenSSH import merge preserves existing password" {
    const saved_count = g_ssh_profile_count;
    defer {
        g_ssh_profile_count = saved_count;
    }

    g_ssh_profile_count = 1;
    g_ssh_profiles[0] = makeSshProfile("lab", "old.example", "olduser", "22");
    copySshProfileField(&g_ssh_profiles[0], .password, "secret");

    var candidate = openssh_config_import.Candidate{};
    opensshCandidateSetForTest(&candidate, .name, "lab");
    opensshCandidateSetForTest(&candidate, .host, "new.example");
    opensshCandidateSetForTest(&candidate, .user, "alice");
    opensshCandidateSetForTest(&candidate, .port, "2222");
    opensshCandidateSetForTest(&candidate, .proxy_jump, "jump.example");

    var stats = OpenSshImportStats{};
    mergeOpenSshCandidate(candidate, &stats);

    try std.testing.expectEqual(@as(usize, 1), stats.updated);
    try std.testing.expectEqualStrings("new.example", profileField(&g_ssh_profiles[0], .ip));
    try std.testing.expectEqualStrings("alice", profileField(&g_ssh_profiles[0], .user));
    try std.testing.expectEqualStrings("2222", profileField(&g_ssh_profiles[0], .port));
    try std.testing.expectEqualStrings("jump.example", profileField(&g_ssh_profiles[0], .proxy_jump));
    try std.testing.expectEqualStrings("secret", profileField(&g_ssh_profiles[0], .password));
}
```

- [ ] **Step 2: Run the full test compile and verify it fails**

Run:

```bash
zig build test-full
```

Expected: FAIL with missing `SshManageAction`, `sshManageActionForRow`, `OpenSshImportStats`, `mergeOpenSshCandidate`, or `opensshCandidateSetForTest`.

- [ ] **Step 3: Add imports, action enum values, and row mapping helper**

In `src/renderer/overlays.zig`, add the parser import near `profile_codec`:

```zig
const openssh_config_import = @import("../openssh_config_import.zig");
```

Add `load_openssh_config` to `SessionAction`:

```zig
    load_openssh_config,
```

Add this helper near `sshListRowCount()`:

```zig
const SshManageAction = enum {
    profile,
    load_openssh_config,
    new_ssh,
    edit_ssh,
    delete_ssh,
    cancel,
};

fn sshManageActionForRow(row: usize, visible_profile_count: usize) SshManageAction {
    if (row < visible_profile_count) return .profile;
    return switch (row - visible_profile_count) {
        0 => .load_openssh_config,
        1 => .new_ssh,
        2 => .edit_ssh,
        3 => .delete_ssh,
        else => .cancel,
    };
}
```

Change `sshListRowCount()` manage mode from `sshVisibleProfileCount() + 4` to:

```zig
        .manage => sshVisibleProfileCount() + 5,
```

- [ ] **Step 4: Route the new row from mouse and keyboard**

Update `sessionLauncherExecuteAt()`:

```zig
        .load_openssh_config => loadOpenSshConfigDefault(),
```

Update the `g_ssh_list_visible` branch of `sessionHitTest()` to use `sshManageActionForRow()`:

```zig
        if (row < sshVisibleProfileCount()) return .connect_selected;
        if (g_ssh_list_mode != .manage) return .connect_selected;
        return switch (sshManageActionForRow(row, sshVisibleProfileCount())) {
            .profile => .connect_selected,
            .load_openssh_config => .load_openssh_config,
            .new_ssh => .new_ssh,
            .edit_ssh => .edit_selected,
            .delete_ssh => .delete_selected,
            .cancel => .cancel,
        };
```

Update the `.manage` branch of `runSshListRow()`:

```zig
            switch (sshManageActionForRow(row, visible_profile_count)) {
                .profile => {
                    const profile_idx = sshVisibleProfileIndexAt(row) orelse return;
                    connectSshProfile(profile_idx);
                },
                .load_openssh_config => loadOpenSshConfigDefault(),
                .new_ssh => openSshFormNew(),
                .edit_ssh => openSshEditPicker(),
                .delete_ssh => openSshDeletePicker(),
                .cancel => sessionLauncherClose(),
            }
```

- [ ] **Step 5: Implement merge statistics and candidate merge**

Add this code near `agentSaveSshProfile()`:

```zig
const OpenSshImportStats = struct {
    created: usize = 0,
    updated: usize = 0,
    skipped: usize = 0,
    capped: bool = false,
};

fn findLoadedSshProfileIndex(identifier_raw: []const u8) ?usize {
    const identifier = std.mem.trim(u8, identifier_raw, " \t\r\n");
    if (identifier.len == 0) return null;
    for (0..g_ssh_profile_count) |idx| {
        if (std.ascii.eqlIgnoreCase(identifier, profileField(&g_ssh_profiles[idx], .name))) return idx;
    }
    for (0..g_ssh_profile_count) |idx| {
        if (std.ascii.eqlIgnoreCase(identifier, profileField(&g_ssh_profiles[idx], .ip))) return idx;
    }
    return null;
}

fn mergeOpenSshCandidate(candidate: openssh_config_import.Candidate, stats: *OpenSshImportStats) void {
    const name = candidate.name();
    const host = candidate.host();
    const user = candidate.user();
    const port = candidate.port();
    const proxy_jump = candidate.proxyJump();
    if (name.len == 0 or host.len == 0 or user.len == 0) {
        stats.skipped += 1;
        return;
    }
    if (!isSshTokenSafe(name) or !isSshTokenSafe(host) or !isSshTokenSafe(user)) {
        stats.skipped += 1;
        return;
    }
    if (!isPortTokenSafe(port) or !command_palette_model.isProxyJumpSafe(proxy_jump)) {
        stats.skipped += 1;
        return;
    }

    const found_idx = findLoadedSshProfileIndex(name) orelse findLoadedSshProfileIndex(host);
    var created_new = false;
    const idx = found_idx orelse blk: {
        if (g_ssh_profile_count >= SSH_PROFILE_MAX) {
            stats.capped = true;
            return;
        }
        const next = g_ssh_profile_count;
        g_ssh_profile_count += 1;
        g_ssh_profiles[next] = .{};
        created_new = true;
        break :blk next;
    };

    if (idx >= g_ssh_profile_count) {
        stats.skipped += 1;
        return;
    }

    if (created_new) {
        stats.created += 1;
    } else {
        stats.updated += 1;
    }
    const profile = &g_ssh_profiles[idx];
    copySshProfileField(profile, .name, name);
    copySshProfileField(profile, .ip, host);
    copySshProfileField(profile, .user, user);
    copySshProfileField(profile, .port, if (port.len > 0) port else "22");
    copySshProfileField(profile, .proxy_jump, proxy_jump);
}

fn opensshCandidateSetForTest(candidate: *openssh_config_import.Candidate, comptime field: enum { name, host, user, port, proxy_jump }, value: []const u8) void {
    const len = @min(value.len, openssh_config_import.FIELD_MAX);
    switch (field) {
        .name => {
            @memcpy(candidate.name_buf[0..len], value[0..len]);
            candidate.name_len = len;
        },
        .host => {
            @memcpy(candidate.host_buf[0..len], value[0..len]);
            candidate.host_len = len;
        },
        .user => {
            @memcpy(candidate.user_buf[0..len], value[0..len]);
            candidate.user_len = len;
        },
        .port => {
            @memcpy(candidate.port_buf[0..len], value[0..len]);
            candidate.port_len = len;
        },
        .proxy_jump => {
            @memcpy(candidate.proxy_jump_buf[0..len], value[0..len]);
            candidate.proxy_jump_len = len;
        },
    }
}
```

- [ ] **Step 6: Implement default file import**

Refactor the existing `saveSshProfiles()` body into a checked helper so the import command can avoid claiming persistence after a failed write:

```zig
fn saveSshProfiles(allocator: std.mem.Allocator) void {
    _ = saveSshProfilesChecked(allocator);
}

fn saveSshProfilesChecked(allocator: std.mem.Allocator) bool {
    const path = sshProfilesPath(allocator) catch return false;
    defer allocator.free(path);
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return false;
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    out.appendSlice(allocator, "# WispTerm SSH profiles. Fields are hex encoded: name, host, user, password, port, proxy_jump.\n") catch return false;
    for (g_ssh_profiles[0..g_ssh_profile_count]) |profile| {
        for (0..SSH_FIELD_COUNT) |i| {
            if (i > 0) out.append(allocator, '\t') catch return false;
            appendHexField(allocator, &out, profile.fields[i][0..profile.lens[i]]) catch return false;
        }
        out.append(allocator, '\n') catch return false;
    }

    const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return false;
    defer file.close();
    file.writeAll(out.items) catch return false;
    return true;
}
```

Add this function near the SSH profile persistence functions:

```zig
fn loadOpenSshConfigDefault() void {
    const allocator = AppWindow.g_allocator orelse return;
    loadSshProfiles();

    const path = platform_dirs.openSshConfigPath(allocator) catch {
        openSshList();
        showStatusToast("OpenSSH config not found");
        return;
    };
    defer allocator.free(path);

    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        openSshList();
        showStatusToast("OpenSSH config not found");
        return;
    };
    defer allocator.free(content);

    var candidates_buf: [64]openssh_config_import.Candidate = undefined;
    const candidates = openssh_config_import.parseCandidates(content, &candidates_buf);
    var stats = OpenSshImportStats{};
    for (candidates) |candidate| mergeOpenSshCandidate(candidate, &stats);

    var saved = true;
    if (stats.created + stats.updated > 0) {
        saved = saveSshProfilesChecked(allocator);
    }
    openSshList();

    var msg_buf: [96]u8 = undefined;
    const msg = if (stats.created + stats.updated == 0)
        "No OpenSSH hosts imported"
    else if (!saved)
        std.fmt.bufPrint(&msg_buf, "Imported {d}, updated {d} SSH profiles (not saved)", .{ stats.created, stats.updated }) catch "Imported OpenSSH profiles (not saved)"
    else
        std.fmt.bufPrint(&msg_buf, "Imported {d}, updated {d} SSH profiles", .{ stats.created, stats.updated }) catch "Imported OpenSSH profiles";
    showStatusToast(msg);
}
```

- [ ] **Step 7: Render the import row in the SSH list**

In `renderSessionLauncher()` under `g_ssh_list_visible` and `.manage`, render the new action before New/Edit/Delete:

```zig
                    renderSessionRow(layout, window_height, row, "Load OpenSSH config", "~/.ssh/config", g_ssh_list_selected == row);
                    row += 1;
                    renderSessionRow(layout, window_height, row, i18n.s().sl_new_ssh_server, i18n.s().sl_v_add, g_ssh_list_selected == row);
```

Update `sessionDesiredBoxWidth()` for `g_ssh_list_visible` manage mode so the new row participates in sizing:

```zig
                    desired = @max(desired, sessionTwoColumnWidth("Load OpenSSH config", "~/.ssh/config"));
```

- [ ] **Step 8: Update existing SSH list tests for the extra action row**

In existing tests that expect `sshListRowCount()` in manage mode, update counts by one. For example:

```zig
try std.testing.expectEqual(@as(usize, 7), sshListRowCount());
```

for the test with two visible filtered profiles.

- [ ] **Step 9: Run full tests and verify overlay behavior passes**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 10: Commit overlay import work**

Run:

```bash
git add src/renderer/overlays.zig
git commit -m "feat: import openssh config into ssh profiles"
```

## Task 4: Add Command Center Entry, Localization, And Docs

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/i18n.zig`
- Modify: `docs/configuration.md`

- [ ] **Step 1: Add failing command lookup test**

In `src/command_center_state.zig`, add:

```zig
test "findCommandAction resolves Load OpenSSH Config" {
    try std.testing.expectEqual(CommandAction.load_openssh_config, findCommandAction("Load OpenSSH Config"));
}
```

- [ ] **Step 2: Run the fast test and verify it fails**

Run:

```bash
zig build test
```

Expected: FAIL with missing `CommandAction.load_openssh_config`.

- [ ] **Step 3: Add the command action and static entry**

In `src/command_center_state.zig`, add this enum member:

```zig
    load_openssh_config,
```

Add this `command_entries` item near `New Session`:

```zig
    .{ .title = "Load OpenSSH Config", .detail = "Import ~/.ssh/config into SSH profiles", .shortcut = "", .action = .load_openssh_config },
```

- [ ] **Step 4: Route command execution**

In `src/renderer/overlays.zig`, update `executeCommand()`:

```zig
        .load_openssh_config => loadOpenSshConfigDefault(),
```

The function should leave the command palette by opening the SSH list through `openSshList()` after import.

- [ ] **Step 5: Add i18n switch cases**

In `src/i18n.zig`, update `commandTitle()`:

```zig
        .load_openssh_config => "导入 OpenSSH 配置",
```

Update `commandDetail()`:

```zig
        .load_openssh_config => "把 ~/.ssh/config 导入为 SSH profile",
```

- [ ] **Step 6: Document the new command**

In `docs/configuration.md`, after the Settings page section, add:

```markdown
## OpenSSH config import

Open the command center and run **Load OpenSSH Config** to import compatible
entries from `~/.ssh/config` into WispTerm's SSH profiles. WispTerm imports
`Host`, `HostName`, `User`, `Port`, and `ProxyJump`, skips wildcard host
patterns, and does not import passwords.
```

- [ ] **Step 7: Run fast tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit command and docs work**

Run:

```bash
git add src/command_center_state.zig src/i18n.zig src/renderer/overlays.zig docs/configuration.md
git commit -m "feat: expose openssh config import command"
```

## Task 5: Final Verification

**Files:**
- Verify all changed files.

- [ ] **Step 1: Check final diff**

Run:

```bash
git status --short
git log --oneline -5
```

Expected: only intended files are committed or staged for final cleanup. Existing untracked `.claude/` remains untracked and is not committed.

- [ ] **Step 2: Check whitespace**

Run:

```bash
git diff --check
```

Expected: no output and exit code 0.

- [ ] **Step 3: Run fast tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 4: Run full tests**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 5: Summarize implementation**

Report:

- Parser module added in `src/openssh_config_import.zig`.
- Default path helper added in `src/platform/dirs.zig`.
- Command Center command and first-run SSH list row added.
- Import preserves existing saved passwords and never reads password data from OpenSSH config.
- Verification command outputs.
