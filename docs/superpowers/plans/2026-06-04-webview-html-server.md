# WebView HTML Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a refresh button to the embedded WebView toolbar and open Ctrl-clicked `.html` / `.htm` terminal paths through an HTTP server in the file's own environment.

**Architecture:** Keep pure decision logic in `src/html_server_model.zig`, runtime server/process management in `src/html_server.zig`, and existing UI/input integration in `browser_panel`, `input`, `hit_test`, and `renderer/overlays`. SSH HTML serving starts a remote loopback server and reuses the existing SSH tunnel URL helper, matching the already-supported Jupyter loopback path.

**Tech Stack:** Zig 0.15.2, WebView2 C bridge on Windows, WKWebView bridge on macOS, `std.process.Child`, existing `ssh_tunnel`, existing terminal preview path resolution, and Ghostty-style modifier link actions.

---

## File Structure

- Create `src/html_server_model.zig`: pure HTML suffix detection, server candidate ordering, percent-encoding, URL construction, and environment key helpers. Add to `src/test_fast.zig`.
- Create `src/html_server.zig`: runtime registry, local/WSL/SSH server spawning, process cleanup, reachability checks, and WebView URL generation.
- Modify `src/browser_panel.zig` and `src/browser_panel_stub.zig`: expose `refresh()` and call `html_server.deinit()` during panel teardown.
- Modify `src/platform/webview.zig`, `src/platform/webview_windows.zig`, `src/platform/webview_macos.zig`, `src/platform/webview_unsupported.zig`, `src/platform/webview2_bridge.c`, and `src/platform/webview_macos_bridge.m`: add backend reload support.
- Modify `src/input/hit_test.zig`: generalize right-aligned panel header button geometry so refresh, display toggle, and close have stable hit boxes.
- Modify `src/renderer/overlays.zig`: render the refresh icon/button and keep the toolbar compact.
- Modify `src/input.zig`: hit-test the refresh button and route Ctrl-clicked HTML paths to the HTML server before Markdown preview.
- Modify `src/test_main.zig` only if a compile guard needs to assert the WebView facade remains backend-neutral.

## Task 1: Pure HTML Server Model

**Files:**
- Create: `src/html_server_model.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing tests**

Add `src/html_server_model.zig` with tests first:

```zig
const std = @import("std");

pub const ServerKind = enum {
    python3,
    py_launcher_python3,
    python3_via_python,
    python2,
    python2_via_python,
    node_inline,
    npx_http_server,
};

pub const Probe = struct {
    python3: bool = false,
    py_launcher_python3: bool = false,
    python_is_python3: bool = false,
    python_is_python2: bool = false,
    python2: bool = false,
    node: bool = false,
    npx_http_server: bool = false,
};

pub fn isHtmlPath(path: []const u8) bool {
    _ = path;
    return false;
}

pub fn chooseServerKind(probe: Probe) ?ServerKind {
    _ = probe;
    return null;
}

pub fn percentEncodeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    _ = allocator;
    _ = segment;
    return error.RedTestExpectedFailure;
}

pub fn buildHttpUrl(allocator: std.mem.Allocator, host: []const u8, port: u16, file_name: []const u8) ![]u8 {
    _ = allocator;
    _ = host;
    _ = port;
    _ = file_name;
    return error.RedTestExpectedFailure;
}

test "html_server_model: detects html path suffixes only" {
    try std.testing.expect(isHtmlPath("index.html"));
    try std.testing.expect(isHtmlPath("INDEX.HTML"));
    try std.testing.expect(isHtmlPath("report.htm"));
    try std.testing.expect(!isHtmlPath("README.md"));
    try std.testing.expect(!isHtmlPath("html"));
    try std.testing.expect(!isHtmlPath("https://example.com/index.html"));
}

test "html_server_model: server candidate ordering prefers target python before node" {
    try std.testing.expectEqual(ServerKind.python3, chooseServerKind(.{ .python3 = true, .node = true }).?);
    try std.testing.expectEqual(ServerKind.py_launcher_python3, chooseServerKind(.{ .py_launcher_python3 = true, .node = true }).?);
    try std.testing.expectEqual(ServerKind.python3_via_python, chooseServerKind(.{ .python_is_python3 = true, .python2 = true }).?);
    try std.testing.expectEqual(ServerKind.python2, chooseServerKind(.{ .python2 = true, .node = true }).?);
    try std.testing.expectEqual(ServerKind.python2_via_python, chooseServerKind(.{ .python_is_python2 = true, .node = true }).?);
    try std.testing.expectEqual(ServerKind.node_inline, chooseServerKind(.{ .node = true, .npx_http_server = true }).?);
    try std.testing.expectEqual(ServerKind.npx_http_server, chooseServerKind(.{ .npx_http_server = true }).?);
    try std.testing.expectEqual(@as(?ServerKind, null), chooseServerKind(.{}));
}

