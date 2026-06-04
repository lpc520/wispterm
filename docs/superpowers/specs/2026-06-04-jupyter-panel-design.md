# Jupyter Panel — Render a Remote Jupyter Server in an Embedded Web Panel

Date: 2026-06-04
Status: Approved (design)

## Problem

Users want to open and view a running Jupyter (Lab/Notebook) server from inside
WispTerm — typically a Jupyter started by the user on a **remote** host they are
already SSH'd into — without leaving the terminal.

WispTerm already ships the machinery this needs, but two facts shape the work:

1. **The embedded web panel already exists.** `src/browser_panel.zig` is a
   right-side embedded-webview panel with a URL bar, per-tab ownership, resize,
   and SSH-tunnel-aware navigation. Submitting a URL flows
   `submitUrlBar → openForSurface → externalUrlForSurface(surface) →
   ssh_tunnel.externalUrlForSurface`. When the panel is owned by an SSH surface
   (`surface.launch_kind == .ssh` and `surface.ssh_connection != null`) and the
   URL host is loopback (`localhost` / `127.0.0.1`), `ssh_tunnel.zig:116
   sshLoopbackUrl` builds a tunnel from a local port to the remote port and
   rewrites the URL. This is exactly the "paste your Jupyter URL, render it"
   flow — the connection, tunnel, and token handling are **already done**.

2. **The webview backend is Windows-only.** `src/platform/webview.zig`
   `backendForOs` maps only `.windows → webview_windows.zig` (WebView2);
   everything else falls to `webview_unsupported.zig`, where `loaderAvailable()`
   returns `false` and `create()` returns `null`. WispTerm itself only has GUI
   window backends for `windows` and `macos` (`window_backend.zig backendForOs`);
   Linux/WSL has no GUI backend, so it is out of scope. Therefore on **macOS**
   the panel renders nothing today.

So the substantive cost of "Jupyter support on macOS" is **implementing a macOS
WKWebView backend for `platform/webview.zig`**. Jupyter itself is thin glue on
top of the existing panel. This project is best understood as *"port the
embedded webview to macOS, with Jupyter as the first use case"* — it also makes
the existing browser panel usable on macOS for any localhost web UI.

## Goal

1. On **macOS**, make the embedded web panel actually render, by adding a
   WKWebView backend that satisfies the same contract as the Windows backend.
2. Provide a thin, cross-platform Jupyter entry point: open the panel and prompt
   the user to paste their Jupyter URL. Connection, SSH tunnel, and token
   handling reuse the existing `submitUrlBar → externalUrlForSurface` chain with
   **no new connection logic**.
3. WispTerm does **not** manage the Jupyter process lifecycle. The user starts
   `jupyter lab` themselves (locally or on the remote) and pastes the printed
   `http://localhost:<port>/lab?token=...` URL.

## Decisions (locked during brainstorming)

- **Integration shape**: an embedded panel inside WispTerm (not the system
  browser, not an in-terminal native renderer). Route A.
- **Connection model**: WispTerm only *connects*; it never launches or stops the
  Jupyter server.
- **Connection input**: the user pastes the full Jupyter URL including token.
  If the panel is owned by a connected SSH surface, the existing tunnel maps
  `localhost:<remote_port>` to a local port automatically.
- **Reuse, don't fork**: build on `browser_panel.zig` rather than creating a
  parallel panel subsystem. The "Jupyter" surface area is an entry point plus an
  empty-state hint, nothing more.
- **Platform scope**: macOS is the platform that needs new code (Windows already
  works via WebView2; Linux has no GUI backend and is excluded).
- **Not in scope**: in-terminal native `.ipynb` rendering, Jupyter kernel
  protocol, connection forms, parsing terminal output for URLs, server lifecycle.

## Windows baseline (confirmed by code review)

On Windows, the Jupyter use case works **today with zero new code**, provided
the panel is opened from an SSH-launched surface:

1. User is in an SSH terminal surface connected to the remote host.
2. User toggles the browser panel (owned by that surface) and pastes
   `http://localhost:8888/lab?token=...` into the URL bar, then presses Enter.
3. `externalUrlForSurface(surface)` finds the surface's SSH connection, ensures
   a tunnel (local port → remote `8888`), and rewrites the URL to the local
   tunnel port while preserving `/lab?token=...`.
4. WebView2 navigates to the rewritten local URL and renders JupyterLab.

This was verified by reading the code path (the chain is closed and correct); it
has **not** been run on a real Windows GUI. It serves as the behavioral baseline
the macOS implementation must match.

