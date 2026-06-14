# WeChat Remote Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a WeChat-remote user answer a copilot approval prompt — reply Y/同意 to approve, N/拒绝 to deny — and get told, immediately, when an approval is pending.

**Architecture:** Intercept WeChat replies in the `weixin/` routing layer (`agent.sendAi`) through two new `Control` methods, so the copilot's blocked approval resolves and the tailored Chinese replies stay in the WeChat domain. Surface the pending approval through the existing remote-snapshot/followup channel so the already-running followup loop pushes a "needs approval" prompt within ~1s.

**Tech Stack:** Zig. Source under `src/`. Tests are in-file `test "…" {}` blocks. Two suites: `zig build test` (fast, native) and `zig build test-full` (full app graph, windows-gnu target — the only suite that compiles `AppWindow.zig` and runs `ai_chat.zig` tests).

Spec: `docs/superpowers/specs/2026-06-05-weixin-remote-approval-design.md`

---

## File Structure

- **Create** `src/weixin/approval_reply.zig` — pure classifier: WeChat reply text → approve/deny/unrecognized.
- **Modify** `src/weixin/reply_progress.zig` — parse an `Approval:` section; add `needs_approval`/tool/command to `Progress`; detect it first.
- **Modify** `src/ai_chat.zig` — `pub resolveApprovalExternal`; emit an `Approval:` section in `allocRemoteSnapshot`.
- **Modify** `src/weixin/control.zig` — two new VTable methods + wrappers.
- **Modify** `src/AppWindow.zig` — UI-thread handlers + vtable wiring for the two methods.
- **Modify** `src/weixin/agent.zig` — `sendAi` approval branch; extend the test `FakeControl`.
- **Modify** `src/weixin/poller.zig` — `ApprovalAnnouncer`; `allocProgressText` returns/format the approval prompt; followup loop announces once, immediately.
- **Modify** `src/weixin/controller.zig` — stub the two new methods in its test `NoopControl`.

Test-fake stubs for the two new `Control` methods live wherever a `Control` vtable is built: `AppWindow.zig` (real), `agent.zig`, `poller.zig`, `controller.zig` (test fakes).

---

## Task 1: Pure WeChat approval-reply classifier

**Files:**
- Create: `src/weixin/approval_reply.zig`
- Modify: `src/test_main.zig` and `src/test_fast.zig` (register the new module so its tests run)

- [ ] **Step 1: Write the module with failing-by-absence tests**

Create `src/weixin/approval_reply.zig`:

```zig
//! Classifies a WeChat reply sent while the copilot is blocked on an approval.
//! Pure (no allocation/IO) so it is unit-tested directly. Whole-message match
//! (trimmed, ASCII-case-insensitive) keeps "我不确定" from matching the "不" deny
//! token.
const std = @import("std");

pub const Decision = enum { approve, deny, unrecognized };

const approve_tokens = [_][]const u8{ "y", "yes", "ok", "同意", "确认", "好", "好的", "可以" };
const deny_tokens = [_][]const u8{ "n", "no", "拒绝", "取消", "不", "不要" };

pub fn classify(text: []const u8) Decision {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return .unrecognized;
    for (approve_tokens) |tok| if (eqWhole(trimmed, tok)) return .approve;
    for (deny_tokens) |tok| if (eqWhole(trimmed, tok)) return .deny;
    return .unrecognized;
}

/// ASCII-case-insensitive whole-string equality. Non-ASCII bytes (the Chinese
/// tokens) compare exactly, which is what we want.
fn eqWhole(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

const t = std.testing;

test "approve tokens, case-insensitive and trimmed" {
    try t.expectEqual(Decision.approve, classify("y"));
    try t.expectEqual(Decision.approve, classify("Y"));
    try t.expectEqual(Decision.approve, classify("  yes \n"));
    try t.expectEqual(Decision.approve, classify("OK"));
    try t.expectEqual(Decision.approve, classify("同意"));
    try t.expectEqual(Decision.approve, classify("确认"));
    try t.expectEqual(Decision.approve, classify("好的"));
    try t.expectEqual(Decision.approve, classify("可以"));
}

test "deny tokens" {
    try t.expectEqual(Decision.deny, classify("n"));
    try t.expectEqual(Decision.deny, classify("NO"));
    try t.expectEqual(Decision.deny, classify("拒绝"));
    try t.expectEqual(Decision.deny, classify("取消"));
    try t.expectEqual(Decision.deny, classify("不"));
    try t.expectEqual(Decision.deny, classify("不要"));
}

test "unrecognized: empty, partial-match, and real instructions" {
    try t.expectEqual(Decision.unrecognized, classify(""));
    try t.expectEqual(Decision.unrecognized, classify("   "));
    try t.expectEqual(Decision.unrecognized, classify("我不确定")); // contains 不 but not whole-match
    try t.expectEqual(Decision.unrecognized, classify("yes please"));
    try t.expectEqual(Decision.unrecognized, classify("先删回收站"));
}
```

