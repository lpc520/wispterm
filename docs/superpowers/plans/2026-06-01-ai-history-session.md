# AI History Session Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an AI History Session tab that connects to one Local / WSL / SSH target, scans Codex and Claude Code history metadata, lazily opens transcripts, and resumes sessions from their original project directory.

**Architecture:** Implement AI History as an app-level non-terminal tab, not a terminal `Surface`. This follows the Ghostty boundary: Ghostty `Surface` owns PTY interaction and `SplitTree` owns terminal view layout; AI History stays outside those terminal abstractions and creates a real terminal surface only when the user resumes a CLI session. Keep provider parsing, source/cache logic, tab state, and rendering in focused modules rather than extending `renderer/overlays.zig`, `file_explorer.zig`, or `ai_chat.zig`.

**Tech Stack:** Zig, WispTerm GL renderer, existing `TabState` / `AppWindow` tab lifecycle, existing platform PTY command helpers, existing SSH profile codec, `zig build test`, `zig build test-full`.

---

## Scope And File Structure

This plan implements the approved spec at `docs/superpowers/specs/2026-06-01-ai-history-session-design.md`.

Create these focused modules:

- `src/ai_history_types.zig` — shared provider/source/session/transcript/resume types and pure helpers.
- `src/ai_history_provider_codex.zig` — Codex JSONL metadata and transcript parser.
- `src/ai_history_provider_claude.zig` — Claude Code JSONL metadata and transcript parser.
- `src/ai_history_source.zig` — source model, provider roots, target identity, source profile encoding.
- `src/ai_history_cache.zig` — metadata-only cache records and invalidation helpers.
- `src/ai_history_resume.zig` — pure resume command and project-directory validation command builders.
- `src/ai_history_session.zig` — AI History tab state machine, filters, selected row, loading states, scanner host seam.
- `src/renderer/ai_history_renderer.zig` — GL UI layout, rendering, hit testing, and input routing for the history tab.

Modify these existing files:

- `src/test_fast.zig` — register pure AI History modules.
- `src/test_main.zig` — register full app-facing AI History modules and add compile guard that renderer/provider logic does not live in `renderer/overlays.zig`.
- `src/session_persist.zig` — add an AI History snapshot field alongside `ai_session_id`.
- `src/appwindow/tab.zig` — add `TabState.Kind.ai_history`, lifecycle, snapshot/restore hooks, spawn helper.
- `src/AppWindow.zig` — render and input route AI History tabs, expose spawn/resume helpers.
- `src/platform/pty_command.zig`, `src/platform/pty_command_windows.zig`, `src/platform/pty_command_unsupported.zig` — update session launcher row counts/details for AI History.
- `src/command_center_state.zig` — expose `SESSION_LAUNCHER_ROW_AI_HISTORY`.
- `src/renderer/overlays.zig` — add the New Session row and source picker entry points only; do not add scanning/provider logic here.
- `docs/ai-agent.md`, `README.md` — document the AI History Session entry and behavior after the feature works.

Out of scope for this plan:

- Multi-target aggregation.
- Deleting, renaming, archiving, or rewriting `.codex` / `.claude` records.
- Full-transcript indexing or default transcript caching.
- Converting AI History into a terminal split / PTY `Surface`.

---

### Task 1: Add Shared AI History Types

**Files:**
- Create: `src/ai_history_types.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing type/helper tests**

Create `src/ai_history_types.zig` with the public types and these tests first:

```zig
const std = @import("std");

pub const ProviderId = enum {
    codex,
    claude,

    pub fn label(self: ProviderId) []const u8 {
        return switch (self) {
            .codex => "Codex",
            .claude => "Claude Code",
        };
    }
};

pub const MessageRole = enum { user, assistant, system, tool };
pub const MessageKind = enum { normal, tool_call, tool_result, meta };
pub const ScanStatus = enum { ok, partial, not_found, invalid };
pub const ResumeKind = enum { codex_resume, claude_resume, unavailable };

pub const SessionMeta = struct {
    provider: ProviderId,
    session_id: []const u8,
    title: []const u8,
    summary: []const u8 = "",
    project_dir: []const u8 = "",
    created_at_ms: i64 = 0,
    last_active_at_ms: i64 = 0,
    source_path: []const u8,
    resume_kind: ResumeKind,
    message_count: u32 = 0,
    scan_status: ScanStatus = .ok,
};

pub const TranscriptMessage = struct {
    role: MessageRole,
    kind: MessageKind = .normal,
    content: []const u8,
    timestamp_ms: i64 = 0,
};

pub const SortDirection = enum { descending, ascending };

pub fn lessRecent(_: void, lhs: SessionMeta, rhs: SessionMeta) bool {
    if (lhs.last_active_at_ms == rhs.last_active_at_ms) {
        return std.mem.lessThan(u8, lhs.session_id, rhs.session_id);
    }
    return lhs.last_active_at_ms > rhs.last_active_at_ms;
}

pub fn metadataMatches(meta: SessionMeta, query: []const u8) bool {
    if (query.len == 0) return true;
    var query_buf: [256]u8 = undefined;
    const q_len = @min(query.len, query_buf.len);
    for (query[0..q_len], 0..) |ch, i| query_buf[i] = std.ascii.toLower(ch);
    const q = query_buf[0..q_len];
    return containsIgnoreCase(meta.title, q) or
        containsIgnoreCase(meta.summary, q) or
        containsIgnoreCase(meta.project_dir, q) or
        containsIgnoreCase(meta.session_id, q) or
        containsIgnoreCase(meta.source_path, q);
}

