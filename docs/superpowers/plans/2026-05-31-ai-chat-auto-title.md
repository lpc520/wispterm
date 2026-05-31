# AI Chat 对话自动命名 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AI Chat 对话在第一轮（user → assistant）完成后，用一次轻量 LLM 调用自动生成能概括主题的标题，替换默认的 `"DeepSeek"`，且不覆盖手动命名。

**Architecture:** 纯逻辑（首轮提取、触发判断、标题清理、prompt 构建）放进新模块 `src/ai_chat_title.zig`，登记到 `src/test_fast.zig` 跑 native 快速单测。线程 / HTTP / Session 集成留在 `src/ai_chat.zig`：在请求工作线程 `requestThreadMain` 的三个完成点后调用 `maybeAutoTitle`，它在锁内判定+快照、复用现有 `runChatRequestForMessages` 发一个独立精简请求（非流式、无工具），拿到结果清理后 `setTitleIfDefault`。自动命名线程用独立 `Session.title_thread`，沿用 `request_thread` 的 `join`-on-deinit 生命周期。

**Tech Stack:** Zig；`std.Thread`；`std.http.Client`（经现有 `runChatRequestForMessages`）；libghostty-vt 无关。

---

## 环境与测试说明（先读）

- **WispTerm 主 target 是 `x86_64-windows-gnu`（交叉编译），day-to-day 开发在 Windows PowerShell**（见 AGENTS.md）。
- `src/ai_chat_title.zig` 是平台无关纯模块：**可在任意 host 上直接跑** `zig test src/ai_chat_title.zig`（秒级），这是 Task 1–5 的内层验证命令。
- `src/ai_chat.zig` 太重，**不在** fast 套件；它的测试只能经完整套件 `zig build test-full`（AGENTS.md 的 pre-merge 门禁，在 Windows 开发机跑）。Task 6–8 的 ai_chat.zig 测试归此门禁；若当前在非 Windows host，至少完成编译期类型检查与 Task 1–5 native 测试，集成测试与手动验证在 Windows 完成。
- 本改动**不触及**键盘快捷键、桌面版本文件、`remote/`，因此无需更新 README 快捷键段或做版本同步（AGENTS.md 硬规则不适用）。
- 新增文件 `src/ai_chat_title.zig` 文件名满足 Windows 路径安全（全小写、无保留名、无非法字符）。

---

## File Structure

- **Create** `src/ai_chat_title.zig` — 自动命名的纯逻辑：常量（`max_section_bytes` / `max_title_bytes` / `system_prompt`）、类型（`TurnMessage` / `FirstTurn` / `TitleGate`）、`utf8SafeLen`、`extractFirstTurn`、`shouldAutoTitle`、`cleanTitle`、`buildUserContent`，以及全部纯逻辑单测。
- **Modify** `src/test_fast.zig` — 登记 `ai_chat_title.zig` 进快速套件。
- **Modify** `src/ai_chat.zig` — import 新模块；`Session` 增 `title_thread` / `auto_title_attempted` 字段；`deinit` join `title_thread`；`initFromHistoryRecord` 在恢复出 assistant 消息时置位 `auto_title_attempted`；新增 `setTitleIfDefault`、`applyGeneratedTitle`、`buildTitleRequestLocked`、`titleThreadMain`、`maybeAutoTitle`；在 `requestThreadMain` 的三个完成点接线；新增 ai_chat 侧集成测试。

---

## Task 1: 新建 `ai_chat_title.zig`（常量、类型、`utf8SafeLen`）并登记快速套件

**Files:**
- Create: `src/ai_chat_title.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: 创建文件，写入骨架 + `utf8SafeLen`（含测试）**

Create `src/ai_chat_title.zig` with exactly:

```zig
//! Pure, platform-independent logic for AI Chat conversation auto-titling.
//!
//! Lives separate from `ai_chat.zig` (which is too heavy for the fast test
//! suite) so this logic can be unit-tested via `zig build test` /
//! `zig test src/ai_chat_title.zig`. The threaded request + Session
//! integration stays in `ai_chat.zig`.

const std = @import("std");

pub const Role = @import("ai_chat_protocol.zig").Role;

/// Max bytes taken from each of the user / assistant sections when building the
/// title prompt. Truncated on a UTF-8 boundary.
pub const max_section_bytes: usize = 1500;

/// Max bytes of a cleaned display title. Matches `Session.title_buf` length so
/// the title never gets hard-cut mid-codepoint by `copyTitle`.
pub const max_title_bytes: usize = 128;

