# Windows Compat Release (Bundled ConPTY) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `wispterm-windows-portable-compat` release zip bundling the modern ConPTY pair (`conpty.dll` + `OpenConsole.exe`) so crossterm TUIs (Codex) get mouse scrolling on old Windows 10 conhosts, replacing the `portable-webview2` zip.

**Architecture:** A pure policy module decides bundled-vs-system ConPTY; a Windows-only loader resolves the bundled DLL next to the exe with sticky fallback to the kernel32 inbox API; each `Pty` remembers the API that created it. Packaging gains a NuGet-fetched conpty pair and a `portable-compat` staging dir; the updater's `with_required_embedded_browser_payload` flavor becomes `compat` and detects either `WebView2Loader.dll` or `conpty.dll` next to the exe (migration path for old webview2 installs).

**Tech Stack:** Zig 0.15.2 (default target `x86_64-windows-gnu`), PowerShell packaging script, GitHub Actions. Spec: `docs/superpowers/specs/2026-06-12-windows-compat-conpty-bundle-design.md`.

**Layering guards (read before coding):** `src/test_main.zig` bans concrete strings in shared modules at compile time. Rules that matter here: `platform/pty.zig` must not contain the string `windows_conpty`; `Surface.zig`/`termio/*` must not contain `ConPTY`; `release_package.zig`/`update_check.zig`/`App.zig` must not contain `webview2`/asset-name strings. All concrete names (`conpty.dll`, `OpenConsole.exe`, asset prefixes) stay in `src/platform/update_package_windows.zig`, `src/platform/conpty_dll.zig`, and `src/platform/pty_windows.zig`.

**Verification commands:** `zig build test` (fast pure suite, native), `zig build test-full` (app suite, windows-gnu), `zig build` (cross-compile smoke). Run from the worktree root.

---

### Task 1: Pure policy module `console_host_policy.zig`

**Files:**
- Create: `src/platform/console_host_policy.zig`
- Modify: `src/test_fast.zig` (import block, next to `_ = @import("platform/dxgi_core.zig");` at line 44)
- Modify: `src/test_main.zig` (platform import block, next to `_ = @import("platform/pty_command.zig");` at line ~707)

- [ ] **Step 1: Create the module with tests and deliberately-stub implementations**

```zig
//! Pure policy for choosing which pseudo-console host implementation
//! services new terminal sessions. Platform-neutral so the config layer and
//! tests can use it without touching any OS API; the Windows loader consumes
//! the decision in platform/conpty_dll.zig.

const std = @import("std");

/// User preference from the `windows-conpty` config key.
pub const Preference = enum { auto, system };

/// Resolved implementation choice.
pub const Choice = enum { bundled, system };

/// `auto` uses the bundled console host only when both redistributable files
/// sit next to the executable; anything else stays on the OS inbox
/// implementation.
pub fn choose(pref: Preference, dll_present: bool, host_exe_present: bool) Choice {
    _ = pref;
    _ = dll_present;
    _ = host_exe_present;
    return .system; // stub
}

pub fn parsePreference(value: []const u8) ?Preference {
    _ = value;
    return null; // stub
}

test "console host policy uses bundled host only when fully present under auto" {
    try std.testing.expectEqual(Choice.bundled, choose(.auto, true, true));
    try std.testing.expectEqual(Choice.system, choose(.auto, true, false));
    try std.testing.expectEqual(Choice.system, choose(.auto, false, true));
    try std.testing.expectEqual(Choice.system, choose(.auto, false, false));
}

test "console host policy honors forced system preference" {
    try std.testing.expectEqual(Choice.system, choose(.system, true, true));
}

test "console host policy parses config values" {
    try std.testing.expectEqual(Preference.auto, parsePreference("auto").?);
    try std.testing.expectEqual(Preference.system, parsePreference("system").?);
    try std.testing.expect(parsePreference("bundled") == null);
    try std.testing.expect(parsePreference("") == null);
}
```

Register in both test roots:
- `src/test_fast.zig`: add `_ = @import("platform/console_host_policy.zig");` after the `platform/dxgi_core.zig` line.
- `src/test_main.zig`: add `_ = @import("platform/console_host_policy.zig");` right before `_ = @import("platform/pty.zig");` in the platform import block.

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -20`
Expected: FAIL — "console host policy uses bundled host only when fully present under auto" (expected `.bundled`, found `.system`) and the parse test.

- [ ] **Step 3: Replace the stubs with the real implementations**

```zig
pub fn choose(pref: Preference, dll_present: bool, host_exe_present: bool) Choice {
    if (pref == .system) return .system;
    if (dll_present and host_exe_present) return .bundled;
    return .system;
}