test "html_server_model: percent-encodes path segment for URL" {
    const encoded = try percentEncodeSegment(std.testing.allocator, "a b#c.html");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%20b%23c.html", encoded);
}

test "html_server_model: builds localhost URL with encoded file segment" {
    const url = try buildHttpUrl(std.testing.allocator, "127.0.0.1", 49152, "a b.html");
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("http://127.0.0.1:49152/a%20b.html", url);
}
```

Add the module to `src/test_fast.zig`:

```zig
_ = @import("html_server_model.zig");
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `zig build test --summary all`

Expected: FAIL with compile or test failures from `src/html_server_model.zig` because `RedTestExpectedFailure` is returned and `isHtmlPath` / `chooseServerKind` return false/null.

- [ ] **Step 3: Implement the pure model**

Replace the stub functions in `src/html_server_model.zig` with:

```zig
fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

pub fn isHtmlPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) return false;
    return endsWithIgnoreCase(path, ".html") or endsWithIgnoreCase(path, ".htm");
}

pub fn chooseServerKind(probe: Probe) ?ServerKind {
    if (probe.python3) return .python3;
    if (probe.py_launcher_python3) return .py_launcher_python3;
    if (probe.python_is_python3) return .python3_via_python;
    if (probe.python2) return .python2;
    if (probe.python_is_python2) return .python2_via_python;
    if (probe.node) return .node_inline;
    if (probe.npx_http_server) return .npx_http_server;
    return null;
}

fn isUnreserved(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or
        (ch >= 'a' and ch <= 'z') or
        (ch >= '0' and ch <= '9') or
        ch == '-' or ch == '.' or ch == '_' or ch == '~';
}

pub fn percentEncodeSegment(allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (segment) |ch| {
        if (isUnreserved(ch)) {
            try out.append(allocator, ch);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hex[ch >> 4]);
            try out.append(allocator, hex[ch & 0x0F]);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildHttpUrl(allocator: std.mem.Allocator, host: []const u8, port: u16, file_name: []const u8) ![]u8 {
    const encoded = try percentEncodeSegment(allocator, file_name);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "http://{s}:{d}/{s}", .{ host, port, encoded });
}
```

- [ ] **Step 4: Run the tests and verify GREEN**

Run: `zig build test --summary all`

Expected: PASS for `html_server_model` tests and no regressions in fast tests.

- [ ] **Step 5: Commit**

```bash
git add src/html_server_model.zig src/test_fast.zig
git commit -m "test(html): add html server model"
```

## Task 2: Header Button Geometry for Three Browser Buttons

**Files:**
- Modify: `src/input/hit_test.zig`

- [ ] **Step 1: Write the failing hit-test tests**

Append tests to `src/input/hit_test.zig`:

```zig
test "panelHeaderButtonRect: indexes buttons from right to left" {
    const close = panelHeaderButtonRect(sample_panel, 0).?;
    const second = panelHeaderButtonRect(sample_panel, 1).?;
    const third = panelHeaderButtonRect(sample_panel, 2).?;

    try std.testing.expectEqual(@as(f64, 382), close.left);
    try std.testing.expectEqual(@as(f64, 346), second.left);
    try std.testing.expectEqual(@as(f64, 310), third.left);
    try std.testing.expectEqual(close.width, second.width);
    try std.testing.expectEqual(second.width, third.width);
}

test "panelHeaderButton: third button hit-test works" {
    try std.testing.expect(panelHeaderButton(sample_panel, 2, 320, 50));
    try std.testing.expect(!panelHeaderButton(sample_panel, 2, 346, 50));
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `zig test src/input/hit_test.zig`

Expected: FAIL with `panelHeaderButtonRect` / `panelHeaderButton` not found.

- [ ] **Step 3: Implement generic header button helpers**

Add these functions near the existing panel header helpers:

```zig
pub fn panelHeaderButtonRect(l: PanelHeaderLayout, index_from_right: usize) ?Rect {
    if (!l.visible) return null;
    if (l.right <= l.left or l.height <= 0) return null;
    if (l.close_btn_w <= 0 or l.close_margin < 0) return null;

    const stride = l.close_btn_w + PANEL_HEADER_BTN_GAP;
    const offset = @as(f64, @floatFromInt(index_from_right)) * stride;
    const left = l.right - l.close_margin - l.close_btn_w - offset;
    if (left <= l.left) return null;
    return .{ .left = left, .top = l.top, .width = l.close_btn_w, .height = l.height };
}

