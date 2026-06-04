# `/loop` + `/watch` — Scheduled / Recurring AI Prompts

**Date:** 2026-06-04
**Status:** Design approved, pending spec review
**Component:** WispTerm AI chat (副驾/Agent)

## Summary

Add two AI-chat slash commands that re-submit a prompt to the bound AI session on a
schedule:

- **`/loop`** — repeat a prompt every fixed interval, a required number of times, then stop.
- **`/watch`** — fire a prompt at a clock time: daily (`HH:MM`) or one-shot (`YYYY-MM-DD HH:MM`).

The prompt is injected into the AI 副驾/Agent exactly as if the user typed it, so the agent
then acts on it (e.g. the prompt "打开 codex，发送 hi" makes the agent open codex and send hi
using its terminal tools). Tasks are bound to the originating session and survive app restart.

## Goals / Non-goals

**Goals**
- Interval-recurring prompts (`/loop`) and clock-scheduled prompts (`/watch`).
- Tasks persist across WispTerm restarts.
- Tasks are bound to the AI session they were created in.
- Reuse the existing slash-command + `submit()` infrastructure; no new thread.
- Maximize pure, unit-testable logic.

**Non-goals (v1, deferred)**
- Condition/event-driven triggering for `/watch` (watch terminal output, file changes). Time only.
- Cron expressions. Only simple interval (`/loop`) and `HH:MM` / `YYYY-MM-DD HH:MM` (`/watch`).
- A global, session-independent scheduler UI / task manager panel.

## User-facing surface

### Syntax

```
/loop <interval> <count> <prompt>
    interval = integer + unit (s | m | h | d), e.g. 30m, 5h, 2d
    count    = required positive integer
    prompt   = remainder of the line
    e.g.  /loop 30m 8 检查 CI，把失败的测试贴出来

/watch <time> <prompt>
    time = "HH:MM"            → daily, recurring at that local time
         | "YYYY-MM-DD HH:MM" → one-shot at that absolute local time
    e.g.  /watch 09:00 生成今天的早报
          /watch 2026-06-05 09:00 提醒我交报告

/loop            (no args) list this session's loop tasks
/watch           (no args) list this session's watch tasks
                 columns: id | schedule | next-fire | remaining | prompt preview
/loop stop <id>      cancel one task   (stop accepts any task id)
/watch stop <id>
/loop stop all       cancel all of this session's loop tasks
/watch stop all
```

### Behavior decisions (confirmed)

