//! ACP external-agent turn driver. Bridges the stdio JSON-RPC client
//! (`acp/client.zig` + `acp/schema.zig`) to the AI-chat session write-backs so
//! an ACP profile actually converses: it spawns the agent once per session,
//! runs `initialize`/`session/new`, then drives one `session/prompt` per user
//! turn — streaming `agent_message_chunk` text into the transcript, surfacing
//! tool calls as progress cards, and round-tripping `session/request_permission`
//! through the session's blocking `askUser`.
//!
//! Threading: the connection's reader thread calls `onSessionUpdate` and each
//! inbound request runs on its own thread calling `onRequest`. Both mutate the
//! transcript ONLY through the `session.mutex`-guarded `ai_chat` write-backs
//! (same contract `request.zig` follows). `AcpState.state_mutex` guards the
//! per-turn `stream_idx` hand-off between the reader thread and the turn thread.
const std = @import("std");
const builtin = @import("builtin");
const ai_chat = @import("session.zig");
const proto = @import("protocol.zig");
const acp_client = @import("../../acp/client.zig");
const schema = @import("../../acp/schema.zig");

const Session = ai_chat.Session;
const ChatRequest = ai_chat.ChatRequest;

/// Bounded wait for the `initialize` / `session/new` handshake replies.
const HANDSHAKE_TIMEOUT_MS: u64 = 20_000;
/// Poll granularity while blocked on the `session/prompt` reply (so the stop
/// button can inject a `session/cancel` within ~100ms).
const PROMPT_POLL_MS: u64 = 100;

/// Live ACP connection + per-turn stream state, owned by the Session. Created on
/// the first ACP turn and reused across turns; torn down on connection death or
/// `Session.deinit`. `state_mutex` guards `stream_idx` only.
pub const AcpState = struct {
    allocator: std.mem.Allocator,
    session: *Session,
    conn: *acp_client.Connection,
    acp_session_id: []u8,
    stream_idx: ?usize,
    state_mutex: std.Thread.Mutex = .{},

    /// Kill the child + join every client thread (so no more handler callbacks
    /// reference this struct), then free. `conn.deinit()` MUST run first.
    pub fn deinit(self: *AcpState) void {
        self.conn.deinit();
        if (self.acp_session_id.len > 0) self.allocator.free(self.acp_session_id);
        self.allocator.destroy(self);
    }

    fn takeStreamIdx(self: *AcpState) ?usize {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        const idx = self.stream_idx;
        self.stream_idx = null;
        return idx;
    }

    fn peekStreamIdx(self: *AcpState) ?usize {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return self.stream_idx;
    }
};

