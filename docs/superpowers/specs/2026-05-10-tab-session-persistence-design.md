# Tab Session Persistence Design

## Context

Phantty currently opens a single default shell tab on launch and discards all tab/split state when the window closes. Users running multi-tab, multi-split workflows (especially across SSH hosts) must rebuild the layout from scratch every session.

The desired behavior is opt-in restoration of the previous tab arrangement on the next launch: tab order, split layout (orientation + ratios + focus), the active tab, and the connection target plus working directory of every surface inside each tab. Terminal scrollback content and any running processes are explicitly out of scope — restoration recreates the *workspace shape*, not in-flight state.

The existing `src/apprt/window_state.zig` already persists window x/y to `%APPDATA%\phantty\state` as flat key=value at shutdown. That precedent informs file location and shutdown-write timing, but the tab session uses a separate file with a richer format because the split tree is recursive.

## Goals

- Restore tab order, per-tab split tree (orientation + ratio + focused leaf), and active tab on next launch.
- Restore each surface's reconnection target: local shell with cwd, or SSH host/user/port with cwd hint.
- Be opt-in: nothing changes for users who do not enable the feature.
- Never persist secrets (SSH passwords or any auth material).
- Fail open: any error in dump or restore must fall back to the current default-launch behavior, never block the user.

## Non-Goals

