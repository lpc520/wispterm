//! Pure AI-agent state model + marker parsing for tmux/local agent panes.
//! No Surface/GPU deps -> unit-tested in the fast suite.
//!
//! The existing `agent_detector.zig` uses a richer heuristic model
//! (none/running/waiting_approval/needs_input/halted/failed/done + App =
//! none/codex/claude_code) suited for text-scraping.  The OSC 7748 marker
//! uses a simpler 4-state model (idle/working/blocked/done) and a broader
//! kind enum (claude/codex/gemini/other) — the two sets are intentionally
//! separate; this module owns the authoritative OSC-protocol types.

const std = @import("std");

pub const AgentKind = enum { none, claude, codex, gemini, other };
pub const AgentState = enum { idle, working, blocked, done };

/// Our private OSC introducer + tag:
///   OSC 7748 ; wispterm-agent ; state=<s> [; kind=<k>] ST
pub const OSC_NUM: u16 = 7748;
pub const TAG = "wispterm-agent";

pub const Marker = struct {
    state: ?AgentState = null,
    kind: ?AgentKind = null,
};

pub fn parseState(s: []const u8) ?AgentState {
    if (std.mem.eql(u8, s, "idle")) return .idle;
    if (std.mem.eql(u8, s, "working")) return .working;
    if (std.mem.eql(u8, s, "blocked")) return .blocked;
    if (std.mem.eql(u8, s, "done")) return .done;
    return null;
}

pub fn parseKind(s: []const u8) ?AgentKind {
    if (std.mem.eql(u8, s, "claude")) return .claude;
    if (std.mem.eql(u8, s, "codex")) return .codex;
    if (std.mem.eql(u8, s, "gemini")) return .gemini;
    if (std.mem.eql(u8, s, "other")) return .other;
    return null;
}

/// Parse the OSC 7748 payload (everything after `OSC 7748;`, terminator
/// already stripped): `wispterm-agent;state=working;kind=claude`.
/// Returns null if the tag is absent or no recognized field is present.
pub fn parseMarker(payload: []const u8) ?Marker {
    var it = std.mem.splitScalar(u8, payload, ';');
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, std.mem.trim(u8, first, " "), TAG)) return null;
    var m: Marker = .{};
    var any = false;
    while (it.next()) |field| {
        const f = std.mem.trim(u8, field, " ");
        if (std.mem.startsWith(u8, f, "state=")) {
            if (parseState(f["state=".len..])) |st| {
                m.state = st;
                any = true;
            }
        } else if (std.mem.startsWith(u8, f, "kind=")) {
            if (parseKind(f["kind=".len..])) |k| {
                m.kind = k;
                any = true;
            }
        }
    }
    return if (any) m else null;
}

/// Identify the agent from a tmux `#{pane_current_command}` (process basename).
pub fn kindFromCommand(cmd: []const u8) AgentKind {
    const base = std.fs.path.basename(std.mem.trim(u8, cmd, " "));
    if (std.mem.eql(u8, base, "claude")) return .claude;
    if (std.mem.eql(u8, base, "codex")) return .codex;
    if (std.mem.eql(u8, base, "gemini")) return .gemini;
    return .none;
}

/// Aggregate pane states to a tab indicator by priority:
/// blocked > working > done > idle. Empty -> idle.
pub fn aggregate(states: []const AgentState) AgentState {
    var result: AgentState = .idle;
    for (states) |s| {
        if (rank(s) > rank(result)) result = s;
    }
    return result;
}

fn rank(s: AgentState) u8 {
    return switch (s) {
        .idle => 0,
        .done => 1,
        .working => 2,
        .blocked => 3,
    };
}

test "parseMarker reads state and kind" {
    const m = parseMarker("wispterm-agent;state=working;kind=claude").?;
    try std.testing.expectEqual(AgentState.working, m.state.?);
    try std.testing.expectEqual(AgentKind.claude, m.kind.?);
}

test "parseMarker state only" {
    const m = parseMarker("wispterm-agent;state=blocked").?;
    try std.testing.expectEqual(AgentState.blocked, m.state.?);
    try std.testing.expect(m.kind == null);
}

test "parseMarker rejects wrong tag / no fields" {
    try std.testing.expect(parseMarker("other;state=idle") == null);
    try std.testing.expect(parseMarker("wispterm-agent;foo=bar") == null);
    try std.testing.expect(parseMarker("wispterm-agent;state=bogus") == null);
}

test "kindFromCommand maps known agents" {
    try std.testing.expectEqual(AgentKind.claude, kindFromCommand("claude"));
    try std.testing.expectEqual(AgentKind.codex, kindFromCommand("/usr/bin/codex"));
    try std.testing.expectEqual(AgentKind.none, kindFromCommand("bash"));
}

test "aggregate picks the highest-priority state" {
    try std.testing.expectEqual(AgentState.blocked, aggregate(&.{ .idle, .working, .blocked }));
    try std.testing.expectEqual(AgentState.working, aggregate(&.{ .idle, .done, .working }));
    try std.testing.expectEqual(AgentState.idle, aggregate(&.{}));
}
