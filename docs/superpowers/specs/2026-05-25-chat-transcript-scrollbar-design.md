# Chat Transcript Scrollbar — Design

**Date:** 2026-05-25
**Status:** Approved, ready for planning

## Problem

The AI Chat page's message transcript already scrolls (mouse wheel / keyboard
update `Session.scroll_px`), but there is no visible scrollbar. The terminal
tab shows a draggable scrollbar on the right edge that appears on scroll and
fades out; users expect the same affordance in the Chat page so they can see
their scroll position in long conversations and drag to navigate.

## Goal

Add a right-edge scrollbar to the Chat transcript that behaves exactly like the
terminal's:

- Appears when scrolling, stays fully visible ~0.8s, then fades over ~0.4s.
- Stays pinned visible while the pointer hovers it or while dragging.
- Draggable: dragging the thumb scrolls the transcript.
- Only shown when the content overflows the visible transcript area.

## Non-Goals

- No changes to wheel/keyboard scrolling behavior or the "pin to bottom"
  semantics (`scroll_px = 1_000_000` sentinel).
- No changes to the existing input-field scrollbar.
- No reuse/refactor of the terminal `scrollbar_model.zig` (see Approach).

## Approach

Mirror the Chat page's existing self-contained patterns rather than
generalizing the terminal's scrollbar model.

The terminal scrollbar (`src/renderer/overlays/scrollbar.zig` +
`src/scrollbar_model.zig`) operates in **row offsets** (`total`, `len`,
`offset`). The Chat transcript operates in **pixels** (`scroll_px`,
`content_h`, `transcript_h`). Forcing both through one model would be awkward.
The Chat renderer already has a parallel, self-contained pattern for its input
scrollbar (`renderInputScrollbar` / `inputScrollbarGeometry` /
`InputScrollbarHit` / `InputScrollbarDrag`) and for input-scrollbar drag in
`input.zig` (`applyAiInputScrollbarDrag`). We follow that pattern.

Keep all scroll math in **pure, unit-testable helpers**.

### Scroll model reference

- `scroll_px = 0` → top of conversation (oldest) visible.
- `scroll_px` large (clamped to `max_scroll = content_h - transcript_h`) →
  bottom (newest) visible. `1_000_000` is the "pin to bottom" sentinel,
  clamped on render.
- Thumb fraction `f = scroll_px / max_scroll` ∈ [0, 1]; `f = 0` puts the thumb
  at the track top, `f = 1` at the track bottom.

## Components

### 1. `src/ai_chat.zig` — Session state

Add fields to `Session`:

- `scrollbar_opacity: f32 = 0`
- `scrollbar_show_time: i64 = 0`

Add methods:

- `showScrollbar()` — set `scrollbar_opacity = 1.0`, stamp
  `scrollbar_show_time = std.time.milliTimestamp()`. Called from `scrollBy()`
  and the pin-to-bottom code paths so the bar appears whenever the transcript
  moves.
- `scrollToPx(px: f32)` — set `scroll_px = @max(0.0, px)` (render still clamps
  to `max_scroll`). Used by drag.

### 2. `src/renderer/ai_chat_renderer.zig` — geometry + render

- `TranscriptScrollbarGeometry` struct: `track_x`, `track_top_px`, `track_h`,
  `thumb_top_px`, `thumb_h`.
- Pure `transcriptScrollbarGeometry(x, w, transcript_top, transcript_h, content_h, scroll_px) ?TranscriptScrollbarGeometry`:
  - Returns `null` when `content_h <= transcript_h` (no overflow).
  - `track_x = x + w - SCROLLBAR_W` (right edge of transcript area).
  - `track_h = transcript_h`.
  - `thumb_h = @max(MIN_THUMB, track_h * (transcript_h / content_h))`,
    clamped to `track_h`.
  - `f = scroll_px / max_scroll` (clamped to [0,1]);
    `thumb_top_px = track_top_px + f * (track_h - thumb_h)`.
  - Constants mirror the terminal: `SCROLLBAR_W = 12`, `MIN_THUMB = 20`.
- `renderTranscriptScrollbar(session, x, w, transcript_top, transcript_h, content_h, window_height)`:
  - Called after the transcript scissor is disabled (~`:317`).
  - Per-frame fade update (mirror terminal `scrollbarUpdateFade`): if
    hovering/dragging → opacity 1.0; else decay using
    `SCROLLBAR_FADE_DELAY_MS = 800` / `SCROLLBAR_FADE_DURATION_MS = 400`.
  - Skip drawing when geometry is `null` or opacity ≤ ~0.01.
  - Track quad: `mixColor(bg, fg, 0.18)` at `fade * 0.20`.
  - Thumb quad: `mixColor(bg, fg, 0.46)` at `fade * 0.62`.
- Hit-test helpers (pure where possible):
  - `transcriptScrollbarHitTest(...) ?f32` — returns drag offset within the
    thumb (px) if the point is over the thumb, else null; a click on the track
    (outside the thumb) may be ignored for v1 (drag-only), matching the input
    scrollbar.
  - `transcriptScrollbarScrollPxAt(geometry, ypos, drag_offset, window_height) f32`
    — maps a pointer y to a target `scroll_px`.

### 3. `src/input.zig` — interaction

- In the Chat mouse-down dispatch (alongside `inputScrollbarHitTest` at
  ~`:2570`): hit-test the transcript scrollbar; on hit, record drag state
  (drag offset + the target `Session`) and begin dragging, mirroring the
  input-scrollbar branch.
- On mouse-move while dragging: `applyAiTranscriptScrollbarDrag(chat, ypos)`
  → compute target via `transcriptScrollbarScrollPxAt` → `session.scrollToPx`.
- Hover: when the pointer is over the scrollbar area, keep it visible (set
  opacity 1.0 / refresh show time) so it does not fade while hovered.

### Fade / hover state

Per-session (`scrollbar_opacity`, `scrollbar_show_time`) like the terminal's
per-surface state. Global interaction flags (hovering / dragging this
scrollbar) live in `input.zig` next to the existing input-scrollbar drag state,
since there is only one mouse.

## Testing

Unit tests for the pure helpers (Zig `test` blocks in `ai_chat_renderer.zig`,
matching the existing input-scrollbar/test style):

- `transcriptScrollbarGeometry` returns `null` when `content_h <= transcript_h`.
- Thumb height is proportional to `transcript_h / content_h` and never below
  `MIN_THUMB`.
- Thumb position: `scroll_px = 0` → thumb at track top; `scroll_px >= max_scroll`
  → thumb at track bottom; a mid value lands proportionally.
- `transcriptScrollbarScrollPxAt` round-trips: dragging the thumb to the track
  top yields `scroll_px ≈ 0`, to the bottom yields `scroll_px ≈ max_scroll`.

## Files Touched

- `src/ai_chat.zig` — Session fields + `showScrollbar` + `scrollToPx`.
- `src/renderer/ai_chat_renderer.zig` — geometry, render, hit-test helpers, tests.
- `src/input.zig` — mouse-down dispatch, drag-move handler, hover.
