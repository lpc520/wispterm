# 技能同步异步化设计（修复 ANR 与改进错误反馈）

- 日期：2026-06-07
- 状态：设计已批准，待实现
- 相关背景：[skill-center-design](2026-06-06-skill-center-design.md)、[skill-center-sync-redesign-design](2026-06-06-skill-center-sync-redesign-design.md)、[event-driven-render-loop-design](2026-06-07-event-driven-render-loop-design.md)

## 1. 问题与根因

用户在「把本地技能同步到服务器」时遇到：鼠标卡住、应用「无响应」（macOS ANR 弹窗）、最终 sync failed。

经系统化排查，确认这是**两个独立问题**：

### 问题 A：鼠标卡住 + 应用无响应（根因确凿）

技能中心的三条交互路径在 **UI 主线程同步阻塞**执行网络 IO：

| 路径 | 位置 | 阻塞操作 |
|------|------|----------|
| 部署传输 | `skillCenterRunTransfer` `AppWindow.zig:1252` | tar + scp + ssh |
| 导入前扫描 | `skillCenterOpenImportList` `AppWindow.zig:1229` | ssh 远程扫描 |
| 部署前扫描+决策 | `skillCenterDeployDecide` `AppWindow.zig:1305` | ssh 远程扫描 |

底层 `sshExecCapture`（`platform/remote_file.zig:116`）与 `scp.transfer`（`scp.zig:59`）都是 fork 子进程后 `child.wait()` 阻塞。在 macOS 上，键盘输入在主线程的 AppKit 事件循环（`nextEventMatchingMask` + `sendEvent`）里被分发，触发同步后主线程扎进 ssh/scp 阻塞调用，**回不到事件循环处理鼠标/窗口事件** → 鼠标卡死 → 超过系统 watchdog 阈值 → 弹「无响应」。`ConnectTimeout=8` 意味着连不上就冻结 8 秒，scp 大文件更久。

> 注：该问题先于事件驱动渲染循环（PR #168）即存在，并非其引入的回归。

**叠加的永久死锁隐患**：`sshExecCapture`（`remote_file.zig:207-212`）先 `readToEndAlloc(stdout)` 读到 EOF，**之后**才读 stderr。若远程命令往 stderr 写超过 OS 管道缓冲（~64KB），子进程会卡在写 stderr、不退出、不关闭 stdout → 主线程永远等不到 EOF → 永久 ANR。

### 问题 B：sync failed（本设计仅改进反馈，不预设根因）

`transfer`/`scanLocation` 失败时只显示固定文案 `sc_toast_sync_failed`，真实原因（认证失败 / host key / 路径不对 / 网络超时）仅通过 `std.debug.print` 打到 stderr，普通启动看不到。

## 2. 目标与非目标

**目标：**
1. 三条同步路径全部后台化，根治主线程阻塞导致的鼠标卡死 / ANR。
2. 进行中给出「同步中…」提示，期间 UI、鼠标、终端完全可用。
3. 失败时 toast 显示一行关键原因摘要（best-effort）。
4. 顺手修复 `sshExecCapture` 的管道死锁。

**非目标（YAGNI，已与用户确认）：**
- 不做取消机制。
- 不做进度条 / scp 进度。
- 不重写底层 ssh/scp/tar 传输协议。

## 3. 架构

采用**方案 1**：把现有 `scanAsync`/`finishScan` 后台模式从「库扫描」推广到「transfer / import-scan / deploy-scan」。改动集中在已经使用该模式的两个文件，跨平台、线程边界清晰。

线程安全前提（已验证）：`g_force_rebuild`/`g_cells_valid`/`g_window`/`g_allocator` 及 overlays 的 toast 状态**全是 `threadlocal`**，因此后台线程**不能**直接调用 `markUiDirty`/`showStatusToast`——所有结果必须 marshal 回主线程消费。

### `skill_center.zig`（Session 扩展）

新增与 scan 并列的后台 op 机制：

