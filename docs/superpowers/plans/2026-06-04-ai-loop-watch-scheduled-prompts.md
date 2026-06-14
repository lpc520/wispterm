# `/loop` + `/watch` Scheduled AI Prompts — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `/loop` (interval × count) and `/watch` (daily `HH:MM` / one-shot `YYYY-MM-DD HH:MM`) slash commands to WispTerm's AI chat that re-submit a prompt to the bound AI session on a schedule, surviving app restart.

**Architecture:** A pure, fully-unit-tested schedule engine (`ai_loop_schedule.zig`: parsing, time math, JSON codec) sits under a thin runtime store (`ai_loop_store.zig`: in-memory task list, `loop_tasks.json` persistence, tick-driven firing through a wired injector callback). The AI-chat layer parses commands into the store; the app layer (`AppWindow.zig`) wires the injector (resolve a session by id in `tab.g_tabs`, inject + submit) and calls `store.tick()` once per UI frame. No new threads — firing runs on the UI thread where `tab.g_tabs` is populated.

**Tech Stack:** Zig, `std.json` (parse with `.allocate = .alloc_always` per the known parseFromSlice alias-UAF lesson), `std.mem.tokenizeAny`, existing `Session.appendInputText`/`submit`/`requestState`/`sessionId`, `ai_history_time.localOffsetSeconds`, `platform/dirs.pathInConfigDir`.

**Reference spec:** `docs/superpowers/specs/2026-06-04-ai-loop-watch-scheduled-prompts-design.md`

**Scope note (forced by the codebase):** There is no programmatic "resume session by id" (only the interactive `commandPaletteOpenAgentHistory()` picker) and no per-session `provider`/`cwd`. So when a task's bound session is *closed* at fire time, v1 **skips the fire and keeps the task** (it re-activates when the session is reopened, because `/resume` restores the original `session_id` — `ai_chat.zig:640`). Auto-resume/respawn is explicitly out of scope. Slash-command output text is **English**, matching the existing siblings in `slashCommandOutput` (`/clear`, `/permission`, …); per-string i18n is deferred to match that pattern.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/ai_loop_schedule.zig` (create) | **Pure engine.** `Task`, `TaskKind`, arg parsing, interval/time math, `advanceAfterFire`/`recomputeAfterRestart`/`isFinished`/`isDue`, JSON codec. No I/O, no `Session`, no globals. Time + tz offset are passed in. Tests run in the fast suite. |
| `src/ai_loop_store.zig` (create) | **Runtime store.** Owns `[]Task` + mutex + `next_id`, loads/saves `loop_tasks.json`, `registerLoop`/`registerWatch`/`stop`/`snapshotForSession`, and `tick(now)` which fires due tasks through a wired `Injector` callback. Imports the engine + `platform/dirs` + `ai_history_time` only. Tests run in the full suite. |
| `src/ai_chat_composer.zig` (modify) | Add `.loop` + `.watch` to `SlashCommand` and two `slash_command_entries` so they parse + autocomplete. |
| `src/ai_chat.zig` (modify) | Add `Session.submitScheduledPrompt`; dispatch `.loop`/`.watch` in `runBuiltinCommandLocked` (list / stop / create), make `slashCommandOutput` exhaustive. |
| `src/AppWindow.zig` (modify) | Implement + wire the injector, init the store at startup, call `store.tick()` per frame, deinit at shutdown. |
| `src/test_fast.zig` (modify) | `_ = @import("ai_loop_schedule.zig");` |
| `src/test_main.zig` (modify) | `_ = @import("ai_loop_schedule.zig");` and `_ = @import("ai_loop_store.zig");` |

---

## Task 1: Engine — interval & count parsing

**Files:**
- Create: `src/ai_loop_schedule.zig`

- [ ] **Step 1: Write the failing tests**

Create `src/ai_loop_schedule.zig` with ONLY this content (imports, error set, the two functions' signatures returning `error.BadInterval`/`error.BadCount` stubs, and the tests). We add real bodies in Step 3.

```zig
//! Pure (std-only) schedule engine for the /loop and /watch AI-chat commands.
//! No I/O, no Session, no globals. The caller passes the current time (`now_ms`,
//! ms since epoch) and the local UTC offset (`offset_s`, seconds); nothing here
//! reads the clock or the timezone. The runtime store (ai_loop_store.zig) is the
//! I/O layer over this.
const std = @import("std");

pub const ParseError = error{
    MissingArgs,
    BadInterval,
    BadCount,
    BadTime,
    PastTime,
    EmptyPrompt,
};

/// "<positive int><unit>" where unit is s|m|h|d -> milliseconds.
pub fn parseIntervalMs(tok: []const u8) ParseError!i64 {
    _ = tok;
    return error.BadInterval;
}

/// Positive decimal integer -> u32 (0 rejected).
pub fn parseCount(tok: []const u8) ParseError!u32 {
    _ = tok;
    return error.BadCount;
}

test "parseIntervalMs accepts units s/m/h/d" {
    try std.testing.expectEqual(@as(i64, 30_000), try parseIntervalMs("30s"));
    try std.testing.expectEqual(@as(i64, 5 * 60_000), try parseIntervalMs("5m"));
    try std.testing.expectEqual(@as(i64, 2 * 3_600_000), try parseIntervalMs("2h"));
    try std.testing.expectEqual(@as(i64, 24 * 3_600_000), try parseIntervalMs("1d"));
}

test "parseIntervalMs rejects bad forms" {
    try std.testing.expectError(error.BadInterval, parseIntervalMs("5"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("0h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("-3h"));
    try std.testing.expectError(error.BadInterval, parseIntervalMs("5x"));
}

test "parseCount" {
    try std.testing.expectEqual(@as(u32, 10), try parseCount("10"));
    try std.testing.expectError(error.BadCount, parseCount("0"));
    try std.testing.expectError(error.BadCount, parseCount("abc"));
    try std.testing.expectError(error.BadCount, parseCount("-1"));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — the new tests fail their assertions (stubs return errors), or a compile error if `ai_loop_schedule.zig` isn't imported yet. (It gets imported in Task 5; for now run with a temporary import or accept the assertion failures once Task 5 lands. If you prefer, do Task 5's `test_fast.zig` import line first, then return here.)

> Note for Zig: tests live inside the source file and only run once the file is `_ = @import`ed in `test_fast.zig`. To see these fail immediately, add `_ = @import("ai_loop_schedule.zig");` to `src/test_fast.zig` now (it's required anyway — see Task 5).

- [ ] **Step 3: Implement the real bodies**

Replace the two stub functions with:

```zig
pub fn parseIntervalMs(tok: []const u8) ParseError!i64 {
    if (tok.len < 2) return error.BadInterval;
    const unit = tok[tok.len - 1];
    const n = std.fmt.parseInt(i64, tok[0 .. tok.len - 1], 10) catch return error.BadInterval;
    if (n <= 0) return error.BadInterval;
    const mult: i64 = switch (unit) {
        's' => std.time.ms_per_s,
        'm' => std.time.ms_per_min,
        'h' => std.time.ms_per_hour,
        'd' => std.time.ms_per_day,
        else => return error.BadInterval,
    };
    return n * mult;
}

pub fn parseCount(tok: []const u8) ParseError!u32 {
    const n = std.fmt.parseInt(u32, tok, 10) catch return error.BadCount;
    if (n == 0) return error.BadCount;
    return n;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS (no failures; `ai_loop_schedule` tests included).

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_schedule.zig src/test_fast.zig
git commit -m "feat(loop): pure interval/count parsing for /loop /watch engine"
```

---

## Task 2: Engine — `/loop` and `/watch` argument parsing

**Files:**
- Modify: `src/ai_loop_schedule.zig`

- [ ] **Step 1: Write the failing tests**

Add these tests at the bottom of `src/ai_loop_schedule.zig`:

```zig
test "parseLoopArgs splits interval, count, prompt" {
    const r = try parseLoopArgs("30m 8 检查 CI，把失败的测试贴出来");
    try std.testing.expectEqual(@as(i64, 30 * std.time.ms_per_min), r.interval_ms);
    try std.testing.expectEqual(@as(u32, 8), r.count);
    try std.testing.expectEqualStrings("检查 CI，把失败的测试贴出来", r.prompt);
}

test "parseLoopArgs errors" {
    try std.testing.expectError(error.MissingArgs, parseLoopArgs("   "));
    try std.testing.expectError(error.MissingArgs, parseLoopArgs("30m"));
    try std.testing.expectError(error.EmptyPrompt, parseLoopArgs("30m 8"));
    try std.testing.expectError(error.BadInterval, parseLoopArgs("30 8 hi"));
}

test "parseWatchArgs daily HH:MM" {
    // 2024-01-01 00:00 UTC = 1704067200000 ms; offset 0 for determinism.
    const now: i64 = 1_704_067_200_000;
    const r = try parseWatchArgs("09:00 生成早报", now, 0);
    try std.testing.expect(r.daily);
    try std.testing.expectEqual(@as(i32, 9 * 60), r.tod_minutes);
    try std.testing.expectEqual(now + 9 * std.time.ms_per_hour, r.next_fire_ms);
    try std.testing.expectEqualStrings("生成早报", r.prompt);
}

test "parseWatchArgs daily rolls to tomorrow when time passed" {
    const now: i64 = 1_704_067_200_000 + 10 * std.time.ms_per_hour; // 10:00 UTC
    const r = try parseWatchArgs("09:00 x", now, 0);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour, r.next_fire_ms);
}

test "parseWatchArgs one-shot absolute" {
    const now: i64 = 1_704_067_200_000; // 2024-01-01 00:00 UTC
    const r = try parseWatchArgs("2024-01-02 09:30 提醒", now, 0);
    try std.testing.expect(!r.daily);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour + 30 * std.time.ms_per_min, r.next_fire_ms);
    try std.testing.expectEqualStrings("提醒", r.prompt);
}

