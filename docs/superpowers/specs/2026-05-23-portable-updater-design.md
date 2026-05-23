# Portable Updater Design

## Context

Phantty already has a lightweight update checker that compares the running
desktop version with the latest GitHub Release and opens the release page when
an update exists. The approved next step is a portable-package updater that can
download and replace the current portable payload without relying on PowerShell
scripts as the primary update path.

Ghostty's macOS app uses Sparkle with an `UpdateController`, `UpdateDriver`, and
`UpdateViewModel`. Sparkle handles download, verification, installation, and
relaunch on macOS while Ghostty maps those phases to unobtrusive UI states such
as checking, update available, downloading, extracting, installing, and error.
Phantty is Windows-only and cannot reuse Sparkle, but it should follow the same
state-driven shape: keep update workflow state explicit, keep UI presentation
separate from install mechanics, and use an external installer process for the
part that cannot be done safely by the running app.

## Goals

- Support self-updating for all three published portable Windows packages:
  `portable`, `portable-webview2`, and `portable-no-webview`.
- Ship a native `phantty-updater.exe` helper inside each portable zip.
- Avoid PowerShell as the primary update mechanism.
- Replace the current portable payload only after the new payload is downloaded,
  extracted, and validated.
- Wait for the running `phantty.exe` process to exit before replacing files.
- Restart Phantty after a successful update.
- Preserve enough backup state to roll back when replacement fails.
- Keep the existing browser-jump update behavior as a fallback when automatic
  update installation cannot proceed.

## Non-Goals

- Do not implement the installed-profile updater yet.
- Do not introduce MSI, MSIX, IExpress, WiX, Inno Setup, or another installer
  framework in this phase.
- Do not add a resident background updater service.
- Do not use PowerShell scripts for normal update download or replacement.
- Do not change keyboard shortcuts.
- Do not require administrator privileges for normal portable updates.
- Do not implement code signing in this phase, though the design must remain
  compatible with signing both `phantty.exe` and `phantty-updater.exe` later.

## Package Selection

Phantty must update to the same portable flavor the user is already running.

- If the current runtime is built with WebView enabled and
  `WebView2Loader.dll` exists next to `phantty.exe`, download
  `phantty-windows-portable-webview2-vX.Y.Z.zip`.
- If the current runtime is built with WebView disabled, download
  `phantty-windows-portable-no-webview-vX.Y.Z.zip`.
- Otherwise download `phantty-windows-portable-vX.Y.Z.zip`.

The updater must not silently change package flavor. If the matching asset is
missing, Phantty should keep the current installation unchanged and offer the
release page fallback.

## User Experience

Startup auto-check keeps the existing quiet behavior: it only interrupts the
user when a newer release is available. Manual checks continue to report no
update and failure states.

When an update is available, Phantty should expose an install action from the
update prompt and command center. The UI state should progress through:

- checking
- update available
- downloading
- extracting
- ready to restart
- installing
- updated and relaunched
- failed

The first implementation can render these states with the existing overlay/toast
system instead of a full modal. If the automatic updater cannot run, the prompt
should offer the latest release page as a fallback.

## Architecture

The design has three small pieces with clear ownership.

`src/update_check.zig` grows from version checking into release metadata
selection. It should parse the GitHub Release `assets` array, identify the
matching portable zip, and return the selected asset name, browser download URL,
size when available, latest version, and release page URL. Pure parsing and
selection logic should remain unit tested.

`phantty.exe` owns network and preparation work. It starts the download from the
selected release asset, writes it under:

```text
%LOCALAPPDATA%\Phantty\updates\<version>\
```

Then it extracts the zip into:

```text
%LOCALAPPDATA%\Phantty\updates\<version>\payload\
```

Before launching the updater, Phantty validates that the payload contains:

- `phantty.exe`
- `phantty-updater.exe`
- `version.txt`
- `plugins\`
- `WebView2Loader.dll` only for the `portable-webview2` flavor

`phantty-updater.exe` owns file replacement. It is a separate native Zig
executable included in every portable package. Phantty launches the updater from
the extracted new payload, not from the current target directory, so the helper
can replace the target directory's existing `phantty-updater.exe` without
locking it. It takes explicit arguments:

```text
phantty-updater.exe --pid <pid> --source <payload-dir> --target <current-dir> --restart
```

The helper waits for `<pid>` to exit, validates that `<target>` is a plausible
portable Phantty directory, creates a backup, replaces the payload with the
extracted source, and restarts `<target>\phantty.exe` when requested.

## Replacement and Rollback

Replacement should be directory-oriented but conservative:

1. Refuse to run when source or target paths are empty, equal, or not absolute.
2. Refuse to run when `source\phantty.exe` or `source\phantty-updater.exe` is
   missing.
3. Refuse to run when `target\phantty.exe` is missing.
4. Wait for the target process to exit, with a finite timeout and a clear error.
5. Create a backup directory inside the update work area, not inside the target
   directory.
6. Move or copy existing target payload files into the backup before replacing
   them.
7. Copy the new payload into the target directory.
8. Verify the final target contains the required files.
9. Relaunch `phantty.exe` from the target directory.

If any step after backup creation fails, the helper attempts to restore the
backup and leaves a log file. The user may still need to manually open the
release page if rollback also fails.

The replacement set includes the files and directories Phantty packages today:

- `phantty.exe`
- `phantty-updater.exe`
- `version.txt`
- `plugins\`
- `WebView2Loader.dll` when present in the selected package

Portable user files such as `phantty.conf` must not be removed or overwritten by
the updater unless a future package explicitly ships that file.

## Logging and Errors

Phantty and `phantty-updater.exe` should write update logs under:

```text
%LOCALAPPDATA%\Phantty\logs\
```

The helper should also return a non-zero process exit code on failure. Phantty
can show immediate preparation failures before it exits. Helper failures after
Phantty exits are recorded in the log and can be surfaced on the next startup in
a later phase.

Error messages should preserve the underlying operation and path, for example:

- failed to download release asset
- failed to extract update zip
- matching portable asset not found
- timed out waiting for Phantty to exit
- failed to back up existing payload
- failed to copy new payload
- rollback failed

## Build and Packaging

`build.zig` should add a second executable named `phantty-updater`. The updater
should be a small native Windows binary with no terminal emulator dependencies.
It should link only the Windows and Zig standard-library functionality it needs
for process waiting, file operations, and process launch.

`packaging/windows/package.ps1` should copy `phantty-updater.exe` into all three
portable output directories before zipping. The GitHub release workflow should
validate that each portable output contains the updater, then include it in the
existing zip assets.

The existing unsigned IExpress installer remains unpublished and out of scope.

## Testing

Unit tests should cover:

- package-flavor selection from runtime facts;
- GitHub Release asset parsing and matching;
- invalid or missing asset handling;
- updater argument parsing;
- source and target validation;
- replacement manifest construction that excludes `phantty.conf`.

Integration testing on Windows should cover:

- updating a temporary portable directory for the normal package;
- updating a temporary portable directory for the WebView2 package;
- updating a temporary portable directory for the no-WebView package;
- preserving `phantty.conf`;
- failure during replacement followed by rollback;
- relaunch command construction.

Build verification uses:

```powershell
zig build test
zig build
powershell -ExecutionPolicy Bypass -File .\packaging\windows\package.ps1 -SkipInstaller
```

When files are added, removed, renamed, or moved, run the repository's Windows
path compatibility checks from `AGENTS.md` before finishing.

## Open Decisions

No product decisions remain open for the portable-updater phase. The first
implementation supports all three portable release assets and intentionally
leaves installed-profile updates for a later design.
