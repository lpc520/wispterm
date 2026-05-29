# Claude API (Anthropic Messages) Protocol — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Anthropic Messages API (`/v1/messages`) as a third `ApiProtocol`, non-streaming, so the AI Chat panel can talk to Claude directly.

**Architecture:** Mirror the existing `chat_completions` / `responses` split in `ai_chat_protocol.zig`: a new `anthropic` enum variant drives endpoint selection, request-JSON building (with content-block mapping for tool use), and response parsing. The HTTP layer in `ai_chat.zig` branches headers by protocol (`x-api-key` + `anthropic-version` instead of `Authorization: Bearer`). `max_tokens` becomes a per-session setting (default 8192).

**Tech Stack:** Zig; manual JSON building via `appendJsonString` (`ai_chat_protocol.zig:143`); `std.http.Client`. Tests via `zig build test`. Touched files stay registered in `test_fast.zig`/`test_main.zig`.

**Spec:** `docs/superpowers/specs/2026-05-29-claude-api-protocol-design.md`

---

## File Structure

- **Modify** `src/ai_chat_protocol.zig` — `ApiProtocol.anthropic` + `parse`/`name`; `apiEndpoint` branch; `RequestParams.max_tokens`; `buildAnthropicRequestJsonForMessages`; `parseApiResponse` anthropic branch.
- **Modify** `src/ai_chat.zig` — per-session `max_tokens` setting (init param, buffer, history record, config value); pass `max_tokens` into `RequestParams`; protocol-branched auth headers in the HTTP send (`runChatRequestForMessages`, ~`:2914-2980`); anthropic auto-detect (mirror DeepSeek at `:730`).
- **Modify** AI-chat settings UI (wherever protocol/model/stream are edited) — add `anthropic` option + `max_tokens` field.

---

## Task 1: `ApiProtocol.anthropic` enum + parse/name

**Files:**
- Modify: `src/ai_chat_protocol.zig:16-37`
- Test: `src/ai_chat_protocol.zig` (inline, near `:830`)

- [ ] **Step 1: Write the failing test:**