pub fn panelHeaderButton(l: PanelHeaderLayout, index_from_right: usize, x: f64, y: f64) bool {
    const r = panelHeaderButtonRect(l, index_from_right) orelse return false;
    return x >= r.left and x < r.left + r.width and y >= r.top and y < r.top + r.height;
}
```

Then update existing helpers to delegate:

```zig
pub fn panelSecondButtonRect(l: PanelHeaderLayout) ?Rect {
    return panelHeaderButtonRect(l, 1);
}

pub fn panelHeaderSecondButton(l: PanelHeaderLayout, x: f64, y: f64) bool {
    return panelHeaderButton(l, 1, x, y);
}

pub fn panelHeaderCloseButton(l: PanelHeaderLayout, x: f64, y: f64) bool {
    return panelHeaderButton(l, 0, x, y);
}

pub fn panelCloseButtonRect(l: PanelHeaderLayout) ?Rect {
    return panelHeaderButtonRect(l, 0);
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run: `zig test src/input/hit_test.zig`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/input/hit_test.zig
git commit -m "refactor(input): generalize panel header buttons"
```

## Task 3: WebView Reload Facade and Browser Panel Refresh

**Files:**
- Modify: `src/platform/webview.zig`
- Modify: `src/platform/webview_windows.zig`
- Modify: `src/platform/webview_macos.zig`
- Modify: `src/platform/webview_unsupported.zig`
- Modify: `src/platform/webview2_bridge.c`
- Modify: `src/platform/webview_macos_bridge.m`
- Modify: `src/browser_panel.zig`
- Modify: `src/browser_panel_stub.zig`

- [ ] **Step 1: Write failing compile/API tests**

Extend the existing test in `src/platform/webview.zig`:

```zig
const reload_info = @typeInfo(@TypeOf(reload)).@"fn";
try std.testing.expectEqual(@as(usize, 1), reload_info.params.len);
try std.testing.expect(reload_info.params[0].type.? == *@This().Browser);
```

Extend the existing parent-handle API test in `src/browser_panel.zig`:

```zig
const refresh_info = @typeInfo(@TypeOf(refresh)).@"fn";
try std.testing.expectEqual(@as(usize, 0), refresh_info.params.len);
```

- [ ] **Step 2: Run tests and verify RED**

Run: `zig build test --summary all`

Expected: FAIL because `platform_webview.reload` and `browser_panel.refresh` are not defined.

- [ ] **Step 3: Add Zig facade reload methods**

In `src/platform/webview.zig`:

```zig
pub fn reload(browser: *Browser) void {
    impl.reload(browser);
}
```

In `src/platform/webview_windows.zig` add the extern and wrapper:

```zig
extern fn wispterm_webview2_reload(browser: *Browser) callconv(.c) void;

pub fn reload(browser: *Browser) void {
    wispterm_webview2_reload(browser);
}
```

In `src/platform/webview_macos.zig` add the extern and wrapper:

```zig
extern fn wispterm_webview_macos_reload(browser: *Browser) callconv(.c) void;

pub fn reload(browser: *Browser) void {
    wispterm_webview_macos_reload(browser);
}
```

In `src/platform/webview_unsupported.zig`:

```zig
pub fn reload(browser: *Browser) void {
    _ = browser;
}
```

- [ ] **Step 4: Add native bridge reload methods**

In `src/platform/webview2_bridge.c`, extend `ICoreWebView2Vtbl` by adding `Reload` after `NavigateToString` to match the WebView2 interface order used by this local bridge:

```c
HRESULT (STDMETHODCALLTYPE *Reload)(ICoreWebView2 *This);
```

Add this exported function near `wispterm_webview2_navigate`:

```c
void wispterm_webview2_reload(WispTermWebView2Browser *browser) {
    if (!browser || browser->closing || !browser->webview) return;
    browser->last_error = browser->webview->lpVtbl->Reload(browser->webview);
}
```

In `src/platform/webview_macos_bridge.m`, add:

```objc
void wispterm_webview_macos_reload(void *browser) {
    WispTermMacWebView *st = (WispTermMacWebView *)browser;
    if (st == NULL || st->webview == nil) return;
    wispterm_webview_run_on_main(^{
        @autoreleasepool {
            [st->webview reload];
        }
    });
}
```

- [ ] **Step 5: Add browser panel refresh wrappers**

In `src/browser_panel.zig`:

```zig
pub fn refresh() void {
    const browser = g_browser orelse return;
    platform_webview.reload(browser);
    g_last_error = platform_webview.lastError(browser);
}
```

In `src/browser_panel_stub.zig`:

```zig
pub fn refresh() void {}
```

- [ ] **Step 6: Run tests and verify GREEN**

Run: `zig build test --summary all`

Expected: PASS for fast tests. If the native host cannot compile platform C bridges, run `zig build test-full` later in the final verification task.

- [ ] **Step 7: Commit**

```bash
git add src/platform/webview.zig src/platform/webview_windows.zig src/platform/webview_macos.zig src/platform/webview_unsupported.zig src/platform/webview2_bridge.c src/platform/webview_macos_bridge.m src/browser_panel.zig src/browser_panel_stub.zig
git commit -m "feat(webview): add reload support"
```

## Task 4: Refresh Button Rendering and Input Routing

**Files:**
- Modify: `src/renderer/overlays.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Write failing input API tests**

Add a small type-level test near existing input tests in `src/input.zig`:

```zig
test "input: browser toolbar has a refresh action entrypoint" {
    const info = @typeInfo(@TypeOf(refreshBrowserPanel)).@"fn";
    try std.testing.expectEqual(@as(usize, 0), info.params.len);
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `zig build test --summary all`

Expected: FAIL because `refreshBrowserPanel` is not defined.

- [ ] **Step 3: Add refresh hit-test and action**

In `src/input.zig`, add:

```zig
pub fn refreshBrowserPanel() void {
    browser_panel.refresh();
    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
}

fn hitTestBrowserRefreshButton(xpos: f64, ypos: f64) bool {
    return hit_test.panelHeaderButton(browserHeaderLayout() orelse return false, 2, xpos, ypos);
}
```

In `handleMouseButton`, before the display-mode toggle check, add:

```zig
if (hitTestBrowserRefreshButton(xpos, ypos)) {
    refreshBrowserPanel();
    return;
}
```

- [ ] **Step 4: Render the refresh button**

In `src/renderer/overlays.zig`, inside `renderBrowserUrlBar`, compute button rects with indexes:

```zig
const close = hit_test.panelHeaderButtonRect(close_layout, 0) orelse return;
const toggle_rect = hit_test.panelHeaderButtonRect(close_layout, 1);
const refresh_rect = hit_test.panelHeaderButtonRect(close_layout, 2);
```

Use the left edge of `refresh_rect` to size the URL input:

```zig
const first_button_x = if (refresh_rect) |r| @round(@as(f32, @floatCast(r.left))) else @round(@as(f32, @floatCast(close.left)));
const input_w = @max(1.0, first_button_x - input_x - margin);
```

Render refresh when `refresh_rect` exists:

```zig
if (refresh_rect) |r| {
    const r_left = @round(@as(f32, @floatCast(r.left)));
    const refresh_hovered = blk: {
        const win = AppWindow.g_window orelse break :blk false;
        if (win.mouse_x < 0 or win.mouse_y < 0) break :blk false;
        break :blk hit_test.panelHeaderButton(close_layout, 2, @floatFromInt(win.mouse_x), @floatFromInt(win.mouse_y));
    };
    if (refresh_hovered) {
        ui_pipeline.fillQuadAlpha(r_left + 6, bar_y + @round((bar_h - 20) / 2), 20, 20, mixColor(bg, fg, 0.14), 0.95);
    }
    const glyph_color = if (refresh_hovered) fg else mixColor(bg, fg, 0.68);
    const cx = r_left + @as(f32, @floatCast(r.width)) / 2;
    const cy = bar_y + bar_h / 2;
    ui_pipeline.fillQuadAlpha(cx - 5, cy - 6, 8, 1.5, glyph_color, 0.9);
    ui_pipeline.fillQuadAlpha(cx + 3, cy - 6, 1.5, 6, glyph_color, 0.9);
    ui_pipeline.fillQuadAlpha(cx - 5, cy + 4.5, 8, 1.5, glyph_color, 0.9);
    ui_pipeline.fillQuadAlpha(cx - 6.5, cy - 1, 1.5, 6, glyph_color, 0.9);
}
```

Keep the existing close and toggle rendering, replacing `panelSecondButtonRect` calls with the `toggle_rect` value from index `1`.

- [ ] **Step 5: Run tests and verify GREEN**

Run: `zig build test --summary all`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/input.zig src/renderer/overlays.zig
git commit -m "feat(webview): add toolbar refresh button"
```

## Task 5: Runtime HTML Server Manager

**Files:**
- Create: `src/html_server.zig`
- Modify: `src/browser_panel.zig`
- Modify: `src/browser_panel_stub.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write compile and model-facing tests**

Create `src/html_server.zig` with API stubs and tests:

```zig
const std = @import("std");
const Surface = @import("Surface.zig");
const model = @import("html_server_model.zig");

pub const Error = std.mem.Allocator.Error || error{
    NotHtml,
    CwdUnavailable,
    ServerUnavailable,
    SpawnFailed,
    ServerNotReady,
    TunnelFailed,
    PathTooLong,
};

pub const OpenResult = union(enum) {
    url: []u8,
    err: Error,
};

pub fn deinit() void {}

pub fn openForSurface(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) OpenResult {
    _ = allocator;
    _ = surface;
    _ = path;
    return .{ .err = error.NotHtml };
}

pub fn commandForKindForTest(allocator: std.mem.Allocator, kind: model.ServerKind, port: u16) ![]u8 {
    _ = allocator;
    _ = kind;
    _ = port;
    return error.RedTestExpectedFailure;
}

test "html_server: public open API shape stays stable" {
    const info = @typeInfo(@TypeOf(openForSurface)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), info.params.len);
    try std.testing.expect(info.return_type.? == OpenResult);
}