pub fn parsePreference(value: []const u8) ?Preference {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "system")) return .system;
    return null;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add src/platform/console_host_policy.zig src/test_fast.zig src/test_main.zig
git commit -m "feat(win32): add pure console-host choice policy"
```

---

### Task 2: Config key `windows-conpty`

**Files:**
- Modify: `src/config.zig` — field block (~line 320, after `@"jina-api-key"`), `applyKeyValue` chain (~line 864, after the `jina-api-key` branch), CLI help text (~line 1340), sample config (~line 1710), tests (~line 2133)

- [ ] **Step 1: Write the failing test** (append near the existing `config: jina-api-key parses from a config line` test at line 2133)

```zig
test "config: windows-conpty parses and rejects invalid values" {
    const allocator = std.testing.allocator;
    var cfg = Config{};
    defer cfg.deinit(allocator);
    try std.testing.expectEqual(console_host_policy.Preference.auto, cfg.@"windows-conpty");
    cfg.applyKeyValue(allocator, "windows-conpty", "system", ".");
    try std.testing.expectEqual(console_host_policy.Preference.system, cfg.@"windows-conpty");
    cfg.applyKeyValue(allocator, "windows-conpty", "bundled-only", ".");
    try std.testing.expectEqual(console_host_policy.Preference.system, cfg.@"windows-conpty");
}
```

Mirror the exact setup of the neighboring `jina-api-key` test (it shows the real `Config` init/deinit pattern — copy that, only swapping key and assertions).

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -10`
Expected: compile error — no field `windows-conpty`, no `console_host_policy` identifier.

- [ ] **Step 3: Implement the key**

Top of `src/config.zig`, with the other imports:

```zig
const console_host_policy = @import("platform/console_host_policy.zig");
```

Field, after the `@"jina-api-key"` field:

```zig
/// Which Windows pseudo console host services terminal sessions: `auto`
/// prefers a bundled modern ConPTY (conpty.dll + OpenConsole.exe next to
/// wispterm.exe, shipped in the portable-compat package) with fallback to
/// the OS inbox implementation; `system` always uses the inbox one.
/// Ignored on non-Windows platforms.
@"windows-conpty": console_host_policy.Preference = .auto,
```

`applyKeyValue` branch, after the `jina-api-key` branch:

```zig
} else if (std.mem.eql(u8, key, "windows-conpty")) {
    if (console_host_policy.parsePreference(value)) |pref| {
        self.@"windows-conpty" = pref;
    } else {
        log.warn("invalid windows-conpty: {s}", .{value});
    }
```

CLI help (match neighboring line style at ~1340):

```zig
\\  --windows-conpty <auto|system> Windows pseudo console host (default: auto)
```

Sample config (match the commented-key style at ~1710):

```zig
\\# windows-conpty = auto
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): windows-conpty key selects console host preference"
```

---

### Task 3: Windows loader `conpty_dll.zig` + `pty_windows.zig` integration + facade

**Files:**
- Create: `src/platform/conpty_dll.zig`
- Modify: `src/platform/pty_windows.zig` (replace local COORD/externs, add `api` field, rework open/setSize/deinit, add preference setter)
- Modify: `src/platform/pty.zig` (facade setter; MUST NOT contain the string `windows_conpty`)
- Modify: `src/platform/pty_posix.zig`, `src/platform/pty_unsupported.zig` (no-op setters)
- Modify: `src/pty.zig` (re-export)

- [ ] **Step 1: Write the failing facade/API-shape tests**

Append to `src/platform/pty.zig`:

```zig
test "platform pty exposes console host preference setter on all backends" {
    try std.testing.expect(@hasDecl(@This(), "setConsoleHostPreference"));
    try std.testing.expect(@hasDecl(@This(), "ConsoleHostPreference"));
}
```

Append to `src/platform/pty_windows.zig`:

```zig
test "platform pty binds each session to its creating console host api" {
    try std.testing.expect(@hasField(Pty, "api"));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test-full 2>&1 | tail -10`