pub const system_prompt =
    \\You are titling a chat conversation. Given the user's first message and the assistant's reply, produce a short, specific title that captures the topic.
    \\Rules: 2-6 words; no surrounding quotes; no trailing punctuation; reply with the title only; write the title in the same language the user is using.
;

/// Largest length <= `limit` that does not split a UTF-8 codepoint.
/// Returns `s.len` when `s` is already within `limit`.
pub fn utf8SafeLen(s: []const u8, limit: usize) usize {
    if (s.len <= limit) return s.len;
    var end = limit;
    while (end > 0 and (s[end] & 0xC0) == 0x80) : (end -= 1) {}
    return end;
}

test "utf8SafeLen: backs off mid-codepoint" {
    const s = "ab一"; // 'a''b' + U+4E00 (3 bytes) = 5 bytes
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(s, 3)); // limit splits 一
    try std.testing.expectEqual(@as(usize, 2), utf8SafeLen(s, 4));
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen(s, 5));
    try std.testing.expectEqual(@as(usize, 5), utf8SafeLen(s, 99));
}
```

- [ ] **Step 2: 跑测试确认通过（模块可独立编译）**

Run: `zig test src/ai_chat_title.zig`
Expected: PASS（1 test passed）。

- [ ] **Step 3: 登记到快速套件**

In `src/test_fast.zig`, the `test { ... }` block lists modules. Add the new module next to the other `ai_chat_*` entries. Change:

```zig
    _ = @import("ai_chat_protocol.zig");
```

to:

```zig
    _ = @import("ai_chat_protocol.zig");
    _ = @import("ai_chat_title.zig");
```

- [ ] **Step 4: 跑快速套件确认通过**

Run: `zig build test`
Expected: PASS（含 ai_chat_title 的测试）。

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_title.zig src/test_fast.zig
git commit -m "feat(ai-chat): add ai_chat_title module skeleton + utf8SafeLen"
```

---

## Task 2: `extractFirstTurn`（跳过 tool 消息）

**Files:**
- Modify: `src/ai_chat_title.zig`

- [ ] **Step 1: 写失败测试**

Append to `src/ai_chat_title.zig` (after the `utf8SafeLen` test):

```zig
/// Minimal view of a chat message for first-turn extraction.
pub const TurnMessage = struct {
    role: Role,
    content: []const u8,
};

pub const FirstTurn = struct {
    user: []const u8,
    assistant: []const u8,
};

test "extractFirstTurn: first user + first assistant, skipping tool messages" {
    const msgs = [_]TurnMessage{
        .{ .role = .user, .content = "deploy the app" },
        .{ .role = .tool, .content = "running build" },
        .{ .role = .tool, .content = "build ok" },
        .{ .role = .assistant, .content = "Deployed successfully." },
        .{ .role = .assistant, .content = "second answer" },
    };
    const turn = extractFirstTurn(&msgs).?;
    try std.testing.expectEqualStrings("deploy the app", turn.user);
    try std.testing.expectEqualStrings("Deployed successfully.", turn.assistant);
}

test "extractFirstTurn: null when assistant missing" {
    const msgs = [_]TurnMessage{
        .{ .role = .user, .content = "hi" },
        .{ .role = .tool, .content = "x" },
    };
    try std.testing.expect(extractFirstTurn(&msgs) == null);
}

test "extractFirstTurn: null when empty" {
    const msgs = [_]TurnMessage{};
    try std.testing.expect(extractFirstTurn(&msgs) == null);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig test src/ai_chat_title.zig`
Expected: FAIL（`extractFirstTurn` 未定义）。

- [ ] **Step 3: 实现 `extractFirstTurn`**

In `src/ai_chat_title.zig`, add the function immediately after the `FirstTurn` struct definition (above the tests is fine; Zig ignores order):

```zig
/// Return the first user message and the first assistant message, skipping all
/// tool messages (agent-mode tool-call progress / tool results). Returns null
/// if either a user or an assistant message is missing.
pub fn extractFirstTurn(messages: []const TurnMessage) ?FirstTurn {
    var user: ?[]const u8 = null;
    var assistant: ?[]const u8 = null;
    for (messages) |m| {
        switch (m.role) {
            .user => if (user == null) {
                user = m.content;
            },
            .assistant => if (assistant == null) {
                assistant = m.content;
            },
            .tool => {},
        }
    }
    if (user == null or assistant == null) return null;
    return .{ .user = user.?, .assistant = assistant.? };
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig test src/ai_chat_title.zig`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_title.zig
git commit -m "feat(ai-chat): extractFirstTurn skips tool messages"
```

---

## Task 3: `shouldAutoTitle`（触发判定）

**Files:**
- Modify: `src/ai_chat_title.zig`

- [ ] **Step 1: 写失败测试**

Append to `src/ai_chat_title.zig`:

```zig
pub const TitleGate = struct {
    attempted: bool,
    has_api_key: bool,
    title: []const u8,
    default_name: []const u8,
};