test "html_server: non-html model check rejects markdown" {
    try std.testing.expect(!model.isHtmlPath("README.md"));
    try std.testing.expect(model.isHtmlPath("index.html"));
}

test "html_server: command builder emits python and node server commands" {
    const py3 = try commandForKindForTest(std.testing.allocator, .python3, 49152);
    defer std.testing.allocator.free(py3);
    try std.testing.expect(std.mem.indexOf(u8, py3, "python3 -m http.server 49152 --bind 127.0.0.1") != null);

    const py2 = try commandForKindForTest(std.testing.allocator, .python2, 49153);
    defer std.testing.allocator.free(py2);
    try std.testing.expect(std.mem.indexOf(u8, py2, "SimpleHTTPServer") != null);
    try std.testing.expect(std.mem.indexOf(u8, py2, "49153") != null);

    const node = try commandForKindForTest(std.testing.allocator, .node_inline, 49154);
    defer std.testing.allocator.free(node);
    try std.testing.expect(std.mem.indexOf(u8, node, "node -e") != null);
    try std.testing.expect(std.mem.indexOf(u8, node, "49154") != null);
}
```

Add to `src/test_main.zig`:

```zig
_ = @import("html_server.zig");
```

- [ ] **Step 2: Run tests and verify RED**

Run: `zig build test-full --summary all`

Expected: FAIL with `RedTestExpectedFailure` from `commandForKindForTest`. If `test-full` is unavailable, run `zig build test --summary all` and defer the runtime module compile to final verification.

- [ ] **Step 3: Implement server registry and local URL generation**

Replace the stub in `src/html_server.zig` with a runtime manager containing:

```zig
const ssh_tunnel = @import("ssh_tunnel.zig");
const preview_source = @import("input/preview_source.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_process = @import("platform/process.zig");
const platform_remote_file = @import("platform/remote_file.zig");

const MAX_SERVERS = 16;
const READY_TIMEOUT_MS = 8000;
const READY_POLL_NS = 50 * std.time.ns_per_ms;

const Server = struct {
    child: std.process.Child,
    port: u16,
    root_buf: [1024]u8 = undefined,
    root_len: usize = 0,
    ssh: bool = false,

    fn root(self: *const Server) []const u8 {
        return self.root_buf[0..self.root_len];
    }
};

threadlocal var g_servers: [MAX_SERVERS]?Server = [_]?Server{null} ** MAX_SERVERS;

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn dirname(path: []const u8) []const u8 {
    var end: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') end = i;
    }
    if (end == 0) return ".";
    return path[0..end];
}
```

Add process cleanup:

```zig
pub fn deinit() void {
    for (&g_servers) |*slot| stopServer(slot);
}