/// Worker-thread entry point for one ACP turn. Owns `request` and frees it.
pub fn acpTurnThreadMain(request: *ChatRequest) void {
    defer request.deinit();
    const session = request.session;
    defer ai_chat.maybeAutoTitle(session);

    // Sessions restored from history carry an empty acp_command (the record does
    // not persist it). Fail with actionable guidance instead of a spawn crash.
    if (request.acp_command.len == 0) {
        ai_chat.failAssistantStream(session, null, "此 ACP 会话缺少启动命令（通常来自历史记录恢复）。请通过模型切换器（/model 或点击模型名）重新选择 ACP 配置后再继续。");
        return;
    }

    const prompt_text = lastUserText(request.messages) orelse {
        ai_chat.failAssistantStream(session, null, "No user message to send.");
        return;
    };

    const state = ensureState(session, request) catch |err| {
        // ensureState leaves session.acp_state null on any failure (its own
        // errdefer tears the partial connection down), so there is nothing to
        // tear down here — and thus no stderr tail to attach for a handshake
        // failure (the process is already gone); the error name carries it.
        failTurn(session, "ACP agent 启动失败", err, null);
        return;
    };

    // Fresh turn on a reused connection: clear any stale stream from a prior
    // cancelled turn so the first chunk opens a new bubble.
    _ = state.takeStreamIdx();

    const params = schema.encodePromptParams(request.allocator, state.acp_session_id, prompt_text) catch return;
    defer request.allocator.free(params);
    const pending = state.conn.beginCall("session/prompt", params) catch |err| {
        failTurn(session, "ACP prompt 发送失败", err, state);
        teardownState(session);
        return;
    };
    defer pending.release();

    var cancel_sent = false;
    while (!pending.wait(PROMPT_POLL_MS)) {
        // Session teardown: abandon the wait so Session.deinit's request_thread
        // join proceeds to tear the connection down (which fails this pending
        // call). Do NOT wait for a graceful stopReason a closing session ignores.
        if (session.closing.load(.acquire)) return;
        if (ai_chat.requestCancelled(request) and !cancel_sent) {
            cancel_sent = true;
            const cp = schema.encodeCancelParams(request.allocator, state.acp_session_id) catch continue;
            defer request.allocator.free(cp);
            state.conn.notify("session/cancel", cp) catch {};
        }
    }

    const result_json = pending.take(request.allocator) catch |err| {
        // Connection died mid-turn: surface stderr, drop the dead state so the
        // NEXT user message restarts the agent (context reset).
        failTurn(session, "ACP agent 异常退出（下一条消息将重启并重置上下文）", err, state);
        // failTurn finalized the turn (request_inflight now false), so this
        // stopRequest just cancels a permission askUser that may still be blocked
        // on the dead agent — letting AcpState.deinit's inbound-thread join finish
        // — and then resets its own transient stop flag (a no-op when idle).
        // ponytail: covers the realistic stuck case (agent asked permission then
        // died); the sub-µs window between spawning an inbound thread and it
        // reaching askUser is not covered — a hang there would need a rebuild.
        session.stopRequest();
        teardownState(session);
        return;
    };
    defer request.allocator.free(result_json);

    if (cancel_sent) {
        ai_chat.finishStoppedRequest(session);
        return;
    }
    finalizeTurn(session, state, request.started_ms);
}

/// Scan a request's messages tail-first for the last user turn's text.
fn lastUserText(messages: []const proto.RequestMessage) ?[]const u8 {
    var i = messages.len;
    while (i > 0) {
        i -= 1;
        if (messages[i].role == .user) return messages[i].content;
    }
    return null;
}

/// Spawn + handshake the agent on first use; reuse a live connection after.
fn ensureState(session: *Session, request: *ChatRequest) !*AcpState {
    if (session.acp_state) |st| {
        if (st.conn.alive()) return st;
        teardownState(session); // dead connection → rebuild below
    }
    const a = request.allocator;

    const argv = try acp_client.splitCommand(a, request.acp_command);
    defer {
        for (argv) |item| a.free(item);
        a.free(argv);
    }
    if (argv.len == 0) return error.AcpCommandMissing;

    const cwd = try resolveCwdAlloc(a, session);
    defer a.free(cwd);

    const st = try a.create(AcpState);
    errdefer a.destroy(st);
    st.* = .{ .allocator = a, .session = session, .conn = undefined, .acp_session_id = &.{}, .stream_idx = null };

    const conn = try acp_client.Connection.spawn(a, argv, cwd, .{
        .ctx = st,
        .onSessionUpdate = onSessionUpdate,
        .onRequest = onRequest,
    });
    st.conn = conn;
    errdefer conn.deinit();

    {
        const params = try schema.encodeInitializeParams(a, false); // terminal capability lands in PR3
        defer a.free(params);
        var parsed = try callResult(a, conn, "initialize", params);
        defer parsed.deinit();
        const version = schema.parseInitializeProtocolVersion(parsed.value) orelse return error.AcpInitializeFailed;
        if (version != schema.PROTOCOL_VERSION) return error.AcpProtocolVersionMismatch;
    }
    {
        const params = try schema.encodeNewSessionParams(a, cwd);
        defer a.free(params);
        var parsed = try callResult(a, conn, "session/new", params);
        defer parsed.deinit();
        st.acp_session_id = schema.parseNewSessionId(a, parsed.value) orelse return error.AcpNewSessionFailed;
    }

    // Single-owner publish: only the turn thread writes session.acp_state, and
    // Session.deinit reads it after joining the turn thread. No lock needed.
    session.acp_state = st;
    return st;
}

