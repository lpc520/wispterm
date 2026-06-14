# macOS 本地文件浏览器跟随实时 cwd — 设计文档

- 日期：2026-06-07
- 分支：`fix-macos-local-explorer-cwd`
- 状态：已批准（待实现）

## 背景与问题

macOS 上文件浏览器面板在 `LOCAL`（本地）模式下显示为空白（看不到任何文件），但 `REMOTE`（SSH）模式正常。

### 根因（已实证）

文件浏览器的 `.local` 分支（`src/AppWindow.zig` 的 `syncFileExplorerToActiveTerminalSurface`）当前这样解析根目录：

1. `surface.getCwd()`（仅 OSC 7）→ 经 `platform_wsl.guestPathToLocalPathUtf8` 转换 → 用作根；
2. 否则 `surface.getInitialCwd()`（启动目录）；
3. 否则 `syncPanelForTabKind(false)`（空）。

其中 `guestPathToLocalPathUtf8` 是 **WSL 专用**路径转换：对普通 Unix 路径会走 distro 分支去 spawn `wsl.exe`，在 macOS 上必然失败、返回 `null`（见 `src/platform/wsl.zig`）。因此 macOS 上实时 cwd（OSC 7）**永远被丢弃**，本地树只能退回**启动目录**。

放大问题的两点：
- 开发者通常从仓库目录 `~/Documents/Code/phantty` 启动 dev 版，启动目录因此落在受 macOS TCC（隐私）保护的 `~/Documents` 下；
- 本地树无法跟随 shell 的实时 cwd（即使用户 `cd ~` 到不受保护的家目录顶层），始终钉死在被 TCC 拦截的启动目录上。

`openDir` 失败仅以右下角一闪而过的全局 toast 反馈（`src/file_explorer.zig`），列表区 0 条目时无任何文字 → 表现为"纯空白、无报错"。

而 `.remote` 分支用子进程 `ssh ... ls/pwd` 读远程文件系统并自解析根目录，既不触碰本地受保护目录、也不依赖 OSC 7 或启动目录，所以稳定可用。

### 实证结论

- 在有访问权的上下文中，复刻 `listLocal` 的 `openDir(...,.iterate)` 对家目录、`~/Documents`、仓库目录等全部成功列举 → 列目录逻辑与路径本身无误。
- 构造与 WispTerm 同样"adhoc 签名 / 空 entitlements / 无用途声明"的最小 `.app`，经 LaunchServices 启动后访问 `~/Documents` 会被 TCC 阻塞（授权门），而家目录顶层（不受保护）成功 → 确认机制为 macOS TCC。
- macOS 上 `platform_process.processCwd(pid)` 通过 libproc 能拿到 shell 进程的真实当前目录；`surface.dupeCurrentCwd()` 已按 `OSC7 → 进程 cwd 查询 → 启动目录` 三级解析。

> 由于用户当前 shell 在 `~`（家目录顶层不受 TCC 保护），只要本地树跟随到实时 cwd 即可正常列出文件。这就是本次修复的核心。

## 目标 / 非目标

### 目标
- macOS/POSIX 下本地文件浏览器解析到 shell 的**实时原生 cwd**（而非 WSL 转换后的启动目录），在同步点（打开面板 / 切换 surface / toggle）显示当前目录内容。

### 非目标（不在本次范围）
- 面板内显式错误提示（保持现状的 toast）。
- 签名 / `Info.plist` 用途声明等打包层改动。
- 在用户 `cd` 后、无同步事件时持续自动刷新面板（属于另一增强）。
- 任何对 Windows / WSL 行为的改动。

## 设计（方案：按平台分流，POSIX 复用 `dupeCurrentCwd()`）

### 改动点（唯一）：`src/AppWindow.zig` 的 `.local` 分支

将 `syncFileExplorerToActiveTerminalSurface` 中 `.local` 分支用 `comptime builtin.os.tag` 分流：