test "parseWatchArgs one-shot in the past errors" {
    const now: i64 = 1_704_067_200_000;
    try std.testing.expectError(error.PastTime, parseWatchArgs("2023-12-31 09:00 x", now, 0));
}

test "parseWatchArgs bad time" {
    try std.testing.expectError(error.BadTime, parseWatchArgs("25:00 x", 0, 0));
    try std.testing.expectError(error.BadTime, parseWatchArgs("09:99 x", 0, 0));
    try std.testing.expectError(error.MissingArgs, parseWatchArgs("   ", 0, 0));
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — compile error: `parseLoopArgs`/`parseWatchArgs`/`LoopArgs`/`WatchArgs` undefined.

- [ ] **Step 3: Implement**

Add to `src/ai_loop_schedule.zig` (above the tests):

```zig
pub const LoopArgs = struct { interval_ms: i64, count: u32, prompt: []const u8 };
pub const WatchArgs = struct { daily: bool, tod_minutes: i32, next_fire_ms: i64, prompt: []const u8 };

pub fn parseLoopArgs(arg: []const u8) ParseError!LoopArgs {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return error.MissingArgs;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const interval_tok = it.next() orelse return error.MissingArgs;
    const count_tok = it.next() orelse return error.MissingArgs;
    const interval_ms = try parseIntervalMs(interval_tok);
    const count = try parseCount(count_tok);
    const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
    if (prompt.len == 0) return error.EmptyPrompt;
    return .{ .interval_ms = interval_ms, .count = count, .prompt = prompt };
}

pub fn parseWatchArgs(arg: []const u8, now_ms: i64, offset_s: i32) ParseError!WatchArgs {
    const trimmed = std.mem.trim(u8, arg, " \t\r\n");
    if (trimmed.len == 0) return error.MissingArgs;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const first = it.next() orelse return error.MissingArgs;
    if (std.mem.indexOfScalar(u8, first, '-') != null) {
        const time_tok = it.next() orelse return error.BadTime;
        const abs = try parseAbsoluteMs(first, time_tok, offset_s);
        if (abs <= now_ms) return error.PastTime;
        const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
        if (prompt.len == 0) return error.EmptyPrompt;
        return .{ .daily = false, .tod_minutes = 0, .next_fire_ms = abs, .prompt = prompt };
    }
    const tod = try parseHourMinute(first);
    const next = nextDailyOccurrence(tod, now_ms, offset_s);
    const prompt = std.mem.trim(u8, trimmed[it.index..], " \t\r\n");
    if (prompt.len == 0) return error.EmptyPrompt;
    return .{ .daily = true, .tod_minutes = tod, .next_fire_ms = next, .prompt = prompt };
}

fn parseHourMinute(tok: []const u8) ParseError!i32 {
    const colon = std.mem.indexOfScalar(u8, tok, ':') orelse return error.BadTime;
    const hh = std.fmt.parseInt(i32, tok[0..colon], 10) catch return error.BadTime;
    const mm = std.fmt.parseInt(i32, tok[colon + 1 ..], 10) catch return error.BadTime;
    if (hh < 0 or hh > 23 or mm < 0 or mm > 59) return error.BadTime;
    return hh * 60 + mm;
}

fn parseAbsoluteMs(date_tok: []const u8, time_tok: []const u8, offset_s: i32) ParseError!i64 {
    var dit = std.mem.splitScalar(u8, date_tok, '-');
    const y = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    const mo = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    const d = std.fmt.parseInt(i64, dit.next() orelse return error.BadTime, 10) catch return error.BadTime;
    if (dit.next() != null) return error.BadTime;
    if (mo < 1 or mo > 12 or d < 1 or d > 31) return error.BadTime;
    const tod = try parseHourMinute(time_tok);
    const days = daysFromCivil(y, mo, d);
    const local_ms = (days * std.time.s_per_day + @as(i64, tod) * std.time.s_per_min) * std.time.ms_per_s;
    return local_ms - @as(i64, offset_s) * std.time.ms_per_s;
}

/// Days since 1970-01-01 for a proleptic-Gregorian date (Howard Hinnant).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // [0, 11]
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

/// Next UTC ms at which local time-of-day `tod_minutes` occurs (strictly future).
pub fn nextDailyOccurrence(tod_minutes: i32, now_ms: i64, offset_s: i32) i64 {
    const off_ms: i64 = @as(i64, offset_s) * std.time.ms_per_s;
    const local_now = now_ms + off_ms;
    const day_start = @divFloor(local_now, std.time.ms_per_day) * std.time.ms_per_day;
    var candidate = day_start + @as(i64, tod_minutes) * std.time.ms_per_min;
    if (candidate <= local_now) candidate += std.time.ms_per_day;
    return candidate - off_ms;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_schedule.zig
git commit -m "feat(loop): parse /loop and /watch arguments + civil-date time math"
```

---

## Task 3: Engine — `Task` lifecycle (advance / restart / finished / due)

**Files:**
- Modify: `src/ai_loop_schedule.zig`

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src/ai_loop_schedule.zig`:

```zig
fn fixtureLoop(remaining: u32, next_fire: i64) Task {
    return .{ .kind = .loop, .session_id = "s", .prompt = "p", .interval_ms = 30 * std.time.ms_per_min, .remaining = remaining, .next_fire_ms = next_fire };
}

test "isDue at boundary" {
    const t = fixtureLoop(3, 1000);
    try std.testing.expect(isDue(&t, 1000));
    try std.testing.expect(isDue(&t, 2000));
    try std.testing.expect(!isDue(&t, 999));
}

test "advanceAfterFire loop decrements and pushes interval" {
    var t = fixtureLoop(3, 1000);
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expectEqual(@as(u32, 2), t.remaining);
    try std.testing.expectEqual(@as(i64, 1000 + 30 * std.time.ms_per_min), t.next_fire_ms);
    try std.testing.expect(!isFinished(&t));
}

test "advanceAfterFire loop reaching zero is finished" {
    var t = fixtureLoop(1, 1000);
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expectEqual(@as(u32, 0), t.remaining);
    try std.testing.expect(isFinished(&t));
}

test "advanceAfterFire one-shot watch finishes" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = false, .remaining = 1, .next_fire_ms = 1000 };
    advanceAfterFire(&t, 1000, 0);
    try std.testing.expect(isFinished(&t));
}