/// Blocking request → owned + parsed `result` JSON. Caller `.deinit()`s the Parsed.
fn callResult(a: std.mem.Allocator, conn: *acp_client.Connection, method: []const u8, params: []const u8) !std.json.Parsed(std.json.Value) {
    const pending = try conn.beginCall(method, params);
    defer pending.release();
    if (!pending.wait(HANDSHAKE_TIMEOUT_MS)) return error.AcpCallTimeout;
    const json = try pending.take(a);
    defer a.free(json);
    return std.json.parseFromSlice(std.json.Value, a, json, .{});
}

/// The working dir the tool layer would use, made absolute. Falls back through
/// session override → global default → process cwd.
fn resolveCwdAlloc(a: std.mem.Allocator, session: *Session) ![]u8 {
    if (session.workingDirOverride()) |w| {
        if (std.fs.cwd().realpathAlloc(a, w)) |abs| return abs else |_| {}
    }
    if (ai_chat.defaultWorkingDir()) |w| {
        if (std.fs.cwd().realpathAlloc(a, w)) |abs| return abs else |_| {}
    }
    return std.process.getCwdAlloc(a);
}

/// Drop and free the session's ACP connection. `AcpState.deinit` kills the child
/// and joins the client threads. Safe no-op when no state is stored. Does NOT
/// touch request state, so it is safe to call mid-turn (dead-connection rebuild).
fn teardownState(session: *Session) void {
    const st = session.acp_state orelse return;
    session.acp_state = null;
    st.deinit();
}

/// Finish the turn on the standard path so request_inflight / the status line
/// clear even for a pure-tool turn that streamed no text.
fn finalizeTurn(session: *Session, state: *AcpState, started_ms: i64) void {
    if (state.takeStreamIdx()) |idx| {
        ai_chat.finishAssistantStream(session, idx, started_ms, 0, null);
    } else {
        ai_chat.appendAssistantResult(session, .{ .content = @constCast("") }, started_ms);
    }
}

/// `failAssistantStream` with a formatted reason + the agent's stderr tail.
fn failTurn(session: *Session, prefix: []const u8, err: anyerror, state: ?*AcpState) void {
    const a = session.allocator;
    const base = std.fmt.allocPrint(a, "{s}: {s}", .{ prefix, @errorName(err) }) catch return;
    defer a.free(base);

    var combined: ?[]u8 = null;
    defer if (combined) |c| a.free(c);
    if (state) |st| {
        if (st.conn.stderrTail(a)) |tail| {
            defer a.free(tail);
            const trimmed = std.mem.trim(u8, tail, " \t\r\n");
            if (trimmed.len > 0) {
                combined = std.fmt.allocPrint(a, "{s}\n--- agent stderr ---\n{s}", .{ base, trimmed }) catch null;
            }
        } else |_| {}
    }

    const idx = if (state) |st| st.peekStreamIdx() else null;
    ai_chat.failAssistantStream(session, idx, combined orelse base);
}

// ---------------------------------------------------------------------------
// Handler callbacks (client reader / inbound threads → session write-backs)
// ---------------------------------------------------------------------------

fn onSessionUpdate(ctx: *anyopaque, allocator: std.mem.Allocator, update: schema.SessionUpdate) void {
    const state: *AcpState = @ptrCast(@alignCast(ctx));
    var u = update;
    defer u.deinit(allocator);
    switch (u) {
        .agent_message_chunk => |text| appendDelta(state, text, ""),
        .agent_thought_chunk => |text| appendDelta(state, "", text),
        .tool_call => |info| {
            closeStream(state);
            progressCard(state.session, info);
        },
        .tool_call_update => |info| if (isFailed(info.status)) progressFail(state.session, info),
        .plan => |text| ai_chat.appendProgressMessage(state.session, text) catch {},
        .ignored => {},
    }
}

/// Append streamed content/reasoning, opening the assistant bubble on first use.
/// Runs only on the (single) reader thread, so the open-once check is race-free;
/// state_mutex is held only for the stream_idx hand-off to the turn thread.
fn appendDelta(state: *AcpState, content: []const u8, reasoning: []const u8) void {
    state.state_mutex.lock();
    if (state.stream_idx == null) {
        state.stream_idx = ai_chat.beginAssistantStream(state.session) catch {
            state.state_mutex.unlock();
            return;
        };
    }
    const idx = state.stream_idx.?;
    state.state_mutex.unlock();
    ai_chat.appendAssistantStreamDelta(state.session, idx, content, reasoning) catch {};
}