test "shouldAutoTitle: fires on first turn with default title and key" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    try std.testing.expect(shouldAutoTitle(.{
        .attempted = false,
        .has_api_key = true,
        .title = "DeepSeek",
        .default_name = "DeepSeek",
    }, turn));
}

test "shouldAutoTitle: blocked when title not default" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = false,
        .has_api_key = true,
        .title = "My chat",
        .default_name = "DeepSeek",
    }, turn));
}

test "shouldAutoTitle: blocked when attempted / no key / no turn" {
    const turn = FirstTurn{ .user = "u", .assistant = "a" };
    const base = TitleGate{
        .attempted = false,
        .has_api_key = true,
        .title = "DeepSeek",
        .default_name = "DeepSeek",
    };
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = true,
        .has_api_key = base.has_api_key,
        .title = base.title,
        .default_name = base.default_name,
    }, turn));
    try std.testing.expect(!shouldAutoTitle(.{
        .attempted = base.attempted,
        .has_api_key = false,
        .title = base.title,
        .default_name = base.default_name,
    }, turn));
    try std.testing.expect(!shouldAutoTitle(base, null));
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig test src/ai_chat_title.zig`
Expected: FAIL（`shouldAutoTitle` 未定义）。

- [ ] **Step 3: 实现 `shouldAutoTitle`**

Add to `src/ai_chat_title.zig` after the `TitleGate` struct:

```zig
/// Auto-title fires only when: not attempted yet, an API key is configured, the
/// title is still the default (user has not renamed), and a first turn exists.
pub fn shouldAutoTitle(gate: TitleGate, turn: ?FirstTurn) bool {
    if (gate.attempted) return false;
    if (!gate.has_api_key) return false;
    if (!std.mem.eql(u8, gate.title, gate.default_name)) return false;
    return turn != null;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig test src/ai_chat_title.zig`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_title.zig
git commit -m "feat(ai-chat): shouldAutoTitle gate logic"
```

---

## Task 4: `cleanTitle`（标题清理）

**Files:**
- Modify: `src/ai_chat_title.zig`

- [ ] **Step 1: 写失败测试**

Append to `src/ai_chat_title.zig`:

```zig
test "cleanTitle: first line, strip quotes, collapse spaces" {
    var buf: [max_title_bytes]u8 = undefined;
    const t = cleanTitle("  \"Deploy   the   App\"\nextra line ", &buf).?;
    try std.testing.expectEqualStrings("Deploy the App", t);
}

test "cleanTitle: strip trailing punctuation (ascii + cjk)" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("Set up titles", cleanTitle("Set up titles.", &buf).?);
    try std.testing.expectEqualStrings("配置自动命名", cleanTitle("配置自动命名。", &buf).?);
}

test "cleanTitle: strip CJK corner-bracket quotes" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("部署应用", cleanTitle("「部署应用」", &buf).?);
}

test "cleanTitle: empty / whitespace returns null" {
    var buf: [max_title_bytes]u8 = undefined;
    try std.testing.expect(cleanTitle("   \n  ", &buf) == null);
    try std.testing.expect(cleanTitle("", &buf) == null);
}

test "cleanTitle: clamps to max_title_bytes on UTF-8 boundary" {
    var buf: [max_title_bytes]u8 = undefined;
    const long = "一" ** 50; // 150 bytes of U+4E00 (3 bytes each)
    const t = cleanTitle(long, &buf).?;
    try std.testing.expect(t.len <= max_title_bytes);
    try std.testing.expect(t.len % 3 == 0); // never split a codepoint
    try std.testing.expect(std.unicode.utf8ValidateSlice(t));
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig test src/ai_chat_title.zig`
Expected: FAIL（`cleanTitle` 未定义）。

- [ ] **Step 3: 实现 `cleanTitle` 及其 helper**

Add to `src/ai_chat_title.zig`:

```zig
fn isTitleSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

const quote_pairs = [_]struct { open: []const u8, close: []const u8 }{
    .{ .open = "\"", .close = "\"" },
    .{ .open = "'", .close = "'" },
    .{ .open = "`", .close = "`" },
    .{ .open = "“", .close = "”" },
    .{ .open = "「", .close = "」" },
    .{ .open = "『", .close = "』" },
    .{ .open = "《", .close = "》" },
};

fn stripSurroundingQuotes(s: []const u8) []const u8 {
    for (quote_pairs) |pair| {
        if (s.len >= pair.open.len + pair.close.len and
            std.mem.startsWith(u8, s, pair.open) and
            std.mem.endsWith(u8, s, pair.close))
        {
            return s[pair.open.len .. s.len - pair.close.len];
        }
    }
    return s;
}

const cjk_trailing_puncts = [_][]const u8{ "。", "！", "？", "，", "、", "；", "：" };

fn stripTrailingNoise(s: []const u8) []const u8 {
    var end = s.len;
    outer: while (end > 0) {
        const c = s[end - 1];
        if (isTitleSpace(c) or c == '.' or c == ',' or c == '!' or
            c == '?' or c == ';' or c == ':')
        {
            end -= 1;
            continue;
        }
        for (cjk_trailing_puncts) |p| {
            if (end >= p.len and std.mem.eql(u8, s[end - p.len .. end], p)) {
                end -= p.len;
                continue :outer;
            }
        }
        break;
    }
    return s[0..end];
}

/// Drop a trailing partial UTF-8 sequence (if `s` was byte-cut mid-codepoint).
fn trimIncompleteUtf8(s: []const u8) []const u8 {
    if (s.len == 0) return s;
    var i = s.len;
    while (i > 0) {
        i -= 1;
        if ((s[i] & 0xC0) != 0x80) break; // found a leading byte
    }
    const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
    if (i + cp_len <= s.len) return s; // complete
    return s[0..i]; // incomplete tail
}

/// Clean a raw model response into a display title written into `out`
/// (must be >= `max_title_bytes`). Returns the populated slice, or null if the
/// cleaned title is empty.
/// Steps: take first line, trim, strip a single pair of surrounding quotes,
/// collapse internal whitespace to single spaces (clamped to max_title_bytes on
/// a UTF-8 boundary), then strip trailing whitespace / sentence punctuation.
pub fn cleanTitle(raw: []const u8, out: []u8) ?[]const u8 {
    std.debug.assert(out.len >= max_title_bytes);
    var line = raw;
    if (std.mem.indexOfScalar(u8, line, '\n')) |nl| line = line[0..nl];
    line = std.mem.trim(u8, line, " \t\r\n");
    line = stripSurroundingQuotes(line);
    line = std.mem.trim(u8, line, " \t\r\n");

    var w: usize = 0;
    var pending_space = false;
    for (line) |c| {
        if (isTitleSpace(c)) {
            if (w > 0) pending_space = true;
            continue;
        }
        if (pending_space) {
            if (w >= max_title_bytes) break;
            out[w] = ' ';
            w += 1;
            pending_space = false;
        }
        if (w >= max_title_bytes) break;
        out[w] = c;
        w += 1;
    }

    var cleaned = trimIncompleteUtf8(out[0..w]);
    cleaned = stripTrailingNoise(cleaned);
    if (cleaned.len == 0) return null;
    return cleaned;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `zig test src/ai_chat_title.zig`
Expected: PASS（全部 cleanTitle 测试）。

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_title.zig
git commit -m "feat(ai-chat): cleanTitle normalizes model title output"
```

---

## Task 5: `buildUserContent`（构建 prompt 用户内容）

**Files:**
- Modify: `src/ai_chat_title.zig`

- [ ] **Step 1: 写失败测试**

Append to `src/ai_chat_title.zig`:

```zig
test "buildUserContent: formats user + assistant sections" {
    const turn = FirstTurn{ .user = "hello", .assistant = "world" };
    const c = try buildUserContent(std.testing.allocator, turn);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("User: hello\n\nAssistant: world", c);
}

test "buildUserContent: truncates each section on UTF-8 boundary" {
    const big = "一" ** 1000; // 3000 bytes, exceeds max_section_bytes (1500)
    const turn = FirstTurn{ .user = big, .assistant = "ok" };
    const c = try buildUserContent(std.testing.allocator, turn);
    defer std.testing.allocator.free(c);
    // "User: " + truncated + "\n\nAssistant: ok"
    try std.testing.expect(std.mem.startsWith(u8, c, "User: "));
    try std.testing.expect(std.mem.endsWith(u8, c, "\n\nAssistant: ok"));
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    // user section bytes <= max_section_bytes
    const after_prefix = c["User: ".len..];
    const user_section = after_prefix[0 .. std.mem.indexOf(u8, after_prefix, "\n\n").?];
    try std.testing.expect(user_section.len <= max_section_bytes);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig test src/ai_chat_title.zig`
Expected: FAIL（`buildUserContent` 未定义）。

- [ ] **Step 3: 实现 `buildUserContent`**

Add to `src/ai_chat_title.zig`:

```zig
/// Truncate `s` to at most `max_section_bytes` on a UTF-8 boundary.
fn truncateSection(s: []const u8) []const u8 {
    return s[0..utf8SafeLen(s, max_section_bytes)];
}

/// Build the user-content message ("User: ...\n\nAssistant: ...") for the title
/// request. Each section is truncated to `max_section_bytes` on a UTF-8 boundary.
pub fn buildUserContent(allocator: std.mem.Allocator, turn: FirstTurn) ![]u8 {
    return std.fmt.allocPrint(allocator, "User: {s}\n\nAssistant: {s}", .{
        truncateSection(turn.user),
        truncateSection(turn.assistant),
    });
}
```

- [ ] **Step 4: 跑测试确认通过 + 整个模块**

Run: `zig test src/ai_chat_title.zig`
Expected: PASS（全模块测试）。

Run: `zig build test`
Expected: PASS（快速套件含 ai_chat_title）。

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_title.zig
git commit -m "feat(ai-chat): buildUserContent builds title prompt body"
```

---

## Task 6: `ai_chat.zig` — Session 字段、deinit join、历史恢复置位

**Files:**
- Modify: `src/ai_chat.zig`（import；`Session` 字段 759 区；`deinit` 934 区；`initFromHistoryRecord` 927 区；新增测试）

- [ ] **Step 1: 写失败测试**

Append a test into `src/ai_chat.zig` 的某个现有 `test` 区附近（例如紧接 `test "ai_chat: setTitle emits history hook snapshot"` 之后，约第 5398 行）：

```zig
test "ai_chat: initFromHistoryRecord marks auto_title_attempted when assistant present" {
    const allocator = std.testing.allocator;
    var msgs = [_]agent_history.MessageRecord{
        .{ .role = .user, .content = "hi" },
        .{ .role = .assistant, .content = "hello" },
    };
    const record = agent_history.SessionRecord{
        .session_id = "sess-1",
        .title = "Restored Chat",
        .base_url = "https://api.example.com",
        .api_key = "secret",
        .model = "model-a",
        .system_prompt = "system",
        .thinking_enabled = true,
        .reasoning_effort = "high",
        .stream = false,
        .agent_enabled = false,
        .created_at = 0,
        .updated_at = 0,
        .messages = &msgs,
    };
    const session = try Session.initFromHistoryRecord(allocator, record);
    defer session.deinit();
    try std.testing.expect(session.auto_title_attempted);
}

test "ai_chat: fresh session has auto_title_attempted=false" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    try std.testing.expect(!session.auto_title_attempted);
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test-full`
Expected: FAIL（`auto_title_attempted` 字段不存在 → 编译错误）。
（非 Windows host 若 test-full 无法编译完整 app，记录此限制；字段缺失导致的编译失败仍可在后续步骤通过类型检查确认修复。）

- [ ] **Step 3: 加 import**

In `src/ai_chat.zig`, find this line (约第 99 行):

```zig
const RequestMessage = ai_chat_protocol.RequestMessage;
```

Change it to:

```zig
const RequestMessage = ai_chat_protocol.RequestMessage;
const ai_chat_title = @import("ai_chat_title.zig");
```

- [ ] **Step 4: 加 Session 字段**

In `src/ai_chat.zig`, find (约第 759 行):

```zig
    request_thread: ?std.Thread = null,
```

Change to:

```zig
    request_thread: ?std.Thread = null,
    title_thread: ?std.Thread = null,
    auto_title_attempted: bool = false,
```

- [ ] **Step 5: `deinit` 中 join `title_thread`**

In `src/ai_chat.zig` `pub fn deinit`, find (约第 934 行):

```zig
        if (self.request_thread) |thread| {
            thread.join();
            self.request_thread = null;
        }
```

Change to:

```zig
        if (self.request_thread) |thread| {
            thread.join();
            self.request_thread = null;
        }
        if (self.title_thread) |thread| {
            thread.join();
            self.title_thread = null;
        }
```

- [ ] **Step 6: `initFromHistoryRecord` 恢复后置位**

In `src/ai_chat.zig` `initFromHistoryRecord`, find the tail of the message-restore loop (约第 926–928 行):

```zig
            try session.messages.append(allocator, cloned_msg);
        }
        return session;
