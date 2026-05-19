# SSH File Transfer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `Ctrl+Alt` click remote downloads, configurable SSH download directory, conflict choices, and non-blocking SSH upload/download jobs.

**Architecture:** Keep SCP/SSH process execution in `src/scp.zig`, keep File Explorer transfer state in `src/file_explorer.zig`, and add a small pure path helper module for download-directory and rename-candidate behavior. Input owns the click gesture and pending conflict flow; overlays owns the modal prompt rendering and hit testing.

**Tech Stack:** Zig 0.15.2, Win32/OpenGL UI, existing `scp.exe`/`ssh.exe` helpers, `std.Thread`, `std.atomic.Value`, Phantty config `key = value` parser.

---

## Scope Notes

Ghostty comparison from the approved spec still applies:

- Ghostty has OSC 7 current-working-directory handling and shell integration.
- Ghostty does not have an SCP file explorer or SCP download gesture.
- This implementation should not add terminal-emulation logic. It should stay in Phantty's app/input/file-explorer layer and continue using the existing `scp.zig` helper behavior.

Implementation must follow the approved design in `docs/superpowers/specs/2026-05-19-ssh-file-transfer-design.md`. If a step turns out to require a different behavior, stop and ask before changing the plan.

## File Structure

- Create `src/file_transfer_paths.zig`: pure helpers for default Downloads path, Windows path joining, conflict-name generation, and first available rename target.
- Modify `src/test_main.zig`: import the new helper module tests.
- Modify `src/config.zig`: add `ssh-download-dir`, parse it, document it in the default config template, and add parser tests.
- Modify `src/App.zig`: store `ssh_download_dir` in runtime app state and update it on config reload.
- Modify `src/file_explorer.zig`: add one active background transfer job, expose download/upload start functions, and keep remote listing jobs independent.
- Modify `src/input.zig`: route `Ctrl+Alt` click to download, reuse the flow for `Ctrl+S`, handle conflict choices, and keep SSH terminal drag-drop upload off the UI thread.
- Modify `src/renderer/overlays.zig`: add a three-action file conflict prompt with keyboard and mouse handling.
- Modify `src/AppWindow.zig`: render the conflict prompt in both render paths.
- Modify `README.md` and `src/renderer/overlays.zig`: update shortcut/config documentation and startup shortcut text.

## Task 1: Add File Transfer Path Helpers

**Files:**
- Create: `src/file_transfer_paths.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing tests**

Add this import to `src/test_main.zig` inside the existing `comptime` block:

```zig
    _ = @import("file_transfer_paths.zig");
```

Create `src/file_transfer_paths.zig` with only tests first:

```zig
const std = @import("std");

test "file_transfer_paths: default downloads dir appends Downloads" {
    var buf: [260]u8 = undefined;
    const path = defaultDownloadsDirFromUserProfile(&buf, "C:\\Users\\me").?;
    try std.testing.expectEqualStrings("C:\\Users\\me\\Downloads", path);
}

test "file_transfer_paths: joinWindowsPath avoids duplicate separators" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "C:\\Users\\me\\Downloads\\report.txt",
        joinWindowsPath(&buf, "C:\\Users\\me\\Downloads", "report.txt").?,
    );
    try std.testing.expectEqualStrings(
        "C:\\Users\\me\\Downloads\\report.txt",
        joinWindowsPath(&buf, "C:\\Users\\me\\Downloads\\", "report.txt").?,
    );
}

