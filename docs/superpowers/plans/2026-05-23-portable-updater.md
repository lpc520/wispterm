# Portable Updater Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native portable updater that downloads the matching Phantty release zip, prepares it safely, launches `phantty-updater.exe`, replaces the current portable payload after exit, and relaunches Phantty.

**Architecture:** Follow Ghostty's updater shape, not its macOS Sparkle dependency: Ghostty has an `UpdateController` for entrypoints, an `UpdateDriver` that maps updater callbacks into UI state, and an `UpdateViewModel` with checking, update available, downloading, extracting, installing, and error states. Phantty will keep that state-driven split while using Windows/Zig primitives: `phantty.exe` owns release metadata, download, extraction, and UI state; `phantty-updater.exe` is a separate helper launched from the new payload to wait for the old process, replace files, roll back, and restart.

**Tech Stack:** Zig 0.15.2, Windows `x86_64-windows-gnu`, `std.http.Client`, `std.zip.extract`, Win32 process waiting/launching, existing OpenGL overlay command center, PowerShell only for packaging and verification scripts.

---

## Portable Target Rule

The update target is always the directory containing the currently running
`phantty.exe`. If the user placed Phantty at `D:\Phantty\phantty.exe`, the
download and extraction work still happens under
`%LOCALAPPDATA%\Phantty\updates\<version>\`, but the final replacement target is
`D:\Phantty\`. The updater must preserve portable user files such as
`D:\Phantty\phantty.conf`.

The current user must have write access to that target directory. If the target
is not writable, the updater fails cleanly, leaves the existing Phantty payload
in place, and keeps the release-page fallback available.

## File Structure

- Modify `src/update_check.zig`: extend release parsing to include GitHub assets, portable flavor selection, asset download URLs, richer update states, and result formatting.
- Create `src/update_install.zig`: main-app update preparation helper for runtime package flavor detection, update work directory paths, asset download, zip extraction, payload validation, and launching the helper.
- Create `src/updater_core.zig`: testable updater helper core for CLI argument parsing, path validation, replacement manifest construction, backup, replacement, rollback, and relaunch command construction.
- Create `src/updater_main.zig`: tiny native `phantty-updater.exe` entrypoint that calls `updater_core`.
- Modify `src/App.zig`: store the last installable update, add install worker state, call download/extract/helper launch, and request shutdown after helper launch.
- Modify `src/command_center_state.zig`: add an `Install Update` command center action and tests.
- Modify `src/renderer/overlays.zig`: render installable update prompts, keep release-page fallback, and add an activation API for prompt clicks.
- Modify `src/input.zig`: route update prompt clicks to the new activation API instead of always opening the release page.
- Modify `src/test_main.zig`: import `update_install.zig` and `updater_core.zig` tests.
- Modify `build.zig`: build and install `phantty-updater.exe` beside `phantty.exe`.
- Modify `packaging/windows/package.ps1`: copy `phantty-updater.exe` into all portable package directories.
- Modify `.github/workflows/windows-release.yml`: validate and zip `phantty-updater.exe` in all portable release assets.
- Modify `docs/development.md`: document the updater helper in release assets.

---

### Task 1: Release Asset Metadata and Portable Flavor Selection

**Files:**
- Modify: `src/update_check.zig`

- [ ] **Step 1: Write failing tests for package flavor and asset selection**

Append these tests to `src/update_check.zig`:

```zig
test "update_check: selects portable asset for runtime flavor" {
    const json =
        \\{
        \\  "tag_name":"v0.28.0",
        \\  "html_url":"https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        \\  "draft":false,
        \\  "prerelease":false,
        \\  "assets":[
        \\    {"name":"phantty-windows-portable-v0.28.0.zip","browser_download_url":"https://example.test/portable.zip","size":11},
        \\    {"name":"phantty-windows-portable-webview2-v0.28.0.zip","browser_download_url":"https://example.test/webview2.zip","size":22},
        \\    {"name":"phantty-windows-portable-no-webview-v0.28.0.zip","browser_download_url":"https://example.test/no-webview.zip","size":33}
        \\  ]
        \\}
    ;
    const release = try parseLatestRelease(std.testing.allocator, json);
    defer release.deinit(std.testing.allocator);

    const normal = selectPortableAsset(release, .portable) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-v0.28.0.zip", normal.name);
    try std.testing.expectEqualStrings("https://example.test/portable.zip", normal.download_url);
    try std.testing.expectEqual(@as(u64, 11), normal.size);

    const webview2 = selectPortableAsset(release, .portable_webview2) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-webview2-v0.28.0.zip", webview2.name);

    const no_webview = selectPortableAsset(release, .portable_no_webview) orelse return error.ExpectedAsset;
    try std.testing.expectEqualStrings("phantty-windows-portable-no-webview-v0.28.0.zip", no_webview.name);
}

test "update_check: update result includes selected asset fields" {
    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = "phantty-windows-portable-webview2-v0.28.0.zip",
                .download_url = "https://example.test/webview2.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForFlavor("0.27.2", release, .portable_webview2);
    try std.testing.expectEqual(State.update_available, result.state);
    try std.testing.expectEqualStrings("v0.28.0", result.latest_version);
    try std.testing.expectEqualStrings("phantty-windows-portable-webview2-v0.28.0.zip", result.asset_name);
    try std.testing.expectEqualStrings("https://example.test/webview2.zip", result.asset_download_url);
    try std.testing.expectEqual(@as(u64, 1234), result.asset_size);
}