Expected: compile error / test failure — `setConsoleHostPreference` and `api` don't exist.

- [ ] **Step 3: Create `src/platform/conpty_dll.zig`**

```zig
//! Windows pseudo-console API resolution: prefers the redistributable
//! Microsoft.Windows.Console.ConPTY pair (conpty.dll + OpenConsole.exe)
//! placed next to wispterm.exe, falling back to the OS inbox kernel32
//! implementation. The bundled pair gives old Windows 10 conhosts the
//! modern ConPTY behaviors (mouse-mode passthrough, alt-screen passthrough)
//! that crossterm TUIs such as Codex rely on.
//!
//! Only `platform/pty_windows.zig` may import this module.

const std = @import("std");
const policy = @import("console_host_policy.zig");

const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const DWORD = windows.DWORD;
const HRESULT = i32;

const log = std.log.scoped(.conpty);

pub const COORD = extern struct {
    X: i16,
    Y: i16,
};

pub const HPCON = windows.HANDLE;

pub const CreateFn = *const fn (
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;
pub const ResizeFn = *const fn (hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
pub const CloseFn = *const fn (hPC: HPCON) callconv(.winapi) void;

pub const Api = struct {
    choice: policy.Choice,
    create: CreateFn,
    resize: ResizeFn,
    close: CloseFn,
};

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;
extern "kernel32" fn ResizePseudoConsole(hPC: HPCON, size: COORD) callconv(.winapi) HRESULT;
extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

const system_api = Api{
    .choice = .system,
    .create = &CreatePseudoConsole,
    .resize = &ResizePseudoConsole,
    .close = &ClosePseudoConsole,
};

const bundled_dll_name = "conpty.dll";
const bundled_host_name = "OpenConsole.exe";

var g_mutex: std.Thread.Mutex = .{};
var g_preference: policy.Preference = .auto;
var g_resolved: ?*const Api = null;
var g_bundled_api: Api = undefined;

/// Set from the config layer before (or after) sessions exist. Resets the
/// cached resolution so the next `acquire` re-evaluates; already-created
/// sessions keep the api pointer they were born with.
pub fn setPreference(pref: policy.Preference) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_preference == pref) return;
    g_preference = pref;
    g_resolved = null;
}

pub fn systemApi() *const Api {
    return &system_api;
}

/// Permanently downgrade to the inbox implementation (called after a bundled
/// create failure so one broken redistributable cannot break every new tab).
pub fn stickToSystem() void {
    g_mutex.lock();
    defer g_mutex.unlock();
    g_resolved = &system_api;
}

pub fn acquire() *const Api {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_resolved) |api| return api;
    const api = resolveLocked();
    g_resolved = api;
    return api;
}

fn resolveLocked() *const Api {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = std.fs.selfExeDirPath(&dir_buf) catch {
        log.warn("conpty: cannot resolve exe dir; using system pseudo console", .{});
        return &system_api;
    };

    const dll_present = siblingExists(exe_dir, bundled_dll_name);
    const host_present = siblingExists(exe_dir, bundled_host_name);
    if (policy.choose(g_preference, dll_present, host_present) == .system) {
        if (g_preference == .auto and (dll_present != host_present)) {
            log.warn(
                "conpty: incomplete bundle next to exe (dll={}, host={}); using system pseudo console",
                .{ dll_present, host_present },
            );
        }
        return &system_api;
    }

    return loadBundled(exe_dir) orelse &system_api;
}

fn siblingExists(exe_dir: []const u8, name: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ exe_dir, name }) catch return false;
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn loadBundled(exe_dir: []const u8) ?*const Api {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\{s}", .{ exe_dir, bundled_dll_name }) catch return null;

    var wide_buf: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch {
        log.warn("conpty: bundle path not encodable; using system pseudo console", .{});
        return null;
    };
    wide_buf[wide_len] = 0;

    const module = windows.kernel32.LoadLibraryW(wide_buf[0..wide_len :0].ptr) orelse {
        log.warn("conpty: LoadLibraryW(conpty.dll) failed ({}); using system pseudo console", .{windows.GetLastError()});
        return null;
    };

    const create = windows.kernel32.GetProcAddress(module, "ConptyCreatePseudoConsole") orelse {
        log.warn("conpty: ConptyCreatePseudoConsole missing; using system pseudo console", .{});
        return null;
    };
    const resize = windows.kernel32.GetProcAddress(module, "ConptyResizePseudoConsole") orelse {
        log.warn("conpty: ConptyResizePseudoConsole missing; using system pseudo console", .{});
        return null;
    };
    const close = windows.kernel32.GetProcAddress(module, "ConptyClosePseudoConsole") orelse {
        log.warn("conpty: ConptyClosePseudoConsole missing; using system pseudo console", .{});
        return null;
    };

    g_bundled_api = .{
        .choice = .bundled,
        .create = @ptrCast(@alignCast(create)),
        .resize = @ptrCast(@alignCast(resize)),
        .close = @ptrCast(@alignCast(close)),
    };
    log.info("conpty: using bundled conpty.dll next to exe", .{});
    return &g_bundled_api;
}

test "conpty resolution falls back to system when no bundle is present" {
    // The test binary has no conpty.dll/OpenConsole.exe next to it, so auto
    // must resolve to the inbox implementation.
    setPreference(.auto);
    g_mutex.lock();
    g_resolved = null;
    g_mutex.unlock();
    try std.testing.expectEqual(policy.Choice.system, acquire().choice);
}

test "conpty resolution honors forced system preference" {
    setPreference(.system);
    try std.testing.expectEqual(policy.Choice.system, acquire().choice);
    setPreference(.auto);
}
```