/// Seal the current assistant bubble so a following tool card / new text starts
/// a fresh message. Leaves earlier bubbles rendered as-is (no usage footer).
fn closeStream(state: *AcpState) void {
    state.state_mutex.lock();
    defer state.state_mutex.unlock();
    state.stream_idx = null;
}

fn progressCard(session: *Session, info: schema.ToolCallInfo) void {
    const text = progressCardText(session.allocator, info) catch return;
    defer session.allocator.free(text);
    ai_chat.appendProgressMessage(session, text) catch {};
}

fn progressFail(session: *Session, info: schema.ToolCallInfo) void {
    const text = std.fmt.allocPrint(session.allocator, "[{s}] {s} 失败", .{ kindText(info.kind), titleText(info.title) }) catch return;
    defer session.allocator.free(text);
    ai_chat.appendProgressMessage(session, text) catch {};
}

fn isFailed(status: []const u8) bool {
    return std.mem.eql(u8, status, "failed");
}

fn kindText(kind: []const u8) []const u8 {
    return if (kind.len > 0) kind else "tool";
}

fn titleText(title: []const u8) []const u8 {
    return if (title.len > 0) title else "(untitled)";
}

/// Progress-card label for a tool call. Terminal-backed calls point the user at
/// the terminal tab that PR3 will attach; everything else is `[kind] title`.
fn progressCardText(allocator: std.mem.Allocator, info: schema.ToolCallInfo) ![]u8 {
    if (info.terminal_id.len > 0) {
        return std.fmt.allocPrint(allocator, "[terminal] {s} → 已在终端标签运行", .{titleText(info.title)});
    }
    return std.fmt.allocPrint(allocator, "[{s}] {s}", .{ kindText(info.kind), titleText(info.title) });
}

fn onRequest(ctx: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) anyerror![]u8 {
    const state: *AcpState = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, method, "session/request_permission")) {
        var req = try schema.parsePermissionRequest(allocator, params);
        defer req.deinit(allocator);
        var options: [8]ai_chat.QuestionOption = undefined; // ACP option lists are small (≤4 observed)
        const n = @min(req.options.len, options.len);
        for (req.options[0..n], 0..) |opt, i| options[i] = .{ .label = opt.name, .description = opt.kind };
        const answer = state.session.askUser(req.title, options[0..n]);
        return switch (answer) {
            .option_index => |i| schema.encodePermissionSelected(allocator, req.options[@min(i, n - 1)].id),
            .custom, .cancelled => schema.encodePermissionCancelled(allocator),
        };
    }
    return error.MethodNotFound; // terminal/* wired in PR3
}

// ===========================================================================
// Tests
// ===========================================================================

test "lastUserText returns the final user turn, ignoring later assistant/tool" {
    var messages = [_]proto.RequestMessage{
        .{ .role = .user, .content = @constCast("first") },
        .{ .role = .assistant, .content = @constCast("reply") },
        .{ .role = .user, .content = @constCast("second") },
        .{ .role = .tool, .content = @constCast("tool output") },
    };
    try std.testing.expectEqualStrings("second", lastUserText(messages[0..]).?);
    try std.testing.expect(lastUserText(&.{}) == null);
    var only_tool = [_]proto.RequestMessage{.{ .role = .tool, .content = @constCast("x") }};
    try std.testing.expect(lastUserText(only_tool[0..]) == null);
}

test "progressCardText maps tool kind/title and terminal calls" {
    const a = std.testing.allocator;
    const plain = try progressCardText(a, .{
        .id = @constCast("t1"),
        .title = @constCast("run tests"),
        .kind = @constCast("execute"),
        .status = @constCast("pending"),
        .content_text = @constCast(""),
        .terminal_id = @constCast(""),
    });
    defer a.free(plain);
    try std.testing.expectEqualStrings("[execute] run tests", plain);

    const term = try progressCardText(a, .{
        .id = @constCast("t2"),
        .title = @constCast("npm test"),
        .kind = @constCast("execute"),
        .status = @constCast("pending"),
        .content_text = @constCast(""),
        .terminal_id = @constCast("term-1"),
    });
    defer a.free(term);
    try std.testing.expect(std.mem.startsWith(u8, term, "[terminal] npm test"));

    const untitled = try progressCardText(a, .{
        .id = @constCast(""),
        .title = @constCast(""),
        .kind = @constCast(""),
        .status = @constCast(""),
        .content_text = @constCast(""),
        .terminal_id = @constCast(""),
    });
    defer a.free(untitled);
    try std.testing.expectEqualStrings("[tool] (untitled)", untitled);
}