test "file_transfer_paths: rename candidate preserves extension" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "report (1).txt",
        renameCandidateName(&buf, "report.txt", 1).?,
    );
    try std.testing.expectEqualStrings(
        "archive.tar (2).gz",
        renameCandidateName(&buf, "archive.tar.gz", 2).?,
    );
    try std.testing.expectEqualStrings(
        ".env (3)",
        renameCandidateName(&buf, ".env", 3).?,
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```powershell
zig build test
```

Expected: FAIL with compile errors for undefined `defaultDownloadsDirFromUserProfile`, `joinWindowsPath`, and `renameCandidateName`.

- [ ] **Step 3: Implement the helper module**

Replace `src/file_transfer_paths.zig` with this implementation plus the tests from Step 1:

```zig
const std = @import("std");

pub fn defaultDownloadsDir(buf: *[260]u8) ?[]const u8 {
    const userprofile = std.process.getEnvVarOwned(std.heap.page_allocator, "USERPROFILE") catch return null;
    defer std.heap.page_allocator.free(userprofile);
    return defaultDownloadsDirFromUserProfile(buf, userprofile);
}

pub fn defaultDownloadsDirFromUserProfile(buf: *[260]u8, userprofile: []const u8) ?[]const u8 {
    return joinWindowsPathSmall(buf, userprofile, "Downloads");
}

fn joinWindowsPathSmall(buf: *[260]u8, dir: []const u8, name: []const u8) ?[]const u8 {
    var wide: [512]u8 = undefined;
    const joined = joinWindowsPath(&wide, dir, name) orelse return null;
    if (joined.len > buf.len) return null;
    @memcpy(buf[0..joined.len], joined);
    return buf[0..joined.len];
}

pub fn joinWindowsPath(buf: *[512]u8, dir: []const u8, name: []const u8) ?[]const u8 {
    if (dir.len == 0 or name.len == 0) return null;
    if (dir.len > buf.len) return null;
    @memcpy(buf[0..dir.len], dir);
    var pos = dir.len;
    const last = dir[dir.len - 1];
    if (last != '\\' and last != '/') {
        if (pos >= buf.len) return null;
        buf[pos] = '\\';
        pos += 1;
    }
    if (pos + name.len > buf.len) return null;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    return buf[0..pos];
}

pub fn renameCandidateName(buf: *[512]u8, filename: []const u8, index: usize) ?[]const u8 {
    if (filename.len == 0 or index == 0) return null;
    const dot = extensionDot(filename);
    const stem = filename[0..dot];
    const ext = filename[dot..];
    const written = std.fmt.bufPrint(buf, "{s} ({d}){s}", .{ stem, index, ext }) catch return null;
    return written;
}

fn extensionDot(filename: []const u8) usize {
    var i = filename.len;
    while (i > 0) {
        i -= 1;
        if (filename[i] == '.') {
            if (i == 0) return filename.len;
            return i;
        }
    }
    return filename.len;
}

pub fn firstAvailableRenamePath(buf: *[512]u8, dir: []const u8, filename: []const u8) ?[]const u8 {
    var name_buf: [512]u8 = undefined;
    var i: usize = 1;
    while (i < 1000) : (i += 1) {
        const candidate_name = renameCandidateName(&name_buf, filename, i) orelse return null;
        const candidate_path = joinWindowsPath(buf, dir, candidate_name) orelse return null;
        if (!pathExists(candidate_path)) return candidate_path;
    }
    return null;
}

pub fn pathExists(path: []const u8) bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.openFileAbsolute(path, .{}) catch return false
    else
        std.fs.cwd().openFile(path, .{}) catch return false;
    file.close();
    return true;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add src/file_transfer_paths.zig src/test_main.zig
git commit -m "Add file transfer path helpers"
```

## Task 2: Add `ssh-download-dir` Config and App State

**Files:**
- Modify: `src/config.zig`
- Modify: `src/App.zig`
- Modify: `README.md`

- [ ] **Step 1: Write the failing config test**

Add this test near the existing SSH config tests in `src/config.zig`:

```zig
test "config: ssh download dir parses" {
    const allocator = std.testing.allocator;
    var cfg: Config = .{};
    defer cfg.deinit(allocator);

    try std.testing.expect(cfg.@"ssh-download-dir" == null);

    cfg.applyKeyValue(allocator, "ssh-download-dir", "D:\\Downloads\\Servers", ".");
    try std.testing.expectEqualStrings("D:\\Downloads\\Servers", cfg.@"ssh-download-dir".?);

    cfg.applyKeyValue(allocator, "ssh-download-dir", "", ".");
    try std.testing.expect(cfg.@"ssh-download-dir" == null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```powershell
zig build test
```

Expected: FAIL with no field named `ssh-download-dir`.

- [ ] **Step 3: Implement config parsing**

In `src/config.zig`, add the field near the SSH config fields:

```zig
/// Local directory used for SSH File Explorer downloads. Null uses Downloads.
@"ssh-download-dir": ?[]const u8 = null,
```

In `applyKeyValue`, directly after the `ssh-legacy-algorithms` branch, add:

```zig
    } else if (std.mem.eql(u8, key, "ssh-download-dir")) {
        if (value.len == 0) {
            self.@"ssh-download-dir" = null;
        } else {
            self.@"ssh-download-dir" = self.dupeString(allocator, value) orelse return;
        }
```

In the default config template after `ssh-legacy-algorithms`, add:

```zig
    \\# Local directory for SSH File Explorer downloads. Empty uses %USERPROFILE%\Downloads.
    \\# ssh-download-dir =
    \\
```

- [ ] **Step 4: Wire App runtime state**

In `src/App.zig`, add the field near `ssh_legacy_algorithms`:

```zig
ssh_download_dir: ?[]const u8,
```

In `App.init`, after `background_image` is allocated, duplicate the new config value:

```zig
    const ssh_download_dir = try dupeOptStr(allocator, cfg.@"ssh-download-dir");
    errdefer freeOptStr(allocator, ssh_download_dir);
```

Set it in the `App` initializer near `ssh_legacy_algorithms`:

```zig
        .ssh_download_dir = ssh_download_dir,
```

In `reloadConfig`, after `self.ssh_legacy_algorithms = cfg.@"ssh-legacy-algorithms";`, add:

```zig
    self.replaceOptStr(&self.ssh_download_dir, cfg.@"ssh-download-dir");
```

In `App.deinit`, free it near other optional strings:

```zig
    freeOptStr(self.allocator, self.ssh_download_dir);
```

- [ ] **Step 5: Update README config table**

In `README.md`, add this row near `ssh-legacy-algorithms` or the remote/file explorer config rows:

```markdown
| `ssh-download-dir`         | *(none)*   | Local directory for SSH File Explorer downloads. When unset, downloads use `%USERPROFILE%\Downloads`. |
```

- [ ] **Step 6: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add src/config.zig src/App.zig README.md
git commit -m "Add SSH download directory config"
```

## Task 3: Move File Explorer Transfers to Background Jobs

**Files:**
- Modify: `src/file_explorer.zig`

- [ ] **Step 1: Write failing transfer job tests**

Add these tests near the existing `setTransferStatus` test in `src/file_explorer.zig`:

```zig
fn fakeTransferOk(_: std.mem.Allocator, _: *const Surface.SshConnection, _: []const u8, _: []const u8) scp.TransferResult {
    return .ok;
}

fn fakeTransferFailed(_: std.mem.Allocator, _: *const Surface.SshConnection, _: []const u8, _: []const u8) scp.TransferResult {
    return .failed;
}

test "file_explorer: transfer job reports success asynchronously" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: Surface.SshConnection = .{};
    @memcpy(conn.user_buf[0..4], "root");
    conn.user_len = 4;
    @memcpy(conn.host_buf[0..9], "localhost");
    conn.host_len = 9;

    try std.testing.expect(startTransferJobForTest(.download, &conn, "root@localhost:/tmp/a.txt", "C:\\Users\\me\\Downloads\\a.txt", "a.txt", fakeTransferOk));

    var attempts: usize = 0;
    while (g_transfer_job != null and attempts < 1000) : (attempts += 1) {
        tickAsync();
        std.time.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expect(g_transfer_job == null);
    try std.testing.expectEqual(TransferStatus.success, g_transfer_status);
    try std.testing.expectEqualStrings("a.txt", g_transfer_msg[0..g_transfer_msg_len]);
}

test "file_explorer: second active transfer is rejected" {
    resetTransferStateForTest();
    defer resetTransferStateForTest();

    var conn: Surface.SshConnection = .{};
    @memcpy(conn.user_buf[0..4], "root");
    conn.user_len = 4;
    @memcpy(conn.host_buf[0..9], "localhost");
    conn.host_len = 9;

    try std.testing.expect(startTransferJobForTest(.download, &conn, "root@localhost:/tmp/a.txt", "C:\\Users\\me\\Downloads\\a.txt", "a.txt", fakeTransferFailed));
    try std.testing.expect(!startTransferJobForTest(.download, &conn, "root@localhost:/tmp/b.txt", "C:\\Users\\me\\Downloads\\b.txt", "b.txt", fakeTransferFailed));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
zig build test
```

Expected: FAIL with undefined `resetTransferStateForTest`, `startTransferJobForTest`, and `g_transfer_job`.

- [ ] **Step 3: Add transfer job types and state**

In `src/file_explorer.zig`, add these definitions after the async list state:

```zig
pub const TransferKind = enum { upload, download };
const TransferFn = *const fn (std.mem.Allocator, *const Surface.SshConnection, []const u8, []const u8) scp.TransferResult;

const TransferJob = struct {
    kind: TransferKind,
    conn: Surface.SshConnection,
    context_id: u64,
    src_buf: [512]u8 = undefined,
    src_len: usize = 0,
    dst_buf: [512]u8 = undefined,
    dst_len: usize = 0,
    display_buf: [128]u8 = undefined,
    display_len: usize = 0,
    transfer_fn: TransferFn = scp.transfer,
    result: scp.TransferResult = .failed,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
};

threadlocal var g_transfer_job: ?*TransferJob = null;
```

- [ ] **Step 4: Add start/tick/destroy functions**

Add this code before the current `downloadSelected` function:

```zig
fn startTransferJob(kind: TransferKind, conn: *const Surface.SshConnection, src: []const u8, dst: []const u8, display: []const u8, transfer_fn: TransferFn) bool {
    if (g_transfer_job != null) {
        setTransferStatus(.failed, "Transfer busy");
        return false;
    }
    if (src.len > 512 or dst.len > 512 or display.len > 128) return false;

    const allocator = std.heap.page_allocator;
    const job = allocator.create(TransferJob) catch return false;
    job.* = .{
        .kind = kind,
        .conn = conn.*,
        .context_id = g_async_context_id,
        .src_len = src.len,
        .dst_len = dst.len,
        .display_len = display.len,
        .transfer_fn = transfer_fn,
    };
    @memcpy(job.src_buf[0..src.len], src);
    @memcpy(job.dst_buf[0..dst.len], dst);
    @memcpy(job.display_buf[0..display.len], display);

    const thread = std.Thread.spawn(.{}, transferThread, .{job}) catch {
        allocator.destroy(job);
        return false;
    };
    job.thread = thread;
    g_transfer_job = job;
    setTransferStatus(.in_progress, display);
    return true;
}

fn transferThread(job: *TransferJob) void {
    const allocator = std.heap.page_allocator;
    const src = job.src_buf[0..job.src_len];
    const dst = job.dst_buf[0..job.dst_len];
    job.result = job.transfer_fn(allocator, &job.conn, src, dst);
    job.done.store(true, .release);
}

fn tickTransferJob() void {
    const job = g_transfer_job orelse return;
    if (!job.done.load(.acquire)) return;

    if (job.thread) |thread| thread.join();
    g_transfer_job = null;
    defer destroyTransferJob(job);

    const name = job.display_buf[0..job.display_len];
    switch (job.result) {
        .ok => {
            setTransferStatus(.success, name);
            if (job.kind == .upload and job.context_id == g_async_context_id and g_mode == .remote and g_has_ssh_conn) {
                rescanRemote();
            }
        },
        else => setTransferStatus(.failed, name),
    }
}

fn destroyTransferJob(job: *TransferJob) void {
    std.heap.page_allocator.destroy(job);
}

fn startTransferJobForTest(kind: TransferKind, conn: *const Surface.SshConnection, src: []const u8, dst: []const u8, display: []const u8, transfer_fn: TransferFn) bool {
    return startTransferJob(kind, conn, src, dst, display, transfer_fn);
}

fn resetTransferStateForTest() void {
    if (g_transfer_job) |job| {
        if (job.thread) |thread| thread.join();
        destroyTransferJob(job);
        g_transfer_job = null;
    }
    g_transfer_status = .idle;
    g_transfer_msg_len = 0;
}
```

At the start of `pub fn tickAsync() void`, add:

```zig
    tickTransferJob();
```

In `pub fn deinit() void`, before clearing history rows, add:

```zig
    if (g_transfer_job) |job| {
        if (job.thread) |thread| thread.join();
        destroyTransferJob(job);
        g_transfer_job = null;
    }
```

- [ ] **Step 5: Convert upload/download wrappers**

Replace the synchronous `scp.transfer` calls in `downloadSelected` and `uploadFile`.

For `downloadSelected`, after building `src`, `dst`, and `name`, use:

```zig
    _ = startTransferJob(.download, &g_ssh_conn, src, dst, name, scp.transfer);
```

For `uploadFile`, after building `dst` and `filename`, use:

```zig
    _ = startTransferJob(.upload, &g_ssh_conn, local_path, dst, filename, scp.transfer);
```

Add this public helper for the input conflict flow:

```zig
pub fn downloadRemoteFileToPath(remote_path: []const u8, local_path: []const u8, display_name: []const u8) bool {
    if (g_mode != .remote or !g_has_ssh_conn) return false;
    var spec_buf: [512]u8 = undefined;
    const src = scp.remoteSpec(&spec_buf, &g_ssh_conn, remote_path);
    return startTransferJob(.download, &g_ssh_conn, src, local_path, display_name, scp.transfer);
}
```

- [ ] **Step 6: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```powershell
git add src/file_explorer.zig
git commit -m "Run SSH file transfers in background jobs"
```

## Task 4: Add Download Flow and Conflict Prompt State

**Files:**
- Modify: `src/input.zig`
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Write failing input action tests**

In `src/input.zig`, add this pure helper and tests near other small input helpers:

```zig
const FileExplorerClickAction = enum { select_only, preview, expand_dir, download };

fn fileExplorerClickAction(mode: file_explorer.Mode, is_dir: bool, ctrl: bool, shift: bool, alt: bool, click_count: u8) FileExplorerClickAction {
    _ = mode;
    _ = is_dir;
    _ = ctrl;
    _ = shift;
    _ = alt;
    _ = click_count;
    return .select_only;
}

test "input: ctrl alt click remote file chooses download before preview" {
    try std.testing.expectEqual(
        FileExplorerClickAction.download,
        fileExplorerClickAction(.remote, false, true, false, true, 1),
    );
}

test "input: ctrl click file keeps preview action" {
    try std.testing.expectEqual(
        FileExplorerClickAction.preview,
        fileExplorerClickAction(.remote, false, true, false, false, 1),
    );
}

test "input: double click directory expands" {
    try std.testing.expectEqual(
        FileExplorerClickAction.expand_dir,
        fileExplorerClickAction(.remote, true, false, false, false, 2),
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
zig build test
```

Expected: FAIL because `fileExplorerClickAction` returns `select_only`.

- [ ] **Step 3: Implement click action helper**

Replace `fileExplorerClickAction` with:

```zig
fn fileExplorerClickAction(mode: file_explorer.Mode, is_dir: bool, ctrl: bool, shift: bool, alt: bool, click_count: u8) FileExplorerClickAction {
    if (mode == .remote and !is_dir and ctrl and alt and !shift) return .download;
    if (!is_dir and ((ctrl and !shift and !alt) or click_count == 2)) return .preview;
    if (is_dir) return .expand_dir;
    return .select_only;
}
```

- [ ] **Step 4: Add pending conflict state and helpers**

At the top of `src/input.zig`, add:

```zig
const file_transfer_paths = @import("file_transfer_paths.zig");
```

Near the other threadlocal input state, add:

```zig
const PendingDownloadConflict = struct {
    remote_path_buf: [512]u8 = undefined,
    remote_path_len: usize = 0,
    local_dir_buf: [260]u8 = undefined,
    local_dir_len: usize = 0,
    filename_buf: [128]u8 = undefined,
    filename_len: usize = 0,
};

threadlocal var g_pending_download_conflict: ?PendingDownloadConflict = null;
```

Add these helper functions near `getDownloadsFolder`:

```zig
fn configuredDownloadDir(buf: *[260]u8) []const u8 {
    if (AppWindow.g_app) |app| {
        if (app.ssh_download_dir) |dir| {
            const len = @min(dir.len, buf.len);
            @memcpy(buf[0..len], dir[0..len]);
            return buf[0..len];
        }
    }
    return file_transfer_paths.defaultDownloadsDir(buf) orelse "";
}

fn beginRemoteFileDownload(row_idx: usize) void {
    if (file_explorer.g_mode != .remote) return;
    if (row_idx >= file_explorer.g_entry_count) return;
    const entry = &file_explorer.g_entries[row_idx];
    if (entry.is_dir) return;

    var dir_buf: [260]u8 = undefined;
    const local_dir = configuredDownloadDir(&dir_buf);
    if (local_dir.len == 0) {
        file_explorer.setTransferStatus(.failed, "Download folder missing");
        return;
    }

    const filename = entry.name_buf[0..entry.name_len];
    var dst_buf: [512]u8 = undefined;
    const dst = file_transfer_paths.joinWindowsPath(&dst_buf, local_dir, filename) orelse {
        file_explorer.setTransferStatus(.failed, "Download path too long");
        return;
    };

    if (file_transfer_paths.pathExists(dst)) {
        storePendingDownloadConflict(entry, local_dir);
        overlays.fileConflictPromptOpen(filename, dst);
        AppWindow.g_force_rebuild = true;
        AppWindow.g_cells_valid = false;
        return;
    }

    const remote_path = entry.path_buf[0..entry.path_len];
    _ = file_explorer.downloadRemoteFileToPath(remote_path, dst, filename);
}

fn storePendingDownloadConflict(entry: *const file_explorer.FlatEntry, local_dir: []const u8) void {
    var pending: PendingDownloadConflict = .{};
    const remote_path = entry.path_buf[0..entry.path_len];
    pending.remote_path_len = @min(remote_path.len, pending.remote_path_buf.len);
    @memcpy(pending.remote_path_buf[0..pending.remote_path_len], remote_path[0..pending.remote_path_len]);
    pending.local_dir_len = @min(local_dir.len, pending.local_dir_buf.len);
    @memcpy(pending.local_dir_buf[0..pending.local_dir_len], local_dir[0..pending.local_dir_len]);
    const filename = entry.name_buf[0..entry.name_len];
    pending.filename_len = @min(filename.len, pending.filename_buf.len);
    @memcpy(pending.filename_buf[0..pending.filename_len], filename[0..pending.filename_len]);
    g_pending_download_conflict = pending;
}

fn resolvePendingDownloadConflict(action: overlays.FileConflictAction) void {
    const pending = g_pending_download_conflict orelse return;
    g_pending_download_conflict = null;

    if (action == .skip) {
        file_explorer.setTransferStatus(.idle, "");
        return;
    }

    const remote_path = pending.remote_path_buf[0..pending.remote_path_len];
    const local_dir = pending.local_dir_buf[0..pending.local_dir_len];
    const filename = pending.filename_buf[0..pending.filename_len];

    var dst_buf: [512]u8 = undefined;
    const dst = switch (action) {
        .skip => return,
        .overwrite => file_transfer_paths.joinWindowsPath(&dst_buf, local_dir, filename) orelse return,
        .rename => file_transfer_paths.firstAvailableRenamePath(&dst_buf, local_dir, filename) orelse return,
    };
    _ = file_explorer.downloadRemoteFileToPath(remote_path, dst, filename);
}
```

- [ ] **Step 5: Replace selected-file download path**

In `handleFileExplorerKey`, replace the current `Ctrl+S` download body with:

```zig
                if (file_explorer.g_mode == .remote) {
                    if (file_explorer.g_selected) |selected| beginRemoteFileDownload(selected);
                    return true;
                }
```

- [ ] **Step 6: Route mouse clicks through the helper**

In `handleFileExplorerPress`, replace the current row action block:

```zig
        if (!file_explorer.g_entries[row_idx].is_dir and ((ctrl and !shift and !alt) or click_count == 2)) {
            if (openFileExplorerPreview(row_idx)) {
                AppWindow.g_force_rebuild = true;
                return;
            }
        }
        if (file_explorer.g_entries[row_idx].is_dir) {
            file_explorer.toggleExpand(row_idx);
        }
```

with:

```zig
        switch (fileExplorerClickAction(file_explorer.g_mode, file_explorer.g_entries[row_idx].is_dir, ctrl, shift, alt, click_count)) {
            .download => {
                beginRemoteFileDownload(row_idx);
                AppWindow.g_force_rebuild = true;
                return;
            },
            .preview => {
                if (openFileExplorerPreview(row_idx)) {
                    AppWindow.g_force_rebuild = true;
                    return;
                }
            },
            .expand_dir => file_explorer.toggleExpand(row_idx),
            .select_only => {},
        }
```

- [ ] **Step 7: Add conflict prompt overlay API skeleton**

In `src/renderer/overlays.zig`, add this public enum near other overlay state:

```zig
pub const FileConflictAction = enum { skip, overwrite, rename };
```

Add no-op functions first:

```zig
pub fn fileConflictPromptOpen(_: []const u8, _: []const u8) void {}
pub fn fileConflictPromptVisible() bool { return false; }
pub fn fileConflictPromptHandleKey(_: win32_backend.KeyEvent) ?FileConflictAction { return null; }
pub fn fileConflictPromptExecuteAt(_: f64, _: f64, _: f32, _: f32) ?FileConflictAction { return null; }
```

This lets the input compile before the prompt is implemented in Task 5.

- [ ] **Step 8: Hook conflict prompt input**

In `handleKey`, immediately after the window close confirm branch, add:

```zig
    if (overlays.fileConflictPromptVisible()) {
        if (overlays.fileConflictPromptHandleKey(ev)) |action| resolvePendingDownloadConflict(action);
        return;
    }
```

In `handleMouse`, before the session launcher/settings/command palette branches, add:

```zig
    if (overlays.fileConflictPromptVisible()) {
        if (ev.button == .left and ev.action == .press) {
            const win = AppWindow.g_window orelse return;
            const fb = win.getFramebufferSize();
            const xpos: f64 = @floatFromInt(ev.x);
            const ypos: f64 = @floatFromInt(ev.y);
            if (overlays.fileConflictPromptExecuteAt(xpos, ypos, @floatFromInt(fb.width), @floatFromInt(fb.height))) |action| {
                resolvePendingDownloadConflict(action);
            }
        }
        return;
    }
```

- [ ] **Step 9: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 10: Commit**

```powershell
git add src/input.zig src/renderer/overlays.zig
git commit -m "Route SSH downloads through conflict-aware input flow"
```

## Task 5: Implement the Conflict Prompt Overlay

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Write failing overlay tests**

In `src/renderer/overlays.zig`, add tests near the prompt layout code added in this task:

```zig
test "overlays: file conflict buttons hit test in top coordinates" {
    fileConflictPromptOpen("report.txt", "C:\\Users\\me\\Downloads\\report.txt");
    defer fileConflictPromptClose();

    const layout = fileConflictPromptLayout(900, 600);
    try std.testing.expectEqual(
        FileConflictAction.skip,
        fileConflictPromptHitTest(layout.skip_x + 4, layout.skip_top_px + 4, layout).?,
    );
    try std.testing.expectEqual(
        FileConflictAction.overwrite,
        fileConflictPromptHitTest(layout.overwrite_x + 4, layout.overwrite_top_px + 4, layout).?,
    );
    try std.testing.expectEqual(
        FileConflictAction.rename,
        fileConflictPromptHitTest(layout.rename_x + 4, layout.rename_top_px + 4, layout).?,
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```powershell
zig build test
```

Expected: FAIL with undefined `fileConflictPromptClose`, `fileConflictPromptLayout`, and `fileConflictPromptHitTest`.

- [ ] **Step 3: Add prompt state and layout**

In `src/renderer/overlays.zig`, add:

```zig
const FileConflictPromptLayout = struct {
    panel_x: f32,
    panel_top_px: f32,
    panel_w: f32,
    panel_h: f32,
    skip_x: f32,
    skip_top_px: f32,
    skip_w: f32,
    skip_h: f32,
    overwrite_x: f32,
    overwrite_top_px: f32,
    overwrite_w: f32,
    overwrite_h: f32,
    rename_x: f32,
    rename_top_px: f32,
    rename_w: f32,
    rename_h: f32,
};

threadlocal var g_file_conflict_visible: bool = false;
threadlocal var g_file_conflict_name_buf: [128]u8 = undefined;
threadlocal var g_file_conflict_name_len: usize = 0;
threadlocal var g_file_conflict_path_buf: [260]u8 = undefined;
threadlocal var g_file_conflict_path_len: usize = 0;

fn fileConflictPromptLayout(window_width: f32, window_height: f32) FileConflictPromptLayout {
    const panel_w = @round(@min(@max(620.0, window_width - 128.0), 860.0));
    const panel_h = @round(@max(238.0, overlayTextHeight() * 4.0 + 124.0));
    const panel_x = @round(@max(24.0, (window_width - panel_w) / 2.0));
    const panel_top_px = @round(@max(48.0, (window_height - panel_h) / 2.0));

    const button_h = @round(@max(38.0, overlayTextHeight() + 16.0));
    const skip_w = @round(@max(104.0, measureTitlebarText("Skip") + 42.0));
    const overwrite_w = @round(@max(132.0, measureTitlebarText("Overwrite") + 42.0));
    const rename_w = @round(@max(116.0, measureTitlebarText("Rename") + 42.0));
    const gap: f32 = 12.0;
    const button_top_px = panel_top_px + panel_h - 30.0 - button_h;
    const rename_x = panel_x + panel_w - 32.0 - rename_w;
    const overwrite_x = rename_x - gap - overwrite_w;
    const skip_x = overwrite_x - gap - skip_w;

    return .{
        .panel_x = panel_x,
        .panel_top_px = panel_top_px,
        .panel_w = panel_w,
        .panel_h = panel_h,
        .skip_x = skip_x,
        .skip_top_px = button_top_px,
        .skip_w = skip_w,
        .skip_h = button_h,
        .overwrite_x = overwrite_x,
        .overwrite_top_px = button_top_px,
        .overwrite_w = overwrite_w,
        .overwrite_h = button_h,
        .rename_x = rename_x,
        .rename_top_px = button_top_px,
        .rename_w = rename_w,
        .rename_h = button_h,
    };
}

fn fileConflictPromptHitTest(xpos: f64, ypos: f64, layout: FileConflictPromptLayout) ?FileConflictAction {
    if (pointInTopRect(xpos, ypos, layout.skip_x, layout.skip_top_px, layout.skip_w, layout.skip_h)) return .skip;
    if (pointInTopRect(xpos, ypos, layout.overwrite_x, layout.overwrite_top_px, layout.overwrite_w, layout.overwrite_h)) return .overwrite;
    if (pointInTopRect(xpos, ypos, layout.rename_x, layout.rename_top_px, layout.rename_w, layout.rename_h)) return .rename;
    return null;
}
```

- [ ] **Step 4: Replace skeleton API functions**

Replace the Task 4 skeleton functions with:

```zig
pub fn fileConflictPromptOpen(name: []const u8, path: []const u8) void {
    g_file_conflict_visible = true;
    g_file_conflict_name_len = @min(name.len, g_file_conflict_name_buf.len);
    @memcpy(g_file_conflict_name_buf[0..g_file_conflict_name_len], name[0..g_file_conflict_name_len]);
    g_file_conflict_path_len = @min(path.len, g_file_conflict_path_buf.len);
    @memcpy(g_file_conflict_path_buf[0..g_file_conflict_path_len], path[0..g_file_conflict_path_len]);
}

pub fn fileConflictPromptClose() void {
    g_file_conflict_visible = false;
    g_file_conflict_name_len = 0;
    g_file_conflict_path_len = 0;
}

pub fn fileConflictPromptVisible() bool {
    return g_file_conflict_visible;
}

pub fn fileConflictPromptHandleKey(ev: win32_backend.KeyEvent) ?FileConflictAction {
    if (!g_file_conflict_visible) return null;
    return switch (ev.vk) {
        win32_backend.VK_ESCAPE => blk: {
            fileConflictPromptClose();
            break :blk .skip;
        },
        win32_backend.VK_RETURN => blk: {
            fileConflictPromptClose();
            break :blk .rename;
        },
        else => null,
    };
}

pub fn fileConflictPromptExecuteAt(xpos: f64, ypos: f64, window_width: f32, window_height: f32) ?FileConflictAction {
    if (!g_file_conflict_visible) return null;
    const layout = fileConflictPromptLayout(window_width, window_height);
    const action = fileConflictPromptHitTest(xpos, ypos, layout) orelse {
        if (pointInTopRect(xpos, ypos, layout.panel_x, layout.panel_top_px, layout.panel_w, layout.panel_h)) return null;
        fileConflictPromptClose();
        return .skip;
    };
    fileConflictPromptClose();
    return action;
}
```

- [ ] **Step 5: Add render function**

Add this render function next to `renderWindowCloseConfirm`:

```zig
pub fn renderFileConflictPrompt(window_width: f32, window_height: f32) void {
    if (!g_file_conflict_visible) return;

    const gl = &AppWindow.gl;
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const layout = fileConflictPromptLayout(window_width, window_height);
    const panel_y = @round(window_height - layout.panel_top_px - layout.panel_h);
    const skip_y = @round(window_height - layout.skip_top_px - layout.skip_h);
    const overwrite_y = @round(window_height - layout.overwrite_top_px - layout.overwrite_h);
    const rename_y = @round(window_height - layout.rename_top_px - layout.rename_h);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const panel = mixColor(bg, fg, 0.050);
    const panel_top = mixColor(bg, fg, 0.073);
    const panel_border = mixColor(bg, fg, 0.24);
    const quiet_border = mixColor(bg, fg, 0.15);
    const muted = mixColor(bg, fg, 0.56);
    const body = mixColor(bg, fg, 0.80);

    gl_init.renderQuadAlpha(0, 0, window_width, window_height, .{ 0.0, 0.0, 0.0 }, 0.42);
    renderRoundedQuadAlpha(layout.panel_x - 1, panel_y - 1, layout.panel_w + 2, layout.panel_h + 2, 13, panel_border, 0.42);
    renderRoundedQuadAlpha(layout.panel_x, panel_y, layout.panel_w, layout.panel_h, 12, panel, 0.99);
    renderRoundedQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 72, layout.panel_w - 2, 71, 12, panel_top, 0.78);
    gl_init.renderQuadAlpha(layout.panel_x + 1, panel_y + layout.panel_h - 72, layout.panel_w - 2, 1, quiet_border, 0.40);

    const pad: f32 = 34;
    const title_y = @round(panel_y + layout.panel_h - 50);
    const text_x = layout.panel_x + pad;
    const text_right = layout.panel_x + layout.panel_w - pad;
    renderTitlebarTextStrongLimited("File already exists", text_x, title_y, fg, text_right - text_x);

    const name = g_file_conflict_name_buf[0..g_file_conflict_name_len];
    const path = g_file_conflict_path_buf[0..g_file_conflict_path_len];
    renderTitlebarTextLimited(name, text_x, title_y - overlayTextHeight() - 16, body, text_right - text_x);
    renderTitlebarTextLimited(path, text_x, title_y - overlayTextHeight() * 2 - 24, muted, text_right - text_x);

    const footer_y = skip_y + layout.skip_h + 20;
    gl_init.renderQuadAlpha(layout.panel_x + 5, footer_y, layout.panel_w - 5, 1, quiet_border, 0.46);

    renderPromptButton(layout.skip_x, skip_y, layout.skip_w, layout.skip_h, "Skip", mixColor(bg, fg, 0.18), fg);
    renderPromptButton(layout.overwrite_x, overwrite_y, layout.overwrite_w, layout.overwrite_h, "Overwrite", mixColor(bg, .{ 0.86, 0.22, 0.20 }, 0.20), .{ 1.0, 0.72, 0.68 });
    renderPromptButton(layout.rename_x, rename_y, layout.rename_w, layout.rename_h, "Rename", mixColor(bg, accent, 0.22), mixColor(fg, accent, 0.18));
}

