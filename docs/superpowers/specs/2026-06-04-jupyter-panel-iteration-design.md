# Jupyter Panel Iteration — Full Mode + Auto-Detect + Multi-Match Picker

Date: 2026-06-04
Status: Approved (design)
Builds on: `2026-06-04-jupyter-panel-design.md` (same branch `worktree-feat-jupyternotebook-support`, PR #151).

## Problem

The first cut of the Jupyter panel works (verified end-to-end on Windows via WebView2: SSH surface → paste URL → tunnel → render). Two friction points remain:

1. **Manual paste.** The user must copy the Jupyter URL (incl. token) from the
   terminal and paste it. The server even bumped the port (8888 → 8889 when 8888
   was busy), so the printed URL differs from what the user typed — exactly the
   case where copy/paste is error-prone.
2. **Side panel only.** Open Jupyter opens a right-docked panel sharing the
   window with the terminal. For real notebook work the user wants the browser
   to take the whole area (terminal hidden), and to dismiss it (restore the
   terminal) with a top-right close button.

## Goal

1. **Display mode:** the browser panel can be **full** (covers the whole content
   area, terminal hidden) or **side** (current right-docked panel). A toggle
   button switches between them; a close button dismisses the panel and restores
   the terminal. **Open Jupyter opens in full mode.** The existing "Toggle
   Browser" command keeps opening in side mode.
2. **Auto-detect:** Open Jupyter scans the focused terminal's text for a running
   Jupyter URL (incl. token) and opens it without manual paste.
3. **Picker:** when more than one distinct Jupyter server is detected, show a
   small list to choose from.

## Decisions (locked during brainstorming)

- **Mode model:** a `side ⇄ full` toggle on the panel (not a Jupyter-only
  overlay). Open Jupyter defaults to `full`.
- **Chrome:** two buttons at the **right of the URL bar** — full/side toggle and
  close (✕). **Esc also closes** (with the webview-focus caveat below).
- **Detection source:** the **focused** terminal surface's snapshot (visible +
  recent scrollback).
- **Detection dedupe:** dedupe by **token** so one server that prints both
  `localhost` and `127.0.0.1` (the observed case) counts as ONE match (prefer
  the `localhost` form). Without this, every single server would falsely trigger
  the picker.
- **Flow:** 0 matches → open `full` + focus empty URL bar (manual fallback);
  1 match → open `full` + navigate; 2+ distinct → picker.
- **Delivery:** continue on `worktree-feat-jupyternotebook-support` / PR #151.

## Architecture

### Component 1 — Panel display mode (`src/browser_panel.zig`, `src/AppWindow.zig`, `src/renderer/overlays.zig`, `src/input.zig`)

- State: `g_display_mode: enum { side, full }` (default `side`). Reset to `side`
  on `close()`.
- Width: in `full`, the panel-width computation returns the **entire content
  width** (window width minus left/right panel offsets), bypassing the
  `MIN_CONTENT_WIDTH` reserve that `panelWidthForWindow`/`width()` apply in
  `side`. The terminal area then computes to ~0 and is fully occluded by the
  native webview child.
- Layout safety: the terminal grid/content-width computation in `AppWindow` must
  tolerate a zero/near-zero terminal width — clamp to ≥1 col/row so nothing
  divides by zero or underflows. The terminal stays laid out (occluded), not
  destroyed, so toggling back to `side` restores it unchanged.
- Chrome: extend `renderBrowserUrlBar` to draw two buttons at the right edge of
  the URL bar — a full/side **toggle** (maximize/restore glyph) and a **close**
  (✕). A pure layout helper (e.g. `urlBarButtonsLayout(bounds)`) returns their
  rects so hit-testing and rendering agree and the math is unit-testable.
- Input: hit-test clicks on those rects in `input.zig` (before URL-bar focus /
  mouse-reporting). Toggle flips `g_display_mode` and re-syncs the panel grid;
  close calls the existing `closeBrowserPanel`. **Esc:** when the panel is
  visible and the URL bar is not focused, Esc closes the panel.