| Topic | Decision |
|-------|----------|
| First `/loop` fire | After **one full interval** (`/loop 5h …` first fires in 5h). |
| `/loop` end | Stops after `count` **successful** sends. |
| Agent busy at fire time | **Skip** this fire; retry next interval; a skipped fire does **not** decrement `count`. |
| `count` semantics | Counts **only successful injections**, not scheduled ticks. |
| `/watch HH:MM` | Recurs daily. If today's time already passed, first fire is tomorrow. |
| `/watch YYYY-MM-DD HH:MM` | One-shot. Absolute time in the past at creation → error. |
| Restart: missed `/loop` intervals | **Skipped**; resume cadence at next future slot (no catch-up storm). |
| Restart: missed one-shot `/watch` | **Catch up once** on startup (don't lose a reminder). |
| Restart: missed daily `/watch` | Next future occurrence. |
| Error handling | Invalid syntax / missing or ≤0 count / past absolute time → error message in the chat, same channel as other slash-command output. |

## Architecture (Approach A: pure engine + tick-driven scheduler + state file)

### Component 1 — `src/ai_loop_schedule.zig` (pure, no I/O, TDD)

The brain. No `Session`, no alloc-of-globals, no file/clock side effects (time passed in).

```
TaskKind = enum { loop, watch }

Task = struct {
    id:            []const u8,   // stable, generated at creation
    kind:          TaskKind,
    session_id:    []const u8,   // binding anchor (ai_chat.zig sessionId())
    model:         []const u8,   // captured for list display only
    title:         []const u8,   // captured for list display only
    prompt:        []const u8,

    // loop
    interval_ms:   i64,          // 0 for watch
    remaining:     u32,          // loop: successful sends left. one-shot watch: 1 pending → 0 done.
                                 // daily watch: unused (never auto-finishes; only manual stop).

    // watch
    daily:         bool,         // true => recurring HH:MM; false => one-shot absolute
    tod_minutes:   i32,          // minutes since local midnight (daily)
    absolute_ms:   i64,          // one-shot absolute (non-daily)

    next_fire_ms:  i64,
    created_ms:    i64,
}
```

Exported pure functions:
- `parseLoop(text, now, ctx) !Task` / `parseWatch(text, now, ctx) !Task` — text + session context → Task (or a typed parse error). `ctx` carries session_id/model/title + `now_ms` + `utc_offset_seconds` (clock + tz passed in, never read here).
- `nextFire(task, now) i64` — compute next fire timestamp.
- `dueTasks(tasks, now) []index` — which tasks are due (next_fire_ms <= now).
- `advanceAfterFire(task, now) Task` — loop: decrement `remaining`, push `next_fire_ms += interval_ms`; watch daily: advance to next day's `tod`; watch one-shot: mark done (`remaining = 0`).
- `recomputeAfterRestart(task, now) ?Task` — apply the missed-fire policy; returns null if the task is finished/dropped.
- `isFinished(task) bool` — true when (loop with `remaining == 0`) or (one-shot watch with
  `remaining == 0`). A daily watch is never finished; it ends only via `/watch stop`.
- `encode(tasks, writer)` / `decode(bytes) []Task` — JSON codec, round-trippable.
- Listing/formatting helpers as needed for the `/loop` (no-arg) output.

`std.time.milliTimestamp()` and local-tz conversion are NOT called here — the caller passes
`now` and tz offset. (Reuse `ai_history_time.zig`'s libc tz shim for the integration layer's
local-time math, consistent with the date-filter work.)

### Component 2 — Scheduler integration (App / AppWindow)

Owns the in-memory `[]Task`, loaded from disk on startup. No new thread.

- On the **existing periodic tick** (RendererThread render interval / per-frame AppWindow update),
  call `dueTasks(now)`.
- For each due task:
  1. Resolve the bound `Session` by `session_id` among open AI sessions.
  2. If found and **not** `request_inflight`: set its input to `task.prompt`, call `submit()`,
     then `advanceAfterFire`. (`submit()` already early-returns when inflight — reuse that as the
     busy-skip; but check `request_inflight` first so a busy skip does NOT advance `next_fire`
     past the retry, and does not decrement `remaining`.)
  3. If found but busy (`requestState().inflight`) → skip (leave task unchanged; stays due, retries
     next interval; `remaining` not decremented).
  4. If **not** open (no session in `tab.g_tabs` matches `session_id`) → **skip this fire, keep the
     task**, and log a one-line notice. The task re-activates automatically when that session is
     reopened, because `/resume` restores the original `session_id` (`ai_chat.zig:640`
     `copySessionId(record.session_id)`). Auto-resuming/respawning a closed session programmatically
     is **out of scope for v1** (no programmatic resume-by-id exists; `/resume` is an interactive
     picker — `commandPaletteOpenAgentHistory()`).
  5. Persist the task list whenever it changes (fire/advance/finish/cancel).
- Tick granularity (~render interval, seconds) is acceptable for minute/hour-scale schedules.

### Component 3 — Slash-command wiring

- `src/ai_chat_composer.zig`: add `.loop` and `.watch` to `SlashCommand`, plus two
  `slash_command_entries` (with i18n'd descriptions). Parsing stays pure here; argument parsing
  delegates to `ai_loop_schedule.parseLoop/parseWatch`.
- `src/ai_chat.zig` `runBuiltinCommandLocked`: dispatch `.loop`/`.watch` →
  - no args → list this session's tasks of that kind (output message);
  - `stop <id>` / `stop all` → cancel + persist + confirmation message;
  - otherwise → parse → register task (capture session_id/provider/model/cwd) + persist +
    confirmation message ("已创建循环任务 #id：每 30m，剩 8 次，下次 …").

### Component 4 — Persistence

Mirror the `window_state.zig` (I/O) + `window_state_codec.zig` (pure codec) split:

- Pure codec lives in `ai_loop_schedule.zig` (`encode`/`decode`).
- A thin I/O wrapper reads/writes `loop_tasks.json` in the platform config dir
  (`platform_dirs`), versioned (`{ "version": 1, "tasks": [ … ] }`).
- Write on every task-list mutation; load once at startup.

## Data flow

```
user types "/loop 30m 8 <prompt>" in session S
  → composer parses first token → .loop
  → runBuiltinCommandLocked(.loop, "30m 8 <prompt>")
  → parseLoop(...) → Task{ session_id=S.id, interval=30m, remaining=8, next_fire=now+30m }
  → tasks.append(task); persist(loop_tasks.json); reply "已创建 …"

... every tick ...
  → dueTasks(now) → [task]
  → resolve S by session_id in tab.g_tabs → open & not busy
  → S.submitScheduledPrompt(prompt)          (busy → returns false → skip, no decrement)
                                             (closed → skip + keep + log; retries when reopened)
  → task = advanceAfterFire(task, now)        (remaining 8→7, next_fire += 30m)
  → if isFinished(task) remove; persist

... restart ...
  → load loop_tasks.json
  → for each task: recomputeAfterRestart(task, now)
       loop: drop missed intervals, next_fire = next future slot
       one-shot watch in past: next_fire = now (catch up once)
       daily watch: next future HH:MM
```

## Error handling & edge cases

- Parse errors (bad interval unit, missing/≤0 count, malformed time, past absolute time) →
  typed error from the pure parser → human-readable chat message; task not created.
- Bound session closed mid-loop → resume/respawn path (Component 2.4).
- Task `prompt` itself is a slash command (e.g. `/loop` injecting `/clear`) → injected verbatim;
  documented as user responsibility (no special guard in v1).
- Clock changes / DST for daily watch → recomputed each fire via tz shim; acceptable ±1h edge.
- Persist failure (disk) → log + toast; in-memory tasks keep running for the session.

## Testing

Pure-engine unit tests in `ai_loop_schedule.zig` (run under fast `test`; ensure it's `@import`ed
in `test_fast.zig`/`test_main.zig` per the test-inclusion wiring rule):

- `parseLoop`/`parseWatch`: valid forms, every error form, unit conversions, prompt with spaces.
- `nextFire` / `advanceAfterFire`: loop decrement + interval push; daily roll to tomorrow;
  one-shot completion.
- `dueTasks`: boundary at `next_fire_ms == now`.
- `recomputeAfterRestart`: missed loop intervals skipped; missed one-shot caught up; daily → next.
- `encode`/`decode`: round-trip equality incl. all fields.
- Count semantics: a simulated busy-skip does not decrement `remaining`.

Both suites green (`zig build test` + `zig build test-full`), per project baseline.

## i18n

Add en + zh-CN keys for: the two command descriptions, creation confirmations, list output
headers, stop confirmations, and each parse-error message (`src/i18n.zig` catalog).

## Out of scope / future

- **Auto-resume/respawn of a closed bound session** at fire time (needs a programmatic
  resume-by-id, which doesn't exist yet). v1 skips + keeps the task until the session reopens.
- `/watch` condition/event triggers (terminal output match, file change).
- Cron syntax; multiple times per day for `/watch`.
- Cross-session/global task list view.
- Per-task enable/disable without deleting.
