# Chat-Panel File-Drop Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dropping a local file anywhere over a visible AI chat surface inserts its absolute path (quoted when it contains whitespace, plus a trailing space) into that session's composer.

**Architecture:** Add one branch to the existing `clipboard.handleFileDrop` pipeline, between the file-explorer and SSH handlers. A new pure module formats the dropped path; a new `AppWindow` function hit-tests the drop point against the AI-chat-tab content rect and the copilot-sidebar bounds and inserts the text via the same `appendInputText` clipboard-paste already uses.

**Tech Stack:** Zig. Existing OS drop plumbing (macOS `performDragOperation`, Windows `WM_DROPFILES`) → `input.handleFileDrop(path, x, y)`. Tests via `zig build test` (fast) and `zig build test-full` (full app graph).

---

## File Structure

- **Create `src/input/file_drop_path.zig`** — pure `formatDroppedPath(allocator, raw)`; no platform/AppWindow imports so it runs in the fast suite (mirrors `ai_chat_layout.zig`, `ai_sidebar.zig`). Owns: dropped-path → composer-text formatting (whitespace quoting + trailing space).
- **Modify `src/test_fast.zig`** — register the new module so its unit tests run.
- **Modify `src/AppWindow.zig`** — add `appendDroppedPathToChatAtPoint(text, x, y) bool`: geometry hit-test + session lookup + insert + copilot focus.
- **Modify `src/input/clipboard.zig`** — add `handleAiChatFileDrop`, wire it into `handleFileDrop`, name the previously-ignored `y` param.

Reference facts (verified against the tree at plan time):
- `clipboard.handleFileDrop` is at `src/input/clipboard.zig:240`, currently `handleFileDrop(local_path: []const u8, x: i32, _: i32)`.
- `Session.appendInputText(self, text)` — `src/ai_chat.zig:875` (inserts at cursor, clears select-all, clamps to the fixed `input_buf`).
- AppWindow helpers (all framebuffer px): `activeAiChat()` `:853`, `currentTitlebarHeight()` `:1344`, `leftPanelsWidth()` `:1349`, `aiCopilotVisible()` `:1353`, `activeCopilotSessionForInput()` `:1386`, `rightPanelsWidthForWindow(window_width)` `:1416`. AppWindow already exposes `pub const input = @import("input.zig")` (`:59`), `pub const ai_chat` (`:45`), `const ai_sidebar` (`:80`), `const window_backend` (`:15`), and already calls `input.focusAiCopilot()` (`:1406`).
- `window_backend.clientSize(win)` returns `.{ .width, .height }` (i32) — `src/platform/window_backend.zig:185`.
- `ai_sidebar.boundsForWindow(window_width: i32, window_height: i32, titlebar_height: f32, left_offset: f32, right_offset: f32)` returns `Bounds{ left, top, right, bottom: i32 }` (top-left origin) — `src/ai_sidebar.zig`.
- `shellSingleQuoteForPaste` (`src/input/clipboard.zig:141`) already does `'\''` escaping; we deliberately do NOT reuse it (it always quotes; our module quotes only on whitespace) to keep the pure module free of clipboard's AppWindow imports. The ~6-line escape loop is intentionally duplicated.

---

## Task 1: Pure path-formatting module (`formatDroppedPath`)

**Files:**
- Create: `src/input/file_drop_path.zig`
- Modify: `src/test_fast.zig` (register the module)
- Test: tests live inside `src/input/file_drop_path.zig`

- [ ] **Step 1: Create the module with a deliberately-wrong stub and the four tests**

Create `src/input/file_drop_path.zig`:

```zig
//! Pure formatting for a file path dropped onto the AI chat composer.
//!
//! No platform/AppWindow imports so it runs in the fast test suite (mirrors
//! ai_chat_layout.zig / ai_sidebar.zig). The drop pipeline
//! (src/input/clipboard.zig) calls this to turn an OS-provided absolute path
//! into the text inserted at the composer cursor.

const std = @import("std");

/// Returns the composer text for a dropped file `raw` path. If `raw` contains
/// ASCII whitespace it is single-quoted (POSIX `'\''` escaping for embedded
/// single quotes); otherwise it is inserted verbatim. A single trailing space
/// is always appended so successive drops / continued typing stay separated.
/// Caller owns the returned slice.
pub fn formatDroppedPath(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    // STUB: returns the raw path with no trailing space or quoting. Replaced in
    // Step 3 — present only so the tests compile and fail on assertions.
    return allocator.dupe(u8, raw);
}

test "formatDroppedPath leaves a space-free path verbatim with trailing space" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/file.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/home/me/file.txt ", out);
}

test "formatDroppedPath single-quotes a path containing a space" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/my file.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'/home/me/my file.txt' ", out);
}

test "formatDroppedPath escapes embedded single quotes when quoting" {
    const out = try formatDroppedPath(std.testing.allocator, "/home/me/a 'b'.txt");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("'/home/me/a '\\''b'\\''.txt' ", out);
}

test "formatDroppedPath always appends exactly one trailing space" {
    const out = try formatDroppedPath(std.testing.allocator, "plain");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("plain ", out);
}
```