- [ ] **Step 2: Register the module so its tests run**

In `src/test_main.zig` and `src/test_fast.zig`, find the block of `_ = @import("weixin/...")` lines (next to `weixin/agent.zig` / `weixin/reply_progress.zig`) and add:

```zig
_ = @import("weixin/approval_reply.zig");
```

If a file does not already import sibling `weixin/*` test modules, add the line next to the other `_ = @import("weixin/...")` entries in that file. (Per repo rule: a Zig test only runs when the file is `_ = @import`ed in `test_fast.zig`/`test_main.zig`.)

- [ ] **Step 3: Run the tests**

Run: `zig build test`
Expected: PASS, including the three new `approval_reply` tests.

- [ ] **Step 4: Commit**

```bash
git add src/weixin/approval_reply.zig src/test_main.zig src/test_fast.zig
git commit -m "feat(weixin): classify remote approval replies

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Detect an `Approval:` section in reply_progress

**Files:**
- Modify: `src/weixin/reply_progress.zig`

- [ ] **Step 1: Write the failing test**

Append to `src/weixin/reply_progress.zig` (in the test block at the bottom):

```zig
test "approval section is detected and takes priority over done/tool branches" {
    const baseline = "Model:\nGLM\n\nStatus:\nReady\n\nYou:\nclean up\n";
    const current =
        "Model:\nGLM\n\nStatus:\nApproval needed\n\n" ++
        "Approval:\nterminal_repl_exec\nrm -rf /tmp/x\n\n" ++
        "You:\nclean up\n\nTool:\nrunning\n\nAI:\npre-tool note\n";
    const p = progress(baseline, current);
    try t.expect(p.needs_approval);
    try t.expect(!p.done);
    try t.expectEqualStrings("terminal_repl_exec", p.approval_tool);
    try t.expectEqualStrings("rm -rf /tmp/x", p.approval_command);
}