- [ ] **Step 4: Rework `src/platform/pty_windows.zig`**

Remove the local `COORD` struct and the three `CreatePseudoConsole`/`ClosePseudoConsole`/`ResizePseudoConsole` externs (lines 16-19, 36-46). Add at the top:

```zig
const conpty_dll = @import("conpty_dll.zig");
const console_host_policy = @import("console_host_policy.zig");

const COORD = conpty_dll.COORD;
const PseudoConsoleHandle = conpty_dll.HPCON;
const log = std.log.scoped(.conpty);
```

(Delete the old `const PseudoConsoleHandle = windows.HANDLE;` line; keep `HRESULT`/`s_ok` as-is.)

Add the preference setter (module level):

```zig
pub fn setConsoleHostPreference(pref: console_host_policy.Preference) void {
    conpty_dll.setPreference(pref);
}
```

`Pty` struct: add field `api: *const conpty_dll.Api,`.

In `open`, replace the two `CreatePseudoConsole` lines (121-123) with:

```zig
        const coord = COORD{ .X = @intCast(size.ws_col), .Y = @intCast(size.ws_row) };
        var api = conpty_dll.acquire();
        var hr = api.create(coord, self.in_pipe_pty, self.out_pipe_pty, 0, &self.pseudo_console);
        if (hr != s_ok and api.choice == .bundled) {
            // One broken redistributable must not break every new tab: latch
            // back to the inbox implementation and retry once.
            log.warn("conpty: bundled create failed (hr=0x{x}); falling back to system pseudo console", .{@as(u32, @bitCast(hr))});
            conpty_dll.stickToSystem();
            api = conpty_dll.systemApi();
            hr = api.create(coord, self.in_pipe_pty, self.out_pipe_pty, 0, &self.pseudo_console);
        }
        if (hr != s_ok) return error.CreatePseudoConsoleFailed;
        self.api = api;
```

In `deinit`, replace `ClosePseudoConsole(self.pseudo_console);` with `self.api.close(self.pseudo_console);`.

In `setSize`, replace `ResizePseudoConsole(self.pseudo_console, coord)` with `self.api.resize(self.pseudo_console, coord)`.

- [ ] **Step 5: Facade + stubs + re-export**

`src/platform/pty.zig` (after the `pub const Pty = impl.Pty;` line; do NOT write the string `windows_conpty` anywhere in this file):

```zig
pub const ConsoleHostPreference = @import("console_host_policy.zig").Preference;

/// Which console host implementation services new sessions (no-op on
/// platforms whose PTY backend has only one implementation).
pub fn setConsoleHostPreference(pref: ConsoleHostPreference) void {
    impl.setConsoleHostPreference(pref);
}
```

`src/platform/pty_posix.zig` and `src/platform/pty_unsupported.zig` (module level):

```zig
pub fn setConsoleHostPreference(pref: @import("console_host_policy.zig").Preference) void {
    _ = pref;
}
```

`src/pty.zig` (after the existing re-exports):