fn stopServer(slot: *?Server) void {
    if (slot.*) |*server| {
        _ = server.child.kill() catch {};
        _ = server.child.wait() catch {};
        slot.* = null;
    }
}
```

Add URL construction for local/WSL and SSH:

```zig
fn localUrlForPath(allocator: std.mem.Allocator, port: u16, path: []const u8) Error![]u8 {
    const name = basename(path);
    if (name.len == 0) return error.PathTooLong;
    return model.buildHttpUrl(allocator, "127.0.0.1", port, name) catch error.PathTooLong;
}
```

- [ ] **Step 4: Implement command builders and probes**

Add POSIX command probes for WSL and SSH in `src/html_server.zig`:

```zig
fn serverProbeScript() []const u8 {
    return "if command -v python3 >/dev/null 2>&1; then echo python3; exit 0; fi; " ++
        "if command -v python >/dev/null 2>&1; then python - <<'PY'\nimport sys\nprint('python3' if sys.version_info[0] >= 3 else 'python2')\nPY\nexit 0; fi; " ++
        "if command -v python2 >/dev/null 2>&1; then echo python2; exit 0; fi; " ++
        "if command -v node >/dev/null 2>&1; then echo node; exit 0; fi; " ++
        "if command -v npx >/dev/null 2>&1 && npx --no-install http-server --version >/dev/null 2>&1; then echo npx_http_server; exit 0; fi; " ++
        "echo none";
}