```

Change to:

```zig
            try session.messages.append(allocator, cloned_msg);
        }
        // A restored session that already has an assistant reply has passed its
        // first-turn window; never re-title it. (A half-finished session with no
        // assistant reply keeps auto_title_attempted=false and is still default-
        // titled, so it can be named after its next completed turn.)
        for (session.messages.items) |restored| {
            if (restored.role == .assistant) {
                session.auto_title_attempted = true;
                break;
            }
        }
        return session;
```

- [ ] **Step 7: 跑测试确认通过**

Run: `zig build test-full`
Expected: PASS（两个新测试通过；其余测试不回归）。

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): Session auto-title fields + restore guard"
```

---

## Task 7: `ai_chat.zig` — `setTitleIfDefault` + `applyGeneratedTitle`

**Files:**
- Modify: `src/ai_chat.zig`（`setTitle` 1191 区后加方法；自由函数；新增测试）

- [ ] **Step 1: 写失败测试**

Append into `src/ai_chat.zig` test 区（紧接 Task 6 的测试之后）：

```zig
test "ai_chat: applyGeneratedTitle cleans and sets title when still default" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "  \"Deploy the App\"  \nignored second line ");
    try std.testing.expectEqualStrings("Deploy the App", session.title());
}

test "ai_chat: applyGeneratedTitle leaves a renamed title untouched" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        "My Custom Name",
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "Generated Title");
    try std.testing.expectEqualStrings("My Custom Name", session.title());
}

test "ai_chat: applyGeneratedTitle ignores empty model output" {
    const allocator = std.testing.allocator;
    const session = try Session.init(
        allocator,
        DEFAULT_NAME,
        "https://api.example.com",
        "secret",
        "model-a",
        "system",
        "enabled",
        "high",
        "false",
        "true",
    );
    defer session.deinit();
    applyGeneratedTitle(session, "   \n  ");
    try std.testing.expectEqualStrings(DEFAULT_NAME, session.title());
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `zig build test-full`
Expected: FAIL（`setTitleIfDefault` / `applyGeneratedTitle` 未定义）。

- [ ] **Step 3: 加 `setTitleIfDefault` 方法**

In `src/ai_chat.zig`, find `pub fn setTitle`（约第 1184–1191 行）：

```zig
    pub fn setTitle(self: *Session, title_text: []const u8) void {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        self.copyTitle(title_text);
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
    }