test "update_check: missing matching asset fails instead of changing flavor" {
    const release = ReleaseInfo{
        .tag_name = "v0.28.0",
        .html_url = "https://github.com/xuzhougeng/phantty/releases/tag/v0.28.0",
        .draft = false,
        .prerelease = false,
        .assets = &.{
            .{
                .name = "phantty-windows-portable-v0.28.0.zip",
                .download_url = "https://example.test/portable.zip",
                .size = 1234,
            },
        },
        .owned = false,
    };

    const result = evaluateReleaseForFlavor("0.27.2", release, .portable_webview2);
    try std.testing.expectEqual(State.failed, result.state);
}
```

- [ ] **Step 2: Run the tests and verify failure**

Run:

```powershell
zig build test
```

Expected: fail because `PortableFlavor`, `ReleaseAsset`, `assets`, `selectPortableAsset`, `evaluateReleaseForFlavor`, `asset_name`, `asset_download_url`, and `asset_size` do not exist yet.

- [ ] **Step 3: Add asset types and result fields**

In `src/update_check.zig`, replace the top type definitions with this shape while preserving existing function names where callers already use them:

```zig
pub const Order = enum { older, equal, newer, unknown };
pub const State = enum {
    idle,
    checking,
    up_to_date,
    update_available,
    downloading,
    extracting,
    ready_to_restart,
    installing,
    updated,
    failed,
};

pub const PortableFlavor = enum {
    portable,
    portable_webview2,
    portable_no_webview,
};

pub const ReleaseAsset = struct {
    name: []const u8,
    download_url: []const u8,
    size: u64 = 0,
};

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    html_url: []const u8,
    draft: bool,
    prerelease: bool,
    assets: []ReleaseAsset = &.{},
    owned: bool = true,

    pub fn deinit(self: ReleaseInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.tag_name);
        allocator.free(self.html_url);
        for (self.assets) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.download_url);
        }
        allocator.free(self.assets);
    }
};

pub const CheckResult = struct {
    state: State,
    latest_version: []const u8 = "",
    release_url: []const u8 = "",
    asset_name: []const u8 = "",
    asset_download_url: []const u8 = "",
    asset_size: u64 = 0,
};
```

- [ ] **Step 4: Implement JSON asset parsing**

Add these helpers near the existing `jsonString`/`jsonBool` helpers and update `parseLatestRelease` to call `parseAssets`:

```zig
fn jsonInt(root: std.json.Value, name: []const u8) u64 {
    if (root != .object) return 0;
    const value = root.object.get(name) orelse return 0;
    return switch (value) {
        .integer => |v| if (v > 0) @intCast(v) else 0,
        else => 0,
    };
}

fn parseAssets(allocator: std.mem.Allocator, root: std.json.Value) ![]ReleaseAsset {
    if (root != .object) return &.{};
    const value = root.object.get("assets") orelse return &.{};
    if (value != .array) return &.{};

    var out: std.ArrayListUnmanaged(ReleaseAsset) = .empty;
    errdefer {
        for (out.items) |asset| {
            allocator.free(asset.name);
            allocator.free(asset.download_url);
        }
        out.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) continue;
        const name = jsonString(item, "name") orelse continue;
        const url = jsonString(item, "browser_download_url") orelse continue;
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .download_url = try allocator.dupe(u8, url),
            .size = jsonInt(item, "size"),
        });
    }

    return try out.toOwnedSlice(allocator);
}
```

Update the `parseLatestRelease` return path:

```zig
const assets_owned = try parseAssets(allocator, root);
errdefer {
    for (assets_owned) |asset| {
        allocator.free(asset.name);
        allocator.free(asset.download_url);
    }
    allocator.free(assets_owned);
}

return .{
    .tag_name = tag_name_owned,
    .html_url = html_url_owned,
    .draft = jsonBool(root, "draft"),
    .prerelease = jsonBool(root, "prerelease"),
    .assets = assets_owned,
    .owned = true,
};
```

- [ ] **Step 5: Implement asset selection and flavor-aware evaluation**

Add:

```zig
pub fn portableAssetName(tag_name: []const u8, flavor: PortableFlavor, buf: []u8) ![]const u8 {
    return switch (flavor) {
        .portable => std.fmt.bufPrint(buf, "phantty-windows-portable-{s}.zip", .{tag_name}),
        .portable_webview2 => std.fmt.bufPrint(buf, "phantty-windows-portable-webview2-{s}.zip", .{tag_name}),
        .portable_no_webview => std.fmt.bufPrint(buf, "phantty-windows-portable-no-webview-{s}.zip", .{tag_name}),
    };
}

pub fn selectPortableAsset(release: ReleaseInfo, flavor: PortableFlavor) ?ReleaseAsset {
    var expected_buf: [128]u8 = undefined;
    const expected = portableAssetName(release.tag_name, flavor, &expected_buf) catch return null;
    for (release.assets) |asset| {
        if (std.mem.eql(u8, asset.name, expected)) return asset;
    }
    return null;
}

pub fn evaluateReleaseForFlavor(current_version: []const u8, release: ReleaseInfo, flavor: PortableFlavor) CheckResult {
    if (release.draft or release.prerelease) return .{ .state = .up_to_date };

    return switch (compareVersions(current_version, release.tag_name)) {
        .newer => {
            const asset = selectPortableAsset(release, flavor) orelse return .{ .state = .failed };
            return .{
                .state = .update_available,
                .latest_version = release.tag_name,
                .release_url = release.html_url,
                .asset_name = asset.name,
                .asset_download_url = asset.download_url,
                .asset_size = asset.size,
            };
        },
        .older, .equal, .unknown => .{ .state = .up_to_date },
    };
}

