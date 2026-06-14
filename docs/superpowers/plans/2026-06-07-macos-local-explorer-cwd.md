# macOS 本地文件浏览器跟随实时 cwd — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 macOS/POSIX 下本地文件浏览器解析到 shell 的实时原生 cwd，而不是经 WSL 转换后退回（常被 TCC 拦截的）启动目录，从而不再空白。

**Architecture:** 在 `syncFileExplorerToActiveTerminalSurface` 的 `.local` 分支用 `comptime builtin.os.tag` 分流：Windows 原样保留现有 WSL 解析；POSIX 调用新抽出的 `localExplorerLiveCwd()`（包一层既有的 `surface.dupeCurrentCwd()`：OSC7 → 进程 cwd 查询 → 启动目录）。`localExplorerLiveCwd` 无平台相关代码、跨平台可编译，作为单测接缝。

**Tech Stack:** Zig 0.15.x；测试经 `src/test_main.zig` 聚合（`AppWindow.zig` 已收录），用 `zig build test` 跑快速套件。

参考 spec：`docs/superpowers/specs/2026-06-07-macos-local-explorer-cwd-design.md`

---

## File Structure

- Modify: `src/AppWindow.zig`
  - 新增 import：`const builtin = @import("builtin");`
  - 新增私有函数 `localExplorerLiveCwd(surface, allocator) ?[]u8`（`syncFileExplorerToActiveTerminalSurface` 上方）
  - 改写 `syncFileExplorerToActiveTerminalSurface` 的 `.local` 分支为 comptime 平台分流
  - 新增一个 `test` 块覆盖 `localExplorerLiveCwd`

无新增文件；不改 `Surface.zig`、`file_explorer.zig`、`platform/wsl.zig`、渲染层、打包。

---

### Task 1: 抽出并测试 `localExplorerLiveCwd`（TDD）

**Files:**
- Modify: `src/AppWindow.zig`（import 区第 12 行附近；`syncFileExplorerToActiveTerminalSurface` 第 2922 行上方）
- Test: `src/AppWindow.zig`（同文件 `test` 块）

- [ ] **Step 1: 写失败测试**

在 `src/AppWindow.zig` 末尾（其它 `test "appwindow: ..."` 块附近，例如文件末尾）新增：

```zig
test "appwindow: localExplorerLiveCwd resolves the surface live cwd" {
    var surface: Surface = undefined;
    const live = "/Users/test/live";
    @memcpy(surface.cwd_path[0..live.len], live);
    surface.cwd_path_len = live.len;

    const got = localExplorerLiveCwd(&surface, std.testing.allocator) orelse return error.NullCwd;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(live, got);
}
```

> 说明：`dupeCurrentCwd` 优先返回 `getCwd()`（`cwd_path_len > 0` 即命中并 dup），因此只需设置 `cwd_path`/`cwd_path_len`，不会触发进程查询、不读其它未初始化字段。该测试无平台相关代码，在任何目标上都可编译运行。

- [ ] **Step 2: 跑测试确认失败（红）**

Run: `zig build test 2>&1 | tail -30`
Expected: 编译失败，报 `use of undeclared identifier 'localExplorerLiveCwd'`（函数尚未定义）。

- [ ] **Step 3: 最小实现——新增函数**

在 `src/AppWindow.zig` 中 `fn syncFileExplorerToActiveTerminalSurface() void {` 这一行的**正上方**插入：

```zig
/// 解析本地文件浏览器的根目录：shell 的实时工作目录
/// （OSC 7 → 进程 cwd 查询 → 启动目录）。调用方拥有返回的切片。
/// 仅用于 POSIX——本地路径是原生路径，绝不能走 WSL guest 路径转换。
fn localExplorerLiveCwd(surface: *const Surface, allocator: std.mem.Allocator) ?[]u8 {
    return surface.dupeCurrentCwd(allocator);
}

```

- [ ] **Step 4: 跑测试确认通过（绿）**

Run: `zig build test 2>&1 | tail -20`
Expected: 编译通过、全部测试 PASS（含新 `localExplorerLiveCwd` 测试）。

- [ ] **Step 5: 提交**

```bash
git add src/AppWindow.zig
git commit -m "test(file-explorer): add localExplorerLiveCwd resolving surface live cwd

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `.local` 分支按平台分流并接入实时 cwd

**Files:**
- Modify: `src/AppWindow.zig`（import 区第 12 行附近；`.local` 分支，约第 2944 行）

- [ ] **Step 1: 新增 `builtin` import**

在 `src/AppWindow.zig` 第 12 行 `const Surface = @import("Surface.zig");` 之后另起一行加入：

```zig
const builtin = @import("builtin");
```

（`const std = @import("std");` 已在第 7 行，无需重复。）

- [ ] **Step 2: 改写 `.local` 分支**

将 `syncFileExplorerToActiveTerminalSurface` 中**现有**的 `.local` 分支：

```zig
        .local => {
            if (surface.getCwd()) |guest_path| {
                var native_buf: platform_pty_command.CwdBuffer = undefined;
                var utf8_buf: [260]u8 = undefined;
                if (platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf)) |local_path| {
                    file_explorer.syncPanelForTerminalTarget(.{ .local = local_path });
                    return;
                }
            }
            if (surface.getInitialCwd()) |initial_cwd| {
                file_explorer.syncPanelForTerminalTarget(.{ .local = initial_cwd });
                return;
            }
            file_explorer.syncPanelForTabKind(false);
        },
