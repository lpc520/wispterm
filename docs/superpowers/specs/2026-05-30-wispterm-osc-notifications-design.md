# 设计：WispTerm 桌面通知（OSC 9 / OSC 777）

> 状态：已通过 brainstorming 评审，待写实现计划。
> 日期：2026-05-30
> 范围：本 spec 仅覆盖 **feature #1（WispTerm 渲染端）**。配套的"通知配置 skill（feature #2，发送端，含 Codex 扩展）"是独立子系统，另起 spec / plan / 实现循环。

## 1. 背景与动机

终端程序（含 Claude Code / Codex 及其 hook）可以发 OSC 9 / OSC 777 转义序列来"请求弹一条桌面通知"。WispTerm 基于 ghostty 内核（`build.zig.zon` 固定 ghostty 依赖），其 VT 核心**已经能解析** OSC 9/777，但 WispTerm 自己的 apprt 层**没有接线**——当前只把 VT 的 `.bell` 动作接到了标题栏铃铛指示器（`src/Surface.zig` `VtHandler` ~134），`.show_desktop_notification` 被忽略。

目标：让 WispTerm 收到 OSC 9/777 时，在 **macOS** 弹出原生桌面通知（带标题/正文），在其它平台优雅回落到**标题栏铃铛 badge**。这样发送端（hook/程序）只需发一种统一契约（OSC 9/777），呈现端按平台自适应。

## 2. 关键发现（已存在、可复用的基础设施）

- **ghostty VT 核心已解析 OSC 9/777** → 产生 `stream` 动作 `show_desktop_notification`，其值结构 `{ title: [:0]const u8, body: [:0]const u8 }`（`ghostty/src/terminal/osc.zig:95`、`stream.zig:118`）。ghostty 的只读 handler 把它当"无终端副作用"忽略（`stream_terminal.zig:265`），正好留给我们拦截。
- **WispTerm 只用 `ghostty_vt`（终端/VT 内核），不用 ghostty 的 apprt/Surface**；自有 `src/Surface.zig` 包了一个 `VtHandler`，已用 `if (action == .bell)` 拦截铃铛的成例可镜像。
- **标题栏铃铛渲染已实现**：`src/renderer/titlebar.zig`（~355 画铃铛字形、~566 透明度动画），由 `Surface.bell_indicator / bell_opacity / bell_indicator_time` 驱动，活动 tab 短暂淡出、后台 tab 常驻，聚焦 tab 时 `src/appwindow/tab.zig:521` 自动清除。
- **macOS bridge 已存在**：`src/platform/services_macos_bridge.m`，已有 `wispterm_macos_notification_bell()` 与 `..._request_attention()`，**但无桌面 toast 函数**。
- **WispTerm 是签名的 `.app` bundle**：`packaging/macos/package.sh` 做 codesign + entitlements——这是现代通知 API（`UNUserNotificationCenter`）的前提。已链接框架 8 个（`build.zig:31` `macos_app_frameworks`），**未链 `UserNotifications`**。

## 3. 已确认的设计决策

1. **原生桌面通知：仅 macOS。** WSL/Linux 不做原生（难测，跳过）。
2. **macOS API：`UNUserNotificationCenter`**（唯一未废弃的现代 API，以 "WispTerm" 身份显示）。拒绝授权 / 未决 / 非 bundle 运行 → 回落 badge。
3. **fallback 呈现：标题栏铃铛 badge，复用现有 `bell_indicator` 渲染**（零新渲染代码）。**v1 不显示通知正文文字**（标题栏瞬时文字渲染列为后续增强）。
4. **尊重焦点**：窗口聚焦且通知来自当前活动 surface → 不弹 toast、铃铛短闪；来自后台 tab 或窗口失焦 → 弹 toast + 该 tab 铃铛常驻。
5. **限流 + 去重**：每 surface ≤ 1 条/秒（限流，任意内容）；另对**相同内容**（`Wyhash(title+body)`）用更长的 **5s** 去重窗口抑制重复。〔实现期细化：原措辞的"1s 去重窗口"与"≤1/s 限流"等价冗余、会让 Wyhash 变成死参数，故把去重窗口拉长到 5s，使限流与去重成为两条真正生效的规则。详见 plan 自审。〕
6. **单一配置开关** `desktop-notifications`（默认开）；关闭时整条通知忽略（不弹、不置 badge），不影响裸 `\a` 响铃。

## 4. 架构（方案 A1）

