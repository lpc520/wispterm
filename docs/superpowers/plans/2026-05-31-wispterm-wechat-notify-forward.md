# WispTerm 微信通知转发 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 当 Claude Code / Codex「完成 / 需确认」时，WispTerm 在弹本地通知的同时，把这条通知额外推送到它已绑定的微信 owner（复用内置 iLink 直连，无第三方中转）。

**Architecture:** notify 脚本在它发的 OSC 777 通知 body 末尾追加一个零宽标记（U+200B）。WispTerm 在 `notification.makeItem` 解析时检测并剥离该标记、置位 `Item.forward_wechat`（body 显示/去重都干净）。主线程 `AppWindow.handleNotification` 出队时，若该位为真、`weixin-notify-forward` 开、存在活动绑定且 owner 已绑、且你没正盯着这个 pane，则调 `weixin.Controller.enqueueNotify`，它在一条「即用即弃」的后台线程上用既有 `ilink.Client.sendText(owner, ...)` 发送，绝不阻塞 UI。

**Tech Stack:** Zig（WispTerm 本体，libghostty-vt 内核）、POSIX sh（notify 脚本 + 测试）。测试：`zig build test`（快速纯逻辑，含 `notification.zig`）、`zig build test-full`（全量，含 `weixin/controller.zig`）、`sh .../test-install.sh`（脚本）。

**关键约束（来自调研）：** ghostty 的 OSC 777 解析（`rxvt_extension.zig:30-37`）把 `body` 当作第二个 `;` 之后的**全部剩余字符串**，所以标记只能藏进 body、由 WispTerm 剥离；WispTerm 只看 ghostty 解析后的 `{title, body}`，看不到原始 OSC 字节，故无法用私有 OSC 旁路。

**已知 v1 限制：** 转发依赖 `desktop-notifications=on`（默认即 on）。`handleNotification` 在该开关关闭时整条 early-return，故关闭桌面通知也会关掉微信转发。记录在 SKILL 文档，本期不解耦。

---

## File Structure

| 文件 | 职责 | 改动 |
|---|---|---|
| `src/notification.zig` | 通知 Item / 队列 / 纯路由逻辑 | 加 `Item.forward_wechat` + `makeItem` 剥离零宽标记 + 单测 |
| `src/weixin/controller.zig` | 微信绑定生命周期 + 发送 | 加 `enqueueNotify` + `PushJob`「即用即弃」发送线程 + 纯 `buildNotifyText` + 单测 |
| `src/config.zig` | 配置字段 / 解析 / `--help` | 加 `weixin-notify-forward: bool` |
| `src/AppWindow.zig` | 主线程通知出队 + 配置应用 | 加 `g_weixin_notify_forward` 全局 + `handleNotification` 转发分支 |
| `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh` | 发送端 OSC | body 末尾追加零宽标记 |
| `plugins/skills/wispterm-notify-setup/scripts/test-install.sh` | 脚本测试 | 更新 OSC 断言含标记 |
| `plugins/skills/wispterm-notify-setup/SKILL.md` | skill 文档 | 加「微信转发」一节 |

标记字节统一为 **U+200B = `E2 80 8B`**：Zig 侧字面量 `"\u{200b}"`，sh 侧八进制 `\342\200\213`。

---

## Task 1: notification.zig — 检测并剥离零宽标记

**Files:**
- Modify: `src/notification.zig`（`Item` 结构 ~17-29、`makeItem` ~31-39）
- Test: `src/notification.zig`（同文件 `test` 块；由 `src/test_fast.zig:43` 注册）

- [ ] **Step 1: 写失败测试**

在 `src/notification.zig` 末尾（最后一个 `test` 之后）追加：

```zig
test "makeItem strips the trailing wechat marker and sets forward_wechat" {
    const marked = "完成，轮到你了" ++ wechat_marker;
    const item = makeItem("Claude Code", marked);
    try std.testing.expect(item.forward_wechat);
    try std.testing.expectEqualStrings("完成，轮到你了", item.body());
    try std.testing.expectEqualStrings("Claude Code", item.title());
}

test "makeItem without the marker keeps body intact and forward_wechat false" {
    const item = makeItem("t", "完成，轮到你了");
    try std.testing.expect(!item.forward_wechat);
    try std.testing.expectEqualStrings("完成，轮到你了", item.body());
}
```