fn python2ServerCommand(port: u16) []const u8 {
    _ = port;
    return "python2 -c \"import SimpleHTTPServer,SocketServer; Handler=SimpleHTTPServer.SimpleHTTPRequestHandler; SocketServer.TCPServer.allow_reuse_address=True; httpd=SocketServer.TCPServer(('127.0.0.1', PORT), Handler); httpd.serve_forever()\"";
}
```

Use `std.fmt.allocPrint` when constructing the Python 2 command so `PORT` is replaced by the selected port. Implement `commandForKindForTest` by returning the full shell command string for the requested `ServerKind`; local/WSL/SSH launchers can split or wrap that command as needed.

For local Windows probing, do not use `command -v`. Try local candidates in model order by spawning each candidate for the selected port, waiting for `127.0.0.1:<port>` to become reachable, and killing the child when it exits before readiness. Include `python3`, `python`, `py -3`, `python2`, `node`, and `npx --no-install http-server` candidate argv shapes in the local launcher. For local POSIX probing, use `serverProbeScript()` through `sh -lc`.

Use Node's built-in modules for the no-download fallback:

```zig
const NODE_SERVER_SOURCE =
    "const http=require('http'),fs=require('fs'),path=require('path');" ++
    "const root=process.cwd();" ++
    "const types={'.html':'text/html; charset=utf-8','.htm':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'application/javascript; charset=utf-8','.mjs':'application/javascript; charset=utf-8','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.gif':'image/gif','.svg':'image/svg+xml'};" ++
    "http.createServer((req,res)=>{const u=new URL(req.url,'http://127.0.0.1');let p=path.normalize(path.join(root,decodeURIComponent(u.pathname)));if(!p.startsWith(root)){res.writeHead(403);res.end('forbidden');return;}fs.readFile(p,(e,d)=>{if(e){res.writeHead(404);res.end('not found');return;}res.writeHead(200,{'content-type':types[path.extname(p).toLowerCase()]||'application/octet-stream'});res.end(d);});}).listen(Number(process.argv[1]),'127.0.0.1');";
