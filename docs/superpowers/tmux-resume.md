# tmux Control Mode — Resume Guide (for a GUI host)

Snapshot: **2026-06-03**. Branch: `worktree-feat-remote-perssitance` (pushed to `origin` = `github.com:xuzhougeng/wispterm`). This file is the portable record so work can resume on a macOS/Windows machine where the GUI can actually be driven — the detailed Claude Code memory is machine-local and does **not** travel; the repo (this doc + the plans/spec below) does.

## Goal

iTerm2-style **tmux `-CC` control-mode** integration so remote ssh sessions survive app close / network drop. tmux *windows* ↔ WispTerm *tabs*, tmux *panes* ↔ native *splits*, no visible tmux chrome. Only the server needs tmux; WispTerm *is* the tmux client (hand-rolled, in `src/tmux/`).

## Status — done, committed, both suites green, but **NO user-facing behavior yet** (all dead code until 3d wires it in)

| Phase | What | Key commits |
|---|---|---|
| P1 | `src/tmux/control.zig` + `layout.zig` parsers | `af5a956` `3efb3a3` `2492458` |
| P2 | `src/tmux/session.zig` headless controller (model, command queue, `PaneSink`, `sendKeys`) | `4755d4c` |
| P3a | `Pty.openVirtual` — socketpair virtual PTY (`src/platform/pty_posix.zig`) | `47c5d70` `c8c11a5` |
| P3b | `Surface.initVirtual` (no-child pane surface) + `src/tmux/pane.zig` `PaneMap` (sink + `pumpKeystrokes`) | `7d2e478` `65ce6d2` `a6391d0` |
| infra | `src/test_posix.zig` so `zig build test-full` actually runs the posix-only tests | `10d4893` |
| P3c-1 | `SplitTree.fromTmuxLayout` — tmux layout → binary split tree (N-ary fold + ratios) | `ff41e9b` `3a29677` |
| P3c-2 | `Session.EventSink`; `PaneMap` borrowed-surface + reverse lookup; `TabState` tmux fields; `src/appwindow/tmux_bridge.zig` (reconcile + window/pane→tab mapping) | `c36486c` `8a66e69` `91ddd56` `5751efd` |

Suites: fast `zig build test` ≈ 604 passed; full `zig build test-full` ≈ 25/25 steps, 0 failed (incl. native `wispterm-posix-test`).

## Design docs (read first)

- Spec: `docs/superpowers/specs/2026-06-03-tmux-control-mode-integration-design.md`
- Plans: `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase{1,2,3a-virtual-pty,3b-pane-surface,3c1-layout-to-splittree}.md`

## NEXT: Phase 3d (connection + controller read-loop) — do it on the GUI host

Phase 3c-2 landed the bridge (`src/appwindow/tmux_bridge.zig`): a `TmuxBridge` owning a `Session` + `PaneMap`, implementing `Session.EventSink` to reconcile each `%layout-change` into the tab's `SplitTree` (reuse surfaces by pane id / create virtual-PTY panes / drop vanished panes), and mapping `%window-renamed`/`%window-close`/`%window-pane-changed` onto tab title/close + split focus. It has **no runtime caller yet**. Plan: `docs/superpowers/plans/2026-06-03-tmux-control-mode-phase3c2-appwindow-wiring.md`.

Phase 3d wires it to a live connection:

1. Launch `ssh -tt host -- tmux -CC new -A -s <name>` in a PTY; instantiate `TmuxBridge.create(alloc, cols, rows, scrollback_limit, cursor_style, cursor_blink)`.
2. Run the controller read-loop: poll the ssh fd + every pane's `controller_fd`; route ssh→`bridge.session.feed(bytes)`, drain `bridge.session.pendingCommands()`→ssh pipe (then `clearCommands`), and call `bridge.panes.pumpKeystrokes(&bridge.session)`.
3. Bootstrap: `bridge.session.start()` (already enqueues `refresh-client -C` + `list-windows`); seed history per pane via `capture-pane -p -e -J`; resize via `refresh-client -C`.
4. Native split/new-tab/resize actions → `bridge.session.splitPane/newWindow/killWindow/resizeClient` (the **inbound** direction; the echoed `%layout-change` drives the redraw via the bridge).
5. **AppWindow seam.** The bridge is POSIX-only (`Pty.openVirtual`), and `AppWindow.zig` forbids `os.tag` branching (see its line-297 self-check). Reach the bridge through a platform-dispatched indirection — a `platform/`-style module that is the bridge on posix and a no-op stub on windows — not a direct `@import` from `AppWindow.zig`.
6. Detach/reconnect overlay + backoff; close-confirm-before-`kill-window`; `session_persist` re-attach.