- [ ] **Step 2: 跑测试，确认编译失败**

Run: `zig build test`
Expected: 编译错误 —— `wechat_marker` 未定义、`Item` 无 `forward_wechat` 字段。

- [ ] **Step 3: 加字段 + 常量 + 剥离逻辑**

在 `Item` 结构里（`body_len: usize = 0,` 之后）加字段：

```zig
    /// True when the body carried the WispTerm notifier's WeChat-forward marker
    /// (stripped before storage). Read by AppWindow.handleNotification.
    forward_wechat: bool = false,
```

在 `pub fn makeItem` 之前加常量：

```zig
/// Zero-width space (U+200B) the WispTerm notifier appends to a notification's
/// OSC 777 body to mark it for forwarding to the bound WeChat owner. It is
/// invisible in every renderer, so a build that does not strip it still shows a
/// clean toast. We strip it here so the stored/hashed/displayed body is clean.
pub const wechat_marker = "\u{200b}"; // bytes E2 80 8B
```

把 `makeItem` 改为（替换整个函数体的 body 处理）：

```zig
pub fn makeItem(title_in: []const u8, body_in: []const u8) Item {
    var item: Item = .{};
    item.title_len = @min(title_in.len, max_title);
    @memcpy(item.title_buf[0..item.title_len], title_in[0..item.title_len]);

    var body = body_in;
    if (std.mem.endsWith(u8, body, wechat_marker)) {
        item.forward_wechat = true;
        body = body[0 .. body.len - wechat_marker.len];
    }
    item.body_len = @min(body.len, max_body);
    @memcpy(item.body_buf[0..item.body_len], body[0..item.body_len]);
    return item;
}
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `zig build test`
Expected: PASS（新增 2 个测试 + 既有 `makeItem`/`Queue`/`contentHash`/`shouldDeliver`/`decideRoute` 测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add src/notification.zig
git commit -m "feat(notification): strip wechat-forward marker, set forward_wechat

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: notify 脚本发标记 + 更新脚本测试

**Files:**
- Modify: `plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh`（OSC 输出，~77-80）
- Test: `plugins/skills/wispterm-notify-setup/scripts/test-install.sh`（OSC 断言，~24-47）

- [ ] **Step 1: 先更新脚本测试，使其失败**

在 `test-install.sh` 顶部、`BEL="$(printf '\007')"` 之后加一行：

```sh
MARKER="$(printf '\342\200\213')"
```

把以下 5 处 OSC 断言的「`...${BEL}`」改成「`...${MARKER}${BEL}`」：

```sh
assert_contains "$t" "${ESC}]777;notify;WispTerm;hi${MARKER}${BEL}" "CC Notification -> OSC777 title+body"
```
```sh
assert_contains "$t" "${ESC}]777;notify;Claude Code;完成，轮到你了${MARKER}${BEL}" "CC Stop -> OSC777 Claude Code title+body"
```
```sh
assert_contains "$t" "${ESC}]777;notify;Codex;done deal${MARKER}${BEL}" "Codex argv -> OSC777 Codex/body"
```
```sh
assert_contains "$t" "${ESC}]777;notify;ab;xy${MARKER}${BEL}" "sanitize strips ';' from title and body"
```
```sh
assert_contains "$t" "${ESC}]777;notify;a;bcd${MARKER}${BEL}" "sanitize strips ESC/BEL control bytes from body"
```

（`assert_contains "$t" "$BEL"` 那条「emits BEL」与空载荷两条不动。）

- [ ] **Step 2: 跑脚本测试，确认失败**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh`
Expected: 上述 5 条 FAIL（脚本还没发标记，实际输出无 `MARKER`）。

- [ ] **Step 3: 让脚本发标记**