fn renderPromptButton(x: f32, y: f32, w: f32, h: f32, label: []const u8, bg: [3]f32, fg: [3]f32) void {
    renderRoundedQuadAlpha(x - 1, y - 1, w + 2, h + 2, 8, mixColor(fg, bg, 0.18), 0.72);
    renderRoundedQuadAlpha(x, y, w, h, 7, bg, 0.96);
    renderTitlebarTextStrong(label, x + (w - measureTitlebarText(label)) / 2, rowTextY(y, h), fg);
}
```

- [ ] **Step 6: Render it in both AppWindow paths**

In `src/AppWindow.zig`, after each call to `overlays.renderUpdatePrompt(@floatFromInt(fb_width), @floatFromInt(fb_height))` and before `overlays.renderWindowCloseConfirm(@floatFromInt(fb_width), @floatFromInt(fb_height))`, add:

```zig
    overlays.renderFileConflictPrompt(@floatFromInt(fb_width), @floatFromInt(fb_height));
```

There are two render paths in this file; add the call in both places where `renderWindowCloseConfirm` is currently called.

- [ ] **Step 7: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 8: Commit**

```powershell
git add src/renderer/overlays.zig src/AppWindow.zig
git commit -m "Add SSH download conflict prompt"
```

## Task 6: Make SSH Terminal Drag-Drop Upload Non-Blocking

**Files:**
- Modify: `src/input.zig`
- Modify: `src/file_explorer.zig`

- [ ] **Step 1: Add a public upload-to-remote-path helper**

In `src/file_explorer.zig`, add:

```zig
pub fn uploadLocalFileToRemoteSpec(local_path: []const u8, dst_spec: []const u8, display_name: []const u8, conn: *const Surface.SshConnection) bool {
    return startTransferJob(.upload, conn, local_path, dst_spec, display_name, scp.transfer);
}
```

- [ ] **Step 2: Update SSH terminal file drop**

In `handleSshTerminalFileDrop` in `src/input.zig`, replace the synchronous transfer block:

```zig
    const result = scp.transfer(allocator, &conn, local_path, destination);
    if (result != .ok) {
        std.debug.print("SSH file drop upload failed\n", .{});
        return true;
    }