Study targets: `src/appwindow/tmux_bridge.zig` (the `TmuxBridge` API), `src/appwindow/tab.zig` (the tree-swap in `splitFocusedSurfaceWithCommand` ~lines 712–730; `spawnTabWithCommandAndCwd`; `closeTab`), and `AppWindow` threading.

## Critical non-obvious findings (don't relearn the hard way)

1. **Don't reuse ghostty-vt's tmux parser.** It ships one but it's compiled out (oniguruma gated off in `GhosttyZig.zig`); enabling it means forking the pinned dep + adding a C regex lib. We hand-roll in `src/tmux/`.
2. **POSIX-only tests must be registered in `src/test_posix.zig`, not just `test_main.zig`.** The default build target is `x86_64-windows-gnu`; tests guarded `!= .windows` in `test_main.zig` are silently excluded there, and the linux target doesn't build the app test binary. `test_posix.zig` is a native, libc-linked binary run by `test-full` on a posix host. (This was discovered after Phase 3a's tests had never actually run.)
3. **A real `Surface` cannot be built in a headless test** (its `Renderer` needs the GPU backend; no test constructs one). Keep runtime-tested logic Surface-agnostic (e.g. `PaneMap`, `fromTmuxLayout` with sentinel factories); everything that touches a real `Surface`/`TabState`/`AppWindow` is compile-checked + **GUI-verified** — which is why 3c-2/3d belong on a GUI host.
4. **A no-child pane needs no new type:** the posix `Command` default `.{}` has `pid = -1`, so `wait()` already reports "still running" and `deinit()` is a safe no-op. `Surface.initVirtual` just leaves `command = .{}`.
5. **`SplitTree` ref-count ownership:** it's an immutable, ref-counted, binary tree. `fromTmuxLayout`/`fromSnapshot` factories transfer **one** ref per leaf to the new tree (they do *not* call `.ref()` themselves). To reuse an existing surface, the factory returns `surface.ref()`. Replace a tab's tree via `old = t.tree; t.tree = new; old.deinit();`.
6. tmux layouts are **N-ary** (`{a,b,c}` row / `[a,b,c]` column); `SplitTree` is **binary**. `fromTmuxLayout` folds right into binary splits with ratios from each child's cell width/height. Mutually-recursive `build`/`buildChain` need an **explicit** error set (Zig can't infer it).

## Build / test / run

Install **Zig 0.15.2** (exact). First build pulls deps (network).

- **Both platforms:** `zig build test` (native fast suite), `zig build test-full` (full; on a posix host this also runs the native `wispterm-posix-test` step covering `PaneMap`/virtual PTY).
- **macOS** (default build target is windows-gnu, so pass a native target for the app): `zig build macos-app -Dtarget=aarch64-macos` (Intel: `x86_64-macos`) → open the `.app`. Native smoke tests: `zig build test-metal`, `test-macos-window`, `test-macos-font`. Needs Xcode Command Line Tools.
- **macOS gotcha (learned in 3c-2):** `zig build test` (the *fast* suite) does **not link on macOS** — `platform/text.zig`'s native path references the ObjC symbol `_wispterm_macos_text_case_insensitive_equal`, which the fast test binary doesn't link (that suite is for linux/CI). To run app-level tests natively on macOS, build the app test binary for a macOS target: **`zig build test-full -Dtarget=aarch64-macos`** (compiles + runs `test_main.zig` natively, Metal/ObjC linked; this is the only path that runs `tab.zig`/`tmux_bridge.zig` tests). For pure `std`-only modules (`tmux/session.zig`, `tmux/control.zig`, `tmux/layout.zig`, and `tmux/pane.zig`'s sentinel tests), the fastest check is a direct **`zig test src/tmux/<mod>.zig`** (`-lc` for `test_posix.zig`), which bypasses the app/ObjC graph entirely.
- **Windows:** `zig build` → run `zig-out\bin\wispterm.exe`. (POSIX virtual PTY / `PaneMap` are unix-only and don't compile on Windows — by design; the posix test step is skipped.)

What's verifiable per platform **right now**: the `Surface.initVirtual`/`finishInit` refactor touches the real `Surface.init` path, so confirm normal terminals/splits/tabs still work (GUI regression); and on macOS confirm the posix tests are green. The tmux feature itself can't be exercised until 3d gives the bridge a live connection.

## Resuming with Claude Code on the new machine

Install Claude Code + the superpowers plugin, open this repo, then: *"Read `docs/superpowers/tmux-resume.md` and continue with Phase 3d."* The plans + spec + this guide are the full portable context. (Optional: the richer machine-local memory can be copied from the old machine's `~/.claude/projects/<slug>/memory/`, but the slug is path-derived so it's fiddly — this doc is the reliable path.)