```

Add immediately after it (still inside the `Session` struct):

```zig
    /// Set the title only if it is still the default name. Returns true if it
    /// changed. Used by auto-title so a concurrent manual rename always wins.
    pub fn setTitleIfDefault(self: *Session, title_text: []const u8) bool {
        var history_change: ?PendingHistoryChange = null;
        self.mutex.lock();
        if (!std.mem.eql(u8, self.title_buf[0..self.title_len], DEFAULT_NAME)) {
            self.mutex.unlock();
            return false;
        }
        self.copyTitle(title_text);
        history_change = self.captureHistoryChangeLocked();
        self.mutex.unlock();
        self.notifyHistoryChange(history_change);
        return true;
    }
```

- [ ] **Step 4: 加 `applyGeneratedTitle` 自由函数**

In `src/ai_chat.zig`, add a free function near the other request-completion free functions (例如紧接 `finishStoppedRequest` 之后，约第 2843 行之后):

```zig
/// Clean a raw model title response and apply it to the session, but only if the
/// title is still the default (a manual rename in the meantime always wins) and
/// the session is not closing.
fn applyGeneratedTitle(session: *Session, raw: []const u8) void {
    if (session.closing.load(.acquire)) return;
    var buf: [ai_chat_title.max_title_bytes]u8 = undefined;
    const cleaned = ai_chat_title.cleanTitle(raw, &buf) orelse return;
    _ = session.setTitleIfDefault(cleaned);
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `zig build test-full`
Expected: PASS（三个新测试通过；无回归）。

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): setTitleIfDefault + applyGeneratedTitle"
```

---

## Task 8: `ai_chat.zig` — 请求构建、标题线程、触发接线

**Files:**
- Modify: `src/ai_chat.zig`（新增 `buildTitleRequestLocked` / `titleThreadMain` / `maybeAutoTitle`；在 `requestThreadMain` 三处接线）

> 本任务的链路涉及真实 HTTP 与后台线程，无法在不发网络的前提下单测（触发判定与清理逻辑已分别由 `shouldAutoTitle` 与 `applyGeneratedTitle` 的测试覆盖）。因此本任务以**编译期类型检查 + 手动验证**收尾，不新增自动化测试。

- [ ] **Step 1: 加 `buildTitleRequestLocked`（在锁内构造精简 ChatRequest）**

In `src/ai_chat.zig`, add these two free functions next to `applyGeneratedTitle`:

```zig
/// Build a standalone, tool-free, non-streaming ChatRequest for title
/// generation, reusing the session's endpoint/key/model/protocol. Must be
/// called with `session.mutex` held (reads session config + first turn).
/// Caller owns the returned request and must `req.deinit()` it.
fn buildTitleRequestLocked(session: *Session, turn: ai_chat_title.FirstTurn) !*ChatRequest {
    const allocator = session.allocator;
    const req = try allocator.create(ChatRequest);
    errdefer allocator.destroy(req);

    const base_url = try allocator.dupe(u8, session.baseUrl());
    errdefer allocator.free(base_url);
    const api_key = try allocator.dupe(u8, session.apiKey());
    errdefer allocator.free(api_key);
    const model = try allocator.dupe(u8, session.model());
    errdefer allocator.free(model);
    const system_prompt = try allocator.dupe(u8, ai_chat_title.system_prompt);
    errdefer allocator.free(system_prompt);
    const reasoning_effort = try allocator.dupe(u8, "low");
    errdefer allocator.free(reasoning_effort);

    const user_content = try ai_chat_title.buildUserContent(allocator, turn);
    errdefer allocator.free(user_content);

    const messages = try allocator.alloc(RequestMessage, 1);
    errdefer allocator.free(messages);
    // ownership of user_content moves into messages[0]; freed by req.deinit()
    messages[0] = .{ .role = .user, .content = user_content };

    req.* = .{
        .allocator = allocator,
        .session = session,
        .base_url = base_url,
        .api_key = api_key,
        .model = model,
        .protocol = session.protocol,
        .system_prompt = system_prompt,
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = reasoning_effort,
        .stream = false,
        .max_tokens = 64,
        .agent_enabled = false,
        .copilot = false,
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = 0,
    };
    return req;
}