在 `wispterm-notify.sh` 把这段：

```sh
{
  printf '\033]777;notify;%s;%s\007' "$title" "$body"
  printf '\a'
} >"$notify_tty" 2>/dev/null || true
```

改为（仅在 OSC 的 body 后、终止 BEL 前插入零宽标记 `\342\200\213`）：

```sh
{
  printf '\033]777;notify;%s;%s\342\200\213\007' "$title" "$body"
  printf '\a'
} >"$notify_tty" 2>/dev/null || true
```

同时更新该 `printf` 上方的注释段（`# --- 5. ...`）末尾补一句：

```sh
# A trailing zero-width space (U+200B) in the body marks the notification for
# WeChat forwarding; WispTerm strips it (notification.zig). Other terminals show
# nothing extra. The bare BEL after is the bell-badge fallback.
```

- [ ] **Step 4: 跑脚本测试，确认通过**

Run: `sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh`
Expected: 末行 `0 test(s) failed`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add plugins/skills/wispterm-notify-setup/scripts/wispterm-notify.sh \
        plugins/skills/wispterm-notify-setup/scripts/test-install.sh
git commit -m "feat(notify-setup): append zero-width WeChat-forward marker to OSC 777

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: config `weixin-notify-forward` 开关 + 全局

**Files:**
- Modify: `src/config.zig`（字段 ~343、解析 ~822、help ~1238）
- Modify: `src/AppWindow.zig`（全局声明 ~1371、应用 ~1715）

- [ ] **Step 1: 加配置字段**

`src/config.zig`，在 `@"weixin-allowed-user": ?[]const u8 = null,`（~343）之后插入：

```zig
/// When true (with weixin-direct-enabled and a bound owner), also forward agent
/// finish/confirm notifications to the bound WeChat owner. Opt-in; default off.
@"weixin-notify-forward": bool = false,
```

- [ ] **Step 2: 加解析分支**

`src/config.zig`，在 `weixin-allowed-user` 解析分支之后（`self.@"weixin-allowed-user" = self.dupeString(...)` 的那个 `else if` 块结束处，~822-823）插入新分支：

```zig
    } else if (std.mem.eql(u8, key, "weixin-notify-forward")) {
        if (std.mem.eql(u8, value, "true")) {
            self.@"weixin-notify-forward" = true;
        } else if (std.mem.eql(u8, value, "false")) {
            self.@"weixin-notify-forward" = false;
        } else {
            log.warn("invalid weixin-notify-forward: {s}", .{value});
        }
```

（即接在 `weixin-allowed-user` 分支与其后下一个 `} else if` 之间。）

- [ ] **Step 3: 加 `--help` 行**

`src/config.zig`，在 help 文本的 `--weixin-allowed-user <id> ...` 行（~1238）之后插入：

```zig
        \\  --weixin-notify-forward <bool> Forward agent notifications to the bound WeChat owner
```

- [ ] **Step 4: 加全局并在配置应用处赋值**

`src/AppWindow.zig`，在 `pub threadlocal var g_desktop_notifications: bool = true;`（~1371）之后插入：

```zig
pub threadlocal var g_weixin_notify_forward: bool = false;
```

在 `applyReloadedConfig` 里 `g_desktop_notifications = cfg.@"desktop-notifications";`（~1715）之后插入：

```zig
    g_weixin_notify_forward = cfg.@"weixin-notify-forward";
```

- [ ] **Step 5: 编译 + 跑全量测试**

Run: `zig build && zig build test && zig build test-full`
Expected: 编译通过；测试全绿（config 仅有路径相关测试，新增 key 不破坏断言）。

- [ ] **Step 6: 提交**

```bash
git add src/config.zig src/AppWindow.zig
git commit -m "feat(config): add weixin-notify-forward opt-in flag + g_weixin_notify_forward

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: controller `enqueueNotify` + 后台发送线程

**Files:**
- Modify: `src/weixin/controller.zig`（在 `Controller` struct 内加方法 + 文件内加 `PushJob` + 纯函数 + 单测；由 `src/test_main.zig:638` 注册）

- [ ] **Step 1: 写失败测试**

在 `src/weixin/controller.zig` 末尾（最后一个 `test` 之后）追加：

```zig
test "buildNotifyText joins title and body with a newline" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Claude Code\n完成", buildNotifyText("Claude Code", "完成", &buf));
}