- 字段：
  - `op_thread: ?std.Thread`
  - `op_done: std.atomic.Value(bool)`（线程是否已结束，供「忙判断」与非阻塞 join）
  - `op_pending: ?PendingOp`（由 `mutex` 保护）
  - `op_wake: ?*const fn () void`（注入的唤醒回调，保持平台中立）
  - `op_status`：「同步中…」文案（可复用现有 `status` 字段，因为同一时刻 scan 与 op 不会真正并发——op 成功后才触发库重扫）
- 类型：
  - `OpWork = struct { ctx: *anyopaque, run: *const fn (*anyopaque, std.mem.Allocator) PendingOp, destroy: *const fn (*anyopaque, std.mem.Allocator) void }`（仿 `ScanWork`）
  - `PendingOp = union(enum) { import_scan_done, deploy_scan_done, transfer_done }`（详见数据流）
- 方法：
  - `startOp(work: OpWork, wake: *const fn () void) bool`：若 `op_thread != null and !op_done` → 返回 `false`（忙，不 join 等待）；否则 join 上一个已结束线程、设状态「同步中…」、`op_done=false`、spawn `opThreadMain`、返回 `true`
  - `takePendingOp() ?PendingOp`：主线程加锁取出并清空
  - `opThreadMain(session, work, generation)`：`defer work.destroy`；跑 `work.run` → 加锁写 `op_pending` + 清状态 → `op_done.store(true)` → 调 `op_wake`（若 `closing` 则丢弃 pending）
  - `destroy`：`closing=true` + join `op_thread`（沿用 scan 的 UAF 安全写法）

**关键差异**：`startOp` 对正在运行的 op **绝不 join 等待**（远程传输可能很慢，会再次卡主线程），改为「忙则拒绝」。这与 `scanAsync` 的 join-before-next 不同，因为库扫描快、传输慢。

### `AppWindow.zig`

- 新增三个 op Job 结构（`SkillImportScanJob` / `SkillDeployScanJob` / `SkillTransferJob`），各自的 `run` 在后台线程跑现有 `scanLocation` / `skill_transfer.transfer`（复用现有 `SkillLocExec` / `SkillTransferCtx` ops），产出对应的 `PendingOp`。
- 改写三个入口为「启动 op」：
  - `skillCenterOpenImportList` → 构造 `SkillImportScanJob` + `session.startOp(work, window_backend.postWakeup)`
  - `skillCenterDeployDecide` → 构造 `SkillDeployScanJob` + `startOp`
  - `skillCenterRunTransfer` → 构造 `SkillTransferJob` + `startOp`
  - 三者在 `startOp` 返回 `false`（忙）时 `showStatusToast`（如「同步进行中…」）。
- 新增 `pollSkillCenterOp(session)`，挂在主循环 `pollSkillUpdate` 旁（`AppWindow.zig:5738` 一带）。

## 4. 数据流

```
用户按键(主线程) → skillCenterOverlaySelect → 决定 op
  → session.startOp(work, postWakeup)
       忙? → showStatusToast("同步进行中…")，结束
  → op 线程: 跑 scanLocation / transfer（注入的 ssh/scp/tar ops）
       → 加锁写 op_pending {结构化结果 + err 摘要} → op_done=true → postWakeup() 唤醒主循环
  → 主循环顶部: pollSkillCenterOp(session)
       takePendingOp() → 按类型在主线程应用:
         · import_scan_done(rows, target)
             → makeImportState + model.setOverlay(.import_list) + markUiDirty
         · deploy_scan_done(rows, target, name, src_hash)
             → overwriteDecision(present, target_hash, src_hash):
                 noop   → showStatusToast(in_sync)
                 direct → 再次 startOp(SkillTransferJob)   // 第二次后台往返
                 confirm→ model.setOverlay(.confirm) + markUiDirty
         · transfer_done(is_import, ok, err_summary)
             → ok:  showStatusToast(imported/synced) + startSkillCenterScan(库重扫，已 async)
               err: showStatusToast("同步失败: " ++ err_summary)
             → markUiDirty
```

`PendingOp` 各分支携带的数据：
- `import_scan_done`：`target` + 扫描得到的 `rows`（owned，主线程消费后释放）
- `deploy_scan_done`：`target` + `name` + `src_hash` + `rows`
- `transfer_done`：`is_import` + `ok: bool` + `err_summary: ?[]u8`（owned）