- Restoring PTY scrollback contents or any in-flight subprocess state.
- Restoring browser-panel or markdown-preview tabs (deferred).
- Multi-window per-window state (Phantty's tab/window model is being migrated to a per-window struct in a separate workstream; the file format is forward-compatible but only the current window is persisted in v1).
- Caching SSH credentials. Reconnects re-prompt for password / key, identical to today.
- Crash-resilient incremental writes. v1 writes only at clean shutdown.

## Confirmed Scope

- **Layout fidelity:** full split tree (orientation, ratio, focused leaf, active tab, zoom state).
- **Opt-in mechanism:** new config key `restore-tabs-on-startup`, default `false`. When `false`, the file is neither written nor read.
- **Surface kinds covered:** `local_shell` (with cwd) and `ssh` (with user/host/port/cwd). Browser panels and markdown previews are excluded from v1.
- **CLI interaction:** any command-line override (`--command`, `--cwd`, positional args) wins. The session file is preserved untouched and used the next time Phantty launches without overrides.

## Architecture

A new module owns serialization end-to-end. Existing tab/surface code gains thin snapshot/rebuild helpers that the new module calls. No PTY or SSH plumbing is duplicated.

| Module | Status | Responsibility |
|---|---|---|
| `src/session_persist.zig` | new | Define `Session`, `TabSnap`, `NodeSnap`, `SurfaceSnap` POD structs. Provide `dumpSession(allocator, session: Session)` and `loadSession(allocator) ?Session`. Pure I/O + serialization: JSON via `std.json`, atomic file write, `.bak` rename on parse failure. Imports only `std`. |
| `src/config.zig` | modified | Add `@"restore-tabs-on-startup": bool = false`. Add `sessionFilePath(allocator) ![]const u8` returning `<config-dir>/session.json`. |
| `src/AppWindow.zig` | modified | Orchestration only. On startup, after config load and before `openDefaultTab`, call `tab.restoreSessionFromFile()` if `cfg.restore_tabs_on_startup && !cli_has_session_overrides()`. On `deinit`, before tearing down tabs, call `tab.dumpSessionToFile()` if the flag is on. Detect CLI session overrides via existing arg parser. |
| `src/appwindow/tab.zig` | modified | Owns the bridge between live tab state and POD snapshots. Exposes `collectSessionSnapshot(allocator) Session` (walks `g_tabs[0..g_tab_count]`, calls `snapshotTab` per tab), `snapshotTab(tab) TabSnap` (walks one SplitTree), `dumpSessionToFile(allocator)` (one-line: collect + `session_persist.dumpSession`), `restoreSessionFromFile(allocator) bool` (calls `session_persist.loadSession`, then `restoreTab` per snapshot), and `restoreTab(snap) bool` (uses existing `spawnTabWithCommandAndCwd` / `setSshConnection` and `SplitTree.fromSnapshot` to materialize one tab). |
| `src/Surface.zig` | modified | Add `surfaceKind() enum { local_shell, ssh }` helper (tiny — checks `ssh_connection != null`). All other needed accessors (`getCwd`, `getInitialCwd`, `ssh_connection`) already exist. |
| `src/split_tree.zig` | modified | Add `fromSnapshot(gpa, snap, factory) !SplitTree` that builds the `nodes` array directly via pre-order traversal, given a callback that creates a `*Surface` from a `SurfaceSnap`. Avoids relying on user-action split paths to rebuild nested trees. |
| `src/test_main.zig` | modified | Register `_ = @import("session_persist.zig")` so unit tests run under `zig build test`. |

Boundaries:

- `session_persist.zig` knows only `std.json` and POD structs; it does not import `Surface` or `AppWindow`.
- The factory pattern in `SplitTree.fromSnapshot` keeps `split_tree.zig` agnostic to PTY / SSH startup logic. The factory closure is supplied by `tab.zig` and wraps `Surface.init` + `setSshConnection`.
- All I/O lives in `session_persist.zig`. `AppWindow` only orchestrates "when".

## Data Shape

### JSON Schema

```jsonc
{
  "version": 1,
  "active_tab": 1,                  // index into tabs[]; clamped on load
  "tabs": [
    {
      "title_override": null,       // string | null; null means "use surface live title"
      "focused_leaf": 0,            // pre-order leaf index of focused surface; clamped
      "zoomed_leaf": null,          // int | null; non-null = leaf is in zoom-fullscreen state
      "tree": <Node>
    }
  ]
}
```

`<Node>` is a tagged recursive union (`std.json` parses tag field `kind`):

```jsonc
// leaf
{
  "kind": "leaf",
  "surface": {
    "kind": "local_shell" | "ssh",
    "cwd": "/home/user/project" | null,    // OSC 7 (getCwd) preferred, getInitialCwd fallback
    // local_shell only:
    "command": null,                        // null = use config default shell at restore time
    // ssh only:
    "user": "root",
    "host": "srvA.example.com",
    "port": 22
  }
}

// split
{
  "kind": "split",
  "layout": "horizontal" | "vertical",
  "ratio": 0.6,                             // f16 in memory; JSON number; clamped to [0.05, 0.95]
  "left":  <Node>,
  "right": <Node>
}
```

Field rationale:

- `version: 1` — single integer; future migrations branch on it. Unknown future fields are ignored by `std.json` (forward-compat).
- `password` is **deliberately absent** from `ssh` surface schema. Type-level guarantee that no code path can serialize it.
- `cwd: null` distinguishes "unknown" from "empty"; restore treats null as "no auto-cd, use shell defaults".
- `command: null` for `local_shell` means "re-launch with whatever the current config calls the default shell" — preserves user intent if they changed the config since the snapshot was taken.
- `focused_leaf` / `zoomed_leaf` are **pre-order leaf indices**, not `SplitTree.Node.Handle` values. Handles are memory offsets that change across rebuilds; pre-order index is topology-stable.
- `ratio` is clamped to `[0.05, 0.95]` both on JSON load and on tree rebuild — defense in depth against corrupted files producing invisible splits.

### Zig POD Structs

```zig
pub const Session = struct {
    version: u32 = 1,
    active_tab: u32 = 0,
    tabs: []TabSnap,
};
pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
};
pub const NodeSnap = union(enum) {  // std.json uses "kind" as tag
    leaf: LeafSnap,
    split: SplitSnap,
};
pub const LeafSnap = struct { surface: SurfaceSnap };
pub const SplitSnap = struct {
    layout: enum { horizontal, vertical },
    ratio: f64,                        // cast back to f16 at rebuild
    left:  *NodeSnap,
    right: *NodeSnap,
};
pub const SurfaceSnap = union(enum) {
    local_shell: struct {
        cwd: ?[]const u8 = null,
        command: ?[]const []const u8 = null,
    },
    ssh: struct {
        cwd: ?[]const u8 = null,
        user: []const u8,
        host: []const u8,
        port: u16 = 22,
    },
};
```

## Data Flow

### Dump path (close)

Triggered from `AppWindow.deinit()`, before any `tab.deinit()` calls.

```
on close (in AppWindow.deinit, before per-tab deinit):
  if !cfg.restore_tabs_on_startup: return         // file untouched if feature off
  tab.dumpSessionToFile(allocator)                // see tab.zig responsibilities

// inside tab.dumpSessionToFile:
  session = tab.collectSessionSnapshot(allocator) // walks g_tabs + g_active_tab
  session_persist.dumpSession(allocator, session) // pure JSON I/O

// inside session_persist.dumpSession:
  json = std.json.stringifyAlloc(allocator, session)
  tmp  = sessionFilePath() ++ ".tmp"
  write(tmp, json)
  os.rename(tmp, sessionFilePath())               // atomic replace
  // any I/O failure: log.warn, do not block close
```

`collectSnapshot` walks each tab's `SplitTree.nodes` in pre-order. For each leaf:

- `kind` = `ssh` if `surface.ssh_connection != null`, else `local_shell`.
- `cwd` = `surface.getCwd() ?? surface.getInitialCwd()`.
- For SSH: read `surface.ssh_connection.{user, host, port}`. **Never** touch `password`.
- The pre-order leaf counter records `focused_leaf` and `zoomed_leaf` for the current tab.

### Restore path (startup)

Triggered from `AppWindow.runMainLoop()`, after config load, before `openDefaultTab`.

```
on startup (in AppWindow.runMainLoop, after config load):
  if !cfg.restore_tabs_on_startup:        goto default
  if cli_has_session_overrides():         goto default   // CLI wins; file kept
  if tab.restoreSessionFromFile(allocator): return       // success, skip default
  goto default

default:
  openDefaultTab()                        // unchanged behavior

// inside tab.restoreSessionFromFile (returns true iff at least one tab restored):
  session = session_persist.loadSession(allocator) orelse return false

  rebuilt = 0
  for snap in session.tabs:
    if restoreTab(snap): rebuilt += 1
    else: log.warn("tab restore failed, skipping")

  if rebuilt == 0: return false
  switchTab(min(session.active_tab, rebuilt - 1))
  return true

// inside session_persist.loadSession (returns null on any failure):
  bytes = read(sessionFilePath()) catch return null      // missing file = silent
  session = std.json.parseFromSlice(bytes) catch:
    rename(sessionFilePath(), sessionFilePath() ++ ".bak")
    log.warn("corrupted session.json, backed up to .bak")
    return null
  if session.tabs.len == 0: return null
  return session
```

### Tree rebuild

`SplitTree.fromSnapshot` constructs the `nodes` array directly via pre-order traversal:

```
fn SplitTree.fromSnapshot(gpa, snap, factory) !SplitTree:
  total = countNodes(snap.tree)
  nodes = arena.alloc(Node, total)
  var idx: usize = 0

  fn writeNode(snap_node) Node.Handle:
    my_handle = idx; idx += 1
    switch snap_node:
      .leaf  => nodes[my_handle] = .{ .leaf = factory(snap_node.surface) }
      .split => |sp|
        left  = writeNode(sp.left)        // pre-order: left subtree gets next handle
        right = writeNode(sp.right)
        nodes[my_handle] = .{ .split = .{
          .layout = sp.layout,
          .ratio  = clamp(sp.ratio, 0.05, 0.95),
          .left = left, .right = right,
        }}
    return my_handle

  _ = writeNode(snap.tree)
  return SplitTree{ ..., .zoomed = resolveLeafByIndex(nodes, snap.zoomed_leaf) }
```

The user-facing "split focused leaf" action path is **not** reused for rebuilding — it requires sequential focus jumps for nested trees and is harder to reason about than direct construction.

### CWD restoration

| Surface kind | Restore mechanism |
|---|---|
| `local_shell` | Pass `cwd` string as `lpCurrentDirectory` to existing `spawnTabWithCommandAndCwd`. If the path no longer exists, the OS returns an error; spawn falls back to launching from `%USERPROFILE%`. |
| `ssh` | Append `-t "cd '<escaped-cwd>' 2>/dev/null; exec $SHELL -l"` to the SSH login command. Single-quote the path with `'\''` escape. `2>/dev/null` swallows missing-directory errors so the shell still starts in `$HOME`. If `cwd` is null, omit the `-t` clause entirely. |

`escapeShellSingleQuoted(path)` replaces every `'` with `'\''` and wraps the whole result in single quotes at the call site. Inside single quotes, `$`, `\`, `"`, and other shell metacharacters are literal — only the closing single quote needs special handling.

## Invariants

| # | Invariant | Enforcement |
|---|---|---|
| I1 | SSH password never reaches disk | `SurfaceSnap.ssh` has no `password` field. Test asserts `password` substring is absent from any serialized output. |
| I2 | `session.json` is always either the previous valid version or the new valid version, never partial | `write tmp + rename` pattern. |
| I3 | Parse failure never panics | Top-level `catch` in `loadSession` plus fuzz test against random bytes. |
| I4 | A failed leaf, tab, or whole-session restore always falls back to a working state | Leaf failure → default shell in that slot; tab failure → skip that tab; total failure → `openDefaultTab`. Each level has a dedicated test. |
| I5 | When `restore-tabs-on-startup` is `false`, the file is neither read nor written | Test: enable, write, disable, close again — file mtime unchanged. |

## Test Strategy

### Unit tests (`zig build test`)

In-file `test "..." {}` blocks in `session_persist.zig`, registered via `test_main.zig`.

**Pure data layer** (no `Surface` / `SplitTree`):

1. Round-trip a hand-built `Session` (nested split, mixed surface kinds) through stringify → parseFromSlice; assert struct equality.
2. Forward-compat: parse JSON containing an unknown future field; known fields decode correctly.
3. Garbage input: `"{ broken"`, half-truncated bytes, empty string, random bytes — all return Zig error, never panic.
4. Ratio clamp on load: JSON values `-0.5`, `1.5`, `NaN` → in-memory ratio in `[0.05, 0.95]`.
5. `focused_leaf` / `zoomed_leaf` / `active_tab` out of range → resolve to safe defaults (0 or null).
6. Empty `tabs` array → `loadSession` returns null; caller treats as "no session".
7. **I1 verification**: stringify a `Session` containing an `ssh` leaf; assert `std.mem.indexOf(output, "password") == null`.

**SSH path quoting** (`escapeShellSingleQuoted`):

8. Table-driven cases: `/var/log`, `/home/x'z`, `/tmp/with space`, `/path/with"$\backslash`, empty string. Assert resulting wrapped command is a single shell argument.

**Tree topology** (uses minimal mock `Surface` stub):

9. `countLeavesPreOrder` on single leaf, two-leaf split, three-level nesting.
10. `splitTreeFromSnapshot` round-trip: snapshot → JSON → parse → rebuild → walk; assert layout, ratio, left/right relationships preserved.
11. Defensive ratio clamp at rebuild stage (in addition to load).

### Integration test (`debug\test-session-restore.ps1`)

Single PowerShell script in the style of `debug\test-file-explorer-ui.ps1`:

1. `zig build` debug.
2. Isolate `%APPDATA%\phantty` via env var.
3. Write minimal config with `restore-tabs-on-startup = true`.
4. Launch phantty, open a second tab (`Ctrl+Shift+T`), split the first tab horizontally (`Ctrl+Shift+O`), `cd` somewhere with a known prompt that emits OSC 7.
5. Close the window via `CloseMainWindow`.
6. Read `session.json`, assert structure: 2 tabs, tab 1 root is `split-h`, both leaves have correct `kind`.
7. Relaunch phantty without args.
8. Verify via Win32 enumeration / screenshot: 2 tabs visible, tab 1 is split.
9. Cleanup.

### Deliberately not tested

- Real SSH reconnection (depends on external server / sshpass; flaky in CI).
- Whether OSC 7 is captured correctly (already covered by existing OSC parser tests).
- `lpCurrentDirectory` actually changing the spawned process's cwd (OS responsibility).
- `std.json` correctness for numeric edge cases or unicode escapes (stdlib's domain).

## Open Questions / Future Work

- **Multi-window:** when the in-progress per-window struct migration lands, `Session` becomes `Session.windows[]`. The `version` field bumps to `2`; old `version: 1` files are read as a single-window session and re-dumped as v2 on next close.
- **Browser / markdown tabs:** add `SurfaceSnap` variants `browser { url }` and `markdown { path }` once their reload semantics are settled.
- **Crash resilience:** if users start losing sessions to crashes, escalate to incremental writes on tab open/close events. Out of scope for v1.
- **SSH cwd auto-cd off-switch:** if some users find `-t "cd ... && exec $SHELL"` interferes with their server-side shell config (e.g., custom motd, tmux auto-attach), add a per-host opt-out. Not needed for v1.
