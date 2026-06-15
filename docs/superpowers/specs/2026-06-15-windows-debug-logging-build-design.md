# Windows debug/diagnostic build + field-bug fixes

Date: 2026-06-15
Status: Implemented (pending Windows GUI sign-off / merge) — all phases landed and reviewed; cumulative `zig build test` + `test-full` green. Remaining gate: Windows GUI verification (console window, `%APPDATA%\wispterm\` log + crash file, ctrl+click/WeChat repro), which can't run on Linux.
Branch: `feat/windows-debug-logging-build`

## Problem

The user base is growing and field reports are arriving that are hard to
reproduce or root-cause from a normal release:

1. "Everything was fine, then the app **crashes when opening the WeChat
   connection**."
2. "On my machine, **Ctrl+click on a remote file freezes** the whole app."

A normal Windows release is built as a **GUI-subsystem** app — it has no
console, so `std.log` / `std.debug.print` (which go to stderr) are invisible,
and there is **no panic/crash handler and no general on-disk log** anywhere in
the codebase. The only on-disk diagnostic today is `render-diagnostic.log`,
which is render-specific and opt-in. There is therefore no way for a user to
produce a log we can read.

We need a Windows build a user can download and run to **generate logs and
crash reports**, plus fixes for the two confirmed root causes.

## Goals

- A **separate Windows debug artifact** that, when run, writes an on-disk debug
  log and a crash report on failure — without changing the normal release.
- It is **reachable**: auto-attached to every GitHub Release *and* buildable
  on-demand for any branch/SHA.
- **Fix both confirmed root causes** found during the audit, not just observe
  them.

## Non-goals (YAGNI)

- On-disk logging / crash handler compiled into the **normal release** build.
  (The crash handler is near-zero cost and could later be added to release —
  noted as a one-line future option, not built here.)
- A fully-async Ctrl+click probe, or a generic "UI handler took >100 ms"
  watchdog.
- Any log upload / telemetry. Logs stay local; the user sends the file.

## Decisions (locked with the user)

1. **Delivery**: a separate CI debug artifact (ReleaseSafe + console + file
   log), *not* logging baked into the normal release.
2. **Scope**: diagnostics infra **and** fix both root causes in the same body
   of work.
3. **Distribution**: auto-attach the debug zip to every release **and** a manual
   `workflow_dispatch` for any branch/SHA.
4. **Freeze fix depth**: bounded timeout + kill (surgical) — turn a permanent
   hang into a bounded delay + logged error. Full async offload is a follow-up.

## Audit findings this design relies on

- CI: `windows-release.yml` builds `ReleaseFast`, GUI subsystem, on tag push;
  `packaging/windows/package.ps1` is parameterized and produces 3 portable zips.
  `macos-debug.yml` is an existing `workflow_dispatch` debug-build precedent.
- `build.zig:578-582` sets `exe.subsystem = if (optimize == .Debug) .Console
  else .Windows`. Build options are embedded in `createAppModuleWithRoot`
  (`build.zig:945-949`).
- `src/main.zig` is the app root module and declares **no** `std_options` and
  **no** `panic`. It already imports `builtin` and `render_diagnostics`.
- `src/scp.zig`: `appendSshOptions` **already** sets `ConnectTimeout=8` and
  `BatchMode=yes` (lines 835/849). So an *unreachable* host already fails fast.
  `sshExecCapped` (line 352) reads stdout via `drainCapped` and then
  `child.wait()` (line 448) — **neither is bounded by a wall-clock timeout**, so
  a *post-connect* hang (remote command stalls / stdout never EOFs) blocks
  forever. This call runs **on the UI thread** for the Ctrl+click probe.
- `src/input.zig`: Ctrl+click → `downloadTerminalFileAtCell` →
  `remotePathIsDirectoryForDownload` → `scp.sshExecCapped` (synchronous, UI
  thread). This dispatch runs *before* the existing async preview path.
- WeChat: login runs on a thread (`weixin/controller.zig`), polling on another
  (`weixin/poller.zig threadMain`). HTTP/JSON/AES paths in `ilink_client.zig` /
  `weixin/media.zig` have unguarded spots; a worker-thread failure currently
  dies silently (caught-and-ignored errors) or — for a real panic — aborts with
  nothing captured.

## Architecture

Five units, each independently understandable and (where logic exists) testable.

### A. Build option & subsystem — `build.zig`

- New option **`-Ddebug-console`** (bool, default `false`), capability-generic
  so it passes `build_guards.zig`:
  ```
  const debug_console = b.option(bool, "debug-console",
      "Force a console subsystem and enable on-disk debug logging + crash capture") orelse false;
  ```
- Thread it into the subsystem decision (build.zig:581):
  ```
  exe.subsystem = if (optimize == .Debug or debug_console) .Console else .Windows;
  ```
- Thread it into `createAppModule` / `createAppModuleWithRoot` and embed it so
  app code can gate at comptime (alongside `webview` at build.zig:946):
  ```
  app_options.addOption(bool, "debug_console", debug_console);
  ```
- The debug artifact is built with `-Doptimize=ReleaseSafe -Ddebug-console`.
  ReleaseSafe keeps safety checks (UB/overflow/OOB trap with a message) and is
  timing-faithful to the real release, so the freeze and crash still reproduce.

### B. Diagnostics module — `src/diag_log.zig` (new) + `src/main.zig` wiring

`diag_log.zig` responsibilities (one clear purpose: capture diagnostics to
disk):

- **On-disk log**: thread-safe (`std.Thread.Mutex`) append logger writing to
  `<config-dir>/wispterm-debug.log` using the existing per-OS resolution in
  `src/platform/dirs.zig` (`%APPDATA%\wispterm\` on Windows). Timestamped lines.
  **Size-capped with a single rollover** (`wispterm-debug.log` →
  `wispterm-debug.log.1`) so a long repro is not lost (unlike
  `render-diagnostic.log`, which truncates per session). Distinct file from
  `render-diagnostic.log`.
- **`logFn`**: matches `std.Options.logFn`; formats `level/scope/message` and
  writes to the file (and to stderr, which the console subsystem makes visible).
- **`panicFn`**: matches the `std.debug.FullPanic` function signature
  (`fn (msg: []const u8, first_trace_addr: ?usize) noreturn`); writes a crash
  report (panic message + best-effort stack trace — captured addresses,
  symbolicated when debug info is present) to `<config-dir>/crash-<ts>.txt`,
  then chains to `std.debug.defaultPanic`. Because a Zig panic aborts the whole
  process, this fires for **worker-thread panics too** (poller/login).
- **Windows native-crash capture** (gated `builtin.os.tag == .windows`):
  install a `SetUnhandledExceptionFilter` handler to catch access violations in
  native code (win32 / D3D / WebView2) that never reach Zig's panic —
  best-effort crash file, then return `EXCEPTION_CONTINUE_SEARCH` so the process
  still crashes normally.

`src/main.zig` (root module), all gated on `build_options.debug_console` so the
normal release is unchanged and zero-cost:
```
const build_options = @import("build_options");
pub const std_options: std.Options = if (build_options.debug_console)
    .{ .logFn = diag_log.logFn, .log_level = .debug }
else
    .{};
pub const panic = if (build_options.debug_console)
    std.debug.FullPanic(diag_log.panicFn)
else
    std.debug.FullPanic(std.debug.defaultPanic);
```
Init (open log file, install Windows exception filter) happens early in
`main()`, also gated. `std.debug.print` (308 sites) is left as-is; the console
subsystem makes it visible in the debug build and important diagnostics flow
through `std.log` → file.

### C. Fix #1 — Ctrl+click freeze — `src/scp.zig` (+ `src/input.zig`)

- Add a **wall-clock watchdog** to `sshExecCapped`: a new `timeout_ms`
  parameter; a watchdog thread kills the child process if it outlives the cap,
  so `drainCapped` / `child.wait()` (scp.zig:448) cannot block forever. The
  kill→EOF→`wait` returns path unblocks the caller.
- Extract the timeout/kill decision into a **pure helper** (e.g. given
  start-time, now, cap → "kill") so it is unit-testable without a live SSH.
- Add `ServerAliveInterval` / `ServerAliveCountMax` to `appendSshOptions` so a
  dead *post-connect* session is detected (ConnectTimeout already covers
  pre-connect). Extend the existing arg-assertion tests (scp.zig:1007+).
- The UI-thread probe (`remotePathIsDirectoryForDownload`) passes a short cap
  (~5 s). Existing `sshExecCapped` callers keep current behavior via a default
  cap (or a thin wrapper) — enumerate and update all callers.
- Log `ssh exec start cmd=…` / `drained N bytes in Δms exit=…` / `killed after
  timeout` so the log pinpoints the stall.
- Net: permanent freeze → bounded (≤5 s) delay + logged error.

### D. Fix #2 — WeChat connect crash — `weixin/controller.zig`, `weixin/poller.zig`, `ilink_client.zig`, `weixin/media.zig`

The exact cause is unknown until a captured log/crash lands, so this is
**defensive hardening + instrumentation**; the ReleaseSafe crash handler (B)
captures the precise stack if it still dies.

- Wrap the top of the login thread (`controller.zig`) and the `poller.threadMain`
  loop body in a `catch |e|` that **logs with context and degrades**
  (disconnect / surface an error to the user) instead of crashing or dying
  silently.
- Add `std.log` at the audit-flagged unguarded spots: `httpFetch` (method / url /
  status), JSON parse (`parseFromSliceLeaky` → on error log a response snippet
  rather than unwrapping), AES decrypt (length / padding result), thread-spawn
  success/failure.
- Validate expected JSON fields before dereferencing.

### E. CI & packaging — `.github/workflows/*` + `packaging/windows/package.ps1`

- **`windows-release.yml`** (on tag): after the existing 3 release zips, build +
  attach **`wispterm-windows-debug-<tag>.zip`** to the GitHub Release. The debug
  zip uses the **compat bundle** (bundles WebView2 / ConPTY DLLs so it runs on
  older Win10, since affected users may be on old machines) + console + file log.
- **`windows-debug.yml`** (new, `workflow_dispatch`): inputs = ref/branch +
  optimize choice (default ReleaseSafe / Debug); builds the debug zip for any
  SHA and uploads it as a downloadable Actions artifact. Mirrors
  `macos-debug.yml`.
- **`package.ps1`**: parameterize the zig optimize mode + a `-DebugConsole`
  switch (adds `-Doptimize=… -Ddebug-console`) and a name suffix; reuse the
  existing packaging path rather than duplicating it.

## Data flow

- **Diagnostics**: `std.log` call → (debug build) `diag_log.logFn` → mutex →
  append to `wispterm-debug.log` (+ stderr). Panic → `diag_log.panicFn` →
  `crash-<ts>.txt` → `defaultPanic`. Native exception (Windows) → SEH filter →
  `crash-<ts>.txt` → continue search → crash.
- **Freeze fix**: Ctrl+click → `downloadTerminalFileAtCell` →
  `remotePathIsDirectoryForDownload` → `sshExecCapped(…, timeout_ms=~5000)`;
  watchdog thread arms; on stall it kills the child → drain EOF → `wait`
  returns → caller gets a bounded result + the stall is logged.

## Error handling

- All new logging is **best-effort**: a failure to open/write the log or crash
  file never changes app behavior (mirrors `render_diagnostics`).
- The crash handler always chains to `defaultPanic` / continues the exception
  search — it never swallows a crash, only records it first.
- The SSH watchdog only ever *kills a hung child*; on the normal (fast) path it
  is a no-op.

## Testing

- Unit/pure (`zig build test`, fast suite):
  - `diag_log` line formatting and size-rollover boundary.
  - The pure SSH timeout/kill decision helper.
  - `appendSshOptions` arg assertions extended for the new ServerAlive options.
- `zig build test-full` (windows-gnu cross-compile) stays green; the
  Windows-only SEH path compiles behind the `builtin.os.tag == .windows` gate.
- Manual GUI verification on Windows is the final step: run the debug artifact,
  confirm `wispterm-debug.log` is written, exercise Ctrl+click on an
  unreachable remote (expect bounded delay + log line, not a freeze), and force
  a crash to confirm `crash-<ts>.txt` is produced.

## Open future options (not in scope)

- Compile the crash handler into the normal release too (near-zero cost; would
  capture field crashes without users grabbing the debug build).
- Move the Ctrl+click remote probe fully off the UI thread (async), eliminating
  even the bounded delay.