fn containsIgnoreCase(haystack: []const u8, lowered_query: []const u8) bool {
    if (lowered_query.len == 0) return true;
    if (lowered_query.len > haystack.len) return false;
    var i: usize = 0;
    while (i + lowered_query.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (lowered_query, 0..) |qch, j| {
            if (std.ascii.toLower(haystack[i + j]) != qch) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

test "ai_history_types: provider labels are stable" {
    try std.testing.expectEqualStrings("Codex", ProviderId.codex.label());
    try std.testing.expectEqualStrings("Claude Code", ProviderId.claude.label());
}

test "ai_history_types: metadata search covers title summary project session and path" {
    const meta: SessionMeta = .{
        .provider = .codex,
        .session_id = "sess-123",
        .title = "Fix renderer crash",
        .summary = "OpenGL startup failure",
        .project_dir = "/home/me/wispterm",
        .source_path = "/home/me/.codex/sessions/one.jsonl",
        .resume_kind = .codex_resume,
    };

    try std.testing.expect(metadataMatches(meta, "renderer"));
    try std.testing.expect(metadataMatches(meta, "OPENGL"));
    try std.testing.expect(metadataMatches(meta, "wispterm"));
    try std.testing.expect(metadataMatches(meta, "sess-123"));
    try std.testing.expect(metadataMatches(meta, "sessions/one"));
    try std.testing.expect(!metadataMatches(meta, "missing"));
}

test "ai_history_types: recent sort is descending with session id tie break" {
    var rows = [_]SessionMeta{
        .{ .provider = .claude, .session_id = "b", .title = "B", .source_path = "b.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 10 },
        .{ .provider = .codex, .session_id = "c", .title = "C", .source_path = "c.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 20 },
        .{ .provider = .codex, .session_id = "a", .title = "A", .source_path = "a.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 10 },
    };
    std.mem.sort(SessionMeta, &rows, {}, lessRecent);
    try std.testing.expectEqualStrings("c", rows[0].session_id);
    try std.testing.expectEqualStrings("a", rows[1].session_id);
    try std.testing.expectEqualStrings("b", rows[2].session_id);
}
```

- [ ] **Step 2: Register the module in both test aggregators**

Add the import to `src/test_fast.zig` inside the existing `test { ... }` block:

```zig
    _ = @import("ai_history_types.zig");
```

Add the same import to `src/test_main.zig` in its module import test block. If the file has a single large `test` block later in the file, place the line next to the other pure modules:

```zig
    _ = @import("ai_history_types.zig");
```

- [ ] **Step 3: Run tests and verify the new module passes**

Run:

```bash
zig build test
```

Expected: command exits 0 and includes the new `ai_history_types` tests.

- [ ] **Step 4: Commit**

```bash
git add src/ai_history_types.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add ai history shared types"
```

---

### Task 2: Add Codex Provider Parser

**Files:**
- Create: `src/ai_history_provider_codex.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing Codex parser tests**

Create `src/ai_history_provider_codex.zig`:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");

pub const ParseError = error{OutOfMemory};

pub fn parseMetadata(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    jsonl: []const u8,
) ParseError!types.SessionMeta {
    _ = allocator;
    _ = source_path;
    _ = jsonl;
    return types.SessionMeta{
        .provider = .codex,
        .session_id = "",
        .title = "",
        .source_path = "",
        .resume_kind = .codex_resume,
    };
}

pub fn parseTranscript(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
) ParseError![]types.TranscriptMessage {
    _ = allocator;
    _ = jsonl;
    return &.{};
}

test "ai_history_provider_codex: parses metadata from session_meta and response items" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"session_meta","id":"codex-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Fix the renderer crash"}],"timestamp":"2026-05-31T10:01:00Z"}
        \\{"type":"response_item","role":"assistant","content":[{"type":"output_text","text":"I found the issue."}],"timestamp":"2026-05-31T10:02:00Z"}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.codex/sessions/codex-abc.jsonl", jsonl);
    try std.testing.expectEqual(types.ProviderId.codex, meta.provider);
    try std.testing.expectEqualStrings("codex-abc", meta.session_id);
    try std.testing.expectEqualStrings("Fix the renderer crash", meta.title);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqualStrings("/home/me/.codex/sessions/codex-abc.jsonl", meta.source_path);
    try std.testing.expectEqual(types.ResumeKind.codex_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);
    try std.testing.expect(meta.created_at_ms > 0);
    try std.testing.expect(meta.last_active_at_ms >= meta.created_at_ms);
}

test "ai_history_provider_codex: transcript skips environment and AGENTS noise" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd</environment_context>"}],"timestamp":"2026-05-31T10:00:00Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /tmp/project"}],"timestamp":"2026-05-31T10:00:01Z"}
        \\{"type":"response_item","role":"user","content":[{"type":"input_text","text":"Summarize this repo"}],"timestamp":"2026-05-31T10:01:00Z"}
        \\{"type":"response_item","role":"assistant","content":[{"type":"output_text","text":"It is a terminal emulator."}],"timestamp":"2026-05-31T10:02:00Z"}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Summarize this repo", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.assistant, messages[1].role);
    try std.testing.expectEqualStrings("It is a terminal emulator.", messages[1].content);
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
zig test src/ai_history_provider_codex.zig
```

Expected: FAIL because `parseMetadata` returns empty fields and `parseTranscript` returns no messages.

- [ ] **Step 3: Implement minimal Codex parser**

Replace the stub functions with line-by-line JSON parsing using `std.json.parseFromSlice(std.json.Value, allocator, line, .{})`. Implement these helpers in the same file:

```zig
fn parseLine(allocator: std.mem.Allocator, line: []const u8) ?std.json.Parsed(std.json.Value) {
    if (std.mem.trim(u8, line, " \t\r\n").len == 0) return null;
    return std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch null;
}

fn objectString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn contentText(value: std.json.Value) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .array => |items| {
            for (items.items) |item| {
                if (item != .object) continue;
                if (objectString(item.object, "text")) |text| return text;
            }
        },
        else => {},
    }
    return null;
}

fn isNoiseUserText(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "<environment_context>") != null or
        std.mem.indexOf(u8, text, "AGENTS.md instructions") != null;
}
```

`parseMetadata` should duplicate owned strings with `allocator.dupe`, set `session_id` from `session_meta.id`, set `project_dir` from `session_meta.cwd`, set title from first non-noise user message, set `source_path`, count non-noise user/assistant messages, and parse RFC3339 timestamps with `std.time.iso8601.parse`.

`parseTranscript` should append only non-noise `response_item` user/assistant messages, duplicating content into the returned slice. Add a local `freeTranscript(allocator, messages)` helper if freeing message content is needed by tests.

- [ ] **Step 4: Register and run tests**

Add to `src/test_fast.zig` and `src/test_main.zig`:

```zig
    _ = @import("ai_history_provider_codex.zig");
```

Run:

```bash
zig test src/ai_history_provider_codex.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_provider_codex.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: parse codex history metadata"
```

---

### Task 3: Add Claude Code Provider Parser

**Files:**
- Create: `src/ai_history_provider_claude.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing Claude parser tests**

Create `src/ai_history_provider_claude.zig` with the same exported function names as Codex and these tests:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");

pub const ParseError = error{OutOfMemory};

pub fn parseMetadata(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    jsonl: []const u8,
) ParseError!types.SessionMeta {
    _ = allocator;
    _ = source_path;
    _ = jsonl;
    return types.SessionMeta{
        .provider = .claude,
        .session_id = "",
        .title = "",
        .source_path = "",
        .resume_kind = .claude_resume,
    };
}

pub fn parseTranscript(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
) ParseError![]types.TranscriptMessage {
    _ = allocator;
    _ = jsonl;
    return &.{};
}

test "ai_history_provider_claude: parses metadata from project transcript" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"Fix tests"}}
        \\{"sessionId":"claude-abc","cwd":"/home/me/project","timestamp":"2026-05-31T10:01:00.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will inspect the failure."}]}}
        \\
    ;

    const meta = try parseMetadata(allocator, "/home/me/.claude/projects/project/claude-abc.jsonl", jsonl);
    try std.testing.expectEqual(types.ProviderId.claude, meta.provider);
    try std.testing.expectEqualStrings("claude-abc", meta.session_id);
    try std.testing.expectEqualStrings("Fix tests", meta.title);
    try std.testing.expectEqualStrings("/home/me/project", meta.project_dir);
    try std.testing.expectEqual(types.ResumeKind.claude_resume, meta.resume_kind);
    try std.testing.expectEqual(@as(u32, 2), meta.message_count);
}

test "ai_history_provider_claude: skips isMeta and folds tool result messages" {
    const allocator = std.testing.allocator;
    const jsonl =
        \\{"sessionId":"claude-abc","isMeta":true,"timestamp":"2026-05-31T10:00:00.000Z","type":"user","message":{"role":"user","content":"meta"}}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:01:00.000Z","type":"user","message":{"role":"user","content":"Inspect repo"}}
        \\{"sessionId":"claude-abc","timestamp":"2026-05-31T10:02:00.000Z","type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ls output"}]}}
        \\
    ;

    const messages = try parseTranscript(allocator, jsonl);
    defer allocator.free(messages);
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqual(types.MessageRole.user, messages[0].role);
    try std.testing.expectEqualStrings("Inspect repo", messages[0].content);
    try std.testing.expectEqual(types.MessageRole.tool, messages[1].role);
    try std.testing.expectEqual(types.MessageKind.tool_result, messages[1].kind);
    try std.testing.expectEqualStrings("ls output", messages[1].content);
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run:

```bash
zig test src/ai_history_provider_claude.zig
```

Expected: FAIL because the parser returns empty metadata and no transcript messages.

- [ ] **Step 3: Implement minimal Claude parser**

Use line-by-line `std.json.Value` parsing. Rules:

- Skip any object with `isMeta == true`.
- Read `sessionId` from top-level `sessionId`.
- Read cwd from top-level `cwd`.
- Use first real user text as the title; if absent, use the basename of cwd; if absent, use `"Claude Code Session"`.
- Count real user, assistant, and tool-result messages.
- For `message.content`:
  - string => normal message text.
  - array item `{ "type": "text", "text": ... }` => normal assistant text.
  - array item `{ "type": "tool_result", "content": ... }` => `role = .tool`, `kind = .tool_result`.

- [ ] **Step 4: Register and run tests**

Add to both `src/test_fast.zig` and `src/test_main.zig`:

```zig
    _ = @import("ai_history_provider_claude.zig");
```

Run:

```bash
zig test src/ai_history_provider_claude.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_provider_claude.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: parse claude code history metadata"
```

---

### Task 4: Add Source, Cache, And Resume Pure Logic

**Files:**
- Create: `src/ai_history_source.zig`
- Create: `src/ai_history_cache.zig`
- Create: `src/ai_history_resume.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write source and resume tests**

Create `src/ai_history_source.zig`:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");

pub const Target = union(enum) {
    local,
    wsl: WslTarget,
    ssh: SshTargetRef,
};

pub const WslTarget = struct { distro: []const u8 = "" };
pub const SshTargetRef = struct { profile_name: []const u8 };

pub const ProviderFlags = packed struct {
    codex: bool = true,
    claude: bool = true,
};

pub const ProviderRoot = struct {
    provider: types.ProviderId,
    path: []const u8,
};

pub const Source = struct {
    id: []const u8,
    name: []const u8,
    target: Target,
    providers: ProviderFlags = .{},
    codex_root_override: ?[]const u8 = null,
    claude_root_override: ?[]const u8 = null,
    extra_roots: []const ProviderRoot = &.{},
};

pub fn defaultRoot(provider: types.ProviderId, home: []const u8, out: []u8) ?[]const u8 {
    const suffix = switch (provider) {
        .codex => ".codex",
        .claude => ".claude",
    };
    return std.fmt.bufPrint(out, "{s}/{s}", .{ home, suffix }) catch null;
}

test "ai_history_source: default provider roots use target home" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/me/.codex", defaultRoot(.codex, "/home/me", &buf).?);
    try std.testing.expectEqualStrings("/home/me/.claude", defaultRoot(.claude, "/home/me", &buf).?);
}
```

Create `src/ai_history_resume.zig`:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");

pub const ResumeError = error{MissingProjectDir, UnsupportedProvider, CommandTooLong};

pub fn resumeCommand(meta: types.SessionMeta, out: []u8) ResumeError![]const u8 {
    if (meta.project_dir.len == 0) return error.MissingProjectDir;
    return switch (meta.resume_kind) {
        .codex_resume => std.fmt.bufPrint(out, "codex resume {s}", .{meta.session_id}) catch error.CommandTooLong,
        .claude_resume => std.fmt.bufPrint(out, "claude --resume {s}", .{meta.session_id}) catch error.CommandTooLong,
        .unavailable => error.UnsupportedProvider,
    };
}

pub fn posixCdThen(command: []const u8, project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var quoted_buf: [512]u8 = undefined;
    const quoted = shellSingleQuote(&quoted_buf, project_dir) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "cd {s} && {s}", .{ quoted, command }) catch error.CommandTooLong;
}

pub fn posixDirectoryTest(project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var quoted_buf: [512]u8 = undefined;
    const quoted = shellSingleQuote(&quoted_buf, project_dir) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "test -d {s}", .{quoted}) catch error.CommandTooLong;
}

fn shellSingleQuote(out: []u8, value: []const u8) ?[]const u8 {
    var pos: usize = 0;
    if (pos >= out.len) return null;
    out[pos] = '\'';
    pos += 1;
    for (value) |ch| {
        if (ch == '\'') {
            const escaped = "'\\''";
            if (pos + escaped.len > out.len) return null;
            @memcpy(out[pos..][0..escaped.len], escaped);
            pos += escaped.len;
        } else {
            if (pos >= out.len) return null;
            out[pos] = ch;
            pos += 1;
        }
    }
    if (pos >= out.len) return null;
    out[pos] = '\'';
    pos += 1;
    return out[0..pos];
}

test "ai_history_resume: builds provider resume commands" {
    var out: [128]u8 = undefined;
    const codex: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectEqualStrings("codex resume abc", try resumeCommand(codex, &out));

    const claude: types.SessionMeta = .{
        .provider = .claude,
        .session_id = "xyz",
        .title = "B",
        .project_dir = "/home/me/project",
        .source_path = "b.jsonl",
        .resume_kind = .claude_resume,
    };
    try std.testing.expectEqualStrings("claude --resume xyz", try resumeCommand(claude, &out));
}

test "ai_history_resume: refuses missing project dir" {
    var out: [128]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    try std.testing.expectError(error.MissingProjectDir, resumeCommand(meta, &out));
}

test "ai_history_resume: quotes project dir before shell commands" {
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "test -d '/home/me/it'\\''s here'",
        try posixDirectoryTest("/home/me/it's here", &out),
    );
    try std.testing.expectEqualStrings(
        "cd '/home/me/space dir' && codex resume abc",
        try posixCdThen("codex resume abc", "/home/me/space dir", &out),
    );
}
```

Create `src/ai_history_cache.zig`:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");

pub const FileStamp = struct {
    size: u64,
    mtime_ns: i128,
};

pub const CacheRecord = struct {
    source_id: []const u8,
    provider: types.ProviderId,
    root_path: []const u8,
    source_path: []const u8,
    stamp: FileStamp,
    meta: types.SessionMeta,
};

pub fn stampMatches(record: CacheRecord, stamp: FileStamp) bool {
    return record.stamp.size == stamp.size and record.stamp.mtime_ns == stamp.mtime_ns;
}

test "ai_history_cache: cache stamp matches only exact size and mtime" {
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const record: CacheRecord = .{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    };
    try std.testing.expect(stampMatches(record, .{ .size = 10, .mtime_ns = 20 }));
    try std.testing.expect(!stampMatches(record, .{ .size = 11, .mtime_ns = 20 }));
}
```

- [ ] **Step 2: Register and run tests**

Add to both test aggregators:

```zig
    _ = @import("ai_history_source.zig");
    _ = @import("ai_history_cache.zig");
    _ = @import("ai_history_resume.zig");
```

Run:

```bash
zig test src/ai_history_source.zig
zig test src/ai_history_cache.zig
zig test src/ai_history_resume.zig
zig build test
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit**

```bash
git add src/ai_history_source.zig src/ai_history_cache.zig src/ai_history_resume.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add ai history source and resume logic"
```

---

### Task 5: Add AI History Session State Machine

**Files:**
- Create: `src/ai_history_session.zig`
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write failing session state tests**

Create `src/ai_history_session.zig`:

```zig
const std = @import("std");
const types = @import("ai_history_types.zig");
const source_mod = @import("ai_history_source.zig");

pub const LoadState = enum { idle, scanning, ready, failed };

pub const Session = struct {
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    state: LoadState = .idle,
    rows: std.ArrayListUnmanaged(types.SessionMeta) = .empty,
    selected: usize = 0,
    filter: [128]u8 = undefined,
    filter_len: usize = 0,
    status: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, source: source_mod.Source) Session {
        return .{ .allocator = allocator, .source = source };
    }

    pub fn deinit(self: *Session) void {
        self.rows.deinit(self.allocator);
    }

    pub fn beginScan(self: *Session) void {
        self.state = .scanning;
        self.status = "Scanning";
    }

    pub fn replaceRows(self: *Session, rows: []const types.SessionMeta) !void {
        self.rows.clearRetainingCapacity();
        try self.rows.appendSlice(self.allocator, rows);
        std.mem.sort(types.SessionMeta, self.rows.items, {}, types.lessRecent);
        self.selected = 0;
        self.state = .ready;
        self.status = "Ready";
    }

    pub fn setFilter(self: *Session, text: []const u8) void {
        self.filter_len = @min(text.len, self.filter.len);
        @memcpy(self.filter[0..self.filter_len], text[0..self.filter_len]);
        self.selected = 0;
    }

    pub fn visibleCount(self: *const Session) usize {
        var count: usize = 0;
        for (self.rows.items) |row| {
            if (types.metadataMatches(row, self.filter[0..self.filter_len])) count += 1;
        }
        return count;
    }

    pub fn selectedVisible(self: *const Session) ?types.SessionMeta {
        var visible_idx: usize = 0;
        for (self.rows.items) |row| {
            if (!types.metadataMatches(row, self.filter[0..self.filter_len])) continue;
            if (visible_idx == self.selected) return row;
            visible_idx += 1;
        }
        return null;
    }
};

test "ai_history_session: replacing rows sorts by last active time" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try session.replaceRows(&.{
        .{ .provider = .codex, .session_id = "old", .title = "Old", .source_path = "old.jsonl", .resume_kind = .codex_resume, .last_active_at_ms = 10 },
        .{ .provider = .claude, .session_id = "new", .title = "New", .source_path = "new.jsonl", .resume_kind = .claude_resume, .last_active_at_ms = 20 },
    });

    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("new", session.rows.items[0].session_id);
}

test "ai_history_session: metadata filter controls visible rows" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();

    try session.replaceRows(&.{
        .{ .provider = .codex, .session_id = "a", .title = "Renderer", .source_path = "a.jsonl", .resume_kind = .codex_resume },
        .{ .provider = .claude, .session_id = "b", .title = "Docs", .project_dir = "/repo/docs", .source_path = "b.jsonl", .resume_kind = .claude_resume },
    });
    session.setFilter("docs");
    try std.testing.expectEqual(@as(usize, 1), session.visibleCount());
    try std.testing.expectEqualStrings("b", session.selectedVisible().?.session_id);
}
```

- [ ] **Step 2: Run tests**

Run:

```bash
zig test src/ai_history_session.zig
```

Expected: PASS after the initial implementation above. If compilation fails due missing imports from previous tasks, fix imports only.

- [ ] **Step 3: Register in test aggregators**

Add to both `src/test_fast.zig` and `src/test_main.zig`:

```zig
    _ = @import("ai_history_session.zig");
```

Run:

```bash
zig build test
```

Expected: command exits 0.

- [ ] **Step 4: Commit**

```bash
git add src/ai_history_session.zig src/test_fast.zig src/test_main.zig
git commit -m "feat: add ai history session state"
```

---

### Task 6: Persist AI History Tabs Safely

**Files:**
- Modify: `src/session_persist.zig`
- Modify: `src/appwindow/tab.zig`

- [ ] **Step 1: Write failing persistence tests**

In `src/session_persist.zig`, extend `TabSnap` with a field and tests:

```zig
pub const AiHistorySnap = struct {
    source_id: []const u8,
    target_kind: []const u8,
    target_name: []const u8 = "",
};

pub const TabSnap = struct {
    title_override: ?[]const u8 = null,
    focused_leaf: u32 = 0,
    zoomed_leaf: ?u32 = null,
    tree: NodeSnap,
    ai_session_id: ?[]const u8 = null,
    ai_history: ?AiHistorySnap = null,
};
```

Add tests:

```zig
test "session_persist: AI history tab round-trips its source snapshot" {
    const allocator = std.testing.allocator;

    const placeholder = NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    const tabs = [_]TabSnap{.{
        .tree = placeholder,
        .ai_history = .{
            .source_id = "local-codex",
            .target_kind = "local",
            .target_name = "Local",
        },
    }};
    const original: Session = .{ .active_tab = 0, .tabs = @constCast(&tabs) };

    const json = try dumpSessionToString(allocator, original);
    defer allocator.free(json);

    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();

    try std.testing.expect(parsed.value.tabs[0].ai_history != null);
    try std.testing.expectEqualStrings("local-codex", parsed.value.tabs[0].ai_history.?.source_id);
    try std.testing.expectEqualStrings("local", parsed.value.tabs[0].ai_history.?.target_kind);
}

test "session_persist: old tab without ai_history defaults to null" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":1,"active_tab":0,"tabs":[{"tree":{"leaf":{"surface":{"local_shell":{}}}}}]}
    ;
    var parsed = try loadSessionFromString(allocator, json);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.tabs[0].ai_history == null);
}
```

- [ ] **Step 2: Run persistence tests**

Run:

```bash
zig test src/session_persist.zig
```

Expected: PASS once the field and tests compile.

- [ ] **Step 3: Update tab snapshot/restore hooks**

In `src/appwindow/tab.zig`:

1. Import `ai_history_session.zig` and `ai_history_source.zig`.
2. Add `ai_history_session: ?*ai_history_session.Session = null` to `TabState`.
3. Add `.ai_history` to `TabState.Kind`.
4. In `deinit`, add an `.ai_history` branch that deinitializes and destroys `ai_history_session`.
5. Add a restore hook:

```zig
pub threadlocal var g_ai_history_restore_hook: ?*const fn (session_persist.AiHistorySnap) bool = null;
```

6. In `snapshotTab`, before the terminal branch, add:

```zig
if (t.kind == .ai_history) {
    const session = t.ai_history_session orelse return error.NoAiHistorySession;
    const snap = try session.persistSnap(arena);
    return session_persist.TabSnap{
        .title_override = null,
        .focused_leaf = 0,
        .zoomed_leaf = null,
        .tree = .{ .leaf = .{ .surface = .{ .local_shell = .{} } } },
        .ai_history = snap,
    };
}
```

7. In `restoreTab`, before `ai_session_id`, route `snap.ai_history`:

```zig
if (snap.ai_history) |history_snap| {
    const hook = g_ai_history_restore_hook orelse return false;
    return hook(history_snap);
}
```

Add minimal methods in `ai_history_session.zig`:

```zig
pub fn persistSnap(self: *const Session, allocator: std.mem.Allocator) !session_persist.AiHistorySnap {
    return .{
        .source_id = try allocator.dupe(u8, self.source.id),
        .target_kind = try allocator.dupe(u8, switch (self.source.target) {
            .local => "local",
            .wsl => "wsl",
            .ssh => "ssh",
        }),
        .target_name = try allocator.dupe(u8, self.source.name),
    };
}
```

- [ ] **Step 4: Add tab restore tests**

In `src/appwindow/tab.zig`, add tests mirroring the existing AI Chat restore hook tests:

```zig
test "tab: restoreTab routes ai_history through the restore hook" {
    const placeholder = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var called = false;
    const hook = struct {
        fn cb(snap: session_persist.AiHistorySnap) bool {
            try std.testing.expectEqualStrings("local-history", snap.source_id);
            called = true;
            return true;
        }
    }.cb;
    g_ai_history_restore_hook = hook;
    defer g_ai_history_restore_hook = null;

    const snap = session_persist.TabSnap{
        .tree = placeholder,
        .ai_history = .{ .source_id = "local-history", .target_kind = "local", .target_name = "Local" },
    };
    try std.testing.expect(restoreTab(std.testing.allocator, &snap, 80, 24, .block, false));
    try std.testing.expect(called);
}
```

If Zig does not allow the closure to mutate `called`, use a threadlocal test variable in the same pattern as existing tests.

- [ ] **Step 5: Run tests**

Run:

```bash
zig test src/session_persist.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/session_persist.zig src/appwindow/tab.zig src/ai_history_session.zig
git commit -m "feat: persist ai history tabs"
```

---

### Task 7: Add AI History Tab Spawn And Placeholder Renderer

**Files:**
- Create: `src/renderer/ai_history_renderer.zig`
- Modify: `src/appwindow/tab.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Create renderer layout tests**