```zig
test "ApiProtocol parses and names anthropic + aliases" {
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("anthropic"));
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("claude"));
    try std.testing.expectEqual(ApiProtocol.anthropic, ApiProtocol.parse("messages"));
    try std.testing.expectEqualStrings("anthropic", ApiProtocol.anthropic.name());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `no field named 'anthropic'`.

- [ ] **Step 3: Extend the enum** (`:16`):

```zig
pub const ApiProtocol = enum {
    chat_completions,
    responses,
    anthropic,

    pub fn parse(value: []const u8) ApiProtocol {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return .chat_completions;
        if (std.ascii.eqlIgnoreCase(trimmed, "responses") or
            std.ascii.eqlIgnoreCase(trimmed, "response"))
        {
            return .responses;
        }
        if (std.ascii.eqlIgnoreCase(trimmed, "anthropic") or
            std.ascii.eqlIgnoreCase(trimmed, "claude") or
            std.ascii.eqlIgnoreCase(trimmed, "messages"))
        {
            return .anthropic;
        }
        return .chat_completions;
    }

    pub fn name(self: ApiProtocol) []const u8 {
        return switch (self) {
            .chat_completions => DEFAULT_PROTOCOL,
            .responses => "responses",
            .anthropic => "anthropic",
        };
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): add anthropic ApiProtocol variant"
```

---

## Task 2: `/v1/messages` endpoint

**Files:**
- Modify: `src/ai_chat_protocol.zig:191-196`
- Test: `src/ai_chat_protocol.zig` (inline)

- [ ] **Step 1: Write the failing test:**

```zig
test "apiEndpoint builds the anthropic messages endpoint" {
    const a = std.testing.allocator;
    const ep = try apiEndpoint(a, "https://api.anthropic.com", .anthropic);
    defer a.free(ep);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — switch not exhaustive for `.anthropic`.

- [ ] **Step 3: Add the branch + helper** (`:191`):

```zig
pub fn apiEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8, protocol: ApiProtocol) ![]u8 {
    return switch (protocol) {
        .chat_completions => chatEndpoint(allocator, base_url_raw),
        .responses => responsesEndpoint(allocator, base_url_raw),
        .anthropic => messagesEndpoint(allocator, base_url_raw),
    };
}

pub fn messagesEndpoint(allocator: std.mem.Allocator, base_url_raw: []const u8) ![]u8 {
    return endpointWithSuffix(allocator, base_url_raw, "/v1/messages");
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): anthropic endpoint -> /v1/messages"
```

---

## Task 3: `max_tokens` on RequestParams + request JSON skeleton

**Files:**
- Modify: `src/ai_chat_protocol.zig:127-141` (`RequestParams`, `buildRequestJson`)
- Test: `src/ai_chat_protocol.zig` (inline)

This task adds the field and the system/messages/max_tokens skeleton (tools + tool blocks in Task 4).

- [ ] **Step 1: Write the failing test:**

```zig
test "buildRequestJson anthropic puts system top-level and includes max_tokens" {
    const a = std.testing.allocator;
    var msgs = [_]RequestMessage{
        .{ .role = .user, .content = "hi" },
    };
    const params = RequestParams{ .model = "claude-x", .system_prompt = "be brief", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, false);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_tokens\":8192") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"system\":\"be brief\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"user\"") != null);
    // system must NOT be inside the messages array as a role
    try std.testing.expect(std.mem.indexOf(u8, json, "\"role\":\"system\"") == null);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `RequestParams` has no field `max_tokens` / non-exhaustive switch.

- [ ] **Step 3: Add the field** to `RequestParams` (`:127`):

```zig
pub const RequestParams = struct {
    model: []const u8,
    system_prompt: []const u8,
    protocol: ApiProtocol,
    thinking_enabled: bool,
    reasoning_effort: []const u8,
    stream: bool,
    max_tokens: u32 = 8192,
};
```

Update the `buildRequestJson` switch (`:136`) and add the anthropic builder skeleton (mirror `buildChatCompletionsRequestJsonForMessages` style at `:218`, using `appendJsonString`):

```zig
pub fn buildRequestJson(allocator: std.mem.Allocator, params: RequestParams, messages: []const RequestMessage, include_tools: bool) ![]u8 {
    return switch (params.protocol) {
        .chat_completions => buildChatCompletionsRequestJsonForMessages(allocator, params, messages, include_tools),
        .responses => buildResponsesRequestJsonForMessages(allocator, params, messages, include_tools),
        .anthropic => buildAnthropicRequestJsonForMessages(allocator, params, messages, include_tools),
    };
}

fn buildAnthropicRequestJsonForMessages(
    allocator: std.mem.Allocator,
    params: RequestParams,
    messages: []const RequestMessage,
    include_tools: bool,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\"model\":");
    try appendJsonString(allocator, &out, params.model);
    try out.print(allocator, ",\"max_tokens\":{d}", .{params.max_tokens});
    if (params.system_prompt.len > 0) {
        try out.appendSlice(allocator, ",\"system\":");
        try appendJsonString(allocator, &out, params.system_prompt);
    }
    try out.appendSlice(allocator, ",\"messages\":[");
    try appendAnthropicMessages(allocator, &out, messages); // Task 4
    try out.append(allocator, ']');
    if (include_tools) try appendAnthropicTools(allocator, &out); // Task 4
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}
```

For THIS task, implement `appendAnthropicMessages` for the simple case only (text user/assistant, no tools) so the test passes; `appendAnthropicTools` can be an empty stub `{}`-free no-op (only called when `include_tools`, which the test sets false):

```zig
fn appendAnthropicMessages(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), messages: []const RequestMessage) !void {
    var first = true;
    for (messages) |msg| {
        if (msg.role == .tool) continue; // handled in Task 4
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, out, msg.role.apiName());
        try out.appendSlice(allocator, ",\"content\":");
        try appendJsonString(allocator, out, msg.content);
        try out.append(allocator, '}');
    }
}
fn appendAnthropicTools(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    _ = allocator; _ = out; // filled in Task 4
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Update existing RequestParams literals** — the new field has a default (`= 8192`), so existing `RequestParams{...}` literals in tests/code still compile. Grep to confirm: `git grep -n "RequestParams{" src` → build is green.

- [ ] **Step 6: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): anthropic request JSON skeleton (system, max_tokens, messages)"
```

---

## Task 4: Anthropic tool_use / tool_result content blocks + tools

**Files:**
- Modify: `src/ai_chat_protocol.zig` (`appendAnthropicMessages`, `appendAnthropicTools`)
- Test: `src/ai_chat_protocol.zig` (inline)

Anthropic requires: assistant tool calls → `tool_use` blocks; tool results (internal `.tool` role) → a **user** message with `tool_result` blocks; consecutive tool results grouped into one user message. Tools use `input_schema` (same JSON Schema as the existing OpenAI `parameters`).

- [ ] **Step 1: Write the failing test:**

```zig
test "anthropic maps tool_calls to tool_use and tool results to grouped tool_result" {
    const a = std.testing.allocator;
    var calls = [_]ToolCall{.{ .id = "call_1", .name = "shell_exec", .arguments = "{\"cmd\":\"ls\"}" }};
    var msgs = [_]RequestMessage{
        .{ .role = .user, .content = "run ls" },
        .{ .role = .assistant, .content = "", .tool_calls = &calls },
        .{ .role = .tool, .content = "file.txt", .tool_call_id = "call_1" },
    };
    const params = RequestParams{ .model = "claude-x", .system_prompt = "", .protocol = .anthropic, .thinking_enabled = false, .reasoning_effort = "", .stream = false, .max_tokens = 8192 };
    const json = try buildRequestJson(a, params, &msgs, true);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_use\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input\":{\"cmd\":\"ls\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_use_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"input_schema\"") != null);
}
```

> Verify `ToolCall` field names (`id`, `name`, `arguments`) against `ai_chat_protocol.zig` (the chat-completions builder at `:248` emits `tool_calls`; copy its field accessors). Verify `RequestMessage.tool_calls` is `?[]const ToolCall`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — tool_use/tool_result/input_schema absent.

- [ ] **Step 3: Implement the full mappers.** Walk messages; group consecutive `.tool` messages into one `user` message of `tool_result` blocks. `tool_use.input` is the raw arguments JSON embedded verbatim (it is already a JSON object string; if empty, emit `{}`):

```zig
fn appendAnthropicMessages(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), messages: []const RequestMessage) !void {
    var first = true;
    var i: usize = 0;
    while (i < messages.len) {
        const msg = messages[i];
        if (msg.role == .tool) {
            // group consecutive tool results into one user message
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, "{\"role\":\"user\",\"content\":[");
            var jt: usize = i;
            var block_first = true;
            while (jt < messages.len and messages[jt].role == .tool) : (jt += 1) {
                if (!block_first) try out.append(allocator, ',');
                block_first = false;
                try out.appendSlice(allocator, "{\"type\":\"tool_result\",\"tool_use_id\":");
                try appendJsonString(allocator, out, messages[jt].tool_call_id orelse "");
                try out.appendSlice(allocator, ",\"content\":");
                try appendJsonString(allocator, out, messages[jt].content);
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
            i = jt;
            continue;
        }
        if (!first) try out.append(allocator, ',');
        first = false;
        try out.appendSlice(allocator, "{\"role\":");
        try appendJsonString(allocator, out, msg.role.apiName());
        if (msg.role == .assistant and msg.tool_calls != null and msg.tool_calls.?.len > 0) {
            try out.appendSlice(allocator, ",\"content\":[");
            var wrote = false;
            if (msg.content.len > 0) {
                try out.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
                try appendJsonString(allocator, out, msg.content);
                try out.append(allocator, '}');
                wrote = true;
            }
            for (msg.tool_calls.?) |call| {
                if (wrote) try out.append(allocator, ',');
                wrote = true;
                try out.appendSlice(allocator, "{\"type\":\"tool_use\",\"id\":");
                try appendJsonString(allocator, out, call.id);
                try out.appendSlice(allocator, ",\"name\":");
                try appendJsonString(allocator, out, call.name);
                try out.appendSlice(allocator, ",\"input\":");
                if (call.arguments.len > 0) try out.appendSlice(allocator, call.arguments) else try out.appendSlice(allocator, "{}");
                try out.append(allocator, '}');
            }
            try out.appendSlice(allocator, "]}");
        } else {
            try out.appendSlice(allocator, ",\"content\":");
            try appendJsonString(allocator, out, msg.content);
            try out.append(allocator, '}');
        }
        i += 1;
    }
}
```

For `appendAnthropicTools`: reuse the SAME tool schema source the OpenAI builders use, but emit `name`, `description`, `input_schema` (the schema object) instead of the OpenAI `{type:function, function:{name, description, parameters}}` wrapper. Locate the existing tool-schema builder (search `toolSchema(` / the function that appends `"tools":[` in the chat-completions builder) and write an anthropic variant that emits the inner schema under `input_schema`:

```zig
fn appendAnthropicTools(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    try out.appendSlice(allocator, ",\"tools\":[");
    // For each tool the OpenAI builder emits, emit:
    //   {"name":<n>,"description":<d>,"input_schema":<the same JSON Schema object>}
    // Reuse the shared tool list/description source; do not duplicate schema text.
    try out.append(allocator, ']');
}
```

> Implementer note: the cleanest approach is to refactor the existing OpenAI tool emission into a shared `forEachTool(fn(name, description, schema_json))` and have both builders consume it. Keep the JSON Schema object identical between `parameters` (OpenAI) and `input_schema` (Anthropic).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): anthropic content-block tool mapping + input_schema tools"
```

---

## Task 5: Parse the Anthropic response

**Files:**
- Modify: `src/ai_chat_protocol.zig` (`parseApiResponse`)
- Test: `src/ai_chat_protocol.zig` (inline, mirror the responses-protocol test at `:909`)

- [ ] **Step 1: Write the failing test:**

```zig
test "parseApiResponse anthropic reads text, tool_use, and usage" {
    const a = std.testing.allocator;
    const body =
        \\{"content":[{"type":"text","text":"hello"},{"type":"tool_use","id":"call_1","name":"shell_exec","input":{"cmd":"ls"}}],"stop_reason":"tool_use","usage":{"input_tokens":12,"output_tokens":7}}
    ;
    var result = try parseApiResponse(a, body, .anthropic);
    defer result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "hello") != null);
    try std.testing.expect(result.tool_calls != null);
    try std.testing.expectEqualStrings("shell_exec", result.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call_1", result.tool_calls.?[0].id);
    try std.testing.expect(result.usage != null);
}
```

> Verify `parseApiResponse`'s real signature (it takes the protocol — confirm whether protocol is a param or inferred). Match `ApiResult`/`ApiUsage`/`ToolCall` field names and the `.deinit` signature exactly from the existing function and the responses-protocol test at `:909`.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — anthropic branch missing.

- [ ] **Step 3: Add the anthropic branch** to `parseApiResponse`, using `std.json` parsing consistent with the existing branches:
- Iterate `content[]`: concatenate `text` blocks into `result.content`; each `tool_use` block → `ToolCall{ .id, .name, .arguments = std.json stringify of input }`.
- Map `usage.input_tokens`/`output_tokens` onto `ApiUsage` (use the same field names the responses branch uses; the responses API also exposes input/output token counts — reuse that mapping).
- `stop_reason` need not be stored unless the existing `ApiResult` has a field for it; the agent loop (`ai_chat.zig:2536`) keys off `tool_calls` being non-empty, which is sufficient.

Follow the exact JSON-reading idiom already used in the responses branch (same parser, same ownership/dupe pattern).

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): parse anthropic messages response"
```

---

## Task 6: Per-session `max_tokens` setting + thread into the request

**Files:**
- Modify: `src/ai_chat.zig` (Session settings: init param, buffer/value, history record, config value, `RequestParams` construction near `:1982`)
- Test: `src/ai_chat.zig` (inline) + `src/session_persist.zig` round-trip

`max_tokens` follows the exact same plumbing as `stream` (`ai_chat.zig:626`, `:682`, `:727`, `:751`, `:826`). Default 8192.

- [ ] **Step 1: Write the failing test** (round-trips through a history record):

```zig
test "session preserves max_tokens through history record" {
    const a = std.testing.allocator;
    var session = try Session.initWithSystemPrompt(a, "https://api.anthropic.com", "key", "anthropic", "claude-x", "false", "sys");
    defer session.deinit();
    session.setMaxTokens(4096);
    var record = try session.toHistoryRecord(a);
    defer agent_history.freeOwnedRecord(a, &record);
    try std.testing.expectEqual(@as(u32, 4096), record.max_tokens);
}
```

> Adjust to the actual `initWithSystemPrompt` / `createSession` signature; add `max_tokens` as a new init parameter OR set a default and a setter — pick whichever matches how `stream` is passed. If `stream` is passed as a string arg, add a `max_tokens` string arg too and parse it.

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `setMaxTokens` / `record.max_tokens` undefined.

- [ ] **Step 3: Add the field everywhere `stream` appears:**
- Session struct: `max_tokens: u32 = 8192` (near `:626`).
- Init: parse from the same place `stream` is parsed (`:727`); default 8192 when empty/invalid.
- History record (`agent_history.SessionRecord`): add `max_tokens: u32 = 8192` field; set it in `toHistoryRecordLocked` (`:2022`) and read it in `initFromHistoryRecord` (`:739`).
- `session_persist.zig`: serialize/deserialize `max_tokens` (add to the JSON dump/load with a default for older files — there is already a "future_json"/missing-field test pattern at `:340`).
- Config value accessor: add `maxTokensConfigValue`/`setMaxTokens` mirroring `streamConfigValue` (`:826`).
- In the `RequestParams{...}` construction (search near `:1982` where `base_url`/`protocol` are read for the request) set `.max_tokens = self.max_tokens`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS (incl. `session_persist` round-trip).

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/session_persist.zig src/agent_history.zig
git commit -m "feat(ai-chat): per-session max_tokens setting (default 8192)"
```

---

## Task 7: Protocol-branched auth headers + anthropic auto-detect

**Files:**
- Modify: `src/ai_chat.zig` (HTTP send in `runChatRequestForMessages`, ~`:2914-2980`; auto-detect near `:730`)
- Test: `src/ai_chat.zig` (inline pure helper for header selection + auto-detect)

- [ ] **Step 1: Write the failing test:**

```zig
test "anthropic base url auto-detects the protocol" {
    try std.testing.expect(isAnthropicBaseUrl("https://api.anthropic.com"));
    try std.testing.expect(!isAnthropicBaseUrl("https://api.openai.com"));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | head -40`
Expected: FAIL — `isAnthropicBaseUrl` undefined.

- [ ] **Step 3a: Add `isAnthropicBaseUrl`** (mirror `isDeepSeekBaseUrl` in `ai_chat_protocol.zig:187`):

```zig
pub fn isAnthropicBaseUrl(base_url: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(base_url, "api.anthropic.com") != null;
}
```

In the session init, after `protocol` is parsed (`ai_chat.zig:723`), if the parsed protocol is the default (`chat_completions`) AND the base_url is anthropic, switch to `.anthropic` (mirror the DeepSeek key fallback at `:730`):

```zig
if (session.protocol == .chat_completions and isAnthropicBaseUrl(session.baseUrl())) {
    session.protocol = .anthropic;
}
```

- [ ] **Step 3b: Branch the auth headers** in the HTTP send. Find where `Authorization: Bearer <key>` is set (in `runChatRequestForMessages`, ~`:2914-2980`). Replace the single header set with:

```zig
switch (request.protocol) {
    .anthropic => {
        try headers.append(.{ .name = "x-api-key", .value = api_key });
        try headers.append(.{ .name = "anthropic-version", .value = "2023-06-01" });
    },
    else => {
        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
        // free auth after the request
        try headers.append(.{ .name = "Authorization", .value = auth });
    },
}
```

> Match the exact header-setting API used today (the repo may use `extra_headers` on the `std.http.Client` request, or an `Authorization` field). Mirror the existing call precisely — only add the protocol branch. Confirm `request` carries `protocol` (it does via `ChatRequest`/`RequestParams`); if not, thread it.

- [ ] **Step 4: Run tests + build**

Run: `zig build test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/ai_chat_protocol.zig
git commit -m "feat(ai-chat): anthropic auth headers + base-url auto-detect"
```

---

## Task 8: Settings UI — anthropic option + max_tokens field

**Files:**
- Modify: AI-chat settings editor (find via `git grep -n "responses" src` for where the protocol option is offered in the panel/profile editor; likely an overlay or `command_center_state.zig`/an AI settings form).
- Test: existing UI tests for the settings form, extended.

- [ ] **Step 1:** Locate the settings UI that lets the user pick the protocol and edit base_url/api_key/model/stream. Add `anthropic` to the protocol choices and a `max_tokens` numeric field (default 8192). Persist via the Session setters from Task 6.

- [ ] **Step 2:** Add/extend a test asserting the settings form accepts `anthropic` and a `max_tokens` value and that they reach the Session. Run `zig build test`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(ai-chat): settings UI for anthropic protocol + max_tokens"
```

> If the protocol is only set via a config string / profile import (no dedicated UI widget), this task reduces to documenting `ai-protocol = anthropic` and `max_tokens` in the profile format and adding a parse test — adapt to what exists.

---

## Task 9: Cross-target build + manual verification

- [ ] **Step 1:** `zig build test 2>&1 | tail -30` — all green.
- [ ] **Step 2:** `zig build test-full -Dtarget=x86_64-windows-gnu 2>&1 | tail -30` — no NEW failures vs the 497/499 baseline (memory `phantty-test-execution-env`).
- [ ] **Step 3:** Manual: set an AI profile with base_url `https://api.anthropic.com`, a real key, model `claude-...`, protocol auto-detected to anthropic; send a message and confirm a normal reply; send a message that triggers a tool call and confirm the tool loop completes (tool_use → tool_result round trip).
- [ ] **Step 4:** Confirm OpenAI/DeepSeek profiles still work unchanged (regression).

---

## Self-review notes (coverage)

- B1 enum/parse/name → Task 1. B2 endpoint → Task 2. B3 system/max_tokens/messages → Task 3. B3 tool blocks + input_schema → Task 4. B4 response parse → Task 5. B5 auth headers → Task 7. B6 max_tokens setting → Task 6; settings UI + auto-detect → Tasks 7,8. B7 streaming → intentionally omitted (deferred).
- Type-consistency flags for the implementer: `ToolCall`/`ApiResult`/`ApiUsage`/`RequestMessage` exact field names; `parseApiResponse` signature; the `std.http.Client` header API; `initWithSystemPrompt`/record field names for `max_tokens`. Each is called out at its task.
- No streaming, no Ollama, no Claude-Code-kernel — per spec scope.
```