```

with:

```zig
    if (!file_explorer.uploadLocalFileToRemoteSpec(local_path, destination, filename, &conn)) {
        std.debug.print("SSH file drop upload failed to start\n", .{});
        return true;
    }
```

Keep the existing paste of `remote_path` into the PTY after the job starts. This preserves the current user flow while removing the blocking `scp.transfer()` call from the UI thread.

- [ ] **Step 3: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```powershell
git add src/input.zig src/file_explorer.zig
git commit -m "Start SSH terminal drop uploads asynchronously"
```

## Task 7: Documentation and Shortcut Text

**Files:**
- Modify: `README.md`
- Modify: `src/renderer/overlays.zig`

- [ ] **Step 1: Update README keyboard shortcuts**

In the Keyboard shortcuts table, add a row directly after the preview row:

```markdown
| **Ctrl+Alt** click remote file in File Explorer                                | Download the SSH remote file to the configured local download folder              |
```

- [ ] **Step 2: Update README File Explorer section**

After the paragraph about previewing supported text files, add:

```markdown
In SSH File Explorer mode, `Ctrl+Alt` click a remote file to download it locally.
Downloads use `%USERPROFILE%\Downloads` unless `ssh-download-dir` is set in the
config file. When the destination file already exists, Phantty asks whether to
skip, overwrite, or save with a numbered name.
```

- [ ] **Step 3: Update startup shortcut overlay**

In `src/renderer/overlays.zig`, add a startup shortcut entry after the preview entry:

```zig
    .{ .keys = "Ctrl+Alt-click remote file", .action = "Download file" },