```zig
pub const ConsoleHostPreference = platform_pty.ConsoleHostPreference;
pub const setConsoleHostPreference = platform_pty.setConsoleHostPreference;
```

- [ ] **Step 6: Run both suites**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: PASS (the Step 1 tests now pass; the conpty_dll tests run in the windows-gnu suite and resolve to `.system` because no bundle sits next to the test binary).

- [ ] **Step 7: Commit**

```bash
git add src/platform/conpty_dll.zig src/platform/pty_windows.zig src/platform/pty.zig src/platform/pty_posix.zig src/platform/pty_unsupported.zig src/pty.zig
git commit -m "feat(win32): prefer bundled conpty.dll with sticky system fallback"
```

---

### Task 4: App/AppWindow plumbing (startup + reload)

**Files:**
- Modify: `src/App.zig` (field near line 105-109, init near line 251, `updateConfig` near line 447)
- Modify: `src/AppWindow.zig` (startup config block near line 195, `applyReloadedConfig` near line 4089)

- [ ] **Step 1: Add the App field and copies**

`src/App.zig` imports (top): `const console_host_policy = @import("platform/console_host_policy.zig");`

Field, next to `jina_api_key: []const u8,` (line ~109):

```zig
console_host_preference: console_host_policy.Preference,
```

Init struct literal (next to `.jina_api_key = jina_api_key,` line ~255):

```zig
.console_host_preference = cfg.@"windows-conpty",
```

`updateConfig` (next to the `jina_api_key` replace at line ~451):

```zig
self.console_host_preference = cfg.@"windows-conpty";
```

- [ ] **Step 2: Apply at startup and on reload**

`src/AppWindow.zig` startup block, right after `@import("web_search.zig").setJinaApiKey(app.jina_api_key);` (line ~195):

```zig
@import("pty.zig").setConsoleHostPreference(app.console_host_preference);
```

`applyReloadedConfig`, right after the `setJinaApiKey(cfg.@"jina-api-key");` line (~4089):

```zig
@import("pty.zig").setConsoleHostPreference(cfg.@"windows-conpty");
```

This is the startup-trap pattern (runtime config keys must load at startup via an App field, not just on reload).

- [ ] **Step 3: Run both suites**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: PASS (App.zig has reflective tests that construct App — a missing init field is a compile error, which is the test).

- [ ] **Step 4: Commit**

```bash
git add src/App.zig src/AppWindow.zig
git commit -m "feat(config): plumb windows-conpty preference to the PTY layer at startup"
```

---

### Task 5: Updater flavor `compat` + asset names + detection

**Files:**
- Modify: `src/release_package.zig` (Flavor enum + test)
- Modify: `src/platform/update_package.zig` (`runtimeFlavor` + tests at lines 109-139)
- Modify: `src/platform/update_package_windows.zig` (asset prefix, `runtimeFlavor`, `currentPackage`)
- Modify: `src/update_check.zig` (3 scenario references at lines 452, 520, 549)

- [ ] **Step 1: Update the tests first (failing)**

In `src/platform/update_package.zig`, change the expectations:

```zig
test "platform update package keeps Windows portable flavor logic in platform layer" {
    try std.testing.expectEqual(release_package.Flavor.without_embedded_browser_payload, runtimeFlavor(false, true));
    try std.testing.expectEqual(release_package.Flavor.compat, runtimeFlavor(true, true));
    try std.testing.expectEqual(release_package.Flavor.baseline, runtimeFlavor(true, false));
    try std.testing.expect(release_package.Package.init(.windows, .compat).requiresEmbeddedBrowserPayload());
}

test "platform update package builds Windows portable asset names" {
    var buf: [128]u8 = undefined;
    const normal = try assetNameForScenario("v0.28.0", .baseline, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-v0.28.0.zip", normal);

    const compat = try assetNameForScenario("v0.28.0", .compat, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-compat-v0.28.0.zip", compat);

    const no_embedded_browser = try assetNameForScenario("v0.28.0", .without_embedded_browser_payload, &buf);
    try std.testing.expectEqualStrings("wispterm-windows-portable-no-webview-v0.28.0.zip", no_embedded_browser);
}

test "platform update package matches exact target asset names only" {
    try std.testing.expect(matchesAssetName(
        "wispterm-windows-portable-compat-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.compat),
    ));
    try std.testing.expect(!matchesAssetName(
        "wispterm-windows-portable-v0.28.0.zip",
        "v0.28.0",
        packageForScenario(.compat),
    ));
}
```

