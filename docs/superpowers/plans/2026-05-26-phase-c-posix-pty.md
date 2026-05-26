# Phase C — POSIX PTY/process backend

Branch `feat/phase-c-posix-pty`. Make the local-shell PTY work on POSIX (Linux first;
macOS shares the code). This env is Linux/WSL, so it builds + runs natively.

## Contract (from pty_windows.zig / pty.zig facade)
`Pty` must expose: `open(winsize) !Pty`, `deinit(*Pty)`, `getSize(*const Pty) winsize`,
`setSize(*Pty, winsize) !void`, `startCommand(*Pty, *pty_command.Command, pty_command.CommandLine, pty_command.Cwd) !void`,
`readOutput(*Pty, []u8) ReadError!usize`, `writeInput(*Pty, []const u8) WriteError!void`,
`outputAvailable(*Pty) ?usize`, `cancelOutputRead(*Pty) void`. Plus `ReadError`, `WriteError`, `winsize`.
- `winsize = { ws_col: u16, ws_row: u16, ws_xpixel=0, ws_ypixel=0 }`.
- `CommandLine = [:0]const u8` (the shell command line); `Cwd = ?[*:0]const u8`.
- `Command` (`pty_command_unsupported.Command`) is populated by `startCommand`; `Command.wait(*const,block) !?Exit`, `Exit = union{exited:u32, unknown}`, `deinit(*Command)`.

## Consumer IO model (termio/ReadThread.zig, Surface.zig)
- ReadThread loops **blocking** `readOutput`; `error.ReadInterrupted`→retry, `error.BrokenPipe` or `0`→child exited.
- During resize it polls `outputAvailable()` (byte count; 0→sleep) then reads.
- Shutdown calls `cancelOutputRead()` to break the blocking read so the thread exits.
- `Surface` spawns via `Command.start(&pty, cmd, cwd)` → `pty.startCommand(&impl, cmd, cwd)`.

## C1 — `src/platform/pty_posix.zig` (Pty)
Use libc (link libC) via `std.c` / `extern "c"`: `posix_openpt(O_RDWR|O_NOCTTY)`, `grantpt`, `unlockpt`,
`ptsname_r`. Fields: `master: fd_t`, `slave_path: [N]u8`, `size: winsize`, `cancel_pipe: [2]fd_t`.
- `open`: posix_openpt → grantpt → unlockpt → ptsname_r(master) into slave_path; create cancel self-pipe
  (`std.posix.pipe`); `setSize`-equivalent `ioctl(master, TIOCSWINSZ, &os_ws)`. `os_ws` is the OS
  `struct winsize {ws_row, ws_col, ws_xpixel, ws_ypixel}` — map `ws_row=size.ws_row, ws_col=size.ws_col`
  (note OS order is row,col).
- `setSize`: `ioctl(master, TIOCSWINSZ, &os_ws)`; store `self.size`.
- `startCommand`: `std.posix.fork()`. Child: `setsid()`; `open(slave_path, O_RDWR)`; `ioctl(slave, TIOCSCTTY, 0)`;
  `dup2 slave→0,1,2`; close slave/master/cancel fds; `chdir(cwd)` if non-null; parse `command_line` into argv
  (split on ascii whitespace) and `execvpeZ`(argv[0], argv, environ); on exec failure `_exit(127)`.
  Parent: store child pid into `command.pid`; (keep master open).
- `readOutput`: `poll([{master,POLLIN},{cancel_read,POLLIN}], -1)`. cancel ready → drain it, return
  `error.ReadInterrupted`. master ready → `read(master,buf)`; `0`→return 0; `EINTR`→`ReadInterrupted`;
  `EIO`→`error.BrokenPipe` (Linux signals slave-closed via EIO); else `ReadFailed`. Return bytes.
- `writeInput`: loop `write(master, ...)`; `EPIPE`/`EIO`→`BrokenPipe`; else `WriteFailed`.
- `outputAvailable`: `ioctl(master, FIONREAD, &n)` → `@intCast(n)`; error → `null`.
- `cancelOutputRead`: `write(cancel_pipe[1], &[1]u8{0})` (best-effort).
- `deinit`: close master + cancel_pipe.
Constants (TIOCSWINSZ/TIOCSCTTY/FIONREAD, O_RDWR/O_NOCTTY): from `std.os.linux`/`std.posix` where present,
else `extern`/`const` literals. Resolve by compiling.

## C1b — `pty_command_unsupported.zig` `Command`
Add `pid: std.c.pid_t = -1`. `wait(block)`: if `pid <= 0` return `null`; `waitpid(pid, &status, if (block) 0 else WNOHANG)`;
ret==0 → `null` (still running); on reap → `WIFEXITED` ? `.{ .exited = WEXITSTATUS }` : `.unknown`.
`deinit`: best-effort non-blocking reap to avoid zombie. Guard POSIX syscalls so the file still *compiles*
under a Windows target build if it is ever in that graph (use `std.c`/`std.posix`; add `builtin.os.tag` guard only if needed).

## C2 — `src/platform/process_posix.zig`
Complete the stubs with real waitpid:
- `waitForPid(pid, timeout_ms, diag)`: poll `waitpid(pid, &st, WNOHANG)` until reaped or timeout (sleep ~5ms steps).
- `childExited(id, timeout_ms)`: `waitpid(id, &st, WNOHANG)`; true if reaped/no-such-child within timeout.
- Keep `terminateChild`/`writeAllToPipe`/`spawnDetachedWithOptions`/`currentProcessId` as-is.

## Facade wiring — `pty.zig`
`Backend` += `posix`; `backendForOs`: `.windows=>.windows, .linux,.macos,.freebsd,...=>.posix, else=>.unsupported`;
`impl` switch += `.posix => @import("pty_posix.zig")`. Update the codified test (`backendForOs(.linux)`/`.macos`
now expect `.posix`). `pty_command.zig` stays as-is (its `.unsupported` backend already supplies POSIX
Command/CommandLine/Cwd + shell text).

## C3 — tests (in `pty_posix.zig`, native)
- backend selection (`.linux`/`.macos` → `.posix`).
- open → getSize → setSize(resize) → getSize reflects new size.
- spawn: `startCommand` with `"/bin/echo phantty\n"`-style or `sh -c 'printf hi'`; read until output contains
  the expected bytes; then child exits → `readOutput` eventually returns `BrokenPipe`/0; `command.wait(true)` → `.exited`.
- `outputAvailable` returns a count after the child writes.
- teardown: `deinit` closes fds; `command.deinit()` reaps.

## Verify
- Native (Linux): `zig test src/platform/pty_posix.zig -lc` green (real fork/exec/openpty).
- Windows pre-merge gate unaffected: `zig build test-full -Dtarget=x86_64-windows-gnu` green (pty_posix not in that graph).
- `zig build` (default windows target) clean.