pub fn evaluateRelease(current_version: []const u8, release: ReleaseInfo) CheckResult {
    return evaluateReleaseForFlavor(current_version, release, .portable);
}
```

- [ ] **Step 6: Preserve copied result fields**

Change `copyResult` to accept two additional buffers:

```zig
pub fn copyResult(
    result: CheckResult,
    latest_version_buf: []u8,
    release_url_buf: []u8,
    asset_name_buf: []u8,
    asset_download_url_buf: []u8,
) CheckResult {
    return .{
        .state = result.state,
        .latest_version = copyBounded(latest_version_buf, result.latest_version),
        .release_url = copyBounded(release_url_buf, result.release_url),
        .asset_name = copyBounded(asset_name_buf, result.asset_name),
        .asset_download_url = copyBounded(asset_download_url_buf, result.asset_download_url),
        .asset_size = result.asset_size,
    };
}
```

Update existing callers and tests to provide local asset buffers. Keep buffer lengths at least 128 for asset names and 512 for download URLs.

- [ ] **Step 7: Add flavor-aware fetch helper**

Replace the old fetch body with a flavor-aware helper and keep the old function as a compatibility wrapper:

```zig
pub fn fetchLatestReleaseForFlavor(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    flavor: PortableFlavor,
    latest_version_buf: []u8,
    release_url_buf: []u8,
    asset_name_buf: []u8,
    asset_download_url_buf: []u8,
) CheckResult {
    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const response = client.fetch(.{
        .location = .{ .url = latest_release_api_url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "phantty" } },
        .response_writer = &body.writer,
    }) catch return .{ .state = .failed };
    if (response.status != .ok) return .{ .state = .failed };

    var list = body.toArrayList();
    defer list.deinit(allocator);

    const release = parseLatestRelease(allocator, list.items) catch return .{ .state = .failed };
    defer release.deinit(allocator);

    return copyResult(
        evaluateReleaseForFlavor(current_version, release, flavor),
        latest_version_buf,
        release_url_buf,
        asset_name_buf,
        asset_download_url_buf,
    );
}

pub fn fetchLatestRelease(
    allocator: std.mem.Allocator,
    current_version: []const u8,
    latest_version_buf: []u8,
    release_url_buf: []u8,
) CheckResult {
    var asset_name_buf: [128]u8 = undefined;
    var asset_url_buf: [512]u8 = undefined;
    return fetchLatestReleaseForFlavor(
        allocator,
        current_version,
        .portable,
        latest_version_buf,
        release_url_buf,
        &asset_name_buf,
        &asset_url_buf,
    );
}
```

- [ ] **Step 8: Update status text**

Extend `formatStatusMessage`:

```zig
.downloading => std.fmt.bufPrint(buf, "Downloading update...", .{}),
.extracting => std.fmt.bufPrint(buf, "Preparing update...", .{}),
.ready_to_restart => std.fmt.bufPrint(buf, "Update ready; restart to install", .{}),
.installing => std.fmt.bufPrint(buf, "Installing update...", .{}),
.updated => std.fmt.bufPrint(buf, "Update installed", .{}),
```

- [ ] **Step 9: Run tests and commit**

Run:

```powershell
zig build test
```

Expected: PASS for update-check unit tests, or compile failures only in `App.zig` call sites that still need the new buffers. If compile failures point to `copyResult`, update those call sites before committing.

Commit:

```bash
git add src/update_check.zig
git commit -m "Add portable update asset selection"
```

---

### Task 2: Update Preparation Helper

**Files:**
- Create: `src/update_install.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write tests for runtime flavor and payload validation**

Create `src/update_install.zig` with imports and tests first:

```zig
const std = @import("std");
const build_options = @import("build_options");
const update_check = @import("update_check.zig");

pub const PayloadValidation = struct {
    require_webview2_loader: bool,
};

pub fn runtimeFlavor(webview_enabled: bool, has_webview2_loader: bool) update_check.PortableFlavor {
    if (!webview_enabled) return .portable_no_webview;
    if (has_webview2_loader) return .portable_webview2;
    return .portable;
}

test "update_install: runtime flavor preserves current portable flavor" {
    try std.testing.expectEqual(update_check.PortableFlavor.portable_no_webview, runtimeFlavor(false, true));
    try std.testing.expectEqual(update_check.PortableFlavor.portable_webview2, runtimeFlavor(true, true));
    try std.testing.expectEqual(update_check.PortableFlavor.portable, runtimeFlavor(true, false));
}

test "update_install: payload validation requires packaged files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "phantty.exe", .data = "exe" });
    try tmp.dir.writeFile(.{ .sub_path = "phantty-updater.exe", .data = "updater" });
    try tmp.dir.writeFile(.{ .sub_path = "version.txt", .data = "v0.28.0" });
    try tmp.dir.makeDir("plugins");

    try validatePayloadDir(tmp.dir, .{ .require_webview2_loader = false });
    try std.testing.expectError(error.MissingWebView2Loader, validatePayloadDir(tmp.dir, .{ .require_webview2_loader = true }));

    try tmp.dir.writeFile(.{ .sub_path = "WebView2Loader.dll", .data = "dll" });
    try validatePayloadDir(tmp.dir, .{ .require_webview2_loader = true });
}
```

Add to `src/test_main.zig` inside the `comptime` block:

```zig
    _ = @import("update_install.zig");
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
zig build test
```

Expected: fail because `validatePayloadDir` is undefined.

- [ ] **Step 3: Implement payload validation and current flavor detection**

Add these functions to `src/update_install.zig`:

```zig
pub const PayloadError = error{
    MissingPhanttyExe,
    MissingUpdaterExe,
    MissingVersionFile,
    MissingPluginsDir,
    MissingWebView2Loader,
};

fn fileExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    dir.access(sub_path, .{}) catch return false;
    return true;
}

fn dirExists(dir: std.fs.Dir, sub_path: []const u8) bool {
    var child = dir.openDir(sub_path, .{}) catch return false;
    child.close();
    return true;
}

pub fn validatePayloadDir(dir: std.fs.Dir, options: PayloadValidation) PayloadError!void {
    if (!fileExists(dir, "phantty.exe")) return error.MissingPhanttyExe;
    if (!fileExists(dir, "phantty-updater.exe")) return error.MissingUpdaterExe;
    if (!fileExists(dir, "version.txt")) return error.MissingVersionFile;
    if (!dirExists(dir, "plugins")) return error.MissingPluginsDir;
    if (options.require_webview2_loader and !fileExists(dir, "WebView2Loader.dll")) return error.MissingWebView2Loader;
}

pub fn currentFlavor(allocator: std.mem.Allocator) !update_check.PortableFlavor {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return .portable;
    const loader_path = try std.fs.path.join(allocator, &.{ exe_dir, "WebView2Loader.dll" });
    defer allocator.free(loader_path);
    const has_loader = blk: {
        std.fs.cwd().access(loader_path, .{}) catch break :blk false;
        break :blk true;
    };
    return runtimeFlavor(build_options.webview, has_loader);
}
```