**方案选择**：在 WispTerm 自有的 `VtHandler.vt` 里拦截 `.show_desktop_notification`，镜像现有 `.bell` 模式。
- 否决 A2（接入 ghostty 自带 apprt 动作体系）：WispTerm 不用 ghostty apprt，引入它面太大、不合架构。
- 否决 A3（在 termio/ReadThread 原始字节流识别）：`VtHandler` 才是 VT 动作派发的规范接缝。

```
PTY bytes ──(reader thread)──▶ VtStream ▶ VtHandler.vt(action, value)
                                              │  action == .show_desktop_notification ?
                                              │  复制 title/body(瞬时切片 → dupe + 截断)
                                              ▼
                              Surface.notif_queue   ← 互斥有界队列(新增)
                                              │
   ◀──(main thread, 出队)──────────── drain ─┘
                                              │  notification.decideRoute(...) (纯函数)
                              ┌───────────────┴───────────────┐
                       Route.toast                        Route.badge
                              ▼                                 ▼
        wispterm_macos_notif_show(title,body)     置 bell_indicator(复用 titlebar 铃铛)
        (UNUserNotificationCenter)
                            Route.none → 丢弃(开关关 / 去重 / 限流命中)
```

### 4.1 新模块 `src/notification.zig`（纯逻辑，可原生测）

把全部决策逻辑抽进一个无重依赖的小模块，平台/线程/UI 只做薄壳：

- `NotifItem { title: BoundedArray(u8,256), body: BoundedArray(u8,1024) }`
- `truncateTitleBody(title, body) -> NotifItem`：截断 + 空 body 处理。
- `NotifQueue`：有界互斥队列（容量如 8，满则丢最旧）。
- `AuthStatus = enum { unavailable, denied, authorized }`（对应 bridge 返回的 0/1/2）。
- `Route = enum { none, toast, badge }`
- `shouldDeliver(hash, now_ms, last_hash, last_time_ms) -> bool`：去重（同 hash <1s）+ 限流（≤1/s）。
- **`decideRoute(notif_enabled, is_macos, auth, window_focused, is_active_surface) -> Route`**：第 3 节决策矩阵 + 开关 + 平台/授权门，全部编码于此。

### 4.2 `Surface.zig` 接缝与状态

- `VtHandler.vt`：在 `if (action == .bell)` 旁加 `.show_desktop_notification` 分支 → `truncateTitleBody` → `notif_queue.push`（reader 线程）。
- 新增 `Surface` 字段：`notif_queue: NotifQueue`、`last_notif_hash: u64`、`last_notif_time: i64`（镜像现有 `last_bell_time`）。
- 主线程出队驱动点：复用现有处理铃铛 `bell_pending` 的同一主线程节拍（每帧/事件循环），出队 → `shouldDeliver` → `decideRoute` → toast 或置 `bell_indicator`。

### 4.3 macOS bridge `services_macos_bridge.m`（新增 3 个 C 接口）

| 接口 | 作用 |
|---|---|
| `void wispterm_macos_notif_request_auth(void)` | **懒授权**：首次要发通知时调一次 → 触发系统授权框；completion 里更新进程级缓存 `g_auth_status` |
| `int wispterm_macos_notif_auth_status(void)` | **同步**返回缓存状态(0=未决/不可用,1=已拒,2=已授权)，供 `decideRoute` 决策 |
| `void wispterm_macos_notif_show(const char*title,const char*body)` | `UNMutableNotificationContent` + `UNNotificationRequest`(唯一 id、nil trigger 立即触发)投递 |

- **前台呈现 delegate（必须）**：设 `UNUserNotificationCenterDelegate`，在 `willPresentNotification` 返回 `.banner | .sound`——否则"窗口聚焦但来源 tab 在后台"这一情形 App 处于前台、macOS 会抑制通知。
- 授权查询是异步的，故缓存到 `g_auth_status`，Zig 侧同步读，避免每条通知都异步查询。
- 非 bundle 运行（dev / `zig build run`）：bridge 检测无 bundle → `auth_status=0` → 回落 badge，开发不崩。

### 4.4 配置 `config.zig`

- 新增 `desktop-notifications: bool = true`（沿用 ghostty 同名）。`decideRoute` 第一个门即此开关。

### 4.5 构建 `build.zig`

- `macos_app_frameworks` 加 `"UserNotifications"`（8 → 9）。
- **同步更新**断言"恰好 8 个框架"的测试（`build.zig:293` 一带 → 改为 9 并加 `expectContainsString(..., "UserNotifications")`）。