```

- [ ] **Step 5: Implement local, WSL, and SSH spawn paths**

Implement local spawn with `std.process.Child` using `.cwd = root` and candidate argv:

```zig
fn spawnLocal(allocator: std.mem.Allocator, root: []const u8, kind: model.ServerKind, port: u16) Error!std.process.Child {
    var argv_list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    switch (kind) {
        .python3 => try argv_list.appendSlice(allocator, &.{ "python3", "-m", "http.server", try std.fmt.allocPrint(allocator, "{d}", .{port}), "--bind", "127.0.0.1" }),
        .py_launcher_python3 => try argv_list.appendSlice(allocator, &.{ "py", "-3", "-m", "http.server", try std.fmt.allocPrint(allocator, "{d}", .{port}), "--bind", "127.0.0.1" }),
        .python3_via_python => try argv_list.appendSlice(allocator, &.{ "python", "-m", "http.server", try std.fmt.allocPrint(allocator, "{d}", .{port}), "--bind", "127.0.0.1" }),
        .python2 => try argv_list.appendSlice(allocator, &.{ "python2", "-c", try python2CommandAlloc(allocator, port) }),
        .python2_via_python => try argv_list.appendSlice(allocator, &.{ "python", "-c", try python2CommandAlloc(allocator, port) }),
        .node_inline => try argv_list.appendSlice(allocator, &.{ "node", "-e", NODE_SERVER_SOURCE, try std.fmt.allocPrint(allocator, "{d}", .{port}) }),
        .npx_http_server => try argv_list.appendSlice(allocator, &.{ "npx", "--no-install", "http-server", ".", "-a", "127.0.0.1", "-p", try std.fmt.allocPrint(allocator, "{d}", .{port}) }),
    }
    var child = std.process.Child.init(argv_list.items, allocator);
    child.cwd = root;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.create_no_window = true;
    child.spawn() catch return error.SpawnFailed;
    return child;
}
```

Implement WSL spawn by running `cd <root> && exec <server command>` through `platform_pty_command.wslExecArgv`.

Implement SSH spawn by building an SSH command using the same option set as `ssh_tunnel.spawnSshTunnel`, appending the selected server command after changing to the quoted root:

```sh
cd '<root>' && exec <selected-server-command>
```

Use `platform_remote_file.shellQuote` for remote root quoting. Keep SSH stderr inherited so OpenSSH failures remain visible.

- [ ] **Step 6: Implement openForSurface**

Implement:

```zig
pub fn openForSurface(allocator: std.mem.Allocator, surface: *Surface, path: []const u8) OpenResult {
    if (!model.isHtmlPath(path)) return .{ .err = error.NotHtml };
    const resolved = preview_source.resolveTerminalPreviewPath(allocator, surface, path) catch |err| {
        return .{ .err = if (err == error.CwdUnavailable) error.CwdUnavailable else error.PathTooLong };
    };
    defer allocator.free(resolved);

    const root = dirname(resolved);
    const port = ensureServerForSurface(allocator, surface, root) catch |err| return .{ .err = err };
    var url = localUrlForPath(allocator, port, resolved) catch |err| return .{ .err = err };

    if (surface.launch_kind == .ssh) {
        const tunneled = ssh_tunnel.externalUrlForSurface(allocator, url, surface) orelse {
            allocator.free(url);
            return .{ .err = error.TunnelFailed };
        };
        allocator.free(url);
        url = tunneled;
    }

    return .{ .url = url };
}
```

Ensure `ensureServerForSurface` reuses an existing live server with the same launch kind, SSH identity, and root directory, and verifies reachability before returning.

- [ ] **Step 7: Wire cleanup into browser panel**

In `src/browser_panel.zig` and `src/browser_panel_stub.zig`, import `html_server` and call `html_server.deinit()` inside `deinit()`.

- [ ] **Step 8: Run tests**

Run: `zig build test-full --summary all`

Expected: PASS or platform-specific skip where appropriate. If this fails because `test-full` is not runnable on the current host, record the failure and run `zig build test --summary all`.

- [ ] **Step 9: Commit**

```bash
git add src/html_server.zig src/browser_panel.zig src/browser_panel_stub.zig src/test_main.zig
git commit -m "feat(html): add environment http server manager"
```

## Task 6: Ctrl-click HTML Path Integration

**Files:**
- Modify: `src/input/terminal_link_action.zig`
- Modify: `src/input.zig`

- [ ] **Step 1: Write failing action precedence tests**

In `src/input/terminal_link_action.zig`, extend `InteractiveUnderlineTokenKind`:

```zig
pub const InteractiveUnderlineTokenKind = enum { none, url, html_path, preview_path };
```

Add tests:

```zig
test "interactive underline classifies html before generic preview" {
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.html_path,
        interactiveUnderlineTokenKind(.open_url_or_preview, "index.html"),
    );
    try std.testing.expectEqual(
        InteractiveUnderlineTokenKind.html_path,
        interactiveUnderlineTokenKind(.open_url_or_preview, "dist/report.htm"),
    );
}
```

- [ ] **Step 2: Run tests and verify RED**

Run: `zig test src/input/terminal_link_action.zig`

Expected: FAIL because `html_path` is not returned.

- [ ] **Step 3: Implement HTML classification**

Import the model and update classification:

```zig
const html_server_model = @import("../html_server_model.zig");
```

Update `interactiveUnderlineTokenKind`:

```zig
.open_url_or_preview => if (looksLikeUrl(text))
    .url