deploy 是「后台 scan → 主线程 decide → 可能再启动一次 transfer op」，两次后台往返，期间 UI 全程可用。

**为何必须 `postWakeup`**：主循环空闲时调用 `window_backend.pumpAppEvents(timeout)` 阻塞等待，timeout 由 `render_gate.computeBlockTimeoutMs` 计算，非聚焦 / 无光标闪烁时可能很长。后台完成后不唤醒，UI 会拖很久才刷新。被唤醒后主循环跑一圈 → `pollSkillCenterOp` 消费 → `showStatusToast` 激活 overlay + `g_force_rebuild=true` → 渲染。

## 5. 错误处理

- **stderr 摘要透传（best-effort）**：`SkillTransferCtx`（ops 实现）新增 `last_err: [N]u8` + `last_err_len` side-channel。`remoteExec` / `localExec` / `copy` 失败时把底层 stderr 关键行写入：取最后一非空行，并优先匹配常见模式（`Permission denied` / `Connection timed out` / `Host key` / `No such file` / `Could not resolve hostname`）。`skill_transfer.transfer` 对外仍返回 `bool`（接口不变）；主线程从 ctx 读摘要塞进 `transfer_done.err_summary`。
  - 优先覆盖 **ssh / scan 路径**（"同步到服务器"最常见的认证 / 连接失败）。
  - scp copy 路径若拿不到摘要，回退通用失败文案。
- **toast 文案**：新增 i18n 串，形如「同步失败: <摘要>」，摘要截断到 toast 容量（overlays toast buf 160B）。
- **管道死锁修复**：`sshExecCapture` 改为**并发读 stdout/stderr**（起一个读 stderr 的小线程，或用 `Child.collectOutput`），并让失败路径把 stderr 摘要回传给调用者（当前 `return error.RemoteExecFailed` 丢掉了 stderr）。
- **后台内部错误**（spawn / OOM）→ 回传通用失败的 `transfer_done`。
- **生命周期安全**：`closing` 为真时，`opThreadMain` 丢弃 pending、不调 wake；`destroy` join op 线程，避免 UAF。

## 6. 测试（TDD：先写失败测试）

- `skill_center`：
  - `startOp` 在已有 op 运行时返回 `false`（忙拒绝，不阻塞）
  - `takePendingOp` 正确取出并清空
  - `op_done` 状态流转正确
  - `closing` + `destroy` 时 join 安全（注入假 `OpWork`，不碰真实 ssh）
- stderr 摘要提取：纯函数，多行 stderr → 关键行，单测覆盖各匹配模式与回退。
- 现有 `skill_transfer` / `remote_file` / `scp` 测试保持全绿（ops / transfer 对外接口不变）。

## 7. 改动文件

| 文件 | 改动 |
|------|------|
| `src/skill_center.zig` | 新增 op 后台机制（线程 / pending / startOp / takePendingOp / destroy join），新增 `PendingOp` / `OpWork` |
| `src/AppWindow.zig` | 三路径改 `startOp` + 新增 `pollSkillCenterOp` + 主循环挂载 + 三个 op Job 结构 + 从 ctx 读摘要 |
| `src/platform/remote_file.zig` | `sshExecCapture` 并发读两路修死锁 + stderr 摘要回传 |
| `src/skill_transfer.zig` / `SkillTransferCtx` | err 摘要 side-channel（尽量不动 `transfer` 主接口） |
| `src/i18n.zig` | 新增「同步中…」「同步进行中…」「同步失败: …」文案 |

## 8. 风险与权衡

- **摘要 best-effort**：scp 路径的结构化摘要较难拿全，回退通用文案 + 保留 stderr 日志。这是有意的范围控制。
- **忙拒绝 vs 排队**：同一时刻只允许一个 op，重复触发直接提示「同步进行中…」。简单、无队列状态，符合当前 UI 一次一项的交互。
- **op 与 scan 状态共用**：依赖「op 成功后才触发库重扫」这一时序，二者不真正并发；若未来引入并发需拆分状态字段。