test "buildNotifyText omits the newline when body is empty" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Codex", buildNotifyText("Codex", "", &buf));
}

test "buildNotifyText truncates to fit the output buffer" {
    var buf: [5]u8 = undefined;
    try t.expectEqualStrings("Title", buildNotifyText("Title", "body", &buf));
}

test "enqueueNotify is a no-op when no binding is active (owner unbound)" {
    const path = "zig-cache-tmp-weixin-ctrl-enqueue.json";
    defer std.fs.cwd().deleteFile(path) catch {};

    const ctrl = try Controller.create(t.allocator, path, NoopControl.iface(), .{});
    defer ctrl.destroy();

    // Never started → running=false, owner empty: must not spawn a thread or crash.
    ctrl.enqueueNotify("Claude Code", "完成");
    try t.expect(!ctrl.running);
}
```

- [ ] **Step 2: 跑测试，确认编译失败**

Run: `zig build test-full`
Expected: 编译错误 —— `buildNotifyText` / `enqueueNotify` 未定义。

- [ ] **Step 3: 实现 `buildNotifyText`、`PushJob`、`enqueueNotify`**

在 `src/weixin/controller.zig` 文件顶部常量区（`const SHUTDOWN_JOIN_TIMEOUT_MS ...` 一带）加：

```zig
const NOTIFY_TEXT_MAX: usize = 2000;
```

在 `Controller` struct **之后**、`const ilink_default_base_url = ...` **之前**，加纯函数与 `PushJob`：

```zig
/// Builds the WeChat push text "<title>\n<body>" into `out`, truncating to fit.
/// Pure (no allocation/IO) so it is unit-tested directly.
fn buildNotifyText(title: []const u8, body: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    const tcopy = title[0..@min(title.len, out.len)];
    @memcpy(out[0..tcopy.len], tcopy);
    n = tcopy.len;
    if (body.len != 0 and n < out.len) {
        out[n] = '\n';
        n += 1;
        const bcopy = body[0..@min(body.len, out.len - n)];
        @memcpy(out[n..][0..bcopy.len], bcopy);
        n += bcopy.len;
    }
    return out[0..n];
}

/// A self-contained, owned copy of everything one push needs, so the send can
/// run on a detached thread without touching mutable Controller state.
const PushJob = struct {
    allocator: std.mem.Allocator,
    base_url: []u8,
    token: []u8,
    owner: []u8,
    text: []u8,

    fn create(
        allocator: std.mem.Allocator,
        base_url: []const u8,
        token: []const u8,
        owner: []const u8,
        text: []const u8,
    ) !*PushJob {
        const self = try allocator.create(PushJob);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.base_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(self.base_url);
        self.token = try allocator.dupe(u8, token);
        errdefer allocator.free(self.token);
        self.owner = try allocator.dupe(u8, owner);
        errdefer allocator.free(self.owner);
        self.text = try allocator.dupe(u8, text);
        return self;
    }

    fn destroy(self: *PushJob) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.token);
        self.allocator.free(self.owner);
        self.allocator.free(self.text);
        self.allocator.destroy(self);
    }

    fn run(self: *PushJob) void {
        var client = ilink.Client.init(self.allocator, self.base_url, self.token);
        client.sendText(self.owner, self.text, "") catch |err| {
            std.debug.print("weixin notify forward failed: {}\n", .{err});
        };
        self.destroy();
    }
};
```

在 `Controller` struct 内部（例如紧跟 `unbind` 之后）加方法：

```zig
    /// Forward one notification to the bound owner's WeChat. No-op unless a
    /// binding is live with a bound owner. The network send runs on a detached
    /// one-shot thread so this never blocks the caller (the UI thread).
    /// Best-effort: allocation/spawn/send failures only log.
    pub fn enqueueNotify(self: *Controller, title: []const u8, body: []const u8) void {
        if (!self.running or self.owner.len == 0 or self.token.len == 0) return;

        var text_buf: [NOTIFY_TEXT_MAX]u8 = undefined;
        const text = buildNotifyText(title, body, &text_buf);

        const job = PushJob.create(self.allocator, self.base_url, self.token, self.owner, text) catch return;
        const th = std.Thread.spawn(.{}, PushJob.run, .{job}) catch {
            job.destroy();
            return;
        };
        th.detach();
    }