- [ ] **Step 2: Register the module in the fast test suite**

In `src/test_fast.zig`, add a line alongside the other `input/` registrations (after `src/test_fast.zig:28`'s `_ = @import("input/terminal_link_action.zig");`):

```zig
    _ = @import("input/file_drop_path.zig");
```

- [ ] **Step 3: Run the tests to verify they FAIL (red)**

Run: `zig build test`
Expected: FAIL. The first, second, and fourth tests fail on `expectEqualStrings` (stub omits the trailing space and quoting); e.g. `expected "/home/me/file.txt ", found "/home/me/file.txt"`.

- [ ] **Step 4: Replace the stub with the real implementation**

In `src/input/file_drop_path.zig`, replace the stub `formatDroppedPath` body (keep the doc comment) and add the `needsQuoting` helper below it:

```zig
pub fn formatDroppedPath(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    if (needsQuoting(raw)) {
        try out.append(allocator, '\'');
        for (raw) |ch| {
            if (ch == '\'') {
                try out.appendSlice(allocator, "'\\''");
            } else {
                try out.append(allocator, ch);
            }
        }
        try out.append(allocator, '\'');
    } else {
        try out.appendSlice(allocator, raw);
    }
    try out.append(allocator, ' ');
    return out.toOwnedSlice(allocator);
}

fn needsQuoting(raw: []const u8) bool {
    for (raw) |ch| {
        if (std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}
```

- [ ] **Step 5: Run the tests to verify they PASS (green)**

Run: `zig build test`
Expected: PASS (0 failed). The four `formatDroppedPath` tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/input/file_drop_path.zig src/test_fast.zig
git commit -m "feat(chat): pure formatDroppedPath for dropped file paths

Quotes a dropped path only when it contains whitespace ('\\'' escaping
for embedded single quotes) and always appends a trailing space. Pure
module so it runs in the fast test suite.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: AppWindow hit-test + insert (`appendDroppedPathToChatAtPoint`)

**Files:**
- Modify: `src/AppWindow.zig` (add function immediately after `activeCopilotSessionForInput` at `src/AppWindow.zig:1386-1390`)

This is integration glue over window/tab globals (no pure unit test; verified by `zig build test-full` compiling and by GUI testing in Task 4). It reuses the already-tested `ai_sidebar.boundsForWindow` and the rect math the IME-caret code already uses (`src/AppWindow.zig:4109-4133`).

- [ ] **Step 1: Add the function**

In `src/AppWindow.zig`, directly after the closing brace of `activeCopilotSessionForInput` (the function ending around `:1390`), insert:

```zig
/// Inserts `text` into a visible AI chat composer when a file is dropped at
/// framebuffer-pixel `(x, y)`. Returns true if the point landed over a chat
/// surface and the text was inserted. Checks the dedicated AI-chat tab first
/// (its whole content area is the drop target), then the right-docked copilot
/// panel. Called by the file-drop pipeline (input/clipboard.zig). Coordinates
/// are framebuffer px, matching the OS drop events and clientSize.
pub fn appendDroppedPathToChatAtPoint(text: []const u8, x: i32, y: i32) bool {
    const win = g_window orelse return false;
    const size = window_backend.clientSize(win);

    if (activeAiChat()) |session| {
        const px: f32 = @floatFromInt(x);
        const py: f32 = @floatFromInt(y);
        const left = leftPanelsWidth();
        const top = currentTitlebarHeight();
        const right = @as(f32, @floatFromInt(size.width)) - rightPanelsWidthForWindow(size.width);
        const bottom: f32 = @floatFromInt(size.height);
        if (px >= left and px < right and py >= top and py < bottom) {
            session.appendInputText(text);
            return true;
        }
        return false;
    }

    if (aiCopilotVisible()) {
        const bounds = ai_sidebar.boundsForWindow(size.width, size.height, currentTitlebarHeight(), leftPanelsWidth(), 0);
        if (x >= bounds.left and x < bounds.right and y >= bounds.top and y < bounds.bottom) {
            const session = activeCopilotSessionForInput() orelse return false;
            session.appendInputText(text);
            input.focusAiCopilot();
            return true;
        }
    }

    return false;
}
```

- [ ] **Step 2: Verify it compiles in the full app graph**

Run: `zig build test-full`
Expected: builds and PASSES (0 failed). No new test yet — this step only confirms the new function type-checks within AppWindow. (The fast suite `zig build test` does not include AppWindow.)

- [ ] **Step 3: Commit**

```bash
git add src/AppWindow.zig
git commit -m "feat(chat): hit-test dropped path against chat tab + copilot panel

appendDroppedPathToChatAtPoint inserts text into the AI-chat-tab
composer or the copilot sidebar when a drop lands over it, focusing
the copilot panel so it is ready to edit/send.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Wire the chat branch into the drop pipeline

**Files:**
- Modify: `src/input/clipboard.zig` (import the module, add `handleAiChatFileDrop`, update `handleFileDrop` at `:240-243`)

- [ ] **Step 1: Import the formatting module**

In `src/input/clipboard.zig`, add to the import block near the top (after `const selection_unit = @import("../selection_unit.zig");` at `:12`):

```zig
const file_drop_path = @import("file_drop_path.zig");
```

- [ ] **Step 2: Add the chat-drop handler**

In `src/input/clipboard.zig`, add this function immediately above `handleFileExplorerDrop` (i.e. right after the closing brace of `handleFileDrop` at `:243`):

```zig
fn handleAiChatFileDrop(local_path: []const u8, x: i32, y: i32) bool {
    const allocator = std.heap.page_allocator;
    const text = file_drop_path.formatDroppedPath(allocator, local_path) catch return false;
    defer allocator.free(text);
    return AppWindow.appendDroppedPathToChatAtPoint(text, x, y);
}
```

- [ ] **Step 3: Wire it into `handleFileDrop` and name the `y` param**

In `src/input/clipboard.zig`, replace the existing `handleFileDrop` (`:240-243`):

```zig
pub fn handleFileDrop(local_path: []const u8, x: i32, _: i32) bool {
    if (handleFileExplorerDrop(local_path, x)) return true;
    return handleSshTerminalFileDrop(local_path);
}
```

with:

```zig
pub fn handleFileDrop(local_path: []const u8, x: i32, y: i32) bool {
    if (handleFileExplorerDrop(local_path, x)) return true;
    if (handleAiChatFileDrop(local_path, x, y)) return true;
    return handleSshTerminalFileDrop(local_path);
}
```

- [ ] **Step 4: Verify the full app graph builds and tests pass**

Run: `zig build test-full`
Expected: builds and PASSES (0 failed).

- [ ] **Step 5: Verify the fast suite still passes**

Run: `zig build test`
Expected: PASSES (0 failed), including the four `formatDroppedPath` tests.

- [ ] **Step 6: Commit**

```bash
git add src/input/clipboard.zig
git commit -m "feat(chat): insert dropped file path into chat composer

handleFileDrop now routes a drop landing over a visible AI chat surface
to the composer (between the file-explorer and SSH handlers), inserting
the formatted absolute path instead of an scp upload.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run both suites green**

Run: `zig build test && zig build test-full`
Expected: both exit 0, 0 failed.

- [ ] **Step 2: Record the manual GUI checklist (macOS + Windows; no Linux GUI backend)**

These cannot be run in CI; perform on a GUI build. The macOS bridge exposes `wispterm_macos_window_test_push_file_drop(handle, path, x, y)` for scripted drops.

1. Drop a file onto an AI chat **tab** → its path appears in the composer with a trailing space.
2. Open the copilot sidebar over a terminal, drop a file onto the **panel** → path inserted into the copilot composer and the panel takes focus (can Enter immediately).
3. Drop a file onto the **terminal** area (copilot open) → unchanged SSH/terminal behavior; nothing inserted into the composer.
4. Drop a path **containing a space** → inserted single-quoted (`'…'`).
5. Drop **multiple files** at once → space-separated paths in the composer.
6. Drop onto an SSH terminal with **no chat surface visible** → existing scp upload still works.

- [ ] **Step 3: Note GUI verification status**

GUI verification is pending on macOS/Windows (consistent with the project's other features). Record the outcome in the session memory once verified.

---

## Self-Review notes

- **Spec coverage:** insert format (whitespace-quoted + trailing space) → Task 1; whole-panel drop region for both chat surfaces → Task 2; pipeline ordering (after file-explorer, before SSH) → Task 3; multiple-file behavior (one event per file → space-separated) → inherent, checked in Task 4 Step 2.4/2.5; macOS+Windows only / framebuffer-px coords → Task 2 doc + facts. Error handling (off-panel → false → SSH path; alloc fail → false) → Task 2 returns + Task 3 `catch return false`.
- **Type consistency:** `formatDroppedPath(allocator, raw) Allocator.Error![]u8` defined in Task 1, called with `catch` in Task 3. `appendDroppedPathToChatAtPoint(text, x, y) bool` defined in Task 2, called in Task 3. `Bounds` fields `left/top/right/bottom` and `clientSize` `width/height` match the referenced source lines.
- **No placeholders:** every code/step is complete and concrete.
