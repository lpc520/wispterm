//! Unified CLI agent delegation tool (`cli_agent`): hand one self-contained
//! task to an external CLI agent (first backend: Codex), stream its progress
//! into the chat card, and return its final report. Leaf module — depends on
//! ai_chat_types, platform process helpers, and sibling exec/output adapters;
//! never on session.zig or AppWindow.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("../assistant/conversation/types.zig");

const ToolContext = types.ToolContext;

pub const DEFAULT_TIMEOUT_MS: u32 = 600_000;
pub const MAX_TIMEOUT_MS: u32 = 3_600_000;

/// One parsed stdout line from a backend. Set fields are owned by the
/// caller-provided allocator; the caller frees them.
pub const Event = struct {
    progress: ?[]u8 = null,
    final: ?[]u8 = null,
};

pub const Backend = struct {
    key: []const u8, // value of the tool's `agent` argument
    display: []const u8,
    exe: []const u8, // executable name resolved via PATH
    base_args: []const []const u8, // fixed args between exe and task
    parseEvent: *const fn (allocator: std.mem.Allocator, line: []const u8) ?Event,
};

const codex_backend = Backend{
    .key = "codex",
    .display = "Codex",
    .exe = "codex",
    .base_args = &.{ "exec", "--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check", "--" },
    .parseEvent = codexParseEvent,
};

pub const backends = [_]Backend{codex_backend};

/// Comma-joined backend keys for error messages and docs; stays correct as
/// the table grows.
pub const available_keys = blk: {
    var s: []const u8 = "";
    for (backends, 0..) |b, i| s = s ++ (if (i == 0) "" else ", ") ++ b.key;
    break :blk s;
};

pub fn find(key: []const u8) ?*const Backend {
    for (&backends) |*backend| {
        if (std.mem.eql(u8, backend.key, key)) return backend;
    }
    return null;
}

fn objectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Parse one line of `codex exec --json` output. Tolerant by design: any
/// line that is not JSON or not a recognized event returns null; when no
/// agent_message is ever seen, run() falls back to the raw stdout tail, so
/// codex JSON-format drift degrades gracefully instead of failing.
fn codexParseEvent(allocator: std.mem.Allocator, line: []const u8) ?Event {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const event_type = objectString(parsed.value, "type") orelse return null;
    const item = parsed.value.object.get("item") orelse return null;
    const item_type = objectString(item, "item_type") orelse return null;
    if (std.mem.eql(u8, event_type, "item.completed") and std.mem.eql(u8, item_type, "agent_message")) {
        const text = objectString(item, "text") orelse return null;
        const owned = allocator.dupe(u8, text) catch return null;
        return .{ .final = owned };
    }
    if (std.mem.eql(u8, event_type, "item.started") and std.mem.eql(u8, item_type, "command_execution")) {
        const command = objectString(item, "command") orelse return null;
        const owned = std.fmt.allocPrint(allocator, "codex: $ {s}", .{command}) catch return null;
        return .{ .progress = owned };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "find resolves codex and rejects unknown keys" {
    const backend = find("codex") orelse return error.TestExpectedBackend;
    try std.testing.expectEqualStrings("codex", backend.exe);
    try std.testing.expect(find("oh-my-pi") == null);
    try std.testing.expectEqualStrings("codex", available_keys);
}

test "codexParseEvent extracts progress from item.started command_execution" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.started\",\"item\":{\"id\":\"item_1\",\"item_type\":\"command_execution\",\"command\":\"bash -lc 'ls'\",\"status\":\"in_progress\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.final == null);
    try std.testing.expectEqualStrings("codex: $ bash -lc 'ls'", event.progress.?);
}

test "codexParseEvent extracts final from item.completed agent_message" {
    const a = std.testing.allocator;
    const line = "{\"type\":\"item.completed\",\"item\":{\"id\":\"item_9\",\"item_type\":\"agent_message\",\"text\":\"All tests pass.\"}}";
    const event = codexParseEvent(a, line) orelse return error.TestExpectedEvent;
    defer if (event.progress) |p| a.free(p);
    defer if (event.final) |f| a.free(f);
    try std.testing.expect(event.progress == null);
    try std.testing.expectEqualStrings("All tests pass.", event.final.?);
}

test "codexParseEvent ignores unknown events, other item phases, and non-JSON lines" {
    const a = std.testing.allocator;
    try std.testing.expect(codexParseEvent(a, "[2026-07-10] plain human output") == null);
    try std.testing.expect(codexParseEvent(a, "") == null);
    try std.testing.expect(codexParseEvent(a, "{not json") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"thread.started\",\"thread_id\":\"t1\"}") == null);
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"reasoning\",\"text\":\"hmm\"}}") == null);
    // command_execution progress only fires on item.started, not completed (no dupes)
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"command_execution\",\"command\":\"ls\",\"status\":\"completed\"}}") == null);
    // agent_message only counts when completed
    try std.testing.expect(codexParseEvent(a, "{\"type\":\"item.started\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"partial\"}}") == null);
}
