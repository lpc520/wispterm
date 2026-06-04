# FAQ & Troubleshooting

*English · [中文](FAQ-zh)*

> Common questions about elevation, remote access, configuration, and platform support.

## Why isn't my shell running as Administrator? (Windows)

WispTerm does not elevate shells on its own. Shells inherit the same privilege
level as the running `wispterm.exe` process. Starting WispTerm normally (a
double-click or non-elevated shortcut) gives you a standard token, even if your
account is in the Administrators group (UAC split token).

## How do I run an elevated shell? (Windows)

- **Run WispTerm elevated:** right-click `wispterm.exe` or its shortcut and
  choose **Run as administrator**. New tabs inherit the elevated token after UAC
  approval.
- **Separate elevated window only:** from any shell, run
  `Start-Process pwsh -Verb RunAs` (or `powershell`). This starts a new elevated
  process after UAC; it does not replace the current tab.

There is no supported way to promote an existing non-elevated shell to elevated
without a new process and UAC consent.

## Why does remote mirror the local terminal size on phones?

WispTerm Remote mirrors the local window because the desktop app is the source
of truth for terminal state — the local PTY, VT state, scrollback, cursor, and
split layout are captured there and streamed to the browser. The mobile UI can
refocus a single surface, but it does not currently create a separate
phone-sized terminal grid. See [[Remote-Access]].

## Where is my config, and how do I hot-reload it?

Run `wispterm --show-config-path` to print the resolved path, or press `Ctrl+,`
(`Cmd+,` on macOS) to open it in your editor. Saving the file applies most
changes without a restart. Full details and the key reference are in
[[Configuration]].

## Is there a Linux build?

WispTerm ships for **Windows** and **macOS** today. The **Linux** port is still
in progress — track it in
[`TODO.md`](https://github.com/xuzhougeng/wispterm/blob/main/TODO.md).

---
*See also: [[Configuration]] · [[Remote-Access]] · [[Home]]*