- [ ] **Step 4: Add update work directory and extraction helpers**

Add:

```zig
pub const PreparedUpdate = struct {
    work_dir: []u8,
    zip_path: []u8,
    payload_dir: []u8,

    pub fn deinit(self: PreparedUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.work_dir);
        allocator.free(self.zip_path);
        allocator.free(self.payload_dir);
    }
};

pub fn updateWorkDir(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    const appdata = try std.fs.getAppDataDir(allocator, "Phantty");
    defer allocator.free(appdata);
    return try std.fs.path.join(allocator, &.{ appdata, "updates", version });
}

pub fn prepareWorkPaths(allocator: std.mem.Allocator, version: []const u8, asset_name: []const u8) !PreparedUpdate {
    const work_dir = try updateWorkDir(allocator, version);
    errdefer allocator.free(work_dir);
    const zip_path = try std.fs.path.join(allocator, &.{ work_dir, asset_name });
    errdefer allocator.free(zip_path);
    const payload_dir = try std.fs.path.join(allocator, &.{ work_dir, "payload" });
    errdefer allocator.free(payload_dir);
    return .{ .work_dir = work_dir, .zip_path = zip_path, .payload_dir = payload_dir };
}

pub fn extractZipToPayload(zip_path: []const u8, payload_dir: []const u8) !void {
    std.fs.deleteTreeAbsolute(payload_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.makeDirAbsolute(payload_dir);
    var payload = try std.fs.openDirAbsolute(payload_dir, .{});
    defer payload.close();

    var zip_file = try std.fs.openFileAbsolute(zip_path, .{});
    defer zip_file.close();
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = zip_file.reader(&read_buf);
    try std.zip.extract(payload, &reader, .{ .allow_backslashes = true });
}
```

- [ ] **Step 5: Add download helper**

Add:

```zig
pub fn downloadAsset(allocator: std.mem.Allocator, url: []const u8, zip_path: []const u8) !void {
    if (std.fs.path.dirname(zip_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    var out = try std.fs.createFileAbsolute(zip_path, .{ .truncate = true });
    defer out.close();
    var file_buf: [16 * 1024]u8 = undefined;
    var writer = out.writer(&file_buf);

    var client: std.http.Client = .{
        .allocator = allocator,
        .write_buffer_size = 16 * 1024,
    };
    defer client.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .keep_alive = false,
        .headers = .{ .user_agent = .{ .override = "phantty" } },
        .response_writer = &writer.interface,
    });
    if (response.status != .ok) return error.DownloadFailed;
    try writer.end();
}
```

- [ ] **Step 6: Add helper launch function**

Add:

```zig
pub fn currentExeDir(allocator: std.mem.Allocator) ![]u8 {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    errdefer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.MissingExeDir;
    const owned = try allocator.dupe(u8, exe_dir);
    allocator.free(exe_path);
    return owned;
}

pub fn launchUpdater(
    allocator: std.mem.Allocator,
    payload_dir: []const u8,
    target_dir: []const u8,
    pid: u32,
) !void {
    const updater_path = try std.fs.path.join(allocator, &.{ payload_dir, "phantty-updater.exe" });
    defer allocator.free(updater_path);
    var pid_buf: [32]u8 = undefined;
    const pid_text = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const argv = [_][]const u8{
        updater_path,
        "--pid",
        pid_text,
        "--source",
        payload_dir,
        "--target",
        target_dir,
        "--restart",
    };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = payload_dir;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
}
```

- [ ] **Step 7: Run tests and commit**

Run:

```powershell
zig build test
```

Expected: PASS for `update_install` tests.

Commit:

```bash
git add src/update_install.zig src/test_main.zig
git commit -m "Add portable update preparation helpers"
```

---

### Task 3: Native Updater Core

**Files:**
- Create: `src/updater_core.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write tests for argument parsing, manifest, and validation**

Create `src/updater_core.zig`:

```zig
const std = @import("std");

pub const Options = struct {
    pid: u32,
    source: []const u8,
    target: []const u8,
    restart: bool,
};

pub const ManifestEntry = struct {
    path: []const u8,
    directory: bool = false,
    optional: bool = false,
};

pub const replacement_manifest = [_]ManifestEntry{
    .{ .path = "phantty.exe" },
    .{ .path = "phantty-updater.exe" },
    .{ .path = "version.txt" },
    .{ .path = "plugins", .directory = true },
    .{ .path = "WebView2Loader.dll", .optional = true },
};

test "updater_core: parses updater arguments" {
    const args = [_][]const u8{
        "phantty-updater.exe",
        "--pid",
        "123",
        "--source",
        "C:\\Temp\\payload",
        "--target",
        "C:\\Apps\\Phantty",
        "--restart",
    };

    const options = try parseArgs(args[1..]);
    try std.testing.expectEqual(@as(u32, 123), options.pid);
    try std.testing.expectEqualStrings("C:\\Temp\\payload", options.source);
    try std.testing.expectEqualStrings("C:\\Apps\\Phantty", options.target);
    try std.testing.expect(options.restart);
}

test "updater_core: manifest excludes portable user config" {
    for (replacement_manifest) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.path, "phantty.conf"));
    }
}

test "updater_core: rejects equal source and target paths" {
    try std.testing.expectError(error.SourceEqualsTarget, validateOptions(.{
        .pid = 1,
        .source = "C:\\Apps\\Phantty",
        .target = "C:\\Apps\\Phantty",
        .restart = false,
    }));
}
```

Add to `src/test_main.zig`:

```zig
    _ = @import("updater_core.zig");
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```powershell
zig build test
```

Expected: fail because `parseArgs` and `validateOptions` are undefined.

- [ ] **Step 3: Implement parsing and validation**

Add:

```zig
pub const ArgError = error{
    MissingPid,
    MissingSource,
    MissingTarget,
    InvalidPid,
    UnknownArgument,
    SourceEqualsTarget,
    RelativeSource,
    RelativeTarget,
};

pub fn parseArgs(args: []const []const u8) ArgError!Options {
    var pid: ?u32 = null;
    var source: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var restart = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingPid;
            pid = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidPid;
        } else if (std.mem.eql(u8, arg, "--source")) {
            i += 1;
            if (i >= args.len) return error.MissingSource;
            source = args[i];
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTarget;
            target = args[i];
        } else if (std.mem.eql(u8, arg, "--restart")) {
            restart = true;
        } else {
            return error.UnknownArgument;
        }
    }

    const options = Options{
        .pid = pid orelse return error.MissingPid,
        .source = source orelse return error.MissingSource,
        .target = target orelse return error.MissingTarget,
        .restart = restart,
    };
    try validateOptions(options);
    return options;
}

fn isAbsoluteWindowsOrNative(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

pub fn validateOptions(options: Options) ArgError!void {
    if (options.source.len == 0) return error.MissingSource;
    if (options.target.len == 0) return error.MissingTarget;
    if (std.mem.eql(u8, options.source, options.target)) return error.SourceEqualsTarget;
    if (!isAbsoluteWindowsOrNative(options.source)) return error.RelativeSource;
    if (!isAbsoluteWindowsOrNative(options.target)) return error.RelativeTarget;
}
```

- [ ] **Step 4: Add file copy and replacement functions**

Add:

```zig
fn joinAlloc(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ a, b });
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn deletePath(path: []const u8, directory: bool) !void {
    if (directory) {
        std.fs.deleteTreeAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn copyDirRecursive(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    try std.fs.makeDirAbsolute(target);
    var src_dir = try std.fs.openDirAbsolute(source, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try joinAlloc(allocator, source, entry.name);
        defer allocator.free(src_child);
        const dst_child = try joinAlloc(allocator, target, entry.name);
        defer allocator.free(dst_child);
        switch (entry.kind) {
            .directory => try copyDirRecursive(allocator, src_child, dst_child),
            .file => try std.fs.copyFileAbsolute(src_child, dst_child, .{}),
            else => {},
        }
    }
}

fn copyPath(allocator: std.mem.Allocator, source: []const u8, target: []const u8, directory: bool) !void {
    if (directory) {
        try copyDirRecursive(allocator, source, target);
    } else {
        try std.fs.copyFileAbsolute(source, target, .{});
    }
}
```

- [ ] **Step 5: Add backup, replacement, and rollback**

Add:

```zig
pub fn backupDirForSource(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(source) orelse return error.MissingSourceParent;
    return try std.fs.path.join(allocator, &.{ parent, "backup" });
}

pub fn backupCurrentPayload(allocator: std.mem.Allocator, target: []const u8, backup: []const u8) !void {
    std.fs.deleteTreeAbsolute(backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std.fs.makeDirAbsolute(backup);
    for (replacement_manifest) |entry| {
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        if (!pathExists(target_path)) {
            if (entry.optional) continue;
            return error.MissingTargetPayload;
        }
        const backup_path = try joinAlloc(allocator, backup, entry.path);
        defer allocator.free(backup_path);
        try copyPath(allocator, target_path, backup_path, entry.directory);
    }
}

pub fn copyNewPayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    for (replacement_manifest) |entry| {
        const source_path = try joinAlloc(allocator, source, entry.path);
        defer allocator.free(source_path);
        if (!pathExists(source_path)) {
            if (entry.optional) continue;
            return error.MissingSourcePayload;
        }
        const target_path = try joinAlloc(allocator, target, entry.path);
        defer allocator.free(target_path);
        try deletePath(target_path, entry.directory);
        try copyPath(allocator, source_path, target_path, entry.directory);
    }
}

pub fn restoreBackup(allocator: std.mem.Allocator, backup: []const u8, target: []const u8) void {
    for (replacement_manifest) |entry| {
        const backup_path = joinAlloc(allocator, backup, entry.path) catch continue;
        defer allocator.free(backup_path);
        if (!pathExists(backup_path)) continue;
        const target_path = joinAlloc(allocator, target, entry.path) catch continue;
        defer allocator.free(target_path);
        deletePath(target_path, entry.directory) catch {};
        copyPath(allocator, backup_path, target_path, entry.directory) catch {};
    }
}

pub fn replacePayload(allocator: std.mem.Allocator, source: []const u8, target: []const u8) !void {
    const backup = try backupDirForSource(allocator, source);
    defer allocator.free(backup);
    try backupCurrentPayload(allocator, target, backup);
    copyNewPayload(allocator, source, target) catch |err| {
        restoreBackup(allocator, backup, target);
        return err;
    };
}
```

- [ ] **Step 6: Add relaunch command construction**

Add:

```zig
pub fn targetExePath(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    return try std.fs.path.join(allocator, &.{ target, "phantty.exe" });
}
```

- [ ] **Step 7: Run tests and commit**

Run:

```powershell
zig build test
```

Expected: PASS for `updater_core` tests.

Commit:

```bash
git add src/updater_core.zig src/test_main.zig
git commit -m "Add native updater core"
```

---

### Task 4: Updater Executable and Build/Package Wiring

**Files:**
- Create: `src/updater_main.zig`
- Modify: `build.zig`
- Modify: `packaging/windows/package.ps1`
- Modify: `.github/workflows/windows-release.yml`

- [ ] **Step 1: Create updater executable entrypoint**

Create `src/updater_main.zig`:

```zig
const std = @import("std");
const updater_core = @import("updater_core.zig");

const windows = std.os.windows;

const SYNCHRONIZE: u32 = 0x00100000;
const WAIT_OBJECT_0: u32 = 0x00000000;
const WAIT_TIMEOUT: u32 = 0x00000102;
const WAIT_MS: u32 = 60_000;

extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: windows.BOOL, dwProcessId: u32) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;

fn waitForPid(pid: u32) !void {
    const handle = OpenProcess(SYNCHRONIZE, 0, pid) orelse return;
    defer windows.CloseHandle(handle);
    const rc = WaitForSingleObject(handle, WAIT_MS);
    if (rc == WAIT_TIMEOUT) return error.WaitTimedOut;
    if (rc != WAIT_OBJECT_0) return error.WaitFailed;
}

fn relaunch(allocator: std.mem.Allocator, target: []const u8) !void {
    const exe = try updater_core.targetExePath(allocator, target);
    defer allocator.free(exe);
    const argv = [_][]const u8{exe};
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = target;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.create_no_window = true;
    try child.spawn();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const options = updater_core.parseArgs(args[1..]) catch |err| {
        std.debug.print("phantty-updater: invalid arguments: {}\n", .{err});
        return err;
    };

    try waitForPid(options.pid);
    try updater_core.replacePayload(allocator, options.source, options.target);
    if (options.restart) try relaunch(allocator, options.target);
}
```

- [ ] **Step 2: Modify build.zig to build and install updater**

In `build.zig`, after `const optimize = ...`, create a small helper module for the updater:

```zig
    const updater_mod = b.createModule(.{
        .root_source_file = b.path("src/updater_main.zig"),
        .target = target,
        .optimize = optimize,
    });
```

After `b.installArtifact(exe);`, add:

```zig
    const updater_exe = b.addExecutable(.{
        .name = "phantty-updater",
        .root_module = updater_mod,
    });
    updater_exe.subsystem = if (optimize == .Debug) .Console else .Windows;
    b.installArtifact(updater_exe);
```

- [ ] **Step 3: Update packaging script**

In `Copy-PortablePayload`, add a mandatory updater parameter:

```powershell
        [Parameter(Mandatory = $true)][string]$UpdaterPath,
```

Inside the function, after copying `phantty.exe`, add:

```powershell
    Copy-Item -Path $UpdaterPath -Destination (Join-Path $TargetDir 'phantty-updater.exe') -Force
```

After `$binaryPath` validation, add:

```powershell
$updaterPath = Join-Path $repoRoot 'zig-out\bin\phantty-updater.exe'
if (-not (Test-Path $updaterPath)) {
    throw "Expected updater binary was not found: $updaterPath"
}
```

After `$noWebViewBinaryPath`, add:

```powershell
$noWebViewUpdaterPath = Join-Path $noWebViewInstallDir 'bin\phantty-updater.exe'
if (-not $SkipNoWebViewBundle -and -not (Test-Path $noWebViewUpdaterPath)) {
    throw "Expected no-WebView updater binary was not found: $noWebViewUpdaterPath"
}
```

Update the three portable copy calls:

```powershell
Copy-PortablePayload -BinaryPath $binaryPath -UpdaterPath $updaterPath -TargetDir $portableDir -ReleaseVersion $releaseVersion
if ($webView2LoaderPath) {
    Copy-PortablePayload -BinaryPath $binaryPath -UpdaterPath $updaterPath -TargetDir $portableWebView2Dir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath
}
if (-not $SkipNoWebViewBundle) {
    Copy-PortablePayload -BinaryPath $noWebViewBinaryPath -UpdaterPath $noWebViewUpdaterPath -TargetDir $portableNoWebViewDir -ReleaseVersion $releaseVersion
}
```

- [ ] **Step 4: Update release workflow validation**

In `.github/workflows/windows-release.yml`, add updater path variables:

```powershell
          $portableUpdater = "zig-out\dist\portable\phantty-updater.exe"
          $portableWebView2Updater = "zig-out\dist\portable-webview2\phantty-updater.exe"
          $portableNoWebViewUpdater = "zig-out\dist\portable-no-webview\phantty-updater.exe"
```

Add checks beside the existing exe checks:

```powershell
          if (!(Test-Path $portableUpdater)) {
            throw "Portable updater not found: $portableUpdater"
          }
          if (!(Test-Path $portableWebView2Updater)) {
            throw "Portable WebView2 updater not found: $portableWebView2Updater"
          }
          if (!(Test-Path $portableNoWebViewUpdater)) {
            throw "Portable no-WebView updater not found: $portableNoWebViewUpdater"
          }
```

- [ ] **Step 5: Run build/package verification and commit**

Run:

```powershell
zig build
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -SkipInstaller
```

Expected:

```text
zig-out\bin\phantty-updater.exe exists
zig-out\dist\portable\phantty-updater.exe exists
zig-out\dist\portable-webview2\phantty-updater.exe exists
zig-out\dist\portable-no-webview\phantty-updater.exe exists
```

Commit:

```bash
git add src/updater_main.zig build.zig packaging/windows/package.ps1 .github/workflows/windows-release.yml
git commit -m "Build and package portable updater"
```

---

### Task 5: App Update Install Worker

**Files:**
- Modify: `src/App.zig`
- Modify: `src/update_check.zig`

- [ ] **Step 1: Extend App update fields**

In `src/App.zig`, import `update_install` and add buffers:

```zig
const update_install = @import("update_install.zig");
```

In the update state field group, add:

```zig
update_asset_name_buf: [128]u8,
update_asset_url_buf: [512]u8,
available_update: update_check.CheckResult,
install_thread: ?std.Thread,
install_in_flight: bool,
```

Initialize them in `App.init`:

```zig
.update_asset_name_buf = undefined,
.update_asset_url_buf = undefined,
.available_update = .{ .state = .idle },
.install_thread = null,
.install_in_flight = false,
```

- [ ] **Step 2: Update check worker to select current flavor**

In `updateCheckThreadMain`, compute the current flavor and call the flavor-aware fetch:

```zig
const flavor = update_install.currentFlavor(app.allocator) catch .portable;
var asset_name_buf: [128]u8 = undefined;
var asset_url_buf: [512]u8 = undefined;
var result = update_check.fetchLatestReleaseForFlavor(
    app.allocator,
    app_metadata.version,
    flavor,
    &latest_version_buf,
    &release_url_buf,
    &asset_name_buf,
    &asset_url_buf,
);
```

- [ ] **Step 3: Preserve installable update metadata**