Create `src/renderer/ai_history_renderer.zig`:

```zig
const std = @import("std");

pub const Layout = struct {
    left_x: f32,
    left_w: f32,
    list_x: f32,
    list_w: f32,
    detail_x: f32,
    detail_w: f32,
};

pub fn computeLayout(x: f32, width: f32) Layout {
    const left_w = @min(@max(width * 0.20, 180), 260);
    const list_w = @min(@max(width * 0.32, 260), 420);
    const detail_w = @max(120, width - left_w - list_w);
    return .{
        .left_x = x,
        .left_w = left_w,
        .list_x = x + left_w,
        .list_w = list_w,
        .detail_x = x + left_w + list_w,
        .detail_w = detail_w,
    };
}

pub fn render(session: anytype, window_width: f32, window_height: f32, titlebar_offset: f32, x: f32, width: f32) void {
    _ = session;
    _ = window_width;
    _ = window_height;
    _ = titlebar_offset;
    _ = computeLayout(x, width);
    // Placeholder in this task. Later tasks draw actual rows and transcript.
}

test "ai_history_renderer: layout keeps a readable detail column" {
    const layout = computeLayout(0, 1200);
    try std.testing.expect(layout.left_w >= 180);
    try std.testing.expect(layout.list_w >= 260);
    try std.testing.expect(layout.detail_w >= 120);
    try std.testing.expectEqual(layout.left_x + layout.left_w, layout.list_x);
    try std.testing.expectEqual(layout.list_x + layout.list_w, layout.detail_x);
}
```

- [ ] **Step 2: Register renderer in test_main**

Add to `src/test_main.zig`:

```zig
    _ = @import("renderer/ai_history_renderer.zig");
```

Run:

```bash
zig test src/renderer/ai_history_renderer.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 3: Add spawn helper**

In `src/appwindow/tab.zig`, add:

```zig
pub fn spawnAiHistoryTab(allocator: std.mem.Allocator, source: ai_history_source.Source) bool {
    if (g_tab_count >= MAX_TABS) return false;
    const session_ptr = allocator.create(ai_history_session.Session) catch return false;
    session_ptr.* = ai_history_session.Session.init(allocator, source);

    const t = allocator.create(TabState) catch {
        session_ptr.deinit();
        allocator.destroy(session_ptr);
        return false;
    };
    t.kind = .ai_history;
    t.tree = .empty;
    t.focused = .root;
    t.ai_chat_session = null;
    t.copilot_session = null;
    t.ai_history_session = session_ptr;

    g_tabs[g_tab_count] = t;
    active_tab_state.g_active_tab = g_tab_count;
    g_tab_count += 1;
    return true;
}
```

In `src/AppWindow.zig`, import `ai_history_source` and add:

```zig
pub fn spawnAiHistoryTab(source: ai_history_source.Source) bool {
    const allocator = g_allocator orelse return false;
    if (!tab.spawnAiHistoryTab(allocator, source)) return false;
    clearUiStateOnTabChange();
    return true;
}
```

- [ ] **Step 4: Render active AI History tab**

In `src/AppWindow.zig`, import `renderer/ai_history_renderer.zig`. In the main render path where `active_tab.kind == .ai_chat` is handled, add an `.ai_history` branch that clears background, renders titlebar/sidebar/left panels as the AI Chat branch does, then calls:

```zig
if (active_tab.kind == .ai_history) {
    if (active_tab.ai_history_session) |session| {
        ai_history_renderer.render(
            session,
            @floatFromInt(fb_width),
            @floatFromInt(fb_height),
            titlebar_offset,
            leftPanelsWidth(),
            @as(f32, @floatFromInt(fb_width)) - leftPanelsWidth(),
        );
    }
}
```

Keep this as placeholder rendering; do not implement full UI in this task.

- [ ] **Step 5: Run compile verification**

Run:

```bash
zig build test
```

Expected: command exits 0.

- [ ] **Step 6: Commit**

```bash
git add src/renderer/ai_history_renderer.zig src/appwindow/tab.zig src/AppWindow.zig src/test_main.zig
git commit -m "feat: add ai history tab shell"
```

---

### Task 8: Add New Session Entry And Source Picker

**Files:**
- Modify: `src/platform/pty_command.zig`
- Modify: `src/platform/pty_command_windows.zig`
- Modify: `src/platform/pty_command_unsupported.zig`
- Modify: `src/command_center_state.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Update platform session launcher row helpers and tests**

In `src/platform/pty_command.zig`, add:

```zig
pub fn sessionLauncherAiHistoryRow() usize {
    return session_launcher_ai_history_row;
}

pub const session_launcher_ai_history_row = sessionLauncherAiHistoryRowForOs(builtin.os.tag);

pub fn sessionLauncherAiHistoryRowForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 4,
        .unsupported => 3,
    };
}
```

Change row counts:

```zig
pub fn sessionLauncherRowCountForOs(os_tag: std.Target.Os.Tag) usize {
    return switch (backendForOs(os_tag)) {
        .windows => 5,
        .unsupported => 4,
    };
}
```

Change detail strings:

```zig
.windows => "Choose PowerShell, SSH, WSL, AI Agent, or AI History",
.unsupported => "Choose Shell, SSH, AI Agent, or AI History",
```

Update tests near `session launcher rows are platform specific`:

```zig
try std.testing.expectEqual(@as(usize, 5), sessionLauncherRowCountForOs(.windows));
try std.testing.expectEqual(@as(usize, 4), sessionLauncherRowCountForOs(.linux));
try std.testing.expectEqual(@as(usize, 4), sessionLauncherRowCountForOs(.macos));
try std.testing.expectEqual(@as(usize, 4), sessionLauncherAiHistoryRowForOs(.windows));
try std.testing.expectEqual(@as(usize, 3), sessionLauncherAiHistoryRowForOs(.linux));
try std.testing.expect(std.mem.indexOf(u8, sessionLauncherDetailForOs(.windows), "AI History") != null);
```

- [ ] **Step 2: Expose command center row**

In `src/command_center_state.zig`:

```zig
pub const SESSION_LAUNCHER_ROW_AI_HISTORY: usize = platform_pty_command.session_launcher_ai_history_row;
```

- [ ] **Step 3: Update overlay enum and hit handling**

In `src/renderer/overlays.zig`, add `ai_history` to `SessionAction`.

Update key handling:

```zig
.key_h => {
    g_session_launcher_selected = command_center_state.SESSION_LAUNCHER_ROW_AI_HISTORY;
    runSessionLauncherRow(g_session_launcher_selected);
},
```

Update `runSessionLauncherRow`:

```zig
if (row == command_center_state.SESSION_LAUNCHER_ROW_AI_HISTORY) {
    openAiHistorySourcePicker();
    return;
}
```

Add source picker state for MVP:

```zig
const AiHistorySourceChoice = enum { local, wsl, ssh };
threadlocal var g_ai_history_source_visible: bool = false;
threadlocal var g_ai_history_source_selected: usize = 0;
```

Update `sessionLauncherVisible`, close logic, key routing, hit testing, and render logic the same way the SSH/AI list states are wired. For the first pass, rows are:

1. Local
2. WSL, only when `platform_pty_command.sessionLauncherWslRow() != null`
3. SSH Profile..., which opens the existing SSH picker in a new `.ai_history_select` mode
4. Cancel

Add this helper:

```zig
fn openAiHistorySourcePicker() void {
    g_session_launcher_visible = false;
    g_ai_history_source_visible = true;
    g_ai_history_source_selected = 0;
}
```

Add this local source opener:

```zig
fn openLocalAiHistorySession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = "local",
        .name = "Local",
        .target = .local,
    });
}
```

For WSL:

```zig
fn openWslAiHistorySession() void {
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = "wsl-default",
        .name = "WSL",
        .target = .{ .wsl = .{} },
    });
}
```

For SSH, add `ai_history_select` to `SshListMode`; when a profile is selected in that mode, call:

```zig
fn openSshAiHistorySession(profile_idx: usize) void {
    if (profile_idx >= g_ssh_profile_count) return;
    const profile = &g_ssh_profiles[profile_idx];
    const name = profileField(profile, .name);
    sessionLauncherClose();
    _ = AppWindow.spawnAiHistoryTab(.{
        .id = name,
        .name = name,
        .target = .{ .ssh = .{ .profile_name = name } },
    });
}
```

This task should only create the tab with source metadata; real scanning is wired later.

- [ ] **Step 4: Add compile guards**

In `src/test_main.zig`, extend the existing `overlays_source` guard to prevent provider logic entering overlays:

```zig
if (std.mem.indexOf(u8, overlays_source, ".codex") != null or
    std.mem.indexOf(u8, overlays_source, ".claude") != null or
    std.mem.indexOf(u8, overlays_source, "parseMetadata") != null)
{
    @compileError("renderer/overlays.zig must only launch AI History sources; provider scanning belongs in ai_history modules");
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: command exits 0.

- [ ] **Step 6: Commit**

```bash
git add src/platform/pty_command.zig src/platform/pty_command_windows.zig src/platform/pty_command_unsupported.zig src/command_center_state.zig src/renderer/overlays.zig src/test_main.zig
git commit -m "feat: add ai history session launcher"
```

---

### Task 9: Add Local Metadata Scanner And Lazy Transcript Loading

**Files:**
- Modify: `src/ai_history_session.zig`
- Modify: `src/ai_history_source.zig`
- Modify: `src/ai_history_provider_codex.zig`
- Modify: `src/ai_history_provider_claude.zig`

- [ ] **Step 1: Add scanner host seam tests**

In `src/ai_history_session.zig`, add a scanner host interface:

```zig
pub const FileEntry = struct {
    provider: types.ProviderId,
    path: []const u8,
    bytes: []const u8,
};

pub const ScanResult = struct {
    rows: []types.SessionMeta,
    warning_count: u32 = 0,
};

pub const ScannerHost = struct {
    ctx: *anyopaque,
    scan: *const fn (*anyopaque, std.mem.Allocator, source_mod.Source) anyerror!ScanResult,
    loadTranscript: *const fn (*anyopaque, std.mem.Allocator, types.SessionMeta) anyerror![]types.TranscriptMessage,
};
```

Add tests:

```zig
test "ai_history_session: scan host replaces rows and marks ready" {
    const allocator = std.testing.allocator;
    var fake = struct {
        fn scan(_: *anyopaque, alloc: std.mem.Allocator, _: source_mod.Source) !ScanResult {
            const rows = try alloc.alloc(types.SessionMeta, 1);
            rows[0] = .{
                .provider = .codex,
                .session_id = "abc",
                .title = "A",
                .source_path = "a.jsonl",
                .resume_kind = .codex_resume,
                .last_active_at_ms = 1,
            };
            return .{ .rows = rows };
        }
        fn load(_: *anyopaque, alloc: std.mem.Allocator, _: types.SessionMeta) ![]types.TranscriptMessage {
            const rows = try alloc.alloc(types.TranscriptMessage, 1);
            rows[0] = .{ .role = .user, .content = "hello" };
            return rows;
        }
    }{};
    var session = Session.init(allocator, .{ .id = "local", .name = "Local", .target = .local });
    defer session.deinit();
    const host: ScannerHost = .{ .ctx = &fake, .scan = @TypeOf(fake).scan, .loadTranscript = @TypeOf(fake).load };
    try session.scanNow(host);
    try std.testing.expectEqual(LoadState.ready, session.state);
    try std.testing.expectEqualStrings("abc", session.rows.items[0].session_id);
}
```

- [ ] **Step 2: Implement `scanNow` and transcript load**

Add methods:

```zig
pub fn scanNow(self: *Session, host: ScannerHost) !void {
    self.beginScan();
    const result = try host.scan(host.ctx, self.allocator, self.source);
    defer self.allocator.free(result.rows);
    try self.replaceRows(result.rows);
    self.status = if (result.warning_count == 0) "Ready" else "Ready with warnings";
}

pub fn loadSelectedTranscript(self: *Session, host: ScannerHost) ![]types.TranscriptMessage {
    const selected = self.selectedVisible() orelse return error.NoSelection;
    return host.loadTranscript(host.ctx, self.allocator, selected);
}
```

- [ ] **Step 3: Implement local filesystem scanner**

Add a function in `ai_history_session.zig`:

```zig
pub fn scanLocalFilesystem(
    allocator: std.mem.Allocator,
    source: source_mod.Source,
    home: []const u8,
) !ScanResult
```

It should:

- Resolve roots with `ai_history_source.defaultRoot` and overrides.
- Walk each existing root with `std.fs.openDirAbsolute(root, .{ .iterate = true })`.
- Recurse into subdirectories.
- Read only files ending in `.jsonl`.
- Skip files larger than a constant `MAX_METADATA_FILE_BYTES = 2 * 1024 * 1024` and increment warnings.
- Dispatch to Codex or Claude parser based on provider.

- [ ] **Step 4: Run focused tests**

Add a local temp-dir test that creates:

```text
tmp/.codex/sessions/a.jsonl
tmp/.claude/projects/demo/b.jsonl
```

Then call `scanLocalFilesystem(allocator, source, tmp_path)` and expect two rows.

Run:

```bash
zig test src/ai_history_session.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig src/ai_history_source.zig src/ai_history_provider_codex.zig src/ai_history_provider_claude.zig
git commit -m "feat: scan local ai history metadata"
```

---

### Task 10: Wire Basic UI Rows, Filtering, And Transcript Preview

**Files:**
- Modify: `src/renderer/ai_history_renderer.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/ai_history_session.zig`

- [ ] **Step 1: Add hit-test model tests**

In `src/renderer/ai_history_renderer.zig`, add:

```zig
pub const Hit = union(enum) {
    none,
    refresh,
    resume,
    row: usize,
};