fn buildAcpRequest(a: std.mem.Allocator, session: *Session, prompt: []const u8) !*ChatRequest {
    const messages = try a.alloc(proto.RequestMessage, 1);
    errdefer a.free(messages);
    messages[0] = .{ .role = .user, .content = try a.dupe(u8, prompt) };

    const req = try a.create(ChatRequest);
    req.* = .{
        .allocator = a,
        .session = session,
        .base_url = try a.dupe(u8, ""),
        .api_key = try a.dupe(u8, ""),
        .model = try a.dupe(u8, "agent"),
        .protocol = .acp,
        .system_prompt = try a.dupe(u8, ""),
        .messages = messages,
        .thinking_enabled = false,
        .reasoning_effort = try a.dupe(u8, ""),
        .stream = false,
        .agent_enabled = false,
        .acp_command = try a.dupe(u8, session.acp_command),
        .tool_host = null,
        .tool_snapshot = null,
        .started_ms = std.time.milliTimestamp(),
    };
    return req;
}

fn waitForQuestion(session: *Session, timeout_ms: u64) !void {
    var waited: u64 = 0;
    while (session.questionView() == null) {
        if (waited >= timeout_ms) return error.QuestionTimeout;
        std.Thread.sleep(2 * std.time.ns_per_ms);
        waited += 2;
    }
}

test "acp turn streams text, shows a tool card, and round-trips a permission" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;

    // Scripted /bin/sh agent: echoes back request ids, gates the prompt on a
    // permission round-trip, emits a tool card + streamed text, then end_turn.
    const script =
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":1}}\n' "$id";;
        \\    *'"session/new"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"sessionId":"s1"}}\n' "$id";;
        \\    *'"session/prompt"'*)
        \\      printf '%s\n' '{"jsonrpc":"2.0","id":100,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"run tests"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"reject","name":"Reject","kind":"reject_once"}]}}'
        \\      IFS= read -r reply
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"run tests","kind":"execute","status":"pending"}}}'
        \\      printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hello world"}}}}'
        \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"stopReason":"end_turn"}}\n' "$id"
        \\      ;;
        \\  esac
        \\done
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "agent.sh", .data = script });
    const script_path = try tmp.dir.realpathAlloc(a, "agent.sh");
    defer a.free(script_path);

    // Non-deepseek base_url so no DEEPSEEK_API_KEY env pickup → empty key → no
    // auto-title network call fires from the turn's `defer maybeAutoTitle`.
    const session = try Session.initWithProtocol(a, "acp", "https://example.invalid", "", "agent", "acp", "sys", "false", "", "false", "false");
    defer session.deinit();
    const cmd = try std.fmt.allocPrint(a, "/bin/sh {s}", .{script_path});
    defer a.free(cmd);
    session.setAcpCommand(cmd);

    const req = try buildAcpRequest(a, session, "please run the tests");
    var thread = try std.Thread.spawn(.{}, acpTurnThreadMain, .{req});

    // Answer the permission the agent gates its work on; then the turn finishes.
    try waitForQuestion(session, 15_000);
    const view = session.questionView().?;
    try std.testing.expectEqualStrings("run tests", view.question);
    try std.testing.expectEqual(@as(usize, 2), view.options.len);
    try std.testing.expect(session.resolveQuestionOption(0));
    thread.join();

    // The connection is live and owned by the session; deinit tears it down.
    try std.testing.expect(session.acp_state != null);

    session.mutex.lock();
    defer session.mutex.unlock();
    var saw_stream = false;
    var saw_card = false;
    for (session.messages.items) |msg| {
        if (msg.role == .assistant and std.mem.indexOf(u8, msg.content, "hello world") != null) saw_stream = true;
        if (msg.role == .tool and std.mem.indexOf(u8, msg.content, "[execute] run tests") != null) saw_card = true;
    }
    try std.testing.expect(saw_stream);
    try std.testing.expect(saw_card);
}
