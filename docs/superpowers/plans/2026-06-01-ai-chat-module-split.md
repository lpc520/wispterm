# ai_chat.zig Module Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the 8283-line `src/ai_chat.zig` into focused modules — skills loading, a `Session`-free tool layer, the request/streaming layer, and folded-in stream-parse/markdown — leaving `Session` as the ~3000-line core.

**Architecture:** Four sequential, independently-green relocation steps on one branch. Skills/markdown become leaf modules; the tool layer becomes a true leaf behind a narrow `ToolContext` seam; the request layer uses mutual import (intrinsic `Session` coupling). Stream-parsing folds into the existing `ai_chat_protocol.zig`. Tests travel with the code they cover.

**Tech Stack:** Zig (`zig build test` = fast native suite, `zig build test-full` = full app graph). Spec: `docs/superpowers/specs/2026-06-01-ai-chat-module-split-design.md`.

---

## Conventions for every task

- **This is relocation, not rewrite.** When a step says "move decl `foo`", cut the
  declaration *verbatim* (signature + body + any preceding doc-comment) from
  `ai_chat.zig` and paste it into the target file unchanged. Do not edit logic.
- **Reference decls by name, not line number.** Line numbers in this plan are
  approximate locators from the pre-Step-1 file and drift after each step. Use
  `grep -n "fn <name>" src/ai_chat.zig` to find the current location.
- **`pub` promotion:** a moved decl that is still called from `ai_chat.zig` (or
  another module) must become `pub`. A decl that is only called from within its
  new module stays private.
- **Green gate:** before starting and after finishing every task, run:
  ```
  zig build test && zig build test-full
  ```
  Expected: both exit 0. Baseline ~673+/677 passed, 4 skipped, 0 failed.
  Never proceed to the next task with a red suite.
- **One commit per task**, message prefix `refactor(ai-chat):`.

---

## Task 0: Baseline verification

**Files:** none (verification only)

- [ ] **Step 1: Confirm clean tree and branch**

Run: `git status --short && git rev-parse --abbrev-ref HEAD`
Expected: no uncommitted changes except already-committed plan/spec docs; branch `worktree-feat-refactor-ai-chat`.

- [ ] **Step 2: Establish the green baseline**

Run: `zig build test && zig build test-full`
Expected: both exit 0. Record the pass/skip counts as the baseline to preserve.

---

## Task 1: Extract `ai_chat_skills.zig` (leaf)

**Files:**
- Create: `src/ai_chat_skills.zig`
- Modify: `src/ai_chat.zig` (remove decls, add import, rewrite callers)
- Modify: `src/test_main.zig` (register new module import)

**Decls to move** (skill/command root loading + slash output; all currently private, ~lines 458–747):
`slashCommandOutput`, `permissionStatusOutput`, `slashCommandListOutput`,
`listSkillsForDisplay`, `listSkillsForDisplayFromRoots`,
`loadSkillSuggestionListFromRoots`, `loadSkillPreloadContent`,
`loadSkillPreloadContentFromRoots`, `loadSkillSnapshotFromRoots`,
`SkillRoot` (struct), `openSkillRoot`, `openDirectoryPath`,
`defaultSkillRootPaths`, `defaultCommandRootPaths`, `appendSkillRootPath`,
`appendOwnedSkillRootPath`, `freeSkillRootPaths`, `knownActionFromName`,
`isBuiltinCommandName`, `hasName`, `freeOwnedSkillMetaList`,
`skillMetaNameExists`, `skillMetaNameLessThan`.

**Tests to move** (with the code): `slashCommandOutput covers new lifecycle commands`,
`isBuiltinCommandName recognizes built-in slash commands only`,
`session loads custom commands from a commands directory` (only if it does not
touch `Session` — verify; if it does, leave it in `ai_chat.zig` and call
`ai_chat_skills.*`), `ai chat lists skills from explicit root paths`,
`ai chat default skill roots include plugin skills directory`.