pub fn hitTest(layout: Layout, x: f32, y_from_top: f32, row_top: f32, row_h: f32, row_count: usize) Hit {
    if (x >= layout.list_x and x < layout.list_x + layout.list_w and y_from_top >= row_top) {
        const idx_float = (y_from_top - row_top) / row_h;
        if (idx_float >= 0) {
            const idx: usize = @intFromFloat(@floor(idx_float));
            if (idx < row_count) return .{ .row = idx };
        }
    }
    return .none;
}

test "ai_history_renderer: hit test maps list rows" {
    const layout = computeLayout(0, 1000);
    const hit = hitTest(layout, layout.list_x + 10, 120, 100, 24, 5);
    try std.testing.expectEqual(@as(usize, 0), hit.row);
}
```

- [ ] **Step 2: Implement minimal render**

Use existing renderer helpers in `AppWindow.zig` / `renderer/overlays.zig` patterns: background bands, title text, muted labels, row highlight. Render:

- Left column source name and state.
- Search filter text.
- Middle rows from `session.rows`.
- Right detail placeholder for selected row: title, project dir, provider, source path, Resume label.

Keep message transcript rendering simple in this task: show loaded transcript as plain role-prefixed rows if available; otherwise show "Select a session" or "Loading transcript".

- [ ] **Step 3: Route input**

In `AppWindow.zig`, when active tab kind is `.ai_history`:

- Text input appends to `session.filter`.
- Backspace removes filter char.
- Arrow up/down changes `session.selected`.
- Enter triggers lazy transcript load for selected row.
- `r` triggers `scanNow` for local source.

Do not wire SSH/WSL remote scanning in this task.

- [ ] **Step 4: Run tests and compile**

Run:

```bash
zig test src/renderer/ai_history_renderer.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/ai_history_renderer.zig src/AppWindow.zig src/ai_history_session.zig
git commit -m "feat: render ai history browser"
```

---

### Task 11: Implement Resume For Local, WSL, And SSH Targets

**Files:**
- Modify: `src/ai_history_resume.zig`
- Modify: `src/AppWindow.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/platform/pty_command.zig`
- Modify: `src/platform/pty_command_windows.zig`
- Modify: `src/platform/pty_command_unsupported.zig`

- [ ] **Step 1: Add command builder tests**

In `src/ai_history_resume.zig`, add tests for full commands:

```zig
test "ai_history_resume: local shell command checks directory before resume" {
    var resume_buf: [128]u8 = undefined;
    var out: [512]u8 = undefined;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .project_dir = "/home/me/project",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const resume = try resumeCommand(meta, &resume_buf);
    try std.testing.expectEqualStrings(
        "test -d '/home/me/project' && cd '/home/me/project' && codex resume abc",
        try checkedPosixResume(resume, meta.project_dir, &out),
    );
}
```

Implement:

```zig
pub fn checkedPosixResume(command: []const u8, project_dir: []const u8, out: []u8) ResumeError![]const u8 {
    if (project_dir.len == 0) return error.MissingProjectDir;
    var quoted_buf: [512]u8 = undefined;
    const quoted = shellSingleQuote(&quoted_buf, project_dir) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "test -d {s} && cd {s} && {s}", .{ quoted, quoted, command }) catch error.CommandTooLong;
}
```

- [ ] **Step 2: Add AppWindow resume entry point**

In `src/AppWindow.zig`, add:

```zig
pub fn resumeAiHistorySelection() bool {
    const active = tab.activeTab() orelse return false;
    if (active.kind != .ai_history) return false;
    const session = active.ai_history_session orelse return false;
    const meta = session.selectedVisible() orelse return false;
    return spawnResumeTerminal(session.source.target, meta);
}
```

Implement `spawnResumeTerminal(target, meta)`:

- Build provider command via `ai_history_resume.resumeCommand`.
- For `.local`, use the configured local shell with a command that checks and changes directory.
- For `.wsl`, use `platform_pty_command.wslInteractiveCommand(command_buf[0..], meta.project_dir)` if it supports cwd; otherwise start WSL with `checkedPosixResume`.
- For `.ssh`, look up the saved SSH profile by name through an overlay/AppWindow helper, build SSH command with a trailing checked resume shell command, call `surface.setSshConnection(user, host, port, password, proxy_jump, password.len > 0, AppWindow.g_ssh_legacy_algorithms)`, and schedule password autofill exactly like existing SSH profile connection.

If project dir is missing or command cannot be built, call `overlays.showStatusToast("AI History resume failed: project path unavailable")` and return false.

- [ ] **Step 3: Wire Resume input**

In AI History input handling, map `Enter` on a selected row or a rendered Resume button hit to `resumeAiHistorySelection()`. Map `Space` to `session.loadSelectedTranscript(host)` so transcript preview remains separate from Resume.

- [ ] **Step 4: Run tests**

Run:

```bash
zig test src/ai_history_resume.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_resume.zig src/AppWindow.zig src/renderer/overlays.zig src/platform/pty_command.zig src/platform/pty_command_windows.zig src/platform/pty_command_unsupported.zig
git commit -m "feat: resume ai history sessions"
```

---

### Task 12: Add WSL And SSH Scanning Hooks

**Files:**
- Modify: `src/ai_history_session.zig`
- Modify: `src/platform/remote_file.zig`
- Modify: `src/renderer/overlays.zig`
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add remote scan command builder tests**

In `src/ai_history_session.zig`, add pure command builder tests:

```zig
pub fn providerFindCommand(provider: types.ProviderId, root: []const u8, out: []u8) ![]const u8 {
    var quoted_buf: [512]u8 = undefined;
    const quoted = remote_file.shellQuote(&quoted_buf, root) orelse return error.CommandTooLong;
    return std.fmt.bufPrint(out, "find {s} -type f -name '*.jsonl' -size -2048k | head -500", .{quoted}) catch error.CommandTooLong;
}