/// Background worker for one title request. Owns `req` and frees it on exit.
fn titleThreadMain(req: *ChatRequest) void {
    defer req.deinit();
    const session = req.session;
    const allocator = req.allocator;
    if (session.closing.load(.acquire)) return;

    const result = runChatRequestForMessages(req, req.messages, false) catch return;
    defer result.deinit(allocator);
    if (session.closing.load(.acquire)) return;

    applyGeneratedTitle(session, result.content);
}
```

- [ ] **Step 2: 加 `maybeAutoTitle`（判定 + 快照 + spawn）**

In `src/ai_chat.zig`, add after `titleThreadMain`:

```zig
/// After a completed turn, generate a title in the background if the gate
/// passes. Called from the request worker (`requestThreadMain`) with no lock
/// held. The worker thread that calls this is `session.request_thread`, which
/// `deinit` joins before it joins `title_thread`, so storing the handle here
/// races neither deinit nor the title worker.
fn maybeAutoTitle(session: *Session) void {
    if (session.closing.load(.acquire)) return;
    const allocator = session.allocator;

    session.mutex.lock();
    var spawned_req: ?*ChatRequest = null;
    locked: {
        const turns = allocator.alloc(ai_chat_title.TurnMessage, session.messages.items.len) catch break :locked;
        defer allocator.free(turns);
        for (session.messages.items, 0..) |m, i| {
            turns[i] = .{ .role = m.role, .content = m.content };
        }
        const turn = ai_chat_title.extractFirstTurn(turns);
        const gate = ai_chat_title.TitleGate{
            .attempted = session.auto_title_attempted,
            .has_api_key = session.api_key_len > 0,
            .title = session.title_buf[0..session.title_len],
            .default_name = DEFAULT_NAME,
        };
        if (!ai_chat_title.shouldAutoTitle(gate, turn)) break :locked;

        const req = buildTitleRequestLocked(session, turn.?) catch break :locked;
        session.auto_title_attempted = true;
        spawned_req = req;
    }
    session.mutex.unlock();

    const req = spawned_req orelse return;
    const thread = std.Thread.spawn(.{}, titleThreadMain, .{req}) catch {
        req.deinit();
        return;
    };
    session.mutex.lock();
    session.title_thread = thread;
    session.mutex.unlock();
}
```

- [ ] **Step 3: 接线 — agent 完成点**

In `src/ai_chat.zig` `requestThreadMain`, find the agent branch tail (约第 2787 行):

```zig
        appendAssistantResult(request.session, result, request.started_ms);
        return;
    }