test "advanceAfterFire daily watch rolls forward and never finishes" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = true, .tod_minutes = 9 * 60, .next_fire_ms = 1_704_067_200_000 + 9 * std.time.ms_per_hour };
    advanceAfterFire(&t, t.next_fire_ms, 0);
    try std.testing.expectEqual(1_704_067_200_000 + std.time.ms_per_day + 9 * std.time.ms_per_hour, t.next_fire_ms);
    try std.testing.expect(!isFinished(&t));
}

test "recomputeAfterRestart loop skips missed intervals" {
    var t = fixtureLoop(3, 1000); // far in the past
    recomputeAfterRestart(&t, 10_000, 0);
    try std.testing.expectEqual(@as(i64, 10_000 + 30 * std.time.ms_per_min), t.next_fire_ms);
}

test "recomputeAfterRestart one-shot caught up to now when missed" {
    var t = Task{ .kind = .watch, .session_id = "s", .prompt = "p", .daily = false, .remaining = 1, .next_fire_ms = 1000 };
    recomputeAfterRestart(&t, 10_000, 0);
    try std.testing.expectEqual(@as(i64, 10_000), t.next_fire_ms);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — compile error: `Task`/`TaskKind`/`isDue`/`advanceAfterFire`/`isFinished`/`recomputeAfterRestart` undefined.

- [ ] **Step 3: Implement**

Add to `src/ai_loop_schedule.zig` (above the tests). The string fields are owned by the caller (the store); these functions touch only scalar fields.

```zig
pub const TaskKind = enum { loop, watch };

pub const Task = struct {
    id: u32 = 0,
    kind: TaskKind,
    session_id: []const u8,
    model: []const u8 = "",
    title: []const u8 = "",
    prompt: []const u8,
    interval_ms: i64 = 0, // loop only
    remaining: u32 = 0, // loop: sends left. one-shot watch: 1 pending -> 0 done. daily: unused.
    daily: bool = false, // watch: true=recurring HH:MM, false=one-shot absolute
    tod_minutes: i32 = 0, // daily watch: minutes since local midnight
    next_fire_ms: i64 = 0,
    created_ms: i64 = 0,
};

pub fn isDue(t: *const Task, now_ms: i64) bool {
    return t.next_fire_ms <= now_ms;
}

pub fn isFinished(t: *const Task) bool {
    return switch (t.kind) {
        .loop => t.remaining == 0,
        .watch => if (t.daily) false else t.remaining == 0,
    };
}

pub fn advanceAfterFire(t: *Task, now_ms: i64, offset_s: i32) void {
    switch (t.kind) {
        .loop => {
            if (t.remaining > 0) t.remaining -= 1;
            t.next_fire_ms += t.interval_ms;
            if (t.next_fire_ms <= now_ms) t.next_fire_ms = now_ms + t.interval_ms; // drift guard
        },
        .watch => {
            if (t.daily) {
                t.next_fire_ms = nextDailyOccurrence(t.tod_minutes, now_ms, offset_s);
            } else {
                t.remaining = 0; // one-shot done
            }
        },
    }
}

/// Fix `next_fire_ms` on load: loop skips missed intervals (resume cadence),
/// daily watch -> next future occurrence, missed one-shot -> fire ASAP (now).
pub fn recomputeAfterRestart(t: *Task, now_ms: i64, offset_s: i32) void {
    switch (t.kind) {
        .loop => {
            if (t.next_fire_ms <= now_ms) t.next_fire_ms = now_ms + t.interval_ms;
        },
        .watch => {
            if (t.daily) {
                t.next_fire_ms = nextDailyOccurrence(t.tod_minutes, now_ms, offset_s);
            } else if (t.next_fire_ms <= now_ms) {
                t.next_fire_ms = now_ms;
            }
        },
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_schedule.zig
git commit -m "feat(loop): Task lifecycle (advance/restart/finished/due)"
```

---

## Task 4: Engine — JSON codec

**Files:**
- Modify: `src/ai_loop_schedule.zig`

- [ ] **Step 1: Write the failing test**

Add at the bottom of `src/ai_loop_schedule.zig`:

```zig
test "encode/decode round-trip" {
    const a = std.testing.allocator;
    const tasks = [_]Task{
        .{ .id = 1, .kind = .loop, .session_id = "session-7", .model = "glm", .title = "Build", .prompt = "check ci", .interval_ms = 1_800_000, .remaining = 8, .next_fire_ms = 123, .created_ms = 100 },
        .{ .id = 2, .kind = .watch, .session_id = "session-7", .prompt = "report", .daily = true, .tod_minutes = 540, .remaining = 0, .next_fire_ms = 456, .created_ms = 100 },
    };
    const model = FileModel{ .version = 1, .next_id = 3, .tasks = @constCast(tasks[0..]) };

    const bytes = try encode(a, model);
    defer a.free(bytes);

    var parsed = try decodeAlloc(a, bytes);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 3), parsed.value.next_id);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.tasks.len);
    try std.testing.expectEqualStrings("session-7", parsed.value.tasks[0].session_id);
    try std.testing.expectEqual(TaskKind.watch, parsed.value.tasks[1].kind);
    try std.testing.expectEqual(@as(i32, 540), parsed.value.tasks[1].tod_minutes);
    try std.testing.expectEqualStrings("check ci", parsed.value.tasks[0].prompt);
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — compile error: `FileModel`/`encode`/`decodeAlloc` undefined.

- [ ] **Step 3: Implement**

Add to `src/ai_loop_schedule.zig` (above the tests). Use `.allocate = .alloc_always` so parsed strings never alias the (soon-freed) input buffer — the known parseFromSlice UAF lesson. Match the exact `std.json` call shapes already used in `src/ai_history_cache.zig` if the signatures differ in this Zig version.

```zig
pub const FileModel = struct {
    version: u32 = 1,
    next_id: u32 = 1,
    tasks: []Task = &.{},
};

pub fn encode(allocator: std.mem.Allocator, model: FileModel) ![]u8 {
    return std.json.stringifyAlloc(allocator, model, .{ .whitespace = .indent_2 });
}

pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(FileModel) {
    return std.json.parseFromSlice(FileModel, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}
```

> If `std.json.stringifyAlloc`/`.whitespace` doesn't compile in this Zig version, copy the exact stringify call style from another module in this repo (grep `stringify` / `std.json`); the data shape (struct of ints/bools/enums/strings + a slice) is plain and supported either way.

- [ ] **Step 4: Run the test to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_schedule.zig
git commit -m "feat(loop): JSON codec for loop_tasks (alloc_always)"
```

---

## Task 5: Register the engine in both test runners; confirm fast suite green

**Files:**
- Modify: `src/test_fast.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Add the imports**

In `src/test_fast.zig`, next to the other `_ = @import(...)` lines (near line 37/52), add:

```zig
    _ = @import("ai_loop_schedule.zig");
```

In `src/test_main.zig`, next to its `ai_chat_composer` import (near line 615), add:

```zig
    _ = @import("ai_loop_schedule.zig");
```

(If you already added the `test_fast.zig` line during Task 1, just confirm both are present.)

- [ ] **Step 2: Run both suites**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: both PASS, 0 failed. (Per project baseline `test-full` is ~all-green with a few skips.)

- [ ] **Step 3: Commit**

```bash
git add src/test_fast.zig src/test_main.zig
git commit -m "test(loop): include ai_loop_schedule in fast + full suites"
```

---

## Task 6: Runtime store — state, register, snapshot, stop, persistence

**Files:**
- Create: `src/ai_loop_store.zig`
- Modify: `src/test_main.zig`

- [ ] **Step 1: Write the failing test**

Add `_ = @import("ai_loop_store.zig");` to `src/test_main.zig` (next to the Task 5 import). Then create `src/ai_loop_store.zig` with the full module below (Step 3) BUT temporarily, to drive TDD, first add only the test block at the end and stubs — simplest is to write the whole module (Step 3) and this test together, run, and confirm green. Concretely, create the file with the Step 3 content plus this test appended:

```zig
test "register loop, snapshot, stop, persist round-trip" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    const info = try store.registerLoop("30m 3 hello", .{ .session_id = "session-7", .model = "glm", .title = "t" }, 1000, 0);
    try std.testing.expectEqual(@as(u32, 1), info.id);
    try std.testing.expectEqual(@as(u32, 3), info.remaining);
    try std.testing.expectEqual(@as(i64, 1000 + 30 * std.time.ms_per_min), info.next_fire_ms);

    var snap = try store.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("hello", snap[0].prompt);

    // Reload from disk into a second store sees the persisted task.
    var store2 = Store.init(a, path);
    defer store2.deinit();
    var snap2 = try store2.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap2);
    try std.testing.expectEqual(@as(usize, 1), snap2.len);

    try std.testing.expect(store2.stop("session-7", 1));
    var snap3 = try store2.snapshotForSession(a, "session-7", .loop);
    defer freeSnapshot(a, snap3);
    try std.testing.expectEqual(@as(usize, 0), snap3.len);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — compile error until Step 3's module body exists (or assertion failures if partially stubbed).

- [ ] **Step 3: Implement the module**

Create `src/ai_loop_store.zig`:

```zig
//! Runtime store + persistence for /loop and /watch tasks. Thin glue over the
//! pure engine (ai_loop_schedule.zig). Owns the in-memory task list, the
//! `loop_tasks.json` file, and the per-frame `tick` that fires due tasks through
//! a wired injector. All mutation happens on the UI thread (slash-command
//! handling + tick), guarded by a mutex for defensive safety.
const std = @import("std");
const engine = @import("ai_loop_schedule.zig");
const platform_dirs = @import("platform/dirs.zig");
const ai_history_time = @import("ai_history_time.zig");

pub const Task = engine.Task;
pub const TaskKind = engine.TaskKind;
pub const ParseError = engine.ParseError;

/// Result the injector reports back so the store knows whether to advance.
pub const InjectOutcome = enum { sent, busy, closed };

/// Resolves a session by id and injects the prompt. Set by the app layer.
pub const Injector = *const fn (session_id: []const u8, prompt: []const u8) InjectOutcome;

/// Session context captured at registration (for binding + list display).
pub const SessionCtx = struct {
    session_id: []const u8,
    model: []const u8 = "",
    title: []const u8 = "",
};

/// Returned to the chat layer to format a confirmation message.
pub const RegisterInfo = struct {
    id: u32,
    kind: TaskKind,
    interval_ms: i64 = 0,
    remaining: u32 = 0,
    daily: bool = false,
    next_fire_ms: i64,
};

/// A read-only copy of a task for listing (owned by the caller's allocator).
pub const TaskView = struct {
    id: u32,
    kind: TaskKind,
    interval_ms: i64,
    remaining: u32,
    daily: bool,
    tod_minutes: i32,
    next_fire_ms: i64,
    prompt: []u8,
};

pub fn freeSnapshot(allocator: std.mem.Allocator, views: []TaskView) void {
    for (views) |v| allocator.free(v.prompt);
    allocator.free(views);
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    next_id: u32 = 1,
    path: []const u8, // owned
    last_scan_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) Store {
        var store = Store{
            .allocator = allocator,
            .path = allocator.dupe(u8, path) catch path,
        };
        store.load();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.tasks.items) |*t| self.freeTask(t);
        self.tasks.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    fn freeTask(self: *Store, t: *Task) void {
        self.allocator.free(t.session_id);
        self.allocator.free(t.model);
        self.allocator.free(t.title);
        self.allocator.free(t.prompt);
    }

    fn appendOwned(self: *Store, src: Task) !u32 {
        var t = src;
        t.session_id = try self.allocator.dupe(u8, src.session_id);
        errdefer self.allocator.free(t.session_id);
        t.model = try self.allocator.dupe(u8, src.model);
        errdefer self.allocator.free(t.model);
        t.title = try self.allocator.dupe(u8, src.title);
        errdefer self.allocator.free(t.title);
        t.prompt = try self.allocator.dupe(u8, src.prompt);
        errdefer self.allocator.free(t.prompt);
        t.id = self.next_id;
        self.next_id += 1;
        try self.tasks.append(self.allocator, t);
        return t.id;
    }

    pub fn registerLoop(self: *Store, arg: []const u8, ctx: SessionCtx, now_ms: i64, offset_s: i32) (ParseError || error{OutOfMemory})!RegisterInfo {
        const p = try engine.parseLoopArgs(arg);
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = try self.appendOwned(.{
            .kind = .loop,
            .session_id = ctx.session_id,
            .model = ctx.model,
            .title = ctx.title,
            .prompt = p.prompt,
            .interval_ms = p.interval_ms,
            .remaining = p.count,
            .next_fire_ms = now_ms + p.interval_ms,
            .created_ms = now_ms,
        });
        self.saveLocked();
        return .{ .id = id, .kind = .loop, .interval_ms = p.interval_ms, .remaining = p.count, .next_fire_ms = now_ms + p.interval_ms };
    }

    pub fn registerWatch(self: *Store, arg: []const u8, ctx: SessionCtx, now_ms: i64, offset_s: i32) (ParseError || error{OutOfMemory})!RegisterInfo {
        const p = try engine.parseWatchArgs(arg, now_ms, offset_s);
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = try self.appendOwned(.{
            .kind = .watch,
            .session_id = ctx.session_id,
            .model = ctx.model,
            .title = ctx.title,
            .prompt = p.prompt,
            .daily = p.daily,
            .tod_minutes = p.tod_minutes,
            .remaining = if (p.daily) 0 else 1,
            .next_fire_ms = p.next_fire_ms,
            .created_ms = now_ms,
        });
        self.saveLocked();
        return .{ .id = id, .kind = .watch, .daily = p.daily, .next_fire_ms = p.next_fire_ms };
    }

    pub fn snapshotForSession(self: *Store, allocator: std.mem.Allocator, session_id: []const u8, kind: TaskKind) ![]TaskView {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out: std.ArrayListUnmanaged(TaskView) = .empty;
        errdefer {
            for (out.items) |v| allocator.free(v.prompt);
            out.deinit(allocator);
        }
        for (self.tasks.items) |t| {
            if (t.kind != kind) continue;
            if (!std.mem.eql(u8, t.session_id, session_id)) continue;
            try out.append(allocator, .{
                .id = t.id,
                .kind = t.kind,
                .interval_ms = t.interval_ms,
                .remaining = t.remaining,
                .daily = t.daily,
                .tod_minutes = t.tod_minutes,
                .next_fire_ms = t.next_fire_ms,
                .prompt = try allocator.dupe(u8, t.prompt),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Remove one task by id within a session. Returns true if removed.
    pub fn stop(self: *Store, session_id: []const u8, id: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.tasks.items.len) : (i += 1) {
            const t = self.tasks.items[i];
            if (t.id == id and std.mem.eql(u8, t.session_id, session_id)) {
                var removed = self.tasks.orderedRemove(i);
                self.freeTask(&removed);
                self.saveLocked();
                return true;
            }
        }
        return false;
    }

    /// Remove all tasks of `kind` in a session. Returns the count removed.
    pub fn stopAll(self: *Store, session_id: []const u8, kind: TaskKind) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var removed: u32 = 0;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const t = self.tasks.items[i];
            if (t.kind == kind and std.mem.eql(u8, t.session_id, session_id)) {
                var r = self.tasks.orderedRemove(i);
                self.freeTask(&r);
                removed += 1;
            } else i += 1;
        }
        if (removed > 0) self.saveLocked();
        return removed;
    }

    // ---- persistence ----

    fn load(self: *Store) void {
        const bytes = std.fs.cwd().readFileAlloc(self.allocator, self.path, 8 * 1024 * 1024) catch return;
        defer self.allocator.free(bytes);
        var parsed = engine.decodeAlloc(self.allocator, bytes) catch return;
        defer parsed.deinit();
        const offset_s = ai_history_time.localOffsetSeconds();
        const now_ms = std.time.milliTimestamp();
        self.next_id = parsed.value.next_id;
        for (parsed.value.tasks) |src| {
            var copy = src;
            engine.recomputeAfterRestart(&copy, now_ms, offset_s);
            if (engine.isFinished(&copy)) continue;
            _ = self.appendOwnedKeepingId(copy) catch {};
        }
    }

    fn appendOwnedKeepingId(self: *Store, src: Task) !void {
        var t = src;
        t.session_id = try self.allocator.dupe(u8, src.session_id);
        errdefer self.allocator.free(t.session_id);
        t.model = try self.allocator.dupe(u8, src.model);
        errdefer self.allocator.free(t.model);
        t.title = try self.allocator.dupe(u8, src.title);
        errdefer self.allocator.free(t.title);
        t.prompt = try self.allocator.dupe(u8, src.prompt);
        errdefer self.allocator.free(t.prompt);
        try self.tasks.append(self.allocator, t); // keeps src.id
        if (t.id >= self.next_id) self.next_id = t.id + 1;
    }

    fn saveLocked(self: *Store) void {
        const model = engine.FileModel{ .version = 1, .next_id = self.next_id, .tasks = self.tasks.items };
        const bytes = engine.encode(self.allocator, model) catch return;
        defer self.allocator.free(bytes);
        const file = std.fs.cwd().createFile(self.path, .{ .truncate = true }) catch return;
        defer file.close();
        file.writeAll(bytes) catch return;
    }
};
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_store.zig src/test_main.zig
git commit -m "feat(loop): runtime store with register/snapshot/stop + persistence"
```

---

## Task 7: Store — `tick()` fires due tasks through the injector

**Files:**
- Modify: `src/ai_loop_store.zig`

- [ ] **Step 1: Write the failing test**

Add at the bottom of `src/ai_loop_store.zig`:

```zig
// Test injector that records calls and returns a scripted outcome.
const TestInjector = struct {
    var outcome: InjectOutcome = .sent;
    var calls: u32 = 0;
    var last_prompt_buf: [256]u8 = undefined;
    var last_prompt_len: usize = 0;
    fn inject(session_id: []const u8, prompt: []const u8) InjectOutcome {
        _ = session_id;
        calls += 1;
        last_prompt_len = @min(prompt.len, last_prompt_buf.len);
        @memcpy(last_prompt_buf[0..last_prompt_len], prompt[0..last_prompt_len]);
        return outcome;
    }
};

test "tick fires due loop task, advances, and skips when busy" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = Store.init(a, path);
    defer store.deinit();

    // next_fire = 1000 + 30m; we tick at a time well past it.
    _ = try store.registerLoop("30m 2 do-it", .{ .session_id = "s" }, 1000, 0);
    const fire_at = 1000 + 30 * std.time.ms_per_min + 5;

    // Busy => skip, no decrement, still 1 task with remaining 2.
    TestInjector.outcome = .busy;
    TestInjector.calls = 0;
    store.tickWith(fire_at, 0, TestInjector.inject);
    try std.testing.expectEqual(@as(u32, 1), TestInjector.calls);
    {
        var snap = try store.snapshotForSession(a, "s", .loop);
        defer freeSnapshot(a, snap);
        try std.testing.expectEqual(@as(u32, 2), snap[0].remaining);
    }

    // Sent => decrement to 1, prompt forwarded.
    TestInjector.outcome = .sent;
    TestInjector.calls = 0;
    store.tickWith(fire_at + 1, 0, TestInjector.inject); // +1 to bypass the 1s throttle
    try std.testing.expectEqual(@as(u32, 1), TestInjector.calls);
    try std.testing.expectEqualStrings("do-it", TestInjector.last_prompt_buf[0..TestInjector.last_prompt_len]);
    {
        var snap = try store.snapshotForSession(a, "s", .loop);
        defer freeSnapshot(a, snap);
        try std.testing.expectEqual(@as(u32, 1), snap[0].remaining);
    }
}
```

> The throttle compares `now_ms` to `last_scan_ms` with a 1s minimum gap. The test advances `now_ms` past `fire_at` and uses distinct timestamps so throttling never hides a scan. `tickWith` is the testable core; the public `tick` calls it with the real clock/offset/injector.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — compile error: `tickWith` undefined.

- [ ] **Step 3: Implement**

Add to `src/ai_loop_store.zig`. First, near the top after the imports, add the wired injector global + setter:

```zig
var g_injector: ?Injector = null;
var g_store: ?*Store = null;

/// Wire the app-layer injector (resolve session by id + inject). Call once at startup.
pub fn setInjector(inj: Injector) void {
    g_injector = inj;
}

/// Register the process-wide store instance the app ticks/queries.
pub fn setActive(store: *Store) void {
    g_store = store;
}

pub fn active() ?*Store {
    return g_store;
}

/// Called once per UI frame from the app layer (UI thread, where tab.g_tabs is
/// populated). No-op until both a store and an injector are wired.
pub fn tick(now_ms: i64) void {
    const store = g_store orelse return;
    const inj = g_injector orelse return;
    const offset_s = ai_history_time.localOffsetSeconds();
    store.tickWith(now_ms, offset_s, inj);
}
```

Then add the `tickWith` method inside `pub const Store` (e.g. after `stopAll`):

```zig
    /// Testable core of the per-frame tick. Throttled to once per second.
    pub fn tickWith(self: *Store, now_ms: i64, offset_s: i32, inj: Injector) void {
        if (now_ms - self.last_scan_ms < std.time.ms_per_s) return;
        self.last_scan_ms = now_ms;

        self.mutex.lock();
        defer self.mutex.unlock();
        var changed = false;
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            const t = &self.tasks.items[i];
            if (!engine.isDue(t, now_ms)) {
                i += 1;
                continue;
            }
            switch (inj(t.session_id, t.prompt)) {
                .sent => {
                    engine.advanceAfterFire(t, now_ms, offset_s);
                    changed = true;
                    if (engine.isFinished(t)) {
                        var removed = self.tasks.orderedRemove(i);
                        self.freeTask(&removed);
                        continue; // don't advance i; next task shifted into place
                    }
                },
                .busy, .closed => {
                    // Leave unchanged: stays due, retried on a later tick (no
                    // decrement, no next_fire advance). A daily/one-shot bound to a
                    // closed session fires the instant that session is reopened.
                },
            }
            i += 1;
        }
        if (changed) self.saveLocked();
    }
```

> The injector is called while `self.mutex` is held. This is safe: the injector only touches `Session` (a different mutex) and `tab.g_tabs`, never the store — there is no lock cycle, and everything runs on the single UI thread.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_loop_store.zig
git commit -m "feat(loop): store.tick fires due tasks via injector (busy/closed skip)"
```

---

## Task 8: `Session.submitScheduledPrompt`

**Files:**
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Write the failing test**

Add a test in `src/ai_chat.zig` near the other `Session` tests (these run under the full suite). Use the existing test-construction pattern in this file (e.g. how `session.copySessionId(...)` test fixtures are built around line 4070+/5206+). Model it on those:

```zig
test "submitScheduledPrompt sets composer and reports busy state" {
    const a = std.testing.allocator;
    var session = try Session.init(a, .{});
    defer session.deinit();

    // Not inflight: returns true and the composer reflects the prompt before submit clears it.
    // (submit() will attempt a request; with no agent configured it no-ops/errs gracefully.)
    const ok = session.submitScheduledPrompt("hello world");
    try std.testing.expect(ok);

    // Inflight: returns false (skip).
    session.request_inflight = true;
    const skipped = session.submitScheduledPrompt("again");
    try std.testing.expect(!skipped);
    session.request_inflight = false;
}
```

> Match `Session.init`'s real signature/usage from the existing tests in this file. If `submit()` on an unconfigured session does anything heavy in tests, narrow the first assertion to only check the busy-skip path (the `!skipped` case), which is the behavior the scheduler depends on.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — compile error: `submitScheduledPrompt` undefined.

- [ ] **Step 3: Implement**

Add this method to `pub const Session` in `src/ai_chat.zig` (near `applyRemoteInput`, around line 1068):

```zig
    /// Inject a scheduled prompt as if the user typed + submitted it. Returns
    /// false (skipped, nothing sent) if a request is already inflight. Clears any
    /// half-typed composer text first so the scheduled prompt is sent verbatim.
    /// Caller must run this on the UI thread (mirrors applyRemoteInput).
    pub fn submitScheduledPrompt(self: *Session, text: []const u8) bool {
        self.mutex.lock();
        if (self.request_inflight) {
            self.mutex.unlock();
            return false;
        }
        self.input_len = 0;
        self.input_cursor = 0;
        self.input_scroll_row = 0;
        self.input_scroll_follow_cursor = true;
        self.input_select_all = false;
        self.mutex.unlock();
        self.appendInputText(text);
        self.submit();
        return true;
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig
git commit -m "feat(loop): Session.submitScheduledPrompt for scheduled injection"
```

---

## Task 9: Composer — add `.loop` / `.watch` commands

**Files:**
- Modify: `src/ai_chat_composer.zig`

- [ ] **Step 1: Write the failing test**

Add to the existing test area of `src/ai_chat_composer.zig` (near `test "parseSlashCommand recognizes new lifecycle commands"`, line 318):

```zig
test "parseSlashCommand recognizes loop and watch" {
    try std.testing.expectEqual(SlashCommand.loop, parseSlashCommand("/loop").?);
    try std.testing.expectEqual(SlashCommand.watch, parseSlashCommand("/watch").?);
    try std.testing.expectEqual(SlashCommand.loop, exactBuiltinCommand("/loop").?);
    try std.testing.expectEqual(SlashCommand.watch, exactBuiltinCommand("/watch").?);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -30`
Expected: FAIL — compile error: `SlashCommand.loop`/`.watch` undefined.

- [ ] **Step 3: Implement**

In `src/ai_chat_composer.zig`, add the two enum members to `SlashCommand` (line 6-19), before `unknown`:

```zig
    loop,
    watch,
```

Add two entries to `slash_command_entries` (line 42-87), after the `/distill` entry:

```zig
    .{
        .suggestion = .{ .command = "/loop", .description = "repeat a prompt every interval N times" },
        .action = .loop,
    },
    .{
        .suggestion = .{ .command = "/watch", .description = "send a prompt at a daily or one-shot time" },
        .action = .watch,
    },
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat_composer.zig
git commit -m "feat(loop): register /loop and /watch slash commands in composer"
```

---

## Task 10: Dispatch `/loop` and `/watch` in the chat layer

**Files:**
- Modify: `src/ai_chat.zig`

- [ ] **Step 1: Write the failing test**

Add to `src/ai_chat.zig` (full suite). This drives the create + list + stop wiring end-to-end through a real `Store` injected via `ai_loop_store.setActive`.

```zig
test "runLoopCommandLocked creates, lists, and stops a loop task" {
    const a = std.testing.allocator;
    const ai_loop_store = @import("ai_loop_store.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir_path);
    const path = try std.fs.path.join(a, &.{ dir_path, "loop_tasks.json" });
    defer a.free(path);

    var store = ai_loop_store.Store.init(a, path);
    defer store.deinit();
    ai_loop_store.setActive(&store);
    defer ai_loop_store.setActive(undefined); // restore handled below
    // NOTE: if setActive(undefined) is unsafe in your build, add an ai_loop_store.clearActive() in Task 7 and call it here.

    var session = try Session.init(a, .{});
    defer session.deinit();
    session.copySessionId("session-test");

    session.mutex.lock();
    _ = session.runBuiltinCommandLocked(.loop, "30m 3 hello");
    session.mutex.unlock();

    var snap = try store.snapshotForSession(a, "session-test", .loop);
    defer ai_loop_store.freeSnapshot(a, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("hello", snap[0].prompt);

    session.mutex.lock();
    _ = session.runBuiltinCommandLocked(.loop, "stop 1");
    session.mutex.unlock();
    var snap2 = try store.snapshotForSession(a, "session-test", .loop);
    defer ai_loop_store.freeSnapshot(a, snap2);
    try std.testing.expectEqual(@as(usize, 0), snap2.len);
}
```

> Add `pub fn clearActive() void { g_store = null; }` to `ai_loop_store.zig` (Task 7) and use it instead of `setActive(undefined)` if the latter is awkward. Match `Session.init`'s real signature from existing tests in this file.

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test-full 2>&1 | tail -30`
Expected: FAIL — compile error: `.loop`/`.watch` not handled / `runLoopCommandLocked` helper missing / `slashCommandOutput` switch not exhaustive.

- [ ] **Step 3: Implement**

(a) Add the import near the other `@import`s at the top of `src/ai_chat.zig`:

```zig
const ai_loop_store = @import("ai_loop_store.zig");
const ai_loop_schedule = @import("ai_loop_schedule.zig");
```

(b) Make `slashCommandOutput` exhaustive — add to its switch (these paths are never reached because the dispatch sets `suppress_output`, but the switch must compile):

```zig
        .loop, .watch => allocator.dupe(u8, ""),
```

(c) In `runBuiltinCommandLocked`'s switch (around line 1688), add before `else => {}`:

```zig
            .loop => self.runLoopCommandLocked(.loop, arg, &result),
            .watch => self.runLoopCommandLocked(.watch, arg, &result),
```

(d) Add the helper methods to `pub const Session` (place near `runBuiltinCommandLocked`). It always emits its own message and suppresses the generic output:

```zig
    fn runLoopCommandLocked(self: *Session, kind: ai_loop_schedule.TaskKind, arg: []const u8, result: *BuiltinResult) void {
        result.suppress_output = true;
        const store = ai_loop_store.active() orelse {
            self.emitLoopMessageLocked("Scheduler is not available.");
            return;
        };
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        const now_ms = std.time.milliTimestamp();
        const offset_s = @import("ai_history_time.zig").localOffsetSeconds();
        const ctx = ai_loop_store.SessionCtx{
            .session_id = self.sessionId(),
            .model = self.model(),
            .title = self.title(),
        };

        if (trimmed.len == 0) {
            self.listLoopTasksLocked(store, kind);
            return;
        }
        if (std.mem.startsWith(u8, trimmed, "stop")) {
            const rest = std.mem.trim(u8, trimmed["stop".len..], " \t\r\n");
            if (std.mem.eql(u8, rest, "all")) {
                const n = store.stopAll(ctx.session_id, kind);
                var buf: [64]u8 = undefined;
                self.emitLoopMessageLocked(std.fmt.bufPrint(&buf, "Cancelled {d} task(s).", .{n}) catch "Cancelled tasks.");
            } else {
                const id = std.fmt.parseInt(u32, rest, 10) catch {
                    self.emitLoopMessageLocked("Usage: stop <id> | stop all");
                    return;
                };
                const ok = store.stop(ctx.session_id, id);
                self.emitLoopMessageLocked(if (ok) "Task cancelled." else "No such task in this session.");
            }
            return;
        }

        const info = switch (kind) {
            .loop => store.registerLoop(trimmed, ctx, now_ms, offset_s),
            .watch => store.registerWatch(trimmed, ctx, now_ms, offset_s),
        } catch |err| {
            self.emitLoopMessageLocked(loopErrorText(err, kind));
            return;
        };
        self.emitRegisterConfirmationLocked(info);
    }

    fn listLoopTasksLocked(self: *Session, store: *ai_loop_store.Store, kind: ai_loop_schedule.TaskKind) void {
        const views = store.snapshotForSession(self.allocator, self.sessionId(), kind) catch {
            self.emitLoopMessageLocked("Out of memory.");
            return;
        };
        defer ai_loop_store.freeSnapshot(self.allocator, views);
        if (views.len == 0) {
            self.emitLoopMessageLocked(if (kind == .loop) "No active loop tasks." else "No active watch tasks.");
            return;
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        for (views) |v| {
            if (kind == .loop) {
                w.print("#{d}  every {d}m  remaining {d}  → {s}\n", .{
                    v.id, @divTrunc(v.interval_ms, std.time.ms_per_min), v.remaining, previewPrompt(v.prompt),
                }) catch return;
            } else if (v.daily) {
                w.print("#{d}  daily {d:0>2}:{d:0>2}  → {s}\n", .{
                    v.id, @divTrunc(v.tod_minutes, 60), @mod(v.tod_minutes, 60), previewPrompt(v.prompt),
                }) catch return;
            } else {
                w.print("#{d}  once  → {s}\n", .{ v.id, previewPrompt(v.prompt) }) catch return;
            }
        }
        self.emitLoopMessageLocked(buf.items);
    }

    fn emitRegisterConfirmationLocked(self: *Session, info: ai_loop_store.RegisterInfo) void {
        var buf: [160]u8 = undefined;
        const msg = switch (info.kind) {
            .loop => std.fmt.bufPrint(&buf, "Created loop task #{d}: every {d}m, {d} times.", .{
                info.id, @divTrunc(info.interval_ms, std.time.ms_per_min), info.remaining,
            }) catch "Created loop task.",
            .watch => if (info.daily)
                std.fmt.bufPrint(&buf, "Created watch task #{d} (daily).", .{info.id}) catch "Created watch task."
            else
                std.fmt.bufPrint(&buf, "Created watch task #{d} (one-shot).", .{info.id}) catch "Created watch task.",
        };
        self.emitLoopMessageLocked(msg);
    }

    fn emitLoopMessageLocked(self: *Session, text: []const u8) void {
        self.appendLocalToolMessageLocked(text) catch {
            self.setStatusLocked("Out of memory");
            return;
        };
        self.clearSubmittedInputLocked();
        self.setStatusLocked("Ready");
    }
```

(e) Add these file-scope helpers (near `slashCommandOutput`, around line 348):

```zig
fn previewPrompt(p: []const u8) []const u8 {
    return if (p.len > 48) p[0..48] else p;
}

fn loopErrorText(err: ai_loop_schedule.ParseError, kind: ai_loop_schedule.TaskKind) []const u8 {
    return switch (err) {
        error.MissingArgs => if (kind == .loop)
            "Usage: /loop <interval> <count> <prompt>  e.g. /loop 30m 8 check ci"
        else
            "Usage: /watch <HH:MM | YYYY-MM-DD HH:MM> <prompt>",
        error.BadInterval => "Bad interval. Use a number + s/m/h/d, e.g. 30m, 5h.",
        error.BadCount => "Count must be a positive integer.",
        error.BadTime => "Bad time. Use HH:MM or YYYY-MM-DD HH:MM (24h).",
        error.PastTime => "That time is already in the past.",
        error.EmptyPrompt => "Add the prompt text after the schedule.",
    };
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test-full 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ai_chat.zig src/ai_loop_store.zig
git commit -m "feat(loop): dispatch /loop and /watch (create/list/stop) in chat layer"
```

---

## Task 11: Wire the injector + store into the app (AppWindow)

**Files:**
- Modify: `src/AppWindow.zig`

- [ ] **Step 1: Add the imports**

Near the top imports of `src/AppWindow.zig` (where `ai_chat` / `tab` are imported, ~line 52):

```zig
const ai_loop_store = @import("ai_loop_store.zig");
```

- [ ] **Step 2: Add the injector + a process-wide store**

Add near the other app-layer file-scope state (e.g. by the other `g_*` globals / triggers). The injector resolves a session by id across all open tabs (AI-chat tabs + copilot sidebars) on the UI thread:

```zig
var g_loop_store: ?ai_loop_store.Store = null;

fn loopInjector(session_id: []const u8, prompt: []const u8) ai_loop_store.InjectOutcome {
    var i: usize = 0;
    while (i < tab.MAX_TABS) : (i += 1) {
        const t = tab.g_tabs[i] orelse continue;
        if (t.ai_chat_session) |s| {
            if (std.mem.eql(u8, s.sessionId(), session_id))
                return if (s.submitScheduledPrompt(prompt)) .sent else .busy;
        }
        if (t.copilot_session) |s| {
            if (std.mem.eql(u8, s.sessionId(), session_id))
                return if (s.submitScheduledPrompt(prompt)) .sent else .busy;
        }
    }
    return .closed;
}
```

- [ ] **Step 3: Init the store + wire the injector at startup**

In the startup wiring block (next to `ai_chat.setSessionResumeTrigger(...)`, ~line 111), add:

```zig
    if (platform_dirs.pathInConfigDir(allocator, "loop_tasks.json")) |loop_path| {
        defer allocator.free(loop_path);
        g_loop_store = ai_loop_store.Store.init(allocator, loop_path);
        ai_loop_store.setActive(&g_loop_store.?);
        ai_loop_store.setInjector(loopInjector);
    } else |_| {}
```

> Confirm the symbol used to reach `platform/dirs.zig` in this file (it may already be imported as `platform_dirs`; if not, add `const platform_dirs = @import("platform/dirs.zig");`).

- [ ] **Step 4: Tick the store every frame**

In the main render loop, right after `rememberWindowedPosition(win);` (line 5003):

```zig
        // Fire any due /loop or /watch tasks (UI thread: tab.g_tabs is populated).
        ai_loop_store.tick(std.time.milliTimestamp());
```

- [ ] **Step 5: Deinit on shutdown**

In the window/app cleanup path (near where tabs are cleaned up, ~line 247-252), add:

```zig
    if (g_loop_store) |*store| {
        ai_loop_store.clearActive();
        store.deinit();
        g_loop_store = null;
    }
```

- [ ] **Step 6: Build and run both suites**

Run: `zig build 2>&1 | tail -20 && zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5`
Expected: build succeeds; both suites PASS (0 failed).

- [ ] **Step 7: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(loop): wire scheduler store + injector + per-frame tick into app"
```

---

## Task 12: Cross-compile check, full verification, manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Confirm both suites + release build**

Run: `zig build test 2>&1 | tail -5 && zig build test-full 2>&1 | tail -5 && zig build 2>&1 | tail -5`
Expected: all green, 0 failed, build OK.

- [ ] **Step 2: Manual GUI smoke test (record results; this project's tests can't drive the GUI)**

In a running WispTerm AI chat session:
1. `/loop 1m 3 say the current time` → confirm "Created loop task #1: every 1m, 3 times." Wait ~1 min; the prompt should appear + be answered. After 3 fires the task disappears (`/loop` lists none).
2. `/loop` (no args) → lists the active task while it runs.
3. `/watch 23:59 ping` → "Created watch task #N (daily)."; `/watch` lists it as `daily 23:59`.
4. `/watch stop <id>` → "Task cancelled."; `/watch` lists none.
5. Error paths: `/loop 30m hi` → count error; `/watch 25:00 hi` → bad-time error.
6. Restart WispTerm with an active `/loop` task open in a resumed session → confirm `~/.config/wispterm/loop_tasks.json` exists and the task resumes after `/resume`-ing that session.

- [ ] **Step 3: Final commit (if any verification fixups were needed)**

```bash
git add -A
git commit -m "chore(loop): verification fixups for /loop and /watch"
```

---

## Self-Review (completed by plan author)

**Spec coverage:**
- `/loop` interval×count → Tasks 1,2,3,6,9,10. `/watch` daily + one-shot → Tasks 2,3,6,9,10.
- Bound-to-session injection → Task 8 (`submitScheduledPrompt`) + Task 11 (`loopInjector` resolves by `sessionId()`).
- Busy-skip (no decrement) → Task 7 `tickWith` `.busy` branch + Task 8 inflight check.
- Survive restart → Task 6 `load` + `recomputeAfterRestart`; persistence on every mutation (`saveLocked`).
- Restart policies (loop skip / one-shot catch-up / daily next) → Task 3 `recomputeAfterRestart` + tests.
- First fire after one interval → Task 6 `registerLoop` sets `next_fire = now + interval`.
- List / stop / stop all → Task 6 `snapshotForSession`/`stop`/`stopAll`, Task 10 dispatch.
- Closed-session behavior (skip+keep) → Task 7 `.closed` branch (matches the revised spec scope note).
- Error messages → Task 10 `loopErrorText`.

**Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output. The two "match the existing signature" notes (Zig-version `std.json` shape; `Session.init` test fixture) point to concrete in-repo references rather than leaving logic unspecified.

**Type consistency:** `Task`/`TaskKind`/`ParseError` defined in Task 3/1 and re-exported in Task 6; `InjectOutcome`/`Injector`/`SessionCtx`/`RegisterInfo`/`TaskView` defined in Task 6 and used consistently in Tasks 7/10/11; `tickWith(now_ms, offset_s, inj)` signature matches between Task 7 def and the `tick` wrapper; `submitScheduledPrompt` returns `bool` consistently (Task 8 def, Task 11 caller); `setActive`/`clearActive`/`active`/`setInjector`/`tick` names consistent across Tasks 6/7/10/11.