test "ai_history_session: remote provider find command quotes root" {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "find '/home/me/it'\\''s/.codex' -type f -name '*.jsonl' -size -2048k | head -500",
        try providerFindCommand(.codex, "/home/me/it's/.codex", &out),
    );
}
```

- [ ] **Step 2: Implement WSL scan**

Use `platform/remote_file.zig` existing `wslExec` and shell quoting helpers:

- Get home using `remote_file.wslExec(allocator, remote_file.wslHomeCommand())`.
- Build roots.
- Run `find` command per root.
- For each path returned, run `cat <quoted path>` with a size cap enforced by `find -size -2048k`.
- Parse with provider modules.

WSL failures should set session state failed only when HOME cannot be read. Missing provider roots should be provider warnings, not fatal.

- [ ] **Step 3: Implement SSH scan seam**

Do not add OpenSSH ControlMaster/ControlPersist. Reuse the same SSH profile command style as existing helper SSH/SCP paths. Add `pub fn sshExecCapture(allocator: std.mem.Allocator, conn: ssh_connection.SshConnection, command: []const u8) ![]u8` to `src/platform/remote_file.zig` so AI History uses the same remote-file helper area as WSL HOME/path quoting:

- Builds `ssh` with user, host, port, proxy jump, and legacy algorithms.
- Runs the supplied POSIX command.
- Preserves stderr for user-visible errors.
- Uses existing password askpass plumbing if available; never logs or stores the password.

Wire AI History SSH scan through the scanner host so tests can fake it.

- [ ] **Step 4: Add tests with fake scanner host**

Do not require real SSH or WSL in unit tests. Add tests that call the command builders and a fake host that returns remote JSONL bytes.

Run:

```bash
zig test src/ai_history_session.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_session.zig src/platform/remote_file.zig src/renderer/overlays.zig src/AppWindow.zig
git commit -m "feat: scan wsl and ssh ai history"
```

---

### Task 13: Add Metadata Cache

**Files:**
- Modify: `src/ai_history_cache.zig`
- Modify: `src/ai_history_session.zig`
- Modify: `src/platform/dirs.zig` or current platform dirs module that owns config/data paths

- [ ] **Step 1: Add cache JSON round-trip tests**

In `src/ai_history_cache.zig`, add:

```zig
pub const CacheFile = struct {
    version: u32 = 1,
    records: []CacheRecord,
};

pub fn dump(allocator: std.mem.Allocator, cache: CacheFile) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, cache, .{});
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(CacheFile) {
    return std.json.parseFromSlice(CacheFile, allocator, bytes, .{ .ignore_unknown_fields = true });
}

test "ai_history_cache: json round trip keeps metadata only" {
    const allocator = std.testing.allocator;
    const meta: types.SessionMeta = .{
        .provider = .codex,
        .session_id = "abc",
        .title = "A",
        .source_path = "a.jsonl",
        .resume_kind = .codex_resume,
    };
    const records = [_]CacheRecord{.{
        .source_id = "local",
        .provider = .codex,
        .root_path = "/home/me/.codex",
        .source_path = "/home/me/.codex/sessions/a.jsonl",
        .stamp = .{ .size = 10, .mtime_ns = 20 },
        .meta = meta,
    }};
    const json = try dump(allocator, .{ .records = @constCast(&records) });
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "transcript") == null);
    var parsed = try load(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("abc", parsed.value.records[0].meta.session_id);
}
```

- [ ] **Step 2: Implement cache path**

Add a platform dirs helper named `aiHistoryCachePath(allocator)` returning a path under the app data/config directory, for example `ai_history_cache.json`. Follow the existing style used for agent history or SSH hosts paths.

- [ ] **Step 3: Use cache during scan**

Before parsing a file, compare source path size/mtime to cache records. If unchanged, reuse metadata. If changed, parse and update. Keep transcript loading uncached.

- [ ] **Step 4: Run tests**

Run:

```bash
zig test src/ai_history_cache.zig
zig build test
```

Expected: both commands exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/ai_history_cache.zig src/ai_history_session.zig src/platform/dirs.zig
git commit -m "feat: cache ai history metadata"
```

---

### Task 14: Final UI Polish And Documentation

**Files:**
- Modify: `src/renderer/ai_history_renderer.zig`
- Modify: `docs/ai-agent.md`
- Modify: `README.md`
- Modify: `src/renderer/overlays.zig` if any user-visible session launcher text changed

- [ ] **Step 1: Complete UI states**

Render these states explicitly:

- Loading: "Scanning AI history..."
- Empty: "No Codex or Claude Code history found"
- Provider root missing: "Codex history not found" / "Claude Code history not found"
- Partial: "Scan completed with warnings"
- Connection failed: target error and Retry affordance
- Transcript load failed: detail-local Retry
- Resume unavailable: project path missing

- [ ] **Step 2: Check text fit**

Use constrained row text helpers, not raw unbounded text, for:

- Long source names.
- Long project dirs.
- Long titles.
- Long source paths.

Keep fixed row heights so filtering and selection do not resize the layout.

- [ ] **Step 3: Update docs**

In `docs/ai-agent.md`, add a section after "AI Chat Sessions":

```markdown
## AI History Sessions

Open the session launcher with `Ctrl+Shift+T` and choose `AI History` to browse
Codex and Claude Code transcripts stored on a Local, WSL, or SSH target. WispTerm
connects to the selected target, scans `$HOME/.codex` and `$HOME/.claude` for
metadata, and loads a transcript only when you open that row.

Use `Resume` to open a real terminal tab on the same target. WispTerm first
checks the original project directory recorded in the history file; if that
directory is missing, resume stops instead of falling back to `$HOME`.
```

In `README.md`, add this bullet immediately after the existing AI Agent sessions bullet:

```markdown
- **AI history browser** - browse local, WSL, and SSH Codex / Claude Code history and resume sessions from their original project directories
```

- [ ] **Step 4: Run docs and tests checks**

Run:

```bash
zig build test
zig build test-full
```

Expected: `zig build test` exits 0. `zig build test-full` should match the project baseline; if there is an existing known skip/failure, record the exact result in the final handoff.

- [ ] **Step 5: Commit**

```bash
git add src/renderer/ai_history_renderer.zig docs/ai-agent.md README.md src/renderer/overlays.zig
git commit -m "docs: describe ai history sessions"
```

---

## Final Verification

- [ ] Run `zig build test`.
- [ ] Run `zig build test-full`.
- [ ] On Windows, open WispTerm and press `Ctrl+Shift+T`.
- [ ] Choose `AI History` → `Local`; verify the tab opens and scans local `$HOME/.codex` / `$HOME/.claude`.
- [ ] Choose `AI History` → `WSL`; verify the tab gets WSL `$HOME` and scans WSL history.
- [ ] Choose `AI History` → SSH profile; verify the tab scans the remote `$HOME` without printing or logging the password.
- [ ] Open a transcript; verify the transcript loads only after row selection.
- [ ] Resume a record whose project directory exists; verify a new terminal tab opens in that directory and runs `codex resume <id>` or `claude --resume <id>`.
- [ ] Temporarily rename the project directory and retry Resume; verify WispTerm shows an error and does not execute resume from `$HOME`.
- [ ] Run Windows checkout safety checks if any files were added or renamed during implementation, per `docs/development.md#windows-checkout-safety`.

## Plan Self-Review Notes

- Spec coverage: The plan covers single-target AI History Session creation, Local/WSL/SSH scanning, Codex/Claude providers, metadata-only cache, lazy transcript loading, metadata filtering, Resume in original project dir, path-missing failure, docs, and final verification.
- Ghostty comparison: The plan keeps AI History outside terminal `Surface` / `SplitTree`, and uses a real terminal surface only for Resume.
- Known implementation risk: SSH scanning requires a careful helper that preserves OpenSSH stderr and does not introduce ControlMaster/ControlPersist. Task 12 isolates that work and avoids real SSH in unit tests.