```

- [ ] **Step 4: Run tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add README.md src/renderer/overlays.zig
git commit -m "Document SSH file download shortcut"
```

## Task 8: Final Verification

**Files:**
- No source edits unless verification finds a defect.

- [ ] **Step 1: Run unit tests**

Run:

```powershell
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run development build**

Run:

```powershell
zig build
```

Expected: PASS and `.\zig-out\bin\phantty.exe` exists.

- [ ] **Step 3: Check Windows path compatibility if files were added**

Run the repository's Windows path compatibility script from `AGENTS.md` in PowerShell.

Expected output includes:

```text
windows_name_violations=0
casefold_collisions=0
```

Run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no output.

- [ ] **Step 4: Manual SSH profile verification**

If `%APPDATA%\phantty\ssh_hosts` contains a usable real SSH profile, decode only the non-password fields in the test notes and do not print or commit the password.

Verify:

```powershell
ssh.exe -p $Port "$User@$Host" pwd
scp.exe -P $Port "$User@$Host:/tmp/test-file" ".\zig-out\ui-test\test-file"
ssh.exe -T -p $Port "$User@$Host" "cat > '/tmp/test-file'"
```

Expected: all helper commands work without ControlMaster/ControlPersist/ControlPath options.

- [ ] **Step 5: Manual UI verification**

Run:

```powershell
zig build
.\zig-out\bin\phantty.exe
```

In a Phantty SSH profile session:

- Open File Explorer.
- `Ctrl+Alt` click a remote file with no local conflict.
- Confirm the file appears in `%USERPROFILE%\Downloads` or `ssh-download-dir`.
- Repeat with a conflicting local file and choose `Skip`; confirm the local file is untouched.
- Repeat and choose `Overwrite`; confirm the local file is replaced.
- Repeat and choose `Rename`; confirm `name (1).ext` or the next available suffix appears.
- Start a large upload with `U` or drag-drop and confirm the terminal remains responsive while transfer status is `in_progress`.

- [ ] **Step 6: Final status**

Run:

```powershell
git status --short
```

Expected: only intentional source/doc changes are present, or a clean tree if every task was committed.