In `src/release_package.zig`, update the test:

```zig
test "release package exposes embedded browser payload requirement" {
    try std.testing.expect(Package.init(.windows, .compat).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!Package.init(.windows, .baseline).requiresEmbeddedBrowserPayload());
    try std.testing.expect(!(Package{ .platform = .linux }).requiresEmbeddedBrowserPayload());
}
```

- [ ] **Step 2: Run to verify failure**

Run: `zig build test 2>&1 | tail -10`
Expected: compile error — enum `release_package.Flavor` has no member `compat`.

- [ ] **Step 3: Implement the rename and detection**

`src/release_package.zig`:

```zig
pub const Flavor = enum {
    baseline,
    /// Full-featured package for older Windows machines: ships the embedded
    /// browser loader plus a modern bundled console host.
    compat,
    without_embedded_browser_payload,
};
```

and `requiresEmbeddedBrowserPayload`:

```zig
    pub fn requiresEmbeddedBrowserPayload(self: Package) bool {
        return self.flavor == .compat;
    }
```

`src/platform/update_package.zig` `runtimeFlavor` (line 29):

```zig
fn runtimeFlavor(webview_enabled: bool, has_compat_payload: bool) release_package.Flavor {
    if (!webview_enabled) return .without_embedded_browser_payload;
    if (has_compat_payload) return .compat;
    return .baseline;
}
```

Also rename the `has_embedded_browser_payload` parameter to `has_compat_payload` in `runtimePackageForOs` (line 76) and `runtimePackage` (line 88). Do NOT change `update_install.zig`'s public `runtimePackage` parameter name (it would churn App.zig call sites for nothing) — its forwarding still compiles.

`src/platform/update_package_windows.zig`:

```zig
const embedded_browser_payload_path = "WebView2Loader.dll";
const bundled_console_host_payload_path = "conpty.dll";
```

`assetNameParts`: rename the `.with_required_embedded_browser_payload` arm to `.compat` with prefix `"wispterm-windows-portable-compat-"`.

`currentPackage`: detect either payload (the "or" migrates v1.18.0 webview2 installs into the compat asset on their next update):

```zig
pub fn currentPackage(allocator: std.mem.Allocator, webview_enabled: bool) !release_package.Package {
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return release_package.Package.init(.windows, .baseline);
    const has_compat_payload = payloadExists(allocator, exe_dir, embedded_browser_payload_path) or
        payloadExists(allocator, exe_dir, bundled_console_host_payload_path);
    return release_package.Package.init(.windows, runtimeFlavor(webview_enabled, has_compat_payload));
}

fn payloadExists(allocator: std.mem.Allocator, exe_dir: []const u8, name: []const u8) bool {
    const path = std.fs.path.join(allocator, &.{ exe_dir, name }) catch return false;
    defer allocator.free(path);
    var file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}
```

Keep the local `runtimeFlavor` in this file in sync (same three-line body as the facade one).

`src/update_check.zig`: replace the three `.with_required_embedded_browser_payload` references with `.compat`.

- [ ] **Step 4: Sweep for stragglers**