```

- [ ] **Step 4: 跑测试，确认通过**

Run: `zig build test-full`
Expected: PASS（新增 4 个测试 + 既有 controller 测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add src/weixin/controller.zig
git commit -m "feat(weixin): add Controller.enqueueNotify for off-thread WeChat push

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: AppWindow.handleNotification 接线转发

**Files:**
- Modify: `src/AppWindow.zig`（`handleNotification` 出队循环，~3486-3537）

- [ ] **Step 1: 在出队循环里加转发分支**

`src/AppWindow.zig` `handleNotification` 中，`while (surface.notif_queue.pop()) |item| { ... }` 循环体内、`switch (route) { ... }` 这一整块**之后**、循环 `}` **之前**，插入：

```zig
        // Forward to the bound WeChat owner when the notifier marked it, the
        // opt-in is on, and you are not looking right at this surface. The
        // controller self-guards on an active binding + bound owner and sends
        // off-thread, so this never blocks. (Reaches here only after the
        // shouldDeliver gate above, so it inherits rate-limit/dedup.)
        if (item.forward_wechat and g_weixin_notify_forward and
            !(window_focused and is_active_surface))
        {
            if (g_app) |app| {
                if (app.weixin_controller) |ctrl| ctrl.enqueueNotify(item.title(), item.body());
            }
        }
```

- [ ] **Step 2: 编译**

Run: `zig build`
Expected: 通过。（`item` 为 `notification.Item`，已含 `forward_wechat`/`title()`/`body()`；`g_weixin_notify_forward`/`g_app`/`window_focused` 均在作用域。）

- [ ] **Step 3: 跑全量测试，确认无回归**

Run: `zig build test && zig build test-full`
Expected: 全绿。

- [ ] **Step 4: 提交**

```bash
git add src/AppWindow.zig
git commit -m "feat(appwindow): forward marked notifications to bound WeChat owner

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

> **注：** `handleNotification` 是 UI 线程私有函数且依赖 tab/窗口状态，无清晰的纯单测接缝。转发**决策**已被 Task 1（标记/置位）与 Task 4（`enqueueNotify` 守卫）单测覆盖；本任务的接线靠编译 + Task 6 手验确认。

---

## Task 6: SKILL 文档 + 全量回归

**Files:**
- Modify: `plugins/skills/wispterm-notify-setup/SKILL.md`

- [ ] **Step 1: 加「微信转发」文档节**

在 `SKILL.md` 的 `## Notes` 之前插入：

```markdown
## WeChat forwarding (optional)

In addition to the in-terminal toast/bell, WispTerm can forward each agent
finish / confirmation notification to a WeChat account you've already bound to
WispTerm's built-in iLink direct connection — no third-party relay.

**Prerequisites (all required):**
1. A WispTerm build that includes notification → WeChat forwarding.
2. `weixin-direct-enabled = true` in your WispTerm config.
3. Scan the QR (WispTerm's WeChat panel) to bind, then **send the bot at least
   one message** so it auto-binds you as owner (or pin `weixin-allowed-user`).
4. `weixin-notify-forward = true` in your WispTerm config.
5. Keep `desktop-notifications = on` (default) — forwarding rides the same
   notification pipeline and is skipped when desktop notifications are off.

**Behavior:** a push is sent only when the notification is from this notifier,
the binding is live with a bound owner, and you are **not** actively viewing
that pane (window unfocused, or a different tab/split). The phone message is
`<title>\n<body>`, e.g. `Claude Code` / `完成，轮到你了`.

**Verify:** run the test command below to trigger one notification while the
WispTerm window is unfocused, and confirm the message arrives in WeChat.
```