else if (html_server_model.isHtmlPath(text))
    .html_path
else if (looksLikePreviewPath(text))
    .preview_path
else
    .none,
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `zig test src/input/terminal_link_action.zig`

Expected: PASS.

- [ ] **Step 5: Route Ctrl-click HTML before preview**

In `src/input.zig`, import the runtime manager:

```zig
const html_server = @import("html_server.zig");
const html_server_model = @import("html_server_model.zig");
```

Add:

```zig
fn openHtmlPanelForCell(surface: *Surface, cell_pos: CellPos) bool {
    const allocator = AppWindow.g_allocator orelse return false;
    const path = extractPreviewPathAtCell(allocator, surface, cell_pos) orelse return false;
    defer allocator.free(path);
    if (!html_server_model.isHtmlPath(path)) return false;

    switch (html_server.openForSurface(allocator, surface, path)) {
        .url => |url| {
            defer allocator.free(url);
            const parent = AppWindow.currentNativeHandle();
            browser_panel.open(parent, url);
            if (AppWindow.g_window) |win| syncPanelGridFromWindow(win);
            AppWindow.g_force_rebuild = true;
            AppWindow.g_cells_valid = false;
            return true;
        },
        .err => |err| {
            file_explorer.setTransferStatus(.failed, switch (err) {
                error.CwdUnavailable => "HTML cwd unknown",
                error.ServerUnavailable => "Install Python 3 in this environment",
                error.ServerNotReady => "HTML server not reachable",
                error.TunnelFailed => "HTML SSH tunnel failed",
                else => "HTML preview failed",
            });
            return true;
        },
    }
}
```

In the `.open_url_or_preview` branch in `handleMouseButton`, insert before preview:

```zig
if (openHtmlPanelForCell(clicked_surface, cell_pos)) return;
```

- [ ] **Step 6: Run tests**

Run: `zig build test --summary all`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/input.zig src/input/terminal_link_action.zig
git commit -m "feat(input): open html paths in webview"
```

## Task 7: Final Verification

**Files:**
- Verify: full repository

- [ ] **Step 1: Run fast tests**

Run: `zig build test --summary all`

Expected: PASS.

- [ ] **Step 2: Run full tests**

Run: `zig build test-full --summary all`

Expected: PASS. If the current host cannot run the Windows-target full build, capture the exact error and run `zig build test --summary all` as the completed local gate.

- [ ] **Step 3: Windows checkout safety if files were added**

Run the Windows checkout safety checks documented in `docs/development.md#windows-checkout-safety`.

Expected: no reserved names, illegal characters, case-fold collisions, symlinks, or path-length violations.

- [ ] **Step 4: Manual Windows smoke path**

On Windows with WebView2 available:

```powershell
zig build
zig-out\bin\wispterm.exe
```

Expected:

- Refresh button reloads the current WebView page.
- Ctrl-clicking local `index.html` opens through a local HTTP URL.
- Ctrl-clicking WSL `index.html` starts a WSL server and keeps relative CSS working.
- Ctrl-clicking SSH `index.html` starts a remote loopback server, tunnels it locally, and keeps relative CSS working.
- Missing server tools show an install prompt instead of copying remote files locally.

- [ ] **Step 5: Commit verification notes if code changed after earlier commits**

```bash
git status --short
```

Expected: clean except unrelated pre-existing files such as `.claude/`.

## Self-Review

- Spec coverage: WebView refresh is covered by Tasks 3 and 4. Ctrl-click HTML precedence is covered by Task 6. Local/WSL/SSH HTTP serving and no-download npm fallback are covered by Tasks 1 and 5. Error handling and testing are covered by Tasks 5, 6, and 7.
- Placeholder scan: no placeholder markers are used.
- Type consistency: `html_server_model.ServerKind`, `html_server.OpenResult`, `browser_panel.refresh`, and `platform_webview.reload` are introduced before use by later tasks.