Run: `grep -rn "with_required_embedded_browser_payload" src/`
Expected: no matches. (test_main.zig's guards reference banned *strings*, not this enum — they need no change.)

- [ ] **Step 5: Run both suites**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/release_package.zig src/platform/update_package.zig src/platform/update_package_windows.zig src/update_check.zig
git commit -m "feat(update): compat flavor replaces webview2; detects bundled console host"
```

---

### Task 6: Packaging — `package.ps1` compat bundle

**Files:**
- Modify: `packaging/windows/package.ps1`

No Zig tests cover PowerShell; verification is syntax parsing (if `pwsh` exists locally) plus CI. Make the edits exactly as below.

- [ ] **Step 1: Param block** — replace `[switch]$SkipWebView2Bundle` with:

```powershell
    [string]$ConPtyVersion = '1.24.260512001',
    [switch]$SkipCompatBundle,
```

(keep the other params unchanged; `$WebView2Version` stays).

- [ ] **Step 2: Add `Get-ConPtyPair`** after the `Get-WebView2Loader` function:

```powershell
function Get-ConPtyPair {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $cacheRoot = Join-Path $RepoRoot '.zig-cache\conpty'
    $packageDir = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version"
    $dllPath = Join-Path $packageDir 'runtimes\win-x64\native\conpty.dll'
    $hostPath = Join-Path $packageDir 'build\native\runtimes\x64\OpenConsole.exe'
    if ((Test-Path $dllPath) -and (Test-Path $hostPath)) {
        return @{ Dll = $dllPath; HostExe = $hostPath }
    }

    New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
    $nupkgPath = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version.nupkg"
    $zipPath = Join-Path $cacheRoot "Microsoft.Windows.Console.ConPTY.$Version.zip"
    $packageUrl = "https://www.nuget.org/api/v2/package/Microsoft.Windows.Console.ConPTY/$Version"

    if (-not (Test-Path $nupkgPath)) {
        Write-Host "Downloading Microsoft.Windows.Console.ConPTY $Version"
        Invoke-WebRequest -Uri $packageUrl -OutFile $nupkgPath
    }

    Remove-Item -Path $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $nupkgPath -Destination $zipPath -Force
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $packageDir -Force
    } finally {
        Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $dllPath)) {
        throw "conpty.dll was not found in Microsoft.Windows.Console.ConPTY $Version."
    }
    if (-not (Test-Path $hostPath)) {
        throw "OpenConsole.exe was not found in Microsoft.Windows.Console.ConPTY $Version."
    }

    return @{ Dll = $dllPath; HostExe = $hostPath }
}
```

- [ ] **Step 3: Extend `Copy-PortablePayload`** — add an optional parameter after `[string]$WebView2LoaderPath`:

```powershell
        [hashtable]$ConPtyPair
```

and at the end of the function body:

```powershell
    if ($null -ne $ConPtyPair) {
        Copy-Item -Path $ConPtyPair.Dll -Destination (Join-Path $TargetDir 'conpty.dll') -Force
        Copy-Item -Path $ConPtyPair.HostExe -Destination (Join-Path $TargetDir 'OpenConsole.exe') -Force
    }
```

- [ ] **Step 4: Swap the webview2 staging dir for compat**

- `$portableWebView2Dir = Join-Path $resolvedOutputDir 'portable-webview2'` → `$portableCompatDir = Join-Path $resolvedOutputDir 'portable-compat'`
- Fetch both payloads under one gate (replaces the `if (-not $SkipWebView2Bundle)` block):

```powershell
$conPtyPair = $null
if (-not $SkipCompatBundle) {
    $webView2LoaderPath = Get-WebView2Loader -RepoRoot $repoRoot -Version $WebView2Version
    $conPtyPair = Get-ConPtyPair -RepoRoot $repoRoot -Version $ConPtyVersion
}
```

- `Remove-Item` list: replace `$portableWebView2Dir` with `$portableCompatDir`.
- Staging call:

```powershell
if ($webView2LoaderPath) {
    Copy-PortablePayload -BinaryPath $binaryPath -TargetDir $portableCompatDir -ReleaseVersion $releaseVersion -WebView2LoaderPath $webView2LoaderPath -ConPtyPair $conPtyPair
}
```

- The two `Write-Host "Portable WebView2 build: ..."` lines → `Write-Host "Portable compat build: $(Join-Path $portableCompatDir 'wispterm.exe')"`.
- Installer staging (`$stagingDir`) keeps using `$webView2LoaderPath` only — unchanged.

- [ ] **Step 5: Verify syntax if pwsh is available, then commit**

Run: `command -v pwsh && pwsh -NoProfile -Command '$t=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile("packaging/windows/package.ps1",[ref]$t,[ref]$t); if($t){$t; exit 1} else {"parse ok"}' || echo "pwsh not available; CI validates"`
Expected: "parse ok" (or the skip message).

```bash
git add packaging/windows/package.ps1
git commit -m "feat(packaging): portable-compat bundle with ConPTY pair replaces portable-webview2"
```

---

### Task 7: CI — `windows-release.yml`

**Files:**
- Modify: `.github/workflows/windows-release.yml`

- [ ] **Step 1: Validation step** — replace the `portableWebView2*` variables/checks (lines 85-88, 109-123) with:

```powershell
          $portableCompatExe = "zig-out\dist\portable-compat\wispterm.exe"
          $portableCompatVersion = "zig-out\dist\portable-compat\version.txt"
          $portableCompatWebView2Loader = "zig-out\dist\portable-compat\WebView2Loader.dll"
          $portableCompatConPty = "zig-out\dist\portable-compat\conpty.dll"
          $portableCompatConsoleHost = "zig-out\dist\portable-compat\OpenConsole.exe"
          $portableCompatPluginSkills = "zig-out\dist\portable-compat\plugins\skills"
