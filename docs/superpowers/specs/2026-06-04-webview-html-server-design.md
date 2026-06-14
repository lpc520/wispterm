# WebView Refresh and HTML Server Design

## Goal

Improve the embedded WebView panel UI and make Ctrl-clicking terminal HTML paths open them in the embedded WebView. HTML must be served over HTTP from the filesystem where it lives so relative CSS, JS, images, and module imports continue to resolve.

## Ghostty Reference

Ghostty models clickable terminal content as link actions (`src/input/Link.zig`) and has an `OpenUrl.Kind.html` action type (`src/apprt/action.zig`). Its app runtime opens URLs with the host OS or runtime UI. WispTerm keeps that modifier-plus-token action shape, but routes HTML paths to its own embedded WebView extension.

## WebView Toolbar

The existing URL bar becomes a compact toolbar with:

- Address field.
- Refresh button.
- Full/side display toggle.
- Close button.

Refresh uses a new platform facade method, `platform_webview.reload(browser)`. Windows calls WebView2 `Reload`, macOS calls `WKWebView reload`, and unsupported backends provide a no-op. This refreshes the current WebView page rather than re-navigating to WispTerm's stored initial URL.

## Ctrl-click HTML Flow

When the primary open modifier is held (Ctrl on Windows/Linux, Cmd on macOS), terminal token actions are ordered as:

1. Web URL: existing URL open flow.
2. `.html` / `.htm` path: open through the HTML server flow.
3. Other previewable files: existing Markdown/text/image/PDF preview flow.
4. Other paths: existing command-based preview fallback.

HTML path resolution reuses existing terminal preview path rules:

- Local: resolve relative paths against the shell's current cwd.
- WSL: resolve inside the WSL guest filesystem.
- SSH: resolve inside the remote SSH filesystem, requiring SSH metadata for relative paths.

## HTML Server Flow

Do not open `file://` URLs. Start an HTTP server with the HTML file's parent directory as root, then open the percent-encoded file basename through WebView.

For local paths, start the server locally. For WSL paths, start it inside WSL. For SSH paths, start it on the remote host and use the existing SSH loopback tunnel to expose the remote `127.0.0.1:<port>` to the local WebView.

Server detection and launch is per environment. WispTerm checks what is installed in that environment and tries candidates in this order:

1. Python 3: `python3 -m http.server <port> --bind 127.0.0.1`, then `python -m http.server ...` when `python` is Python 3.
2. Python 2: `python2` or Python 2 via `python`, using a small `SimpleHTTPServer` command run with `-c` so it binds `127.0.0.1` and serves the current working directory.
3. Node/npm fallback when present without downloading dependencies: prefer a built-in `node -e` static server command; then try an already-installed `http-server` only through a no-install command such as `npx --no-install` or the npm equivalent. If no local package is installed, this fallback fails and WispTerm prompts the user to install Python 3 or a static server in that environment.

If none works in the target environment, show a clear user-visible message that Python 3 or another local static HTTP server needs to be installed there. Do not silently copy WSL/SSH HTML to the host, because that breaks relative assets.

## Server Lifecycle

Maintain a small registry of active HTML servers keyed by environment, connection identity, root directory, and command family. Reuse a live server for repeated opens from the same directory. Kill child server processes when the WebView subsystem deinitializes, when their owning SSH connection is no longer usable, or when the process exits.

For SSH, the remote HTTP server and local tunnel are separate resources. The remote server runs on remote loopback; WispTerm constructs `http://127.0.0.1:<remote_port>/<file>` and passes it through the existing SSH tunnel URL helper so WebView receives a local loopback URL.

## Errors

Expected failures should be specific:

- HTML path could not be resolved.
- SSH current directory is unknown for a relative path.
- No Python/Node/npm HTTP server is available in the target environment.
- Server process started but did not become reachable.
- SSH tunnel failed.

The existing transfer/status surface can be reused for concise messages; no secret SSH values should be logged or displayed.

## Testing

Add pure tests for:

- HTML suffix detection, including `.html` and `.htm`.
- HTML action precedence over Markdown preview for Ctrl-click paths.
- URL path escaping for spaces and reserved characters.
- Server candidate ordering for Python 3, Python 2, and Node/npm fallback.
- SSH HTML URL construction before tunneling.

Then implement with TDD and run `zig build test`. Run `zig build test-full` before finishing if the environment supports the full build.