- **Windows**：原样保留现有逻辑（`getCwd → guestPathToLocalPathUtf8 → getInitialCwd → syncPanelForTabKind`），逐字节不变、零回归。
- **macOS/POSIX**：
  - 取 allocator（`g_allocator orelse std.heap.page_allocator`）；
  - `surface.dupeCurrentCwd(alloc)`：
    - 非 `null` → `file_explorer.syncPanelForTerminalTarget(.{ .local = cwd })`，随后 `alloc.free(cwd)`（路径已被 `copyRootPathOnly` 复制进 `g_root_path`，释放安全）；
    - `null` → `file_explorer.syncPanelForTabKind(false)`。

伪代码：

```zig
.local => {
    if (comptime builtin.os.tag == .windows) {
        // —— 现有 Windows/WSL 逻辑，原样保留 ——
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
        const alloc = g_allocator orelse std.heap.page_allocator;
        if (surface.dupeCurrentCwd(alloc)) |cwd| {
            defer alloc.free(cwd);
            file_explorer.syncPanelForTerminalTarget(.{ .local = cwd });
        } else {
            file_explorer.syncPanelForTabKind(false);
        }
    }
},
```

### 实现备注
- `src/AppWindow.zig` 当前**未导入** `builtin`，需补充 `const builtin = @import("builtin");`（`std` 已导入）。
- 确认分支内 `surface.dupeCurrentCwd` 的可见性与签名：`pub fn dupeCurrentCwd(self: *const Surface, allocator: std.mem.Allocator) ?[]u8`（`src/Surface.zig`）。

### 不做的事
- 不新增平台抽象函数 / 文件（方案 2 被否，过度设计）。
- 不在 `rescan()` 加"空根用 `std.process.getCwd` 自解析"的安全网（方案 3 / 改动点 2 被否）：`dupeCurrentCwd` 已自带三级回退，macOS 上基本到不了空根；且 `std.process.getCwd` 解析的是 app 进程 cwd（非 shell 实时 cwd），价值有限。按 YAGNI 略去。
- 不改 `.wsl` 分支、`guestPathToLocalPathUtf8` 本身、渲染层、签名/打包。

## 数据流（macOS）

```
用户打开/聚焦本地 tab
  → syncFileExplorerToActiveTerminalSurface()
  → .local（POSIX 分支）
  → surface.dupeCurrentCwd()  // OSC7 → processCwd(pid) → initial_cwd
      = "/Users/xuzhougeng"（shell 实时目录，非保护）
  → syncPanelForTerminalTarget(.{ .local = "/Users/xuzhougeng" })
  → applyTerminalTargetState → copyRootPathOnly → rescan()
  → file_backend.listLocal → openDir 成功 → 列出文件
```

## 风险与缓解

- **Windows 回归**：用 `comptime` 分流，Windows 编译路径完全不变；`dupeCurrentCwd` / `processCwd` 已是跨平台既有 API（`process_windows.zig` 有实现），两端均可编译。
- **释放时机**：`dupeCurrentCwd` 返回 owned 切片；`syncPanelForTerminalTarget` 内部 `copyRootPathOnly` 以 memcpy 复制路径，故同步后立即 `free` 安全。
- **OSC 7 干扰**：`dupeCurrentCwd` 优先用 OSC 7，其次进程查询；macOS 上即使无 OSC 7，进程查询也能给出实时 cwd，行为正确。

## 测试

- `zig build test`（快速套件，含 `file_explorer` / `platform` 测试）必须通过。
- 按 memory 约定验证 macOS 构建链接：`zig build test-full` + `zig build macos-app -Dtarget=aarch64-macos`。
- 手动验证：从仓库目录（`~/Documents/Code/phantty`）启动 macOS 构建，shell 处于 `~`，打开文件浏览器（Ctrl+Shift+Alt+E）应列出家目录内容而非空白；`cd` 到其它目录后重新 toggle/切换 tab，面板应跟随到新目录。
