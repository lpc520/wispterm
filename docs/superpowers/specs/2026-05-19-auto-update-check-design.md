# Auto Update Check Design

## Context

Phantty already exposes the desktop version from `build.zig.zon` through
`build_options.app_version`, `src/app_metadata.zig`, `phantty.exe --version`,
and the command center `Version` entry. The new feature should reuse that
single version source and must not introduce another desktop version constant.

Ghostty's macOS app uses Sparkle for update checks. Its implementation has an
`UpdateController`, an `UpdateDriver`, and an `UpdateViewModel` that model
states such as checking, update available, no update, and error. Ghostty also
uses an unobtrusive in-window presentation when a terminal window is available,
with a standard updater fallback otherwise. Phantty is Windows-only and does
not currently have an installer update framework, so this feature should copy
Ghostty's state-driven and unobtrusive presentation shape, not Sparkle itself.

## Goals

- Check GitHub Releases after startup when enabled.
- Notify the user only when a newer release is available.
- Let the user jump to the latest GitHub Release page.
- Allow users to disable automatic startup checks.
- Keep failed checks quiet during startup so network or GitHub issues do not
  interrupt terminal use.

## Non-Goals

- Do not download release assets.
- Do not install or replace `phantty.exe`.
- Do not add a background resident updater.
- Do not change keyboard shortcuts.

## User Experience

The default behavior is `auto-update-check = true`. On startup, Phantty starts
a background check after the first window is created. If the latest GitHub
Release tag is newer than the running version, Phantty shows a lightweight
overlay/toast:

`Update available: vX.Y.Z`

Clicking or selecting the update action opens the release in the user's default
browser. A command-center action named `Check for Updates` lets users run the
same check manually and see the result:

- checking: `Checking for updates...`
- newer release: `Update available: vX.Y.Z`
- no newer release: `Phantty is up to date`
- error during manual check: `Update check failed`

Startup errors are logged but not shown. Manual errors are shown because the
user asked for the check.

Users can opt out with:

```text
auto-update-check = false
```

The setting is parsed from the normal config file and CLI path. Hot reload
updates the cached setting for future checks, but it does not cancel a check
that is already in flight.

## Architecture

Add a small `src/update_check.zig` module with testable pure logic and a thin
runtime layer:

- compare normalized semantic versions from the current app version and a
  GitHub Release tag such as `v0.23.3`;
- parse the minimal GitHub Releases JSON fields needed by Phantty:
  `tag_name`, `html_url`, `draft`, and `prerelease`;
- ignore draft and prerelease releases for the default stable check;
- fetch `https://api.github.com/repos/<owner>/<repo>/releases/latest`;
- return a result state: unavailable, up to date, update available, or failed.

`App` owns a small update-check state and starts a detached background thread
when `auto-update-check` is true. The thread uses `std.http.Client` for the
GitHub API request and copies the result into shared state protected by the
existing app mutex or a dedicated update mutex. `AppWindow` polls and consumes
that state during the render loop, then asks `renderer/overlays.zig` to show
the update prompt.

The overlay layer owns only presentation and click handling. Opening the
release URL should reuse `src/system_browser.zig`.

## Testing

Unit tests cover:

- `auto-update-check` default and true/false parsing;
- version comparison, including optional leading `v`;
- current version equal to latest does not notify;
- newer latest version notifies;
- older or malformed tags do not notify;
- GitHub release JSON extraction for `tag_name` and `html_url`;
- command-center action wiring for `Check for Updates`.

Build verification uses `zig build test` and `zig build`.

## Open Decisions

No unresolved product decisions remain. The approved scope is prompt plus
browser jump only, with no automatic download or installation.