```

with corresponding `if (!(Test-Path ...)) { throw ... }` blocks for all six paths (same style as the existing checks), and update the `$distDir` loop list to `@("zig-out\dist\portable", "zig-out\dist\portable-compat", "zig-out\dist\portable-no-webview")`.

- [ ] **Step 2: Asset creation/upload/publish** — rename throughout the remaining steps:

- `$portableWebView2Asset = "wispterm-windows-portable-webview2-$tag.zip"` → `$portableCompatAsset = "wispterm-windows-portable-compat-$tag.zip"`
- `Compress-Archive -Path zig-out\dist\portable-webview2\* ...` → `zig-out\dist\portable-compat\*` into `$portableCompatAsset`
- Upload-artifact step name/path `wispterm-windows-portable-webview2-...` → `wispterm-windows-portable-compat-...`
- `gh release upload`/`gh release create` argument lists: swap the webview2 asset variable for the compat one.

- [ ] **Step 3: Release-notes blurb** — replace the `"- Portable WebView2: ..."` line with:

```
"- Portable compat: zip archive for older Windows 10 machines - bundles WebView2Loader.dll for the embedded browser plus a modern ConPTY (conpty.dll + OpenConsole.exe) so TUI apps like Codex and Claude Code get mouse scrolling and scrollbars",
```

- [ ] **Step 4: Verify YAML parses, then commit**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/windows-release.yml')); print('yaml ok')"`
Expected: `yaml ok`.

```bash
git add .github/workflows/windows-release.yml
git commit -m "ci(windows): publish portable-compat zip instead of portable-webview2"
```

---

### Task 8: Docs

**Files:**
- Modify: `docs/development.md` (lines ~240, ~256-259, ~300, ~309)

- [ ] **Step 1: Update the variant docs**

- Line ~240 bullet: `- portable-compat - portable build for older Windows 10 machines with WebView2Loader.dll plus a bundled modern ConPTY (conpty.dll + OpenConsole.exe)`
- File-tree block (~256-259): `portable-webview2` paths → `portable-compat`, adding the two new files:

```
zig-out\dist\portable-compat\wispterm.exe
zig-out\dist\portable-compat\WebView2Loader.dll
zig-out\dist\portable-compat\conpty.dll
zig-out\dist\portable-compat\OpenConsole.exe
zig-out\dist\portable-compat\version.txt
zig-out\dist\portable-compat\plugins\...
```

- Asset name ~300: `wispterm-windows-portable-webview2-vX.Y.Z.zip` → `wispterm-windows-portable-compat-vX.Y.Z.zip`
- Guidance sentence ~309: recommend the `portable-compat` zip for the embedded browser panel **or for older Windows 10 machines where TUI mouse support needs the bundled ConPTY**.
- Also mention the `windows-conpty = auto|system` config key in the same section (one sentence: compat bundles are preferred automatically; `system` forces the OS inbox ConPTY).

Note: `wiki/` has no webview2-asset mentions (verified by grep), and `docs/development.md` is not one of the @embedFile'd in-app docs, so no wiki sync is needed.

- [ ] **Step 2: Commit**

```bash
git add docs/development.md
git commit -m "docs: describe portable-compat bundle and windows-conpty key"
```

---

### Task 9: Final verification

- [ ] **Step 1: Full suites + release cross-compile smoke**

Run: `zig build test 2>&1 | tail -3 && zig build test-full 2>&1 | tail -3 && zig build -Doptimize=ReleaseFast 2>&1 | tail -3`
Expected: all green; release build produces `zig-out/bin/wispterm.exe`.

- [ ] **Step 2: Straggler sweep**

Run: `grep -rn "portable-webview2\|with_required_embedded_browser_payload" src packaging .github docs/development.md`
Expected: no matches (historical specs under `docs/superpowers/specs/` may still mention the old name; leave those).

- [ ] **Step 3: Verify guard suite still compiles the banned-string checks**

`zig build test-full` already compiles `test_main.zig`; if a guard fired it would have failed above. Nothing extra to run.