```

Change to:

```zig
        appendAssistantResult(request.session, result, request.started_ms);
        maybeAutoTitle(request.session);
        return;
    }
```

- [ ] **Step 4: 接线 — 流式完成点**

In `src/ai_chat.zig` `requestThreadMain`, find the streaming branch tail (约第 2801–2806 行):

```zig
        if (requestCancelled(request)) {
            finishStoppedRequest(request.session);
            return;
        }
        return;
    }
```

Change to:

```zig
        if (requestCancelled(request)) {
            finishStoppedRequest(request.session);
            return;
        }
        maybeAutoTitle(request.session);
        return;
    }
```

- [ ] **Step 5: 接线 — 非流式完成点**

In `src/ai_chat.zig` `requestThreadMain`, find the final (non-streaming) tail (约第 2818–2823 行):

```zig
    if (requestCancelled(request)) {
        finishStoppedRequest(request.session);
        return;
    }
    appendAssistantResult(request.session, result, request.started_ms);
}
```

Change to:

```zig
    if (requestCancelled(request)) {
        finishStoppedRequest(request.session);
        return;
    }
    appendAssistantResult(request.session, result, request.started_ms);
    maybeAutoTitle(request.session);
}
```

- [ ] **Step 6: 编译 + 全套件**

Run: `zig build test-full`
Expected: PASS（编译通过；既有测试不回归）。

- [ ] **Step 7: 手动验证（Windows 开发机，按 AGENTS.md 用真实可见 app）**

1. `zig build`（或 `zig build -Doptimize=ReleaseFast`），启动 `wispterm.exe`。
2. 确保已配置可用的 AI Chat profile（有 API key）。
3. 新建一个 AI Chat tab —— tab 标题应为默认 `DeepSeek`。
4. 发送一条有主题的消息（例如「帮我写一个快速排序的 Python 实现」），等待回复完成。
5. **预期**：回复完成后 ~1 秒内，tab 标题从 `DeepSeek` 变为一个概括主题的简短标题（如「快速排序实现」），语言与对话一致。
6. 手动重命名该 tab（双击/重命名入口）为自定义名；再开新对话并完成一轮 —— 已被你改名的对话标题保持不变，仅新对话被自动命名。
7. 断网或填错 API key 时完成一轮 —— 标题静默保持 `DeepSeek`，无错误弹窗（错误首轮一般因同样故障而静默失败）。

- [ ] **Step 8: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): auto-title conversations after first turn"
```