test "no approval section leaves needs_approval false" {
    const p = progress("You:\nhi\n", "You:\nhi\nAI:\nthere\nStatus:\nidle\n");
    try t.expect(!p.needs_approval);
    try t.expect(p.done);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `Progress` has no field `needs_approval` (compile error). (Note: `reply_progress.zig` tests are registered in `test_main.zig`, not `test_fast.zig`, so only `test-full` compiles/runs them.)

- [ ] **Step 3: Implement**

In `src/weixin/reply_progress.zig`:

(a) Extend the `Progress` struct:

```zig
pub const Progress = struct {
    done: bool = false,
    text: []const u8 = "",
    needs_approval: bool = false,
    approval_tool: []const u8 = "", // borrows from `current`
    approval_command: []const u8 = "", // borrows from `current`
};
```

(b) Add an `approval` role and label. Change the `Role` enum:

```zig
const Role = enum { metadata, user, assistant, tool, reasoning, approval };
```

In `asLabel`, add the new label before `return null;`:

```zig
    if (eq(name, "Approval")) return .approval;
```

(c) In `progress()`, after `const status = latestStatus(cur_sections);` and **before** the `var last_assistant` block, insert the approval check:

```zig
    for (cur_sections) |s| {
        if (s.role == .approval) {
            var tool = trim(s.content);
            var command: []const u8 = "";
            if (std.mem.indexOfScalar(u8, tool, '\n')) |nl| {
                command = trim(tool[nl + 1 ..]);
                tool = trim(tool[0..nl]);
            }
            return .{
                .needs_approval = true,
                .done = false,
                .approval_tool = tool,
                .approval_command = command,
            };
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `zig build test-full`
Expected: PASS — both new tests and all existing `reply_progress` tests.

- [ ] **Step 5: Commit**

```bash
git add src/weixin/reply_progress.zig
git commit -m "feat(weixin): detect approval section in reply progress

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Expose approval externally + emit it in the remote snapshot

**Files:**
- Modify: `src/ai_chat.zig` (around lines 1368–1410 and 1458–1467)
- Test: in-file (runs under `zig build test-full`)

- [ ] **Step 1: Write the failing test**

Add near the other `allocRemoteSnapshot` tests (after the test at ai_chat.zig:5308). It uses the lightweight `Session{ .allocator = … }` pattern and sets the private approval fields directly (same-file test access):

```zig
test "ai chat remote snapshot includes a pending approval section" {
    const allocator = std.testing.allocator;
    var session = Session{ .allocator = allocator };
    defer {
        for (session.messages.items) |msg| msg.deinit(allocator);
        session.messages.deinit(allocator);
    }
    try session.messages.append(allocator, .{
        .role = .user,
        .content = try allocator.dupe(u8, "clean up"),
    });

    const tool = "terminal_repl_exec";
    const command = "rm -rf /tmp/x";
    @memcpy(session.approval_tool_buf[0..tool.len], tool);
    session.approval_tool_len = tool.len;
    @memcpy(session.approval_command_buf[0..command.len], command);
    session.approval_command_len = command.len;
    session.approval_pending = true;
    session.approval_resolved = false;

    const with = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(with);
    try std.testing.expect(std.mem.indexOf(u8, with, "Approval:") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "terminal_repl_exec") != null);
    try std.testing.expect(std.mem.indexOf(u8, with, "rm -rf /tmp/x") != null);

    // Once resolved, the section disappears.
    try std.testing.expect(session.resolveApprovalExternal(true));
    const without = try session.allocRemoteSnapshot(allocator);
    defer allocator.free(without);
    try std.testing.expect(std.mem.indexOf(u8, without, "Approval:") == null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `resolveApprovalExternal` is not defined.

- [ ] **Step 3: Implement `resolveApprovalExternal`**

In `src/ai_chat.zig`, immediately after the private `resolveApproval` fn (ends at line 1467), add a public wrapper:

```zig
    /// Resolve a pending approval from a remote driver (e.g. the WeChat bridge),
    /// mirroring the local handleApprovalKey path. Returns true if there was a
    /// pending approval to resolve.
    pub fn resolveApprovalExternal(self: *Session, approve: bool) bool {
        return self.resolveApproval(approve);
    }
```

- [ ] **Step 4: Implement the snapshot `Approval:` section**

In `allocRemoteSnapshot` (starts at ai_chat.zig:1368), capture the approval fields **before** locking `self.mutex`, then emit the section after `Status`. Replace the top of the function:

```zig
    pub fn allocRemoteSnapshot(self: *Session, allocator: std.mem.Allocator) ![]u8 {
        // Capture any pending approval under approval_mutex BEFORE taking
        // self.mutex (sequential locks, never nested — no reverse ordering
        // exists, so this cannot deadlock).
        var cap_tool_buf: [64]u8 = undefined;
        var cap_cmd_buf: [1024]u8 = undefined;
        var cap_tool: []const u8 = "";
        var cap_command: []const u8 = "";
        {
            self.approval_mutex.lock();
            defer self.approval_mutex.unlock();
            if (self.approval_pending and !self.approval_resolved) {
                const tl = self.approval_tool_len;
                @memcpy(cap_tool_buf[0..tl], self.approval_tool_buf[0..tl]);
                cap_tool = cap_tool_buf[0..tl];
                const cl = self.approval_command_len;
                @memcpy(cap_cmd_buf[0..cl], self.approval_command_buf[0..cl]);
                cap_command = cap_cmd_buf[0..cl];
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try appendLimitedSection(allocator, &out, "Model", self.model(), REMOTE_SNAPSHOT_MAX_BYTES);
        try appendLimitedSection(allocator, &out, "Status", self.status(), REMOTE_SNAPSHOT_MAX_BYTES);

        if (cap_tool.len != 0) {
            var approval_text: std.ArrayListUnmanaged(u8) = .empty;
            defer approval_text.deinit(allocator);
            try approval_text.appendSlice(allocator, cap_tool);
            if (cap_command.len != 0) {
                try approval_text.append(allocator, '\n');
                try approval_text.appendSlice(allocator, cap_command);
            }
            try appendLimitedSection(allocator, &out, "Approval", approval_text.items, REMOTE_SNAPSHOT_MAX_BYTES);
        }
```

Leave the rest of the function (the `var sections …` block onward) unchanged.

- [ ] **Step 5: Run to verify pass**

Run: `zig build test-full`
Expected: PASS — the new snapshot test and all existing `ai_chat` tests.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(ai-chat): expose approval + emit it in remote snapshot

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Add the Control approval seam (interface + all implementers)

This task adds two methods to the `Control` vtable. Every implementer must be
updated in the same commit or the build breaks.

**Files:**
- Modify: `src/weixin/control.zig`
- Modify: `src/AppWindow.zig` (real implementation + wiring)
- Modify: `src/weixin/controller.zig` (test `NoopControl`)
- Modify: `src/weixin/poller.zig` (test `NoopControl`)
- Modify: `src/weixin/agent.zig` (test `FakeControl` — minimal stub; real behavior in Task 5)

- [ ] **Step 1: Extend the interface**

In `src/weixin/control.zig`, add to `VTable` (after `latest_transcript`):

```zig
        ai_approval_pending: *const fn (ctx: *anyopaque) bool,
        resolve_ai_approval: *const fn (ctx: *anyopaque, approve: bool) bool,
```

And add wrappers after `latestTranscript`:

```zig
    pub fn aiApprovalPending(self: Control) bool {
        return self.vtable.ai_approval_pending(self.ctx);
    }
    pub fn resolveAiApproval(self: Control, approve: bool) bool {
        return self.vtable.resolve_ai_approval(self.ctx, approve);
    }
```

- [ ] **Step 2: Implement in AppWindow (the real path)**

In `src/AppWindow.zig`:

(a) Extend the `WeixinRequest.op` enum (line 3232) and add an `approve` input field:

```zig
    op: enum { find_ai, find_term, open_ai, send_input, latest_transcript, ai_approval_pending, resolve_ai_approval },
```

Add after the `reply_context` field (around line 3236):

```zig
    approve: bool = false,
```

(b) In `handleWeixinControlRequest` (the `switch (req.op)`), add two cases before the closing brace of the switch (after the `.latest_transcript` case at ~line 3345):

```zig
        .ai_approval_pending => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            if (tab_state.kind != .ai_chat) return;
            const session = tab_state.ai_chat_session orelse return;
            req.found = session.approvalView() != null;
        },
        .resolve_ai_approval => {
            const idx = weixinActiveAiTabIndex() orelse return;
            const tab_state = tab.g_tabs[idx] orelse return;
            if (tab_state.kind != .ai_chat) return;
            const session = tab_state.ai_chat_session orelse return;
            req.sent = session.resolveApprovalExternal(req.approve);
            if (req.sent) g_force_rebuild = true;
        },
```

(c) Add the two vtable functions next to `wxTranscript` (after line 3396):

```zig
fn wxAiApprovalPending(_: *anyopaque) bool {
    var req = WeixinRequest{ .op = .ai_approval_pending };
    if (!weixinDispatch(&req)) return false;
    return req.found;
}

fn wxResolveAiApproval(_: *anyopaque, approve: bool) bool {
    var req = WeixinRequest{ .op = .resolve_ai_approval, .approve = approve };
    if (!weixinDispatch(&req)) return false;
    return req.sent;
}
```

(d) Register them in `weixin_vtable` (after `.send_input` / `.latest_transcript`, line 3398):

```zig
    .ai_approval_pending = wxAiApprovalPending,
    .resolve_ai_approval = wxResolveAiApproval,
```

- [ ] **Step 3: Stub the test NoopControls**

In `src/weixin/controller.zig`, in `NoopControl` (around line 485), add two functions:

```zig
    fn ai_approval_pending(_: *anyopaque) bool {
        return false;
    }
    fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
        return false;
    }
```

and register them in its `.{ .ctx = &dummy, .vtable = &.{ … } }` (after `.latest_transcript = latest_transcript,`):

```zig
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
```

In `src/weixin/poller.zig`, in its `NoopControl` (around line 665), add:

```zig
    fn aiApprovalPending(_: *anyopaque) bool {
        return false;
    }
    fn resolveAiApproval(_: *anyopaque, _: bool) bool {
        return false;
    }
```

and register in its vtable (after `.latest_transcript = latestTranscript,`):

```zig
            .ai_approval_pending = aiApprovalPending,
            .resolve_ai_approval = resolveAiApproval,
```

In `src/weixin/agent.zig`, in `FakeControl` (around line 149), add minimal stubs:

```zig
    fn ai_approval_pending(_: *anyopaque) bool {
        return false;
    }
    fn resolve_ai_approval(_: *anyopaque, _: bool) bool {
        return false;
    }
```

and register in `control_iface` (after `.send_input = send_input,` / `.latest_transcript = latest_transcript,`):

```zig
            .ai_approval_pending = ai_approval_pending,
            .resolve_ai_approval = resolve_ai_approval,
```

- [ ] **Step 4: Verify both suites compile and pass**

Run: `zig build test`
Expected: PASS.

Run: `zig build test-full`
Expected: PASS (this is the suite that compiles `AppWindow.zig` for windows-gnu and catches any vtable mismatch).

- [ ] **Step 5: Commit**

```bash
git add src/weixin/control.zig src/AppWindow.zig src/weixin/controller.zig src/weixin/poller.zig src/weixin/agent.zig
git commit -m "feat(weixin): add approval query/resolve to the control seam

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: Route WeChat Y/N into the approval (agent.sendAi)

**Files:**
- Modify: `src/weixin/agent.zig`

- [ ] **Step 1: Make the test FakeControl model a real approval**

In `src/weixin/agent.zig`, replace the Task-4 stub fields/functions in `FakeControl` with stateful ones. Add fields near the top of `FakeControl` (after `last_reply_context`):

```zig
    approval_pending: bool = false,
    resolved_calls: u8 = 0,
    last_resolve_approve: bool = false,
```

Replace the two stub functions with:

```zig
    fn ai_approval_pending(ctx: *anyopaque) bool {
        return cast(ctx).approval_pending;
    }
    fn resolve_ai_approval(ctx: *anyopaque, approve: bool) bool {
        const self = cast(ctx);
        if (!self.approval_pending) return false;
        self.approval_pending = false;
        self.resolved_calls += 1;
        self.last_resolve_approve = approve;
        return true;
    }
```

(The `control_iface` registration from Task 4 already points at these names.)

- [ ] **Step 2: Write the failing tests**

Add to the test block in `src/weixin/agent.zig`:

```zig
test "approval pending: Y approves, acks, and streams progress" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "Y", null, &out);
    try t.expectEqual(@as(u8, 1), fake.resolved_calls);
    try t.expect(fake.last_resolve_approve);
    try t.expectEqualStrings("已确认，继续执行。", out.text.items);
    try t.expect(out.expect_ai_progress);
}

test "approval pending: 拒绝 denies and streams the continuation" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "拒绝", null, &out);
    try t.expectEqual(@as(u8, 1), fake.resolved_calls);
    try t.expect(!fake.last_resolve_approve);
    try t.expectEqualStrings("已拒绝该操作。", out.text.items);
    try t.expect(out.expect_ai_progress);
}

test "approval pending: unrecognized reply reminds without acting" {
    var fake = FakeControl{ .approval_pending = true };
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "先删回收站", null, &out);
    try t.expectEqual(@as(u8, 0), fake.resolved_calls);
    try t.expect(!out.expect_ai_progress);
    try t.expect(std.mem.indexOf(u8, out.text.items, "请先回复") != null);
    // The unrecognized text must NOT be forwarded to the composer.
    try t.expectEqual(@as(usize, 0), fake.len);
}

test "no approval pending: default text still goes to the AI surface" {
    var fake = FakeControl{}; // approval_pending defaults false
    var out = Reply.init(t.allocator);
    defer out.deinit();
    try route(t.allocator, fake.control_iface(), defaultSettings(), "hello world", null, &out);
    try t.expectEqualStrings("hello world\r", fake.lastInput());
    try t.expect(out.expect_ai_progress);
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — the approval-pending replies don't match (sendAi still sends normally). (Note: `agent.zig` tests are registered in `test_main.zig`, not `test_fast.zig`.)

- [ ] **Step 4: Implement the sendAi branch**

In `src/weixin/agent.zig`, add the import near the top (after `const types = @import("types.zig");`):

```zig
const approval_reply = @import("approval_reply.zig");
```

Then, in `sendAi` (starts line 89), insert the approval branch as the **first** thing after the AI surface is resolved (right after the `const ai = … orelse blk: { … };` block, before the `var buf` line):

```zig
    if (ctrl.aiApprovalPending()) {
        switch (approval_reply.classify(text)) {
            .approve => {
                _ = ctrl.resolveAiApproval(true);
                try out.set("已确认，继续执行。");
                out.expect_ai_progress = true;
            },
            .deny => {
                _ = ctrl.resolveAiApproval(false);
                try out.set("已拒绝该操作。");
                out.expect_ai_progress = true;
            },
            .unrecognized => try out.set("当前有待确认操作，请先回复 Y 同意 / N 拒绝。"),
        }
        return;
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `zig build test-full`
Expected: PASS — all four new tests plus existing agent tests.

- [ ] **Step 6: Commit**

```bash
git add src/weixin/agent.zig
git commit -m "feat(weixin): route remote Y/N into the copilot approval

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Announce a pending approval to WeChat immediately

**Files:**
- Modify: `src/weixin/poller.zig`

- [ ] **Step 1: Write the failing tests**

Add to the test block in `src/weixin/poller.zig`:

```zig
test "approval announcer fires once per pending episode and resets" {
    var a = ApprovalAnnouncer{};
    try t.expect(!a.due(false));
    try t.expect(a.due(true)); // first pending tick → send
    try t.expect(!a.due(true)); // still pending → silent
    try t.expect(!a.due(false)); // cleared → reset
    try t.expect(a.due(true)); // new pending episode → send again
}

const ApprovalTranscriptControl = struct {
    fn isConnected(_: *anyopaque) bool {
        return true;
    }
    fn findAiSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn findTerminalSurface(_: *anyopaque) ?control_mod.Surface {
        return null;
    }
    fn openAiAgent(_: *anyopaque, _: u32) control_mod.OpenResult {
        return .offline;
    }
    fn sendInput(_: *anyopaque, _: [16]u8, _: []const u8, _: ?types.ReplyContext) bool {
        return false;
    }
    fn latestTranscript(_: *anyopaque) []const u8 {
        return "Model:\nGLM\n\nStatus:\nApproval needed\n\n" ++
            "Approval:\nterminal_repl_exec\nrm -rf /tmp/x\n\nYou:\nclean up\n";
    }
    fn aiApprovalPending(_: *anyopaque) bool {
        return true;
    }
    fn resolveAiApproval(_: *anyopaque, _: bool) bool {
        return false;
    }
    var dummy: u8 = 0;
    fn iface() control_mod.Control {
        return .{ .ctx = &dummy, .vtable = &.{
            .is_connected = isConnected,
            .find_ai_surface = findAiSurface,
            .find_terminal_surface = findTerminalSurface,
            .open_ai_agent = openAiAgent,
            .send_input = sendInput,
            .latest_transcript = latestTranscript,
            .ai_approval_pending = aiApprovalPending,
            .resolve_ai_approval = resolveAiApproval,
        } };
    }
};

test "allocProgressText surfaces a needs-approval prompt naming the command" {
    const empty_sync = try t.allocator.alloc(u8, 0);
    defer t.allocator.free(empty_sync);
    var p = Poller{
        .allocator = t.allocator,
        .client = undefined, // unused by allocProgressText
        .control = ApprovalTranscriptControl.iface(),
        .settings = .{},
        .owner = "u1",
        .account_id = "",
        .sync_buf = empty_sync,
    };
    const r = try p.allocProgressText("Model:\nGLM\n\nStatus:\nReady\n\nYou:\nclean up\n");
    defer if (r.text.len != 0) t.allocator.free(r.text);
    try t.expect(r.needs_approval);
    try t.expect(!r.done);
    try t.expect(std.mem.indexOf(u8, r.text, "rm -rf /tmp/x") != null);
    try t.expect(std.mem.indexOf(u8, r.text, "回复 Y 同意 / N 拒绝") != null);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `ApprovalAnnouncer` undefined; `allocProgressText` has no `needs_approval` field. (Note: `poller.zig` tests are registered in `test_main.zig`, not `test_fast.zig`.)

- [ ] **Step 3: Add the ApprovalAnnouncer helper**

In `src/weixin/poller.zig`, next to `ProgressSchedule` (after its definition ~line 529), add:

```zig
/// Tracks "announce a pending approval exactly once per episode". The followup
/// loop calls due() every tick with the current needs_approval flag: it returns
/// true on the first tick a new approval appears, false while it persists, and
/// resets when the approval clears so a later approval re-announces.
const ApprovalAnnouncer = struct {
    announced: bool = false,

    fn due(self: *ApprovalAnnouncer, needs_approval: bool) bool {
        if (!needs_approval) {
            self.announced = false;
            return false;
        }
        if (self.announced) return false;
        self.announced = true;
        return true;
    }
};
```

- [ ] **Step 4: Extend allocProgressText**

Replace `allocProgressText` (starts line 489) with:

```zig
    fn allocProgressText(self: *Poller, baseline_transcript: []const u8) !struct { done: bool, needs_approval: bool, text: []u8 } {
        self.transcript_mutex.lock();
        defer self.transcript_mutex.unlock();

        const current = self.control.latestTranscript();
        const progress_value = reply_progress.progress(baseline_transcript, current);
        if (progress_value.needs_approval) {
            const subject = if (progress_value.approval_command.len != 0)
                progress_value.approval_command
            else
                progress_value.approval_tool;
            const clipped = subject[0..@min(subject.len, 400)];
            const text = try std.fmt.allocPrint(
                self.allocator,
                "⚠️ 副驾需要你确认是否执行：\n{s}\n\n回复 Y 同意 / N 拒绝。",
                .{clipped},
            );
            return .{ .done = false, .needs_approval = true, .text = text };
        }
        if (progress_value.text.len == 0) return .{ .done = progress_value.done, .needs_approval = false, .text = &.{} };
        return .{
            .done = progress_value.done,
            .needs_approval = false,
            .text = try self.allocator.dupe(u8, progress_value.text),
        };
    }
```

- [ ] **Step 5: Wire the announce into followupThreadMain**

In `followupThreadMain` (starts line 429), add the announcer state and handle the approval branch. Add after `var elapsed_ms: u64 = 0;` (line 436):

```zig
        var announcer = ApprovalAnnouncer{};
```

Then, inside the `while` loop, replace the block from `const progress = self.allocProgressText(...)` through the end of the `if (schedule.pingDue(...))` block with:

```zig
            const progress = self.allocProgressText(job.baseline_transcript) catch continue;
            defer if (progress.text.len != 0) self.allocator.free(progress.text);

            const announce_now = announcer.due(progress.needs_approval);
            if (progress.needs_approval) {
                if (announce_now and progress.text.len != 0) {
                    std.debug.print(
                        "weixin send({d}): kind=ai_approval generation={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                        .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                    );
                    self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                        std.debug.print("weixin send({d}): kind=ai_approval generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    };
                }
                continue;
            }

            if (progress.done and progress.text.len != 0) {
                std.debug.print(
                    "weixin send({d}): kind=ai_final generation={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                    .{ debugNowMs(), generation, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                );
                self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                    std.debug.print("weixin send({d}): kind=ai_final generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    return;
                };
                std.debug.print("weixin send({d}): kind=ai_final generation={d} status=sent bytes={d}\n", .{ debugNowMs(), generation, progress.text.len });
                return;
            }

            if (schedule.pingDue(elapsed_ms) and progress.text.len != 0) {
                std.debug.print(
                    "weixin send({d}): kind=ai_progress generation={d} elapsed_ms={d} to_len={d} to_hash={x} bytes={d} context={}\n",
                    .{ debugNowMs(), generation, elapsed_ms, job.to_user_id.len, debugHash(job.to_user_id), progress.text.len, job.context_token.len != 0 },
                );
                self.sendTextLocked(job.to_user_id, progress.text, job.context_token) catch |err| {
                    std.debug.print("weixin send({d}): kind=ai_progress generation={d} status=failed err={}\n", .{ debugNowMs(), generation, err });
                    continue;
                };
                std.debug.print("weixin send({d}): kind=ai_progress generation={d} status=sent bytes={d}\n", .{ debugNowMs(), generation, progress.text.len });
            }
```

(Only the `progress` handling changes; the surrounding `while` condition, `sleep`, `elapsed_ms += …`, and the post-loop window-expired notice stay as-is. Note `allocProgressText`'s return type now has three fields, which is why the `progress.done`/`progress.text` reads still compile.)

- [ ] **Step 6: Run to verify pass**

Run: `zig build test-full`
Expected: PASS — both new poller tests plus existing ones.

- [ ] **Step 7: Commit**

```bash
git add src/weixin/poller.zig
git commit -m "feat(weixin): push an approval prompt to WeChat immediately

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Fast suite**

Run: `zig build test`
Expected: PASS, 0 failed.

- [ ] **Step 2: Full suite (compiles AppWindow for windows-gnu; runs ai_chat tests)**

Run: `zig build test-full`
Expected: PASS, 0 failed.

- [ ] **Step 3: Confirm the production Windows build links**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: builds with no errors (proves the new vtable methods are wired into the real `weixin_vtable`).

- [ ] **Step 4: GUI verification note**

GUI smoke test cannot run on this Linux host (no GUI backend; WeChat bridge is Windows-only at runtime). Record GUI verification as pending. Manual check on Windows:
1. From WeChat, send an instruction that triggers a tool approval in the copilot.
2. Confirm WeChat receives "⚠️ 副驾需要你确认是否执行：…回复 Y 同意 / N 拒绝。" within ~1–2s.
3. Reply `Y` → the copilot proceeds and the result streams back; reply `N` → "已拒绝该操作。"; reply an unrelated message → "当前有待确认操作，请先回复 Y 同意 / N 拒绝。" and the approval stays pending.

---

## Self-review notes

- **Spec coverage:** Part A (inbound Y/N) = Tasks 1, 4, 5; Part B (immediate notification) = Tasks 2, 3, 6. "Remind, don't act" = Task 5 unrecognized branch (asserts no resolve, no composer write). Vocabulary = Task 1. Snapshot lock ordering = Task 3 comment. Re-announce avoidance (synchronous resolve) = covered by Task 4's synchronous marshaling + Task 6's reset-on-clear.
- **Out of scope (per spec):** the generic web-remote `applyRemoteInput` approval path is intentionally untouched.
- **Type consistency:** `Decision{approve,deny,unrecognized}`, `Progress.needs_approval/approval_tool/approval_command`, `Control.aiApprovalPending()/resolveAiApproval(bool)`, `Session.resolveApprovalExternal(bool)`, `ApprovalAnnouncer.due(bool)`, `allocProgressText → {done, needs_approval, text}` are used identically across tasks.