## 5. 行为：焦点抑制判定矩阵

通知到达，来源 surface = S，所在 tab = T：

| 条件 | toast | badge(铃铛) |
|---|---|---|
| 窗口聚焦 **且** S 是当前活动 surface | ❌ | 置位(活动 tab 短暂闪) |
| S 在后台 tab(窗口聚焦) | ✅ (靠前台 delegate) | 置位(后台常驻) |
| 窗口失焦 | ✅ (App 后台正常显示) | 置位(后台常驻) |
| 非 macOS / 授权被拒 / 未决 / 非 bundle | ❌ | 置位 |
| `desktop-notifications=false` 或 去重/限流命中 | ❌ | ❌(整条丢弃) |

依赖 AppWindow 现有的"窗口是否聚焦""哪个 surface 活动"状态（`tab.zig:516-521` 聚焦清铃铛已证明可得）——实现期确认取用点。

## 6. 测试

**① 纯逻辑单元测试（`src/notification.zig`，注册进 `test_fast.zig`，原生跑）：**
- `NotifQueue`：入/出队、满了丢最旧、容量上限。
- `truncateTitleBody`：title 256 / body 1024 截断、空/无 body。
- `shouldDeliver`：表驱动（同 hash<1s 丢、异 hash 过、>1s 过、超频丢）。
- `decideRoute`：逐行覆盖第 5 节矩阵 + 开关 + 平台/授权门。**最高价值**。

**② 集成测试（`test-full`）：** 把 OSC 9 与 OSC 777 字节喂进 `VtStream`/`VtHandler`，断言 `surface.notif_queue` 出现正确 title/body——端到端验证"ghostty 解析 → 我们的 handler → 我们的队列"，Linux 即可、不碰平台代码。

**③ macOS 手验清单（无法自动化）：**
1. 首条 → 授权框 → 允许 → toast。
2. 窗口失焦触发 → toast 正常。
3. 聚焦且在来源 tab → 不弹、铃铛短闪。
4. 聚焦但来源 tab 在后台 → 弹（验证前台 delegate）+ 后台 tab 铃铛。
5. 拒绝授权（`tccutil reset` 重置）→ 只铃铛、无 toast。
6. 同条快发两次 → 一条；快发 5 条 → ≤1/秒。
7. `desktop-notifications=false` → 啥都没有。
8. 非 macOS（Win/Linux）→ 只铃铛 badge。

**④ 回归门槛：** `zig build test` + `zig build test-full` 全绿（基线 ~673/677、0 failed）。macOS CI（若有 #90 诊断 workflow）编译 Obj-C bridge + 新框架，挡链接错误。

## 7. 前置校验与风险

- **`Info.plist` 必须含 `CFBundleIdentifier`**——`UNUserNotificationCenter` 强制要求。`packaging/` 中未直接 grep 到，实现期须核实/补上，否则 toast 永远失败。
- **`UserNotifications` 框架可用性**：需 macOS 10.14+；WispTerm 目标版本应已满足，实现期确认部署目标。
- **授权竞态**：懒授权后用户尚未点选时，`auth_status` 为未决 → 该窗口期通知落 badge（可接受）。

## 8. 范围边界（YAGNI / 本期不做）

- **feature #2：通知配置 skill（发送端 + Codex 扩展）** —— 独立 spec。
- **Windows / Linux / WSL 原生桌面通知** —— 只做铃铛 badge 回落。
- **标题栏显示通知正文文字** —— v1 只铃铛字形；文字渲染列为后续增强。
- **点击通知 → 聚焦/切到来源 tab** —— v1 只显示，不做点击路由。
- **toast / badge 细粒度独立开关** —— 只一个总开关。

## 9. 影响文件一览（预估）

- 新增 `src/notification.zig`（纯逻辑 + 单测）。
- 改 `src/Surface.zig`（VtHandler 分支、新增字段、主线程出队驱动）。
- 改 `src/platform/services_macos_bridge.m`（3 个接口 + delegate + 授权缓存）。
- 改 `src/config.zig`（`desktop-notifications` 开关）。
- 改 `build.zig`（链 `UserNotifications` + 改框架数测试）。
- 改 `src/test_fast.zig`（注册 `notification.zig` 测试）、`test_main.zig`（集成测试）。
- 核实 `packaging/macos`（`Info.plist` 的 `CFBundleIdentifier`）。