---

## Self-Review 结果

- **Spec 覆盖**：触发条件（Task 8 `maybeAutoTitle` + Task 3 `shouldAutoTitle`）；首轮提取排除 tool（Task 2）；复用对话配置的精简非流式无工具请求（Task 8 `buildTitleRequestLocked`）；跟随语言（Task 1 `system_prompt`）；独立 `title_thread` + deinit join（Task 6 + Task 8）；标题清理（Task 4）；不覆盖手动命名（Task 7 `setTitleIfDefault`）；失败静默（Task 7 `applyGeneratedTitle` 的 null 分支 + Task 8 `titleThreadMain` 的 `catch return`）；历史恢复不误触发（Task 6）；测试纳入 fast 套件（Task 1–5）。✅ 全覆盖。
- **Placeholder 扫描**：无 TBD/TODO；每个代码步骤含完整代码与确切命令。✅
- **类型一致性**：`FirstTurn` / `TurnMessage` / `TitleGate`（Task 2–3）在 Task 8 使用一致；`cleanTitle(raw, out)`、`buildUserContent(allocator, turn)`、`extractFirstTurn([]const TurnMessage)`、`shouldAutoTitle(gate, turn)` 签名前后一致；`setTitleIfDefault` / `applyGeneratedTitle` / `buildTitleRequestLocked` / `titleThreadMain` / `maybeAutoTitle` 名称跨任务一致。✅

## 线程安全要点（实现时牢记）

- `maybeAutoTitle` 由 `request_thread`（即 `requestThreadMain`）在**锁外**调用；它自己取锁做判定/快照，解锁后再 `spawn`，避免与完成函数的 `defer unlock` 形成自死锁。
- `deinit` 先 `closing.store(true)` → join `request_thread`（此时 `maybeAutoTitle` 已执行完并存好 `title_thread` handle）→ 再 join `title_thread`。`title_thread` 内对 session 的访问都先查 `closing`，并通过 `setTitleIfDefault` 的 mutex 串行化。
- `title_thread` 因 gate 仅 spawn 一次，handle 只赋值一次，不与 `deinit` 的 join 竞争。