- [ ] **Step 1: Verify the move-set is leaf**

Run: `grep -nE "Session|ChatRequest|Message" src/ai_chat.zig | awk -F: '$1>=458 && $1<=747'`
Expected: no matches referencing `Session`/`ChatRequest`/`Message` (only `SkillRoot.deinit`'s own `self`). If any appear, stop and reassess — that decl is not leaf.

- [ ] **Step 2: Create `src/ai_chat_skills.zig` with imports**

Header of the new file (the moved decls follow, made `pub` where called from `ai_chat.zig`):
```zig
const std = @import("std");
const skill_registry = @import("skill_registry.zig");
const command_registry = @import("command_registry.zig");
const platform_dirs = @import("platform/dirs.zig");
const ai_chat_composer = @import("ai_chat_composer.zig");

const SlashCommand = ai_chat_composer.SlashCommand;
```
Then paste the moved decls verbatim. Promote to `pub` the ones called from
`ai_chat.zig`: `slashCommandOutput`, `defaultSkillRootPaths`,
`defaultCommandRootPaths`, `knownActionFromName`, `isBuiltinCommandName`,
`hasName`, `listSkillsForDisplayFromRoots`, `loadSkillPreloadContent`,
`loadSkillSnapshotFromRoots`, plus any other still referenced from `ai_chat.zig`
(resolve by compile errors in Step 4).

- [ ] **Step 3: Remove moved decls from `ai_chat.zig` and add import**

Delete the moved declarations and their moved tests from `ai_chat.zig`. Add near
the other `ai_chat_*` imports:
```zig
const ai_chat_skills = @import("ai_chat_skills.zig");
```
Rewrite the in-file callers (Session methods near lines 1118/1163/1173/1179/1750/1786/1940
and the tool fn near 3928) to `ai_chat_skills.<name>(...)`. The `applyPermissionArg`
comment at ~line 428 needs no code change.

- [ ] **Step 4: Compile-resolve `pub` surface**

Run: `zig build test 2>&1 | head -40`
Expected initially: errors like `'<name>' is not marked 'pub'` or `use of undeclared identifier`. For each, either add `pub` to the decl in `ai_chat_skills.zig` or fix the caller to `ai_chat_skills.<name>`. Repeat until it compiles.

- [ ] **Step 5: Register the module for tests**

In `src/test_main.zig`, next to `_ = @import("ai_chat.zig");`, add:
```zig
_ = @import("ai_chat_skills.zig");
```

- [ ] **Step 6: Green gate**

Run: `zig build test && zig build test-full`
Expected: both exit 0, counts match baseline (moved tests now run from the new module).

- [ ] **Step 7: Commit**

```bash
git add src/ai_chat_skills.zig src/ai_chat.zig src/test_main.zig
git commit -m "refactor(ai-chat): extract skill/command loading into ai_chat_skills.zig"
```

---

## Task 2: Extract `ai_chat_types.zig` + `ai_chat_tools.zig` with `ToolContext` seam

This is the decoupling payoff. Sub-task 2A introduces the shared type module and
the seam (true new code, TDD). Sub-task 2B relocates the tool implementations.

### Task 2A: `ai_chat_types.zig` + `ToolContext`

**Files:**
- Create: `src/ai_chat_types.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/test_main.zig`

**Types to move** to `ai_chat_types.zig` (currently `pub` in `ai_chat.zig`, ~lines 124–334):
`AgentSettings`, `ToolSurface`, `ToolSnapshot`, `ToolClosedTab`,
`SshProfileSaveArgs`, `SavedSshProfile`, `ToolHost`, `WeixinReplyContext`,
`ApprovalView`. (Keep `ChatRequest` in `ai_chat.zig` — it holds `*Session`.)

- [ ] **Step 1: Create `src/ai_chat_types.zig`**

```zig
const std = @import("std");
const weixin_types = @import("weixin/types.zig");
```
Paste the listed type decls verbatim (keep them `pub`). Then add the seam:
```zig
/// Narrow context handed to the tool layer so it never touches `Session`.
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    ctx: *anyopaque, // opaque Session; only the callbacks below dereference it
    tool_host: ?ToolHost,
    tool_snapshot: ?ToolSnapshot,
    settings: AgentSettings,
    copilot: bool = false,
    weixin_reply_context: ?WeixinReplyContext = null,
    write_context_surface_id: [64]u8 = undefined,
    write_context_surface_id_len: usize = 0,

    approve: *const fn (ctx: *anyopaque, tool: []const u8, command: []const u8, reason: []const u8) bool,
    cancelled: *const fn (ctx: *anyopaque) bool,

    pub fn requestApproval(self: *ToolContext, tool: []const u8, command: []const u8, reason: []const u8) bool {
        return self.approve(self.ctx, tool, command, reason);
    }
    pub fn isCancelled(self: *const ToolContext) bool {
        return self.cancelled(self.ctx);
    }
    pub fn writeContextSurfaceId(self: *const ToolContext) ?[]const u8 {
        if (self.write_context_surface_id_len == 0) return null;
        return self.write_context_surface_id[0..self.write_context_surface_id_len];
    }
};
```

- [ ] **Step 2: Re-export types from `ai_chat.zig` (no external API change)**

In `ai_chat.zig`, replace the moved type definitions with re-exports so
`App.zig`/`AppWindow.zig`/`config.zig` are unaffected:
```zig
const ai_chat_types = @import("ai_chat_types.zig");
pub const AgentSettings = ai_chat_types.AgentSettings;
pub const ToolSurface = ai_chat_types.ToolSurface;
pub const ToolSnapshot = ai_chat_types.ToolSnapshot;
pub const ToolClosedTab = ai_chat_types.ToolClosedTab;
pub const SshProfileSaveArgs = ai_chat_types.SshProfileSaveArgs;
pub const SavedSshProfile = ai_chat_types.SavedSshProfile;
pub const ToolHost = ai_chat_types.ToolHost;
pub const ApprovalView = ai_chat_types.ApprovalView;
const WeixinReplyContext = ai_chat_types.WeixinReplyContext;
pub const ToolContext = ai_chat_types.ToolContext;
```

- [ ] **Step 3: Register and green gate**

Add `_ = @import("ai_chat_types.zig");` to `src/test_main.zig`.
Run: `zig build test && zig build test-full`
Expected: both exit 0 (pure type relocation; no behavior change yet).

- [ ] **Step 4: Commit**

```bash
git add src/ai_chat_types.zig src/ai_chat.zig src/test_main.zig
git commit -m "refactor(ai-chat): extract shared tool types + ToolContext seam"
```

### Task 2B: `ai_chat_tools.zig`

**Files:**
- Create: `src/ai_chat_tools.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/test_main.zig`
- Modify: `src/test_main.zig` compile-guards (the `@embedFile("ai_chat.zig")` source scans)

**Decls to move** (the tool layer, ~lines 3780–5145, by name):
`executeToolCall`, `parseArgs`, `jsonStringArg`, `jsonIntArg`, `jsonIndexArg`,
`skillInfoTool`, `skillInfoToolFromRoots`, `wisptermDocsTool`,
`weixinSendAttachmentTool`, `toolSurfaceKind`, `terminalListTool`,
`terminalSnapshotTool`, `terminalSelectTool`, `collectToolSnapshot`,
`rememberConnectedSurface`, `rememberClosedTab`, `localCommandExecTool`,
`ShellResult`, `runShellCommand`, `CaptureOutput`, `runArgv`,
`captureOutputThread`, `UnixSessionKind`, `agentAppDisplayName`,
`agentAppReplName`, `shellExecAgentAppRefusal`, `commandWordApp`,
`commandHasNonInteractiveAgentFlag`, `shellExecInteractiveAgentCommandRefusal`,
`sshSessionExecTool`, `wslSessionExecTool`, `ReplKind`, `terminalReplExecTool`,
`plainReplSubmitKey`, `allocPlainReplInput`, `plainReplInputTool`,
`agentAppStateIsTerminal`, `replSnapshotLooksBusy`, `allocAgentAppReplResult`,
`waitForAgentAppReplResult`, `rSessionEvalTool`, `pythonSessionEvalTool`,
`rStringLiteral`, `pythonStringLiteral`, `doubleQuotedStringLiteral`,
`unixSessionExecTool`, `waitForSentinelResult`, `sshProfileSaveApprovalText`,
`sshProfileSaveTool`, `sshProfileConnectTool`, `tabNewTool`, `tabCloseTool`,
`findSurface`, `buildCopilotContext`, `selectedWriteContext`, `setWriteContext`,
`defaultExecSurfaceId`, `ensureWriteContext`, `extractUnixCommandResult`,
`deniedResult`, `truncateOwned`, `DANGEROUS_COMMAND_APPROVAL_REASON`,
`isDangerousCommand`, `containsWord`, `isWordChar`.

**Signature change (the seam):** every tool fn currently taking `request: *ChatRequest`
or `request: *const ChatRequest` changes to take `ctx: *ToolContext` /
`ctx: *const ToolContext`. Mechanical replacements inside the moved bodies:
- `request.allocator` → `ctx.allocator`
- `request.tool_host` → `ctx.tool_host`
- `request.tool_snapshot` → `ctx.tool_snapshot`
- `request.weixin_reply_context` → `ctx.weixin_reply_context`
- `request.copilot` → `ctx.copilot`
- `request.session.requestApproval(t, c, r)` → `ctx.requestApproval(t, c, r)`
- `sessionCancelled(request.session)` → `ctx.isCancelled()`
- `currentAgentSettings()` → `ctx.settings`
- `currentToolHost()` → `ctx.tool_host` (verify each call site's intent)
- write-context buffer reads/writes → `ctx.write_context_surface_id*` /
  `ctx.writeContextSurfaceId()`

**Tests to move** (tool-layer tests; verify each is `Session`-free after the seam,
otherwise adapt to build a `ToolContext`): `buildCopilotContext keeps cwd...`,
`buildCopilotContext truncates...`, `ai chat tools prefer request-local terminal snapshot`,
`ai chat write context requires explicit selection...`, `terminal_list shows one-based tab numbers...`,
`copilot session pre-targets the bound surface...`, `shell exec refuses interactive Codex...`,
`wsl_session_exec refuses to paste shell wrapper...`, `ai chat R string literal...`,
`ai chat REPL kind parses...`, `ai chat Codex running REPL input queues...`,
`Claude Code REPL input waits for app state...`, `ai chat Python string literal...`,
`ai chat detects dangerous shell commands`, `ai chat ssh profile save approval text redacts password`,
`weixin_send_attachment...` (both), `wispterm_docs tool...` (all three),
`ai chat skill_info loads from explicit root paths`.

- [ ] **Step 1: Write a `Session`-free isolation test FIRST (proves the seam)**

In `src/ai_chat_tools.zig` (create it with this test before moving bodies), add a
fake-context test:
```zig
const std = @import("std");
const types = @import("ai_chat_types.zig");

fn fakeApprove(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) bool {
    return true;
}
fn fakeCancelled(_: *anyopaque) bool {
    return false;
}

test "isDangerousCommand flags destructive verbs without a Session" {
    var dummy: u8 = 0;
    var ctx = types.ToolContext{
        .allocator = std.testing.allocator,
        .ctx = &dummy,
        .tool_host = null,
        .tool_snapshot = null,
        .settings = .{},
        .approve = fakeApprove,
        .cancelled = fakeCancelled,
    };
    _ = &ctx;
    try std.testing.expect(isDangerousCommand("rm -rf /tmp/x"));
    try std.testing.expect(!isDangerousCommand("ls -la"));
}
```

- [ ] **Step 2: Run the isolation test — expect FAIL (compile error)**

Run: `zig build test 2>&1 | head -20`
Expected: FAIL — `isDangerousCommand` not defined in `ai_chat_tools.zig` yet. This confirms the test targets the new module.

- [ ] **Step 3: Move the tool decls into `ai_chat_tools.zig`**

File header:
```zig
const std = @import("std");
const builtin = @import("builtin");
const types = @import("ai_chat_types.zig");
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const ToolCall = ai_chat_protocol.ToolCall;
const ToolContext = types.ToolContext;
const ToolSurface = types.ToolSurface;
const ToolSnapshot = types.ToolSnapshot;
const ToolHost = types.ToolHost;
const ToolClosedTab = types.ToolClosedTab;
const SshProfileSaveArgs = types.SshProfileSaveArgs;
const SavedSshProfile = types.SavedSshProfile;
const agent_detector = @import("agent_detector.zig");
const skill_registry = @import("skill_registry.zig");
const wispterm_docs = @import("wispterm_docs.zig");
const weixin_types = @import("weixin/types.zig");
const ai_chat_skills = @import("ai_chat_skills.zig");
const platform_process = @import("platform/process.zig");
const platform_pty_command = @import("platform/pty_command.zig");
const platform_agent_prompt = @import("platform/agent_prompt.zig");
// add further imports as compile errors demand
```
Paste the listed decls verbatim, then apply the mechanical `request.*` → `ctx.*`
replacements from the move-set above. `executeToolCall` becomes
`pub fn executeToolCall(ctx: *ToolContext, call: ToolCall) ![]u8`. Promote to
`pub` everything `ai_chat.zig` still calls (resolve via compile errors).

- [ ] **Step 4: Build the `ToolContext` and adapter callbacks in `ai_chat.zig`**

In `ai_chat.zig`, where `executeToolCall(request, call)` was called, build a
`ToolContext` from the `ChatRequest`. Add file-scope adapter callbacks:
```zig
fn toolApprove(ctx: *anyopaque, tool: []const u8, command: []const u8, reason: []const u8) bool {
    const session: *Session = @ptrCast(@alignCast(ctx));
    return session.requestApproval(tool, command, reason);
}
fn toolCancelled(ctx: *anyopaque) bool {
    const session: *Session = @ptrCast(@alignCast(ctx));
    return sessionCancelled(session);
}

fn toolContextFromRequest(request: *ChatRequest) ai_chat_types.ToolContext {
    return .{
        .allocator = request.allocator,
        .ctx = request.session,
        .tool_host = request.tool_host,
        .tool_snapshot = request.tool_snapshot,
        .settings = currentAgentSettings(),
        .copilot = request.copilot,
        .weixin_reply_context = request.weixin_reply_context,
        .write_context_surface_id = request.write_context_surface_id,
        .write_context_surface_id_len = request.write_context_surface_id_len,
        .approve = toolApprove,
        .cancelled = toolCancelled,
    };
}
```
Replace the old call with:
```zig
var tool_ctx = toolContextFromRequest(request);
const result = try ai_chat_tools.executeToolCall(&tool_ctx, call);
// propagate any write-context mutation back onto the request:
request.write_context_surface_id = tool_ctx.write_context_surface_id;
request.write_context_surface_id_len = tool_ctx.write_context_surface_id_len;
```
Make `Session.requestApproval` and `sessionCancelled` reachable (`pub` /
file-scope) as the compiler requires.

> **Note on `setWriteContext`/`ensureWriteContext`:** these mutate the write-context
> buffer. After the seam they mutate `ctx.write_context_surface_id*`; the
> write-back in the call site above carries the change to the `ChatRequest`.
> Verify with the `write context requires explicit selection` test that switching
> surfaces still persists across tool calls within one request.

- [ ] **Step 5: Remove moved decls + tests from `ai_chat.zig`; add import**

Delete the moved declarations and moved tests from `ai_chat.zig`. Add:
```zig
const ai_chat_tools = @import("ai_chat_tools.zig");
```

- [ ] **Step 6: Update `test_main.zig` compile-guards**

The guards in `src/test_main.zig` (~lines 514–543) `@embedFile("ai_chat.zig")`
and scan for `powershellExecTool`, `localShellFallback(`, `localShellCommandArgv(`,
tab-kind strings, etc. Those strings now live in `ai_chat_tools.zig`. For each
guard, add a parallel `@embedFile("ai_chat_tools.zig")` scan (or repoint the
existing one) so the guard still fires on the relocated text. Register the module:
```zig
_ = @import("ai_chat_tools.zig");
```

- [ ] **Step 7: Verify a guard still trips (negative test)**

Temporarily insert the banned string `powershellExecTool` into a comment in
`ai_chat_tools.zig`, run `zig build test 2>&1 | head`, confirm the
`@compileError` fires, then remove the temporary string.
Expected: compile error appears, then disappears after removal.

- [ ] **Step 8: Green gate**

Run: `zig build test && zig build test-full`
Expected: both exit 0; the new isolation test passes; counts match baseline plus the one new isolation test.

- [ ] **Step 9: Commit**

```bash
git add src/ai_chat_tools.zig src/ai_chat.zig src/test_main.zig
git commit -m "refactor(ai-chat): extract Session-free tool layer behind ToolContext"
```

---

## Task 3: Extract `ai_chat_request.zig` (mutual import)

**Files:**
- Create: `src/ai_chat_request.zig`
- Modify: `src/ai_chat.zig`
- Modify: `src/test_main.zig`

**Decls to move** (request / streaming / title, ~lines 279–327 + 3029–3766 + stream-apply):
`ChatRequest` (struct — moves here; it owns the request lifecycle),
`requestThreadMain`, `requestCancelled`, `sessionCancelled`, `finishStoppedRequest`,
`applyGeneratedTitle`, `buildTitleRequestLocked`, `titleThreadMain`, `maybeAutoTitle`,
`runAgentRequest`, `cloneRequestMessage`, `cloneToolCalls`, `assistantToolCallMessage`,
`requestMessageWithClonedFields`, `durableToolAssistantRequestMessage`,
`appendAssistantResult`, `appendProgressMessage`, `appendReplayableToolMessage`,
`beginAssistantStream`, `appendAssistantStreamDelta`, `finishAssistantStream`,
`failAssistantStream`, `runChatRequest`, `runChatRequestForMessages`,
`runChatRequestStreaming`, `buildRequestJson`, `buildRequestJsonForMessages`,
`allocUsageFooter`, `allocRemoteToolSummary`, `RemoteSnapshotSection`,
`appendRecentLimitedSections`, `appendLimitedSection`, `remoteSnapshotSectionHeaderLen`,
`latestAssistantContent`.

> **Decision point:** if `ChatRequest` proves too entangled to move cleanly in one
> commit, keep `ChatRequest` in `ai_chat.zig` (mark it `pub`) and move only the
> request/streaming *functions* into `ai_chat_request.zig`, which then imports
> `ai_chat.zig` for `ChatRequest`+`Session`. Prefer this fallback if the mutual
> import hits a Zig dependency-loop error.

**Mutual import:** `ai_chat_request.zig` imports `ai_chat.zig` for `Session` (and
`ChatRequest` under the fallback). `ai_chat.zig` imports `ai_chat_request.zig` to
spawn threads. References are pointer-based (`*Session`, `*ChatRequest`) so this
is legal. Promote `Session` methods the request layer calls (e.g. message append
helpers, mutex, fields) to `pub` as the compiler requires.

**Tests to move:** the request/streaming/title/usage-footer/remote-snapshot tests
(e.g. `ai chat request json *`, `ai chat stream response aggregates *`,
`ai chat usage footer *`, `ai chat remote snapshot *`, `ai_chat: applyGeneratedTitle *`,
`ai_chat: setTitle emits history hook snapshot`, `ai chat auto-title *`,
`ai chat stop request suppresses late assistant result`). Move those that compile
cleanly against the new module; leave `Session`-internal ones in `ai_chat.zig`.

- [ ] **Step 1: Create `src/ai_chat_request.zig` skeleton with mutual import**

```zig
const std = @import("std");
const ai_chat = @import("ai_chat.zig");
const Session = ai_chat.Session;
const ai_chat_protocol = @import("ai_chat_protocol.zig");
const ai_chat_title = @import("ai_chat_title.zig");
const ai_chat_tools = @import("ai_chat_tools.zig");
const ai_chat_types = @import("ai_chat_types.zig");
const agent_history = @import("agent_history.zig");
// add imports as compile errors demand
```
Ensure `pub const Session = @This-equivalent` exists in `ai_chat.zig` (it already
is `pub`-accessible as `ai_chat.Session` since the struct is `pub const Session`).

- [ ] **Step 2: Move the listed decls verbatim into `ai_chat_request.zig`**

Paste decls; promote `pub` those `ai_chat.zig` still calls (`requestThreadMain`,
`maybeAutoTitle`, `runChatRequestStreaming`, etc.). Where the request layer calls
the tool layer, route through `ai_chat_tools.executeToolCall` with a
`ToolContext` (the `ChatRequest`→`ToolContext` adapter from Task 2B moves here too
if `ChatRequest` moves here).

- [ ] **Step 3: Remove moved decls + tests from `ai_chat.zig`; add import + pub promotions**

Add `const ai_chat_request = @import("ai_chat_request.zig");`. Rewrite call sites
(thread spawns, title triggers) to `ai_chat_request.<name>`. Promote the `Session`
methods/fields the request layer reads to `pub`.

- [ ] **Step 4: Compile-resolve the mutual import**

Run: `zig build test 2>&1 | head -40`
Expected: iterate on `pub`/import errors. **If you see `dependency loop detected`**,
apply the fallback from the Decision Point (keep `ChatRequest` in `ai_chat.zig`,
mark `pub`, import it from the request module). Re-run until clean.

- [ ] **Step 5: Register module + green gate**

Add `_ = @import("ai_chat_request.zig");` to `src/test_main.zig`.
Run: `zig build test && zig build test-full`
Expected: both exit 0; counts match baseline.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_request.zig src/ai_chat.zig src/test_main.zig
git commit -m "refactor(ai-chat): extract request/streaming/title layer into ai_chat_request.zig"
```

---

## Task 4: Fold stream-parsing into `ai_chat_protocol.zig`; extract `ai_chat_markdown.zig`

**Files:**
- Modify: `src/ai_chat_protocol.zig` (receive stream-parse helpers)
- Create: `src/ai_chat_markdown.zig`
- Modify: `src/ai_chat.zig` (or `ai_chat_request.zig` for stream-apply) and `src/test_main.zig`

### Task 4A: stream-parsing → `ai_chat_protocol.zig`

**Decls to move:** `parseApiStreamResponse` (pure body→ApiResult parser). Keep
`applyApiStreamLineToSession` next to whichever module owns the streaming loop
(`ai_chat_request.zig`) since it mutates `Session`; move only the
`Session`-independent parsing into `ai_chat_protocol.zig`.

**Tests to move:** `ai chat stream response aggregates content and reasoning chunks`,
`ai chat Responses API stream aggregates output text and usage` → into
`ai_chat_protocol.zig`'s test block (it is already in `test_fast` + `test_main`).

- [ ] **Step 1: Move `parseApiStreamResponse` (+ its private helpers) into `ai_chat_protocol.zig`, `pub`**

Paste verbatim; mark `pub fn parseApiStreamResponse`. In `ai_chat_request.zig`
(or wherever it is now), replace the local definition with
`const parseApiStreamResponse = ai_chat_protocol.parseApiStreamResponse;`.

- [ ] **Step 2: Green gate**

Run: `zig build test && zig build test-full`
Expected: both exit 0.

### Task 4B: markdown export → `ai_chat_markdown.zig`

**Decls to move** (~lines 2812–2945): `appendClipboardSection`,
`appendMarkdownDocumentHeader`, `appendMarkdownSection`, `appendMarkdownCodeSection`,
`appendMarkdownInline`, `appendMarkdownBody`, `appendMarkdownFence`,
`appendRepeatedByte`, `longestBacktickRun`. (`latestAssistantContent` already moved
to `ai_chat_request.zig` in Task 3 — leave it there; if markdown needs it, import
or duplicate the 3-line helper. Prefer importing from whichever module owns it.)

**Tests to move:** `ai chat Markdown export includes full transcript details`,
`ai chat clean Markdown export keeps user inputs and final answer only`,
`ai chat clipboard text exports transcript when input is empty` (if `Session`-free
after the move; otherwise leave in `ai_chat.zig` and call `ai_chat_markdown.*`).

- [ ] **Step 1: Create `src/ai_chat_markdown.zig`**

```zig
const std = @import("std");
const ai_chat = @import("ai_chat.zig");
const Message = ai_chat.Message;
```
Paste the moved decls verbatim; promote `pub` those called from `ai_chat.zig`'s
clipboard/export paths.

- [ ] **Step 2: Rewrite callers in `ai_chat.zig`; add import; register module**

Add `const ai_chat_markdown = @import("ai_chat_markdown.zig");`, rewrite the
clipboard/export call sites to `ai_chat_markdown.<name>`, and add
`_ = @import("ai_chat_markdown.zig");` to `src/test_main.zig`.

- [ ] **Step 3: Green gate**

Run: `zig build test && zig build test-full`
Expected: both exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/ai_chat_protocol.zig src/ai_chat_markdown.zig src/ai_chat.zig src/test_main.zig
git commit -m "refactor(ai-chat): fold stream parse into protocol, extract markdown export"
```

---

## Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Confirm the size reduction**

Run: `wc -l src/ai_chat*.zig`
Expected: `src/ai_chat.zig` ≈ ~3000 lines (down from 8283); new modules
`ai_chat_skills.zig`, `ai_chat_types.zig`, `ai_chat_tools.zig`,
`ai_chat_request.zig`, `ai_chat_markdown.zig` present.

- [ ] **Step 2: Confirm no external API drift**

Run: `zig build` (full app build)
Expected: exit 0 — `App.zig`/`AppWindow.zig`/`config.zig` compile unchanged against the re-exported `ai_chat.*` surface.

- [ ] **Step 3: Final green gate**

Run: `zig build test && zig build test-full`
Expected: both exit 0; counts match the Task 0 baseline (plus the one new isolation test).

- [ ] **Step 4: Review the diff**

Run: `git log --oneline main..HEAD && git diff --stat main..HEAD`
Expected: 4–6 `refactor(ai-chat):` commits; net line movement out of `ai_chat.zig`, near-zero net logic change.

---

## Self-review notes (author)

- **Spec coverage:** skills (Task 1), tools+seam+types (Task 2), request (Task 3),
  stream-parse + markdown (Task 4), size/API/green success criteria (Task 5). All
  spec sections mapped.
- **Compile-guard risk** (spec risk table) covered by Task 2B Steps 6–7 with an
  explicit negative test.
- **Mutual-import dependency-loop risk** covered by Task 3 Decision Point + Step 4
  fallback.
- **Tests-travel-with-code** applied per task; `Session`-internal tests explicitly
  left in `ai_chat.zig`.
- **No new behavior** except the `ToolContext` seam + one isolation test.