Replace `storeUpdateResult` with:

```zig
fn storeUpdateResult(self: *App, result: update_check.CheckResult) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    const copied = update_check.copyResult(
        result,
        &self.update_latest_version_buf,
        &self.update_release_url_buf,
        &self.update_asset_name_buf,
        &self.update_asset_url_buf,
    );
    self.update_result = copied;
    if (copied.state == .update_available) {
        self.available_update = copied;
    }
    self.update_check_in_flight = false;
}
```

- [ ] **Step 4: Add install request API**

Add to `src/App.zig`:

```zig
pub fn requestUpdateInstall(self: *App) void {
    self.joinFinishedUpdateThread();
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        if (self.install_in_flight) return;
        if (self.available_update.state != .update_available or self.available_update.asset_download_url.len == 0) {
            self.update_result = .{ .state = .failed };
            return;
        }
        self.install_in_flight = true;
        self.update_result = .{ .state = .downloading };
    }

    const thread = std.Thread.spawn(.{}, updateInstallThreadMain, .{self}) catch |err| {
        std.debug.print("Update install: failed to spawn thread: {}\n", .{err});
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        self.install_in_flight = false;
        self.update_result = .{ .state = .failed };
        return;
    };

    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.install_thread = thread;
}
```

- [ ] **Step 5: Add install worker**

Add:

```zig
fn updateInstallThreadMain(app: *App) void {
    var update: update_check.CheckResult = undefined;
    {
        app.update_mutex.lock();
        update = app.available_update;
        app.update_mutex.unlock();
    }

    var prepared = update_install.prepareWorkPaths(app.allocator, update.latest_version, update.asset_name) catch {
        app.storeInstallFailure();
        return;
    };
    defer prepared.deinit(app.allocator);

    update_install.downloadAsset(app.allocator, update.asset_download_url, prepared.zip_path) catch {
        app.storeInstallFailure();
        return;
    };
    app.storeTransientUpdateState(.extracting);

    update_install.extractZipToPayload(prepared.zip_path, prepared.payload_dir) catch {
        app.storeInstallFailure();
        return;
    };

    var payload = std.fs.openDirAbsolute(prepared.payload_dir, .{}) catch {
        app.storeInstallFailure();
        return;
    };
    defer payload.close();
    const flavor = update_install.currentFlavor(app.allocator) catch .portable;
    update_install.validatePayloadDir(payload, .{
        .require_webview2_loader = flavor == .portable_webview2,
    }) catch {
        app.storeInstallFailure();
        return;
    };

    const target_dir = update_install.currentExeDir(app.allocator) catch {
        app.storeInstallFailure();
        return;
    };
    defer app.allocator.free(target_dir);

    app.storeTransientUpdateState(.installing);
    update_install.launchUpdater(
        app.allocator,
        prepared.payload_dir,
        target_dir,
        @import("apprt/win32.zig").GetCurrentProcessId(),
    ) catch {
        app.storeInstallFailure();
        return;
    };

    app.requestShutdown();
}

fn storeTransientUpdateState(self: *App, state: update_check.State) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.update_result = .{ .state = state };
}

fn storeInstallFailure(self: *App) void {
    self.update_mutex.lock();
    defer self.update_mutex.unlock();
    self.install_in_flight = false;
    self.update_result = .{ .state = .failed };
}
```

- [ ] **Step 6: Join install thread in cleanup**

Add:

```zig
fn joinInstallThread(self: *App) void {
    var thread: ?std.Thread = null;
    {
        self.update_mutex.lock();
        defer self.update_mutex.unlock();
        thread = self.install_thread;
        self.install_thread = null;
    }
    if (thread) |t| t.join();
}
```

Call `self.joinInstallThread();` from `deinit` after `joinUpdateThread()`.

- [ ] **Step 7: Run tests/build and commit**

Run:

```powershell
zig build test
zig build
```

Expected: PASS and successful debug build.

Commit:

```bash
git add src/App.zig src/update_check.zig
git commit -m "Wire portable update install worker"
```

---

### Task 6: UI and Command Center Install Action

**Files:**
- Modify: `src/command_center_state.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Add command center action and failing test**

In `src/command_center_state.zig`, add enum case:

```zig
    install_update,
```

Add command entry near update commands:

```zig
    .{ .title = "Install Update", .detail = "Download and install the latest portable Phantty update", .shortcut = "", .action = .install_update },
```

Extend the update command test:

```zig
    try std.testing.expectEqual(CommandAction.install_update, findCommandAction("Install Update"));
```

Run:

```powershell
zig build test
```

Expected: compile fail in `overlays.zig` because `executeCommand` does not handle `.install_update`.

- [ ] **Step 2: Add update prompt actions**

In `src/renderer/overlays.zig`, add near update prompt globals:

```zig
const UpdatePromptAction = enum { none, open_release, install_update };
threadlocal var g_update_prompt_action: UpdatePromptAction = .none;
```

Modify `showUpdateCheckResult`:

```zig
pub fn showUpdateCheckResult(result: update_check.CheckResult) void {
    if (result.state == .idle) return;
    const action: UpdatePromptAction = if (result.state == .update_available and result.asset_download_url.len > 0)
        .install_update
    else if (result.state == .update_available and result.release_url.len > 0)
        .open_release
    else
        .none;
    showUpdatePrompt(result, action);
}
```

Change `showUpdatePrompt` signature and message:

```zig
fn showUpdatePrompt(result: update_check.CheckResult, action: UpdatePromptAction) void {
    var status_buf: [96]u8 = undefined;
    const status = update_check.formatStatusMessage(&status_buf, result) catch return;
    const suffix = switch (action) {
        .install_update => "  click to install",
        .open_release => "  click to open",
        .none => "",
    };
    const msg = std.fmt.bufPrint(&g_update_prompt_buf, "{s}{s}", .{ status, suffix }) catch return;

    g_update_prompt_len = msg.len;
    g_update_prompt_url_len = 0;
    if (action == .open_release and result.release_url.len > 0) {
        const url_len = @min(g_update_prompt_url_buf.len, result.release_url.len);
        @memcpy(g_update_prompt_url_buf[0..url_len], result.release_url[0..url_len]);
        g_update_prompt_url_len = url_len;
    }
    g_update_prompt_clickable = action != .none;
    g_update_prompt_action = action;
    g_update_prompt_until_ms = std.time.milliTimestamp() + if (action != .none) UPDATE_PROMPT_DURATION_MS else UPDATE_STATUS_DURATION_MS;
}
```

Update `showUpdateCheckingToast`:

```zig
pub fn showUpdateCheckingToast() void {
    showUpdatePrompt(.{ .state = .checking }, .none);
}
```

- [ ] **Step 3: Add prompt activation API**

Replace `openLatestRelease` prompt-click use with:

```zig
pub fn activateUpdatePrompt() void {
    switch (g_update_prompt_action) {
        .install_update => {
            if (AppWindow.g_app) |app| app.requestUpdateInstall();
        },
        .open_release => openLatestRelease(),
        .none => {},
    }
}
```

Keep `openLatestRelease()` for command center fallback.

- [ ] **Step 4: Wire command execution**

In `executeCommand`, add:

```zig
        .install_update => {
            showUpdatePrompt(.{ .state = .downloading }, .none);
            if (AppWindow.g_app) |app| app.requestUpdateInstall();
        },