- Open Jupyter: sets `g_display_mode = .full` when opening.

### Component 2 — Jupyter URL detection (`src/jupyter_detect.zig`, new, pure)

- `pub fn findJupyterUrls(allocator, text) ![]DetectedUrl` — scans `text` for
  substrings `http://` or `https://` with host `localhost` or `127.0.0.1`, a
  `:port`, a path, and a `token=` query param; collects full URLs.
- Scans **bottom-up** (most-recent first); returns results most-recent-first.
- **Dedupe by token value:** same token = same server; keep one entry, preferring
  the `localhost` host form over `127.0.0.1`.
- Pure (no I/O, no platform deps) → unit-tested on all platforms via the fast
  suite. This is the TDD anchor for the feature.

### Component 3 — Open Jupyter flow (`src/input.zig` `openJupyterPanel`)

1. Read the focused surface's terminal snapshot text (reuse the existing
   per-surface snapshot path the AI agent uses — `host.surfaceSnapshot` /
   `remote_snapshot`; openJupyterPanel runs on the UI thread, so the read is
   direct, no worker marshaling).
2. `findJupyterUrls(snapshot)`:
   - **0** → open panel `full`, focus empty URL bar (existing
     `openJupyterForSurface` behavior, now in full mode).
   - **1** → open `full` and navigate to it via the existing
     `openForSurface`/`externalUrlForSurface` chain (SSH tunnel reused).
   - **2+** → open the picker (Component 4).

### Component 4 — Multi-match picker (`src/renderer/overlays.zig` + a pure model)

- A lightweight selection overlay listing the detected servers (`host:port` +
  truncated token). Keyboard ↑/↓ to move, Enter to select, click to select, Esc
  to cancel. Reuses the existing overlay/list rendering and selection-state
  pattern (as used by the command palette).
- On select → open panel `full` and navigate via `openForSurface`. On cancel →
  no panel.
- Selection-index/clamp logic lives in a small pure helper for unit testing;
  rendering and key handling are thin.

## Error handling / caveats

- **Esc reliability:** the URL bar + buttons are WispTerm-drawn chrome above the
  webview, so the ✕/toggle are always clickable. Esc only reaches WispTerm when
  WispTerm (not the embedded web page) holds keyboard focus; while typing inside
  the Jupyter page the webview consumes Esc. So **✕ is the guaranteed close; Esc
  is best-effort.** Document this in the verify step.
- **Detection misses:** non-loopback bind (`--ip=0.0.0.0`) or a tokenless server
  won't be detected → falls back to the manual-paste empty bar (0-match path).
- **Stale URLs in scrollback:** if the user restarted Jupyter, the scrollback may
  contain old tokens; most-recent-first ordering surfaces the newest, and the
  picker lets the user choose when ambiguous.

## Testing

- **Unit (all platforms, fast suite):** `jupyter_detect.findJupyterUrls`
  (extraction, token dedupe, localhost-preference, most-recent ordering, no-match,
  https, odd ports/paths); panel full-mode width math (`panelWidthForWindow`/
  width helper returns full content width in `full`, clamps in `side`);
  URL-bar button layout rects; picker selection clamp.
- **Compile:** `zig build test`, `zig build test-full`, and
  `zig build test-shared -Dtarget=aarch64-macos` (macOS Zig modules).
- **GUI manual:** Windows now (auto-detect from an SSH session, full-mode cover +
  terminal hidden, toggle full⇄side, ✕ restores terminal, Esc best-effort,
  picker with two servers). macOS later (same, once the WKWebView build runs on a
  Mac).

## Non-goals (YAGNI)

- No change to the connect-only model, the SSH tunnel, or server lifecycle.
- No persistent "remember last Jupyter URL" store.
- No parsing of non-loopback or tokenless servers beyond the 0-match fallback.
- No multi-panel/multiple-webview support; one panel per tab as today.
- No new keybinding beyond Esc-to-close; Open Jupyter stays a command-center entry.