```

整体替换为：

```zig
        .local => {
            if (comptime builtin.os.tag == .windows) {
                // Windows：本地 shell 的 cwd 可能是 WSL guest 路径，沿用既有转换。
                if (surface.getCwd()) |guest_path| {
                    var native_buf: platform_pty_command.CwdBuffer = undefined;
                    var utf8_buf: [260]u8 = undefined;
                    if (platform_wsl.guestPathToLocalPathUtf8(guest_path, &native_buf, &utf8_buf)) |local_path| {
                        file_explorer.syncPanelForTerminalTarget(.{ .local = local_path });
                        return;
                    }
                }
                if (surface.getInitialCwd()) |initial_cwd| {
                    file_explorer.syncPanelForTerminalTarget(.{ .local = initial_cwd });
                    return;
                }
                file_explorer.syncPanelForTabKind(false);
            } else {
                // POSIX（含 macOS）：本地路径是原生路径，跟随 shell 实时 cwd，
                // 不走 WSL 转换（后者在 macOS 上对普通 Unix 路径恒返回 null）。
                const alloc = g_allocator orelse std.heap.page_allocator;
                if (localExplorerLiveCwd(surface, alloc)) |cwd| {
                    defer alloc.free(cwd);
                    file_explorer.syncPanelForTerminalTarget(.{ .local = cwd });
                } else {
                    file_explorer.syncPanelForTabKind(false);
                }
            }
        },
```

> 说明：`syncPanelForTerminalTarget` 内部 `copyRootPathOnly` 以 memcpy 把路径复制进 `g_root_path`，故同步调用返回后 `defer alloc.free(cwd)` 释放安全。

- [ ] **Step 3: 编译并跑全套快速测试**

Run: `zig build test 2>&1 | tail -20`
Expected: 编译通过、全部 PASS（Task 1 的测试仍通过；无回归）。

- [ ] **Step 4: 验证 macOS 构建链接（按 memory 约定）**

Run: `zig build macos-app -Dtarget=aarch64-macos 2>&1 | tail -20`
Expected: 构建成功，无编译/链接错误，产出 `zig-out/bin/WispTerm.app`。

- [ ] **Step 5: 提交**

```bash
git add src/AppWindow.zig
git commit -m "fix(file-explorer): follow shell live cwd for local tree on macOS

The .local branch routed the OSC 7 cwd through the WSL-only
guestPathToLocalPathUtf8, which always returns null on macOS, so the local
file tree fell back to the launch dir (often under TCC-protected
~/Documents) and could never follow the shell. On POSIX, resolve via
surface.dupeCurrentCwd() (OSC7 -> process cwd query -> launch dir); the
Windows/WSL path is kept byte-for-byte under a comptime branch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 手动验证（macOS 运行时行为）

**Files:** 无（运行验证）

- [ ] **Step 1: 从仓库目录启动 macOS 构建**

Run:
```bash
./zig-out/bin/WispTerm.app/Contents/MacOS/WispTerm >/tmp/wt.log 2>&1 &
```

- [ ] **Step 2: 在其终端里确保 shell 处于家目录，打开文件浏览器**

操作：在 WispTerm 终端执行 `cd ~`，按 `Ctrl+Shift+Alt+E` 打开文件浏览器。
Expected: 面板列出家目录内容（不再空白），头部为 `LOCAL Explorer`。

- [ ] **Step 3: 验证跟随 cd**

操作：在终端 `cd ~/Downloads`，再按 `Ctrl+Shift+Alt+E` 关闭、`Ctrl+Shift+Alt+E` 重新打开（或切换 tab 触发同步）。
Expected: 面板根目录变为 `~/Downloads` 的内容。
（注：受保护目录如 `~/Documents` 若未授权仍会因 TCC 列不出——这符合预期，属本次范围外的权限问题。）

- [ ] **Step 4: 清理**

Run: `pkill -f "WispTerm.app/Contents/MacOS/WispTerm"; rm -f /tmp/wt.log`

---

## Self-Review

**1. Spec coverage：**
- 「POSIX 用实时 cwd 而非 WSL 转换」→ Task 2 Step 2 的 else 分支 + Task 1 的 `localExplorerLiveCwd`。✓
- 「Windows 原样保留」→ Task 2 Step 2 的 `comptime ... == .windows` 分支逐字保留。✓
- 「需补 `builtin` import」→ Task 2 Step 1。✓
- 「`zig build test` + `macos-app` 验证」→ Task 2 Step 3/4。✓
- 非目标（面板报错 UX / 签名打包 / 空根安全网 / 持续跟踪 cd）→ 均未纳入。✓

**2. Placeholder 扫描：** 无 TBD/TODO；每个代码步骤均含完整代码与确切命令/预期。✓

**3. Type/命名一致性：** `localExplorerLiveCwd(surface: *const Surface, allocator: std.mem.Allocator) ?[]u8` 在 Task 1 定义、Task 2 调用，签名一致；`surface.dupeCurrentCwd(allocator) ?[]u8`（`src/Surface.zig:764`）签名匹配；`Surface` 别名、`g_allocator`、`std.heap.page_allocator`、`file_explorer.syncPanelForTerminalTarget`/`syncPanelForTabKind` 均为 `AppWindow.zig` 现有符号。✓