## Architecture

### Components

- **`src/platform/webview_macos.zig`** (new) — Zig side. `extern` declarations
  for the ObjC bridge plus the contract implementation. Mirrors
  `webview_windows.zig` exactly: `NativeWindowHandle`, `Browser`,
  `max_url_units`, `UrlBuffer`, `Url`, `loaderAvailable`, `urlFromUtf8`,
  `create`, `setBounds`, `setVisible`, `focus`, `navigate`, `isReady`,
  `lastError`, `failed`, `destroy`.
- **`src/platform/webview_macos_bridge.m`** (new) — Objective-C. Creates a
  `WKWebView` as a subview of the window's content `NSView`, positions it at the
  panel bounds, and drives navigation. Follows the existing
  `*_macos_bridge.m` pattern (e.g. `window_macos_bridge.m`,
  `menu_macos_bridge.m`).
- **`src/platform/webview.zig`** (edit) — extend `Backend` with `.macos` and
  `backendForOs` with `.macos => @import("webview_macos.zig")`.
- **`build.zig`** (edit) — link `WebKit.framework` in the macOS link step
  (the `apple-sdk` dependency is already present).
- **Jupyter entry point** (small) — a command/entry that opens the panel with a
  Jupyter-flavored empty state ("Paste your Jupyter URL"). Reuses
  `browser_panel.toggleForSurface` / `submitUrlBar`. Cross-platform (text only).

### Embedding model

macOS renders the terminal via Metal (`wispterm_macos_window_metal_layer`
returns a `CAMetalLayer`). The `NativeHandle` is an opaque pointer to the macOS
window wrapper used by all `wispterm_macos_window_*` externs. The WKWebView is
added as a **subview of the window's content `NSView`**, above the Metal-backed
terminal view; AppKit composites by subview z-order. This is the structural
analogue of the Windows backend parenting a child `HWND` over the render surface
— no structural blocker.

## Data flow (Jupyter, remote)

1. User runs `jupyter lab` on the remote and copies the printed
   `http://localhost:8888/lab?token=...`.
2. The Jupyter panel is owned by the active connected SSH surface. User pastes
   the URL into the URL bar and submits.
3. `ssh_tunnel.externalUrlForSurface(surface)` builds/ensures a tunnel
   (local port → remote `8888`) and rewrites the URL to the local tunnel port,
   preserving path + token.
4. WKWebView navigates to the rewritten local URL → renders full JupyterLab
   (plots, widgets, interactivity).

WispTerm does not touch the Jupyter process.

## macOS-specific risks / verification items

These are the real unknowns; each must be validated on a real macOS GUI:

1. **App Transport Security (ATS) for cleartext HTTP.** The tunnel endpoint is
   `http://127.0.0.1:<local_port>`. WKWebView may block plaintext HTTP by
   default. Mitigation: add `NSAllowsLocalNetworking` (or confirm loopback is
   permitted) in the app's `Info.plist`. **Must verify on device.**
2. **Coordinate flip.** Panel bounds use a top-left pixel origin; `NSView`
   defaults to a bottom-left origin. The bridge converts (as other macOS bridge
   code does).
3. **Backing scale (HiDPI).** Bounds are in framebuffer pixels; `WKWebView`
   frames are in points. Divide by the window's backing scale factor.
4. **Focus / first responder.** Clicking into the WKWebView vs. the terminal
   must route input correctly (`makeFirstResponder` coordination). The Windows
   backend's focus handling is the reference.

## Testing

- **Pure logic** (Zig unit tests, all platforms via `test` / `test-full`):
  URL normalization, loopback detection, tunnel URL rewriting, panel bounds /
  layout math. These already largely exist for `browser_url` / `ssh_tunnel`;
  add coverage for any new Jupyter entry-point logic.
- **WKWebView actual rendering**: macOS GUI manual verification only
  (consistent with the repo's standing "GUI verify pending" practice). Verify:
  panel opens, paste-URL navigates, remote tunnel renders JupyterLab, ATS does
  not block loopback HTTP, resize/focus behave.

## Non-goals (YAGNI)

- Launching or stopping a Jupyter server (local or remote).
- A structured connection form (host picker / port / token fields).
- Parsing terminal scrollback to auto-detect a Jupyter URL/token.
- In-terminal native `.ipynb` cell rendering or Jupyter kernel messaging.
- A Linux webview backend (no Linux GUI window backend exists).
- Any change to the Windows WebView2 backend beyond what the shared contract
  already provides.