```

- [ ] **Step 5: Wire input click**

In `src/input.zig`, change the update prompt click block from:

```zig
            overlays.openLatestRelease();
```

to:

```zig
            overlays.activateUpdatePrompt();
```

- [ ] **Step 6: Run tests/build and commit**

Run:

```powershell
zig build test
zig build
```

Expected: PASS and successful debug build.

Commit:

```bash
git add src/command_center_state.zig src/renderer/overlays.zig src/input.zig
git commit -m "Add portable update install UI action"
```

---

### Task 7: Documentation, Windows Path Checks, and Final Verification

**Files:**
- Modify: `docs/development.md`

- [ ] **Step 1: Update development docs**

In `docs/development.md`, update the packaging output list:

```markdown
zig-out\dist\portable\phantty.exe
zig-out\dist\portable\phantty-updater.exe
zig-out\dist\portable-webview2\phantty.exe
zig-out\dist\portable-webview2\phantty-updater.exe
zig-out\dist\portable-webview2\WebView2Loader.dll
zig-out\dist\portable-no-webview\phantty.exe
zig-out\dist\portable-no-webview\phantty-updater.exe
```

Add one sentence below the release asset list:

```markdown
Each portable zip also includes `phantty-updater.exe`, a native helper used by the desktop app to replace the portable payload after Phantty exits.
```

- [ ] **Step 2: Run unit/build/package verification**

Run:

```powershell
zig build test
zig build
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -SkipInstaller
```

Expected:

```text
zig build test exits 0
zig build exits 0
package.ps1 exits 0
```

- [ ] **Step 3: Run Windows path compatibility check**

Run the AGENTS.md Windows path check:

```powershell
$paths = git ls-files
$reserved = @('CON', 'PRN', 'AUX', 'NUL') + (1..9 | ForEach-Object { "COM$_"; "LPT$_" })
$violations = [System.Collections.Generic.List[object]]::new()
$collisions = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($path in $paths) {
    foreach ($part in ($path -split '/')) {
        $stem = ($part -split '\.')[0].ToUpperInvariant()
        $reasons = @()
        if ($part.IndexOfAny([char[]]'<>:"\|?*') -ge 0) { $reasons += 'illegal_char' }
        if ($part.EndsWith(' ') -or $part.EndsWith('.')) { $reasons += 'trailing_space_or_dot' }
        if ($reserved -contains $stem) { $reasons += 'reserved_name' }
        if ($reasons.Count -gt 0) {
            $violations.Add([pscustomobject]@{ Path = $path; Part = $part; Reasons = ($reasons -join ',') })
        }
    }

    $key = $path.ToLowerInvariant()
    if ($seen.ContainsKey($key) -and $seen[$key] -ne $path) {
        $collisions.Add([pscustomobject]@{ A = $seen[$key]; B = $path })
    } else {
        $seen[$key] = $path
    }
}

"tracked_files=$($paths.Count)"
"windows_name_violations=$($violations.Count)"
$violations | ForEach-Object { "violation`t$($_.Path)`t$($_.Part)`t$($_.Reasons)" }
"casefold_collisions=$($collisions.Count)"
$collisions | ForEach-Object { "collision`t$($_.A)`t$($_.B)" }
$longest = $paths | Sort-Object Length -Descending | Select-Object -First 1
"max_path_length=$($longest.Length) $longest"
```

Expected:

```text
windows_name_violations=0
casefold_collisions=0
```

- [ ] **Step 4: Check symlinks**

Run:

```powershell
git ls-files -s | Select-String '^120000'
```

Expected: no new symlink entries from this work.

- [ ] **Step 5: Commit docs**

Commit:

```bash
git add docs/development.md
git commit -m "Document portable updater packaging"
```

- [ ] **Step 6: Final status**

Run:

```powershell
git status --short
```

Expected: only pre-existing unrelated worktree changes remain.

---

## Self-Review Notes

- Spec coverage: all spec goals map to tasks: three package flavors in Task 1 and Task 2, native helper in Task 3 and Task 4, no PowerShell replacement path in Task 4, safe preparation in Task 2, wait/replace/restart in Task 3, UI state and fallback in Task 5 and Task 6, packaging verification in Task 7.
- Ghostty comparison: the plan preserves Ghostty's controller/driver/view-model separation concept by separating release state (`update_check.zig`), main-app orchestration (`App.zig` plus `update_install.zig`), helper installation mechanics (`updater_core.zig` and `updater_main.zig`), and overlay presentation (`overlays.zig`).
- Type consistency: `PortableFlavor`, `ReleaseAsset`, `CheckResult.asset_*`, and `State` variants are introduced in Task 1 before later tasks consume them.