- [ ] **Step 2: 全量回归（脚本 + Zig）**

Run:
```bash
sh plugins/skills/wispterm-notify-setup/scripts/test-install.sh
zig build && zig build test && zig build test-full
```
Expected: 脚本 `0 test(s) failed`；Zig 编译通过、测试全绿。

- [ ] **Step 3: 提交**

```bash
git add plugins/skills/wispterm-notify-setup/SKILL.md
git commit -m "docs(notify-setup): document WeChat notification forwarding

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## 手动验证清单（无 live WeChat endpoint，无法自动化）

真实绑定（`weixin-direct-enabled=true`、扫码、给 bot 发过消息、`weixin-notify-forward=true`、`desktop-notifications=on`）下：

1. 在 WispTerm 内跑 agent，窗口**失焦**时触发完成 → 手机微信收到 `Claude Code\n完成，轮到你了`，内容干净（无可见标记）。
2. 触发「需确认」(Notification) → 同样收到。
3. 焦点**正在**该 agent pane → 不推（仅本地铃铛短闪）。
4. 切到另一个 tab，agent 在后台 pane 完成 → 推。
5. `weixin-notify-forward=false` → 不推。
6. owner 未绑（从没给 bot 发过消息）→ 静默不推、不崩。
7. `desktop-notifications=false` → 既无 toast 也无微信推送（已知限制）。
8. 快速重复同内容通知 → 受既有去重/限流约束，不轰炸。

---

## Self-Review

**Spec coverage（逐节核对）：**
- §3.1 A2 标记式 → Task 1（剥离）+ Task 2（发标记）✅
- §3.2 转发全部事件 → notify 脚本所有路径都发标记（Task 2），WispTerm 不按事件类型过滤 ✅
- §3.3 焦点门控 → Task 5 `!(window_focused and is_active_surface)` ✅
- §3.4 零宽标记 + WispTerm 剥离 → Task 1/2，字节 `E2 80 8B` 双侧一致 ✅
- §3.5 空 context_token → Task 4 `sendText(owner, text, "")` ✅
- §3.6 `weixin-notify-forward` 开关默认 false → Task 3 ✅
- §6.1 notification.zig → Task 1 ✅
- §6.2 handleNotification 转发分支 + 去重继承 → Task 5（置于 shouldDeliver 之后）✅
- §6.3 controller.enqueueNotify 不阻塞主线程 + owner 空丢弃 + 失败仅 log → Task 4 ✅（用「即用即弃」detached 线程替代「常驻发送线程+队列」，等价满足「不阻塞 UI、失败仅 log」且更少生命周期耦合；spec §6.3 的常驻线程为建议非约束）
- §6.4 config 开关 + --help → Task 3 ✅
- §7 skill 三处改动 → Task 2（脚本×2）+ Task 6（SKILL.md）✅
- §8 测试 → Task 1/4 纯单测、Task 2 脚本测、Task 5/6 编译+回归、手验清单 ✅
- §9 风险（运行期未验证、线程边界、owner 时序）→ 手验清单 + Task 4 守卫 ✅

**Placeholder scan：** 无 TBD/TODO；每个改代码的 step 都给了完整代码与确切命令/预期。✅

**Type consistency：** `wechat_marker`（notification.zig）双侧字节一致；`forward_wechat`、`Item.title()/body()`、`enqueueNotify(title, body)`、`buildNotifyText(title, body, out)`、`PushJob.create/run/destroy`、`g_weixin_notify_forward`、`@"weixin-notify-forward"` 在定义与使用处命名一致。✅

**偏离 spec 说明：** §6.3 采用 detached 即用即弃线程而非常驻队列线程——更简单、无需与 poller 协调生命周期；通知频率低且受 shouldDeliver 限流，每事件一线程开销可接受。`ilink.Client` 每请求自建 `std.http.Client`、无持久资源，适合一次性使用。
