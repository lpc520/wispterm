# SSH File Transfer Design

## Goal

Add a direct remote-file download gesture to the SSH file explorer and move SSH file transfers off the UI thread.

The user-facing behavior:

- `Ctrl+Alt` click a remote file in the File Explorer to download it locally.
- Downloads go to the user's Downloads folder by default.
- A config key can override the download directory.
- If the destination filename already exists, Phantty prompts with `Skip`, `Overwrite`, and `Rename`.
- Existing remote uploads should no longer block rendering/input while `scp.exe` or the SSH stream fallback is running.

## Current State

Phantty already has the pieces needed for this change:

- `src/file_explorer.zig` owns left-panel file state, selection, remote SSH connection metadata, transfer status, and asynchronous remote directory listing.
- Remote listing is already non-blocking through `AsyncListJob`, `std.Thread.spawn`, `tickAsync()`, and a main-thread result handoff.
- Remote upload and download still call `scp.transfer()` synchronously from UI/input paths.
- `src/input.zig` already handles File Explorer mouse clicks and has `Ctrl+S` to download the selected remote file to `%USERPROFILE%\Downloads`.
- `src/scp.zig` already supports both normal `scp.exe` and the SSH stream fallback for upload/download.

The problematic paths are the synchronous transfer calls:

- File Explorer upload (`U` and drag-drop onto the remote panel)
- SSH terminal drag-drop upload
- Existing selected-file download
- New click-to-download gesture

## Ghostty Comparison

Ghostty does not implement a remote SCP file explorer or SCP download gesture, so this feature is Phantty-specific.

The relevant Ghostty behavior to follow is the surrounding terminal convention:

- Ghostty treats OSC 7 as the current working directory reporting mechanism.
- Ghostty shell integration emits OSC 7 using `file://` or `kitty-shell-cwd://` schemes.
- Ghostty keeps terminal input, drag/drop handling, and shell-reported cwd as platform/application concerns around the terminal core rather than reimplementing terminal emulation.

Phantty should keep following that shape: use libghostty-vt for terminal state, keep OSC 7 cwd handling as the source of remote shell cwd when available, and implement SCP file transfer as a Phantty application-layer feature.

## User Experience

### Download Gesture

In the File Explorer while it is in remote mode:

- Single click selects the row.
- Double-click or `Ctrl` click keeps the existing preview behavior.
- `Ctrl+Alt` click a file starts a download.
- `Ctrl+Alt` click a directory does nothing beyond selection, because directory recursive download is out of scope for this change.

`Ctrl+S` remains available for downloading the selected remote file. It should use the same backend path and conflict handling as `Ctrl+Alt` click.

### Download Directory

Add a config key:

```text
ssh-download-dir = C:\Users\me\Downloads
```

Behavior:

- Empty/unset: use `%USERPROFILE%\Downloads`.
- Set: use the configured absolute or relative path exactly as parsed by the existing config system.
- If the directory cannot be resolved or opened, show transfer failure status and do not start `scp.exe`.

### Filename Conflicts

Before starting a download, the UI thread checks whether the destination path already exists.

If there is no conflict, the download starts immediately.

If the path exists, show a small modal/overlay prompt with three actions:

- `Skip`: cancel this transfer and leave the existing file untouched.
- `Overwrite`: download to the original destination path and truncate/replace the file.
- `Rename`: choose the first available Windows-style suffix, for example `file (1).txt`, `file (2).txt`, then start the download.

The prompt applies to a single requested download. No batch policy is needed because this design only downloads one selected file at a time.

## Runtime Architecture

### Transfer Jobs

Add a transfer job model to `src/file_explorer.zig`, parallel to the existing async list job model but separate from it.

The job should contain:

- transfer kind: upload or download
- SSH connection copy
- local path buffer
- remote path/spec buffer
- display name buffer
- context id
- result enum
- done atomic
- optional thread handle

The main thread starts the job, updates `g_transfer_status` to `in_progress`, and returns immediately. The worker thread owns the blocking `scp.transfer()` call. `tickAsync()` or a sibling tick function joins completed transfer jobs and updates status to success/failure.

The file list job and transfer job may run at the same time. This matters because a long upload should not block directory expansion or UI redraws.

### Upload Refresh

When an upload job succeeds and the File Explorer is still in the same remote context, request a remote rescan. This preserves current behavior without making the upload path synchronous.

If the user changes tabs, SSH targets, or File Explorer root while an upload is running, the job can finish in the background. Its result should not mutate a stale file list except for a generic transfer status update.

### Download Completion

When a download job succeeds, show success status with the filename. No automatic open-in-Explorer action is required for this change.

If the destination cannot be created, preserve the underlying `scp`/stream failure logging and show failed status in the panel.

### Transfer Concurrency

For V1, allow one active transfer job at a time. If the user starts another upload or download while one transfer is running, reject the new request and show a short status such as `Transfer busy`.

This keeps state small and avoids multiple simultaneous `scp.exe` password prompts. The list job remains independent, so browsing can still continue while one transfer is running.

## Input Routing

Update `handleFileExplorerPress` in `src/input.zig`:

1. Resolve the clicked row as it does today.
2. Store selection.
3. If remote mode, row is a file, and modifiers are `ctrl && alt && !shift`, start download flow.
4. Otherwise preserve the existing preview and directory expand behavior.

The exact ordering prevents `Ctrl+Alt` click from accidentally opening preview through the existing `Ctrl` click branch.

## Config and App State

Add `ssh-download-dir` to:

- `src/config.zig` field defaults and parsing.
- default config template comment block.
- `src/App.zig` runtime config storage and reload path, so input handlers can read the hot-reloaded value from the active app/window state.
- `README.md` config key table.

The field can be nullable. `null` means use the default Downloads folder.

## Documentation

Because this changes an application shortcut/gesture, update:

- `README.md` keyboard shortcut table.
- `README.md` File Explorer section.
- `src/renderer/overlays.zig` startup shortcut list if space allows.
- Command center only if a command entry is added; no command center entry is required for V1.

## Testing

Use TDD for implementation.

Focused unit tests:

- Config parses `ssh-download-dir`.
- Default download directory resolver falls back to `%USERPROFILE%\Downloads`.
- Rename conflict path generation preserves extensions and increments suffixes.
- Transfer-job result handoff updates status without calling transfer synchronously from the input handler.
- `Ctrl+Alt` click selects a remote file and starts the download flow before preview handling.

Manual/Windows verification:

- `zig build`
- In a real SSH profile session, open the File Explorer.
- `Ctrl+Alt` click a remote file and confirm it downloads under Downloads.
- Repeat with an existing destination and verify `Skip`, `Overwrite`, and `Rename`.
- Upload a large file with `U` or drag/drop and verify the UI remains responsive while transfer status is `in_progress`.
- If the `%APPDATA%\phantty\ssh_hosts` test profile is available, test `ssh.exe`/`scp.exe` against it without printing the password, matching the repository SSH compatibility rules.

## Non-Goals

- Recursive directory download.
- Multi-file selection or batch transfer policy.
- Upload overwrite prompts.
- Opening the local Downloads folder after completion.
- Adding OpenSSH ControlMaster/ControlPersist options. The repository rules explicitly forbid those for Windows helper commands.
