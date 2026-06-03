# Focus Panel by Number (Cmd/Ctrl + 1–9) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user focus the Nth panel of the active tab by number (Cmd+1..9 on macOS, Ctrl+1..9 elsewhere), numbered by on-screen position top-left → bottom-right.

**Architecture:** Reuse `SplitTree.spatial()` (normalized 0–1 leaf rects) to sort leaf panels into row-major reading order (pure `sortReadingOrder`), expose `SplitTree.readingOrder`/`panelHandleAt`, focus via `tab.focusPanelByIndex` → `AppWindow.focusPanel` (mirroring `gotoSplit`, with fall-through when there's no panel at that index). New `focus_panel_1..9` keybind actions default to `Ctrl+1..9` (the existing macOS remap renders them as Cmd+1..9).

**Tech Stack:** Zig 0.15. Tests: `zig build test` (fast suite — `command_dispatch.zig`), `zig build test-full` (full graph — `split_tree.zig`, `keybind.zig`, `tab.zig`, `AppWindow.zig`, `input.zig`). Test output contains unrelated `[config]`/`[session_persist]` warnings — those are EXPECTED noise; success = exit 0, no test-failure lines.

**Spec:** `docs/superpowers/specs/2026-06-03-panel-focus-by-number-design.md`

---

## File structure / responsibilities

- `src/split_tree.zig` — `PanelPos`, pure `sortReadingOrder`, `readingOrder`, `panelHandleAt` (ordering lives next to the existing `Spatial`/`spatial`).
- `src/appwindow/tab.zig` — `focusPanelByIndex` (active-tab glue).
- `src/AppWindow.zig` — `focusPanel` (mirrors `gotoSplit`, runs focus side-effects).
- `src/keybind.zig` — `focus_panel_1..9` actions + `Ctrl+1..9` default triggers.
- `src/input/command_dispatch.zig` — `Command.focus_panel` + `focusPanelNumber` + resolve arm.
- `src/input.zig` — dispatch arm with fall-through.
- `src/renderer/overlays/startup_shortcuts.zig` — shortcut hint row (cosmetic).

Task order keeps every commit compiling: ordering core (1–2) → focus glue (3) → keybind actions (4) → command wiring (5) → hint + final verify (6).

---

### Task 1: Pure reading-order sort (`PanelPos` + `sortReadingOrder`)

**Files:**
- Modify: `src/split_tree.zig` (add types/functions just after the `Spatial` struct, near line ~885; add tests in the test section near the bottom)

- [ ] **Step 1: Write the failing tests** (append to the test section at the bottom of `src/split_tree.zig`)

```zig
test "sortReadingOrder orders panels top-left to bottom-right" {
    const at = struct {
        fn h(i: u16) Node.Handle {
            return @enumFromInt(i);
        }
    }.h;
    // Shuffled input: BR, TL, BL, TR (2x2 grid positions).
    var items = [_]PanelPos{
        .{ .handle = at(6), .x = 0.5, .y = 0.5 }, // bottom-right
        .{ .handle = at(2), .x = 0.0, .y = 0.0 }, // top-left
        .{ .handle = at(5), .x = 0.0, .y = 0.5 }, // bottom-left
        .{ .handle = at(3), .x = 0.5, .y = 0.0 }, // top-right
    };
    sortReadingOrder(&items);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(items[0].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(items[1].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 5), @intFromEnum(items[2].handle));
    try std.testing.expectEqual(@as(Node.Handle.Backing, 6), @intFromEnum(items[3].handle));
}

test "sortReadingOrder: a tall left panel precedes a stacked right column" {
    const at = struct {
        fn h(i: u16) Node.Handle {
            return @enumFromInt(i);
        }
    }.h;
    // Left spans full height (top-left at y=0); right column split top (y=0) / bottom (y=0.5).
    var items = [_]PanelPos{
        .{ .handle = at(4), .x = 0.5, .y = 0.5 }, // right-bottom
        .{ .handle = at(2), .x = 0.0, .y = 0.0 }, // left (tall)
        .{ .handle = at(3), .x = 0.5, .y = 0.0 }, // right-top
    };
    sortReadingOrder(&items);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(items[0].handle)); // left (row 0, x 0)
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(items[1].handle)); // right-top (row 0, x 0.5)
    try std.testing.expectEqual(@as(Node.Handle.Backing, 4), @intFromEnum(items[2].handle)); // right-bottom (row 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test-full`
Expected: FAIL — `PanelPos` / `sortReadingOrder` are not defined.

- [ ] **Step 3: Implement `PanelPos` + `sortReadingOrder`** (add immediately after the closing `};` of the `Spatial` struct, around line ~885)

```zig
/// A leaf panel's handle plus its normalized top-left position (from `spatial`),
/// used to order panels by on-screen reading order.
pub const PanelPos = struct {
    handle: Node.Handle,
    x: f16,
    y: f16,
};

/// Number of vertical buckets across the 1.0-tall grid. Panels whose `y` round
/// to the same bucket are treated as the same visual row (then ordered by `x`).
/// 64 ≈ 1.5% tolerance — fine because rows are separated by a meaningful
/// fraction of the height. A quantized integer key keeps the comparison
/// transitive (avoids the floating-epsilon-comparator hazard).
const ROW_QUANTA: f32 = 64.0;

fn rowKey(y: f16) i32 {
    return @intFromFloat(@round(@as(f32, @floatCast(y)) * ROW_QUANTA));
}

fn readingOrderLessThan(_: void, a: PanelPos, b: PanelPos) bool {
    const ay = rowKey(a.y);
    const by = rowKey(b.y);
    if (ay != by) return ay < by;
    return a.x < b.x;
}

/// Sort panels into screen reading order: top-left → bottom-right (row-major).
/// Stable (so exact ties keep tree order); N is the tiny panel count.
pub fn sortReadingOrder(items: []PanelPos) void {
    std.sort.insertion(PanelPos, items, {}, readingOrderLessThan);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/split_tree.zig
git commit -m "feat(split): add row-major panel reading-order sort"
```

---

### Task 2: `SplitTree.readingOrder` + `panelHandleAt`

**Files:**
- Modify: `src/split_tree.zig` (add the two public methods after `sortReadingOrder`; add a test in the test section)

- [ ] **Step 1: Write the failing test** (append to the test section)

```zig
test "SplitTree: readingOrder is row-major top-left to bottom-right" {
    const session_persist = @import("session_persist.zig");
    // 2x2 grid: root stacks two rows (vertical); each row is left|right (horizontal).
    var tl = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var tr = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var bl = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var br = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var top = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &tl, .right = &tr } };
    var bot = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &bl, .right = &br } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .vertical, .ratio = 0.5, .left = &top, .right = &bot } };

    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [16]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var tree = try fromSnapshot(std.testing.allocator, &root, Stub.make);
    defer {
        if (tree.nodes.len > 0) tree.arena.deinit();
        tree = undefined;
    }

    const order = try tree.readingOrder(std.testing.allocator);
    defer std.testing.allocator.free(order);

    // Pre-order node handles: root=0, top=1, tl=2, tr=3, bot=4, bl=5, br=6.
    try std.testing.expectEqual(@as(usize, 4), order.len);
    try std.testing.expectEqual(@as(Node.Handle.Backing, 2), @intFromEnum(order[0])); // top-left
    try std.testing.expectEqual(@as(Node.Handle.Backing, 3), @intFromEnum(order[1])); // top-right
    try std.testing.expectEqual(@as(Node.Handle.Backing, 5), @intFromEnum(order[2])); // bottom-left
    try std.testing.expectEqual(@as(Node.Handle.Backing, 6), @intFromEnum(order[3])); // bottom-right

    // panelHandleAt is 1-based and range-checked.
    try std.testing.expectEqual(@as(?Node.Handle, @enumFromInt(2)), try tree.panelHandleAt(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(?Node.Handle, @enumFromInt(6)), try tree.panelHandleAt(std.testing.allocator, 4));
    try std.testing.expectEqual(@as(?Node.Handle, null), try tree.panelHandleAt(std.testing.allocator, 5));
    try std.testing.expectEqual(@as(?Node.Handle, null), try tree.panelHandleAt(std.testing.allocator, 0));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `readingOrder` / `panelHandleAt` are not defined.

- [ ] **Step 3: Implement the two methods** (add after `sortReadingOrder`)

```zig
/// Leaf-panel handles in screen reading order (top-left → bottom-right).
/// Caller owns the returned slice. Empty tree → zero-length slice.
pub fn readingOrder(self: *const SplitTree, alloc: Allocator) Allocator.Error![]Node.Handle {
    if (self.nodes.len == 0) return alloc.alloc(Node.Handle, 0);

    var sp = try self.spatial(alloc);
    defer sp.deinit(alloc);

    var positions: std.ArrayListUnmanaged(PanelPos) = .empty;
    defer positions.deinit(alloc);
    var it = self.iterator();
    while (it.next()) |entry| {
        const slot = sp.slots[entry.handle.idx()];
        try positions.append(alloc, .{ .handle = entry.handle, .x = slot.x, .y = slot.y });
    }
    sortReadingOrder(positions.items);

    const handles = try alloc.alloc(Node.Handle, positions.items.len);
    for (positions.items, 0..) |p, i| handles[i] = p.handle;
    return handles;
}

/// Handle of the n-th panel (1-based) in reading order, or null if out of range.
pub fn panelHandleAt(self: *const SplitTree, alloc: Allocator, n_one_based: usize) Allocator.Error!?Node.Handle {
    const order = try self.readingOrder(alloc);
    defer alloc.free(order);
    if (n_one_based >= 1 and n_one_based <= order.len) return order[n_one_based - 1];
    return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/split_tree.zig
git commit -m "feat(split): enumerate panels in reading order + index lookup"
```

---

### Task 3: `tab.focusPanelByIndex` + `AppWindow.focusPanel`

**Files:**
- Modify: `src/appwindow/tab.zig` (add `focusPanelByIndex` after `gotoSplit`, ~line 820; add a test in the test section)
- Modify: `src/AppWindow.zig` (add `focusPanel` after `gotoSplit`, ~line 2116)

- [ ] **Step 1: Write the failing test** (append to `src/appwindow/tab.zig` test section)

```zig
test "focusPanelByIndex focuses panels in screen reading order" {
    const session_persist = @import("../session_persist.zig");
    // Two side-by-side panels: root horizontal, left | right.
    var l = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var r = session_persist.NodeSnap{ .leaf = .{ .surface = .{ .local_shell = .{} } } };
    var root = session_persist.NodeSnap{ .split = .{ .layout = .horizontal, .ratio = 0.5, .left = &l, .right = &r } };
    const Stub = struct {
        var counter: usize = 0;
        var sentinels: [8]usize = undefined;
        fn make(_: *const session_persist.SurfaceSnap, _: std.mem.Allocator) ?*Surface {
            const ptr = &sentinels[counter];
            counter += 1;
            return @ptrCast(@alignCast(ptr));
        }
    };
    Stub.counter = 0;

    var ts = TabState{
        .kind = .terminal,
        .tree = try SplitTree.fromSnapshot(std.testing.allocator, &root, Stub.make),
        .focused = .root,
    };
    // Sentinel surfaces can't be unref'd, so free the arena directly (no TabState.deinit).
    defer ts.tree.arena.deinit();

    const saved_active = active_tab_state.g_active_tab;
    const saved_count = g_tab_count;
    const saved_tab0 = g_tabs[0];
    defer {
        active_tab_state.g_active_tab = saved_active;
        g_tab_count = saved_count;
        g_tabs[0] = saved_tab0;
    }
    g_tabs[0] = &ts;
    active_tab_state.g_active_tab = 0;
    g_tab_count = 1;

    // Handles: root=0, left=1, right=2. Reading order: [left(1), right(2)].
    try std.testing.expect(focusPanelByIndex(std.testing.allocator, 1));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 1), @intFromEnum(ts.focused));
    try std.testing.expect(focusPanelByIndex(std.testing.allocator, 2));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(ts.focused));
    // Out of range → false, focus unchanged.
    try std.testing.expect(!focusPanelByIndex(std.testing.allocator, 3));
    try std.testing.expectEqual(@as(SplitTree.Node.Handle.Backing, 2), @intFromEnum(ts.focused));
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `focusPanelByIndex` is not defined.

- [ ] **Step 3a: Implement `focusPanelByIndex`** in `src/appwindow/tab.zig` (add right after the `gotoSplit` function, ~line 820)

```zig
/// Focus the n-th panel (1-based) of the active tab in screen reading order
/// (top-left → bottom-right). Returns false if there is no such panel (n out of
/// range, empty/non-terminal tab), leaving focus unchanged so the caller can let
/// the key fall through to the terminal.
pub fn focusPanelByIndex(allocator: std.mem.Allocator, n: usize) bool {
    const t = activeTab() orelse return false;
    if (t.kind != .terminal) return false;
    const handle = (t.tree.panelHandleAt(allocator, n) catch return false) orelse return false;
    t.focused = handle;
    return true;
}
```

- [ ] **Step 3b: Implement `focusPanel`** in `src/AppWindow.zig` (add right after the `gotoSplit` function, ~line 2116)

```zig
/// Focus the n-th panel (1-based) of the active tab by screen reading order.
/// Returns whether focus moved (false = no such panel, so the caller can let the
/// key fall through to the terminal).
pub fn focusPanel(n: usize) bool {
    const allocator = g_allocator orelse return false;
    if (tab.focusPanelByIndex(allocator, n)) {
        handleActiveSurfaceChangeWithinTab();
        return true;
    }
    return false;
}
```

- [ ] **Step 4: Run test + build to verify**

Run: `zig build test-full && zig build`
Expected: PASS, build exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/appwindow/tab.zig src/AppWindow.zig
git commit -m "feat(tab): focus a panel by reading-order index"
```

---

### Task 4: Keybind actions `focus_panel_1..9` + default `Ctrl+1..9`

**Files:**
- Modify: `src/keybind.zig` (add enum variants after `switch_tab_9` ~line 91; add default triggers after the `switch_tab_9` binding ~line 435; add a test)

- [ ] **Step 1: Write the failing test** (append to the test section of `src/keybind.zig`)

```zig
test "focus_panel actions parse and have default Ctrl+number bindings" {
    try std.testing.expectEqual(Action.focus_panel_1, Action.parse("focus_panel_1").?);
    try std.testing.expectEqual(Action.focus_panel_9, Action.parse("focus_panel_9").?);
    // Each focus_panel_N has a default Ctrl+digit binding (→ Cmd+digit on macOS
    // via the Ctrl→Cmd remap in the Set builder).
    var found: usize = 0;
    for (default_bindings) |b| {
        switch (b.action) {
            .focus_panel_1, .focus_panel_2, .focus_panel_3, .focus_panel_4, .focus_panel_5, .focus_panel_6, .focus_panel_7, .focus_panel_8, .focus_panel_9 => {
                try std.testing.expect(b.trigger.mods.ctrl);
                found += 1;
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 9), found);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test-full`
Expected: FAIL — `focus_panel_1` is not a member of `Action`.

- [ ] **Step 3a: Add the actions** to the `Action` enum in `src/keybind.zig` — insert these nine lines immediately after `switch_tab_9,` (line 91, before `open_config,`):

```zig
    focus_panel_1,
    focus_panel_2,
    focus_panel_3,
    focus_panel_4,
    focus_panel_5,
    focus_panel_6,
    focus_panel_7,
    focus_panel_8,
    focus_panel_9,
```

- [ ] **Step 3b: Add the default bindings** to the `default_bindings` array — insert these nine lines immediately after the `switch_tab_9` binding (line 435):

```zig
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '1' }, .action = .focus_panel_1 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '2' }, .action = .focus_panel_2 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '3' }, .action = .focus_panel_3 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '4' }, .action = .focus_panel_4 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '5' }, .action = .focus_panel_5 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '6' }, .action = .focus_panel_6 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '7' }, .action = .focus_panel_7 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '8' }, .action = .focus_panel_8 },
    .{ .trigger = .{ .mods = .{ .ctrl = true }, .key_code = '9' }, .action = .focus_panel_9 },
```

(The Set builder at `keybind.zig:122-142` remaps every non-global, non-Tab Ctrl default to the `win`/Cmd modifier on macOS, so these become Cmd+1..9 there. The digit keys are unaffected by the Tab/global exceptions.)

- [ ] **Step 4: Run test to verify it passes**

Run: `zig build test-full`
Expected: PASS. (At this point `focus_panel_N` actions resolve to `null` in `command_dispatch` — inert — until Task 5; nothing else switches exhaustively on `Action`, so this compiles.)

- [ ] **Step 5: Commit**

```bash
git add src/keybind.zig
git commit -m "feat(keybind): add focus_panel_1..9 actions + Ctrl/Cmd+1..9 defaults"
```

---

### Task 5: Command wiring (`command_dispatch` + `input.zig`)

**Files:**
- Modify: `src/input/command_dispatch.zig` (add `Command.focus_panel`, `focusPanelNumber`, resolve arm; add a test)
- Modify: `src/input.zig` (add the `.focus_panel` handler arm)

- [ ] **Step 1: Write the failing test** (append to the test section of `src/input/command_dispatch.zig`)

```zig
test "focus_panel actions resolve to a 1-based focus_panel command (late phase only)" {
    try std.testing.expectEqual(Command{ .focus_panel = 1 }, resolve(.focus_panel_1, .late).?);
    try std.testing.expectEqual(Command{ .focus_panel = 9 }, resolve(.focus_panel_9, .late).?);
    try std.testing.expectEqual(@as(?Command, null), resolve(.focus_panel_1, .early));
    // Regression: the shared `else` arm still resolves switch_tab.
    try std.testing.expectEqual(Command{ .switch_tab = 0 }, resolve(.switch_tab_1, .late).?);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test`
Expected: FAIL — `Command.focus_panel` does not exist.

- [ ] **Step 3a: Add the `Command` variant** in `src/input/command_dispatch.zig` — add to the `Command` union (after `switch_tab: usize,`):

```zig
    focus_panel: usize,
```

- [ ] **Step 3b: Resolve the new actions** — in `resolve`'s `.late` switch, replace the existing terminal arm:

```zig
            else => if (switchTabIndex(action)) |idx| .{ .switch_tab = idx } else null,
```

with:

```zig
            else => if (focusPanelNumber(action)) |n|
                .{ .focus_panel = n }
            else if (switchTabIndex(action)) |idx|
                .{ .switch_tab = idx }
            else
                null,
```

- [ ] **Step 3c: Add the `focusPanelNumber` helper** — add right after `switchTabIndex` (~line 92):

```zig
/// focus_panel_1..9 → 1-based panel number, else null.
fn focusPanelNumber(action: keybind.Action) ?usize {
    return switch (action) {
        .focus_panel_1 => 1,
        .focus_panel_2 => 2,
        .focus_panel_3 => 3,
        .focus_panel_4 => 4,
        .focus_panel_5 => 5,
        .focus_panel_6 => 6,
        .focus_panel_7 => 7,
        .focus_panel_8 => 8,
        .focus_panel_9 => 9,
        else => null,
    };
}
```

- [ ] **Step 3d: Handle the command** in `src/input.zig` — in the command `switch` (executeCommand), add this arm right after the `.focus_split => |target| return switch (target) { ... },` arm (~line 1158):

```zig
        // Numeric panel focus: like focus_split, "performable" — if there is no
        // panel at that index (single-panel tab, or index past the panel count),
        // don't consume the key so it falls through to the terminal.
        .focus_panel => |n| return AppWindow.focusPanel(n),
```

- [ ] **Step 4: Run tests + build to verify**

Run: `zig build test && zig build test-full && zig build`
Expected: PASS (fast suite includes the new `command_dispatch` test), full suite PASS, build exit 0.

- [ ] **Step 5: Commit**

```bash
git add src/input/command_dispatch.zig src/input.zig
git commit -m "feat(input): wire focus_panel_N to AppWindow.focusPanel with fall-through"
```

---

### Task 6: Shortcut hint + final verification

**Files:**
- Modify: `src/renderer/overlays/startup_shortcuts.zig` (add a hint row near the existing "Previous / next panel" entry, line 62)

- [ ] **Step 1: Add the hint row** — in `src/renderer/overlays/startup_shortcuts.zig`, add a new entry immediately after the line containing `.action = "Previous / next panel", .action_zh = "上一个 / 下一个面板"` (line 62). Match the existing struct shape of the surrounding entries exactly; use the single-action form (not the `.pair` form), referencing `.focus_panel_1`:

```zig
    .{ .keys = "Ctrl+1..9", .kind = .single, .first = .focus_panel_1, .action = "Focus panel by number", .action_zh = "按编号聚焦面板" },
```

Note: open `startup_shortcuts.zig` and copy the EXACT field set of an existing `.kind = .single` entry (field names/order, and whether a `.second` field is required) — mirror it precisely. If every existing entry is `.pair`, use the `.pair` form with `.first = .focus_panel_1, .second = .focus_panel_9` and label "Focus panel 1–9 by number". Do not invent fields.

- [ ] **Step 2: Build to verify the hint compiles**

Run: `zig build`
Expected: exit 0.

- [ ] **Step 3: Full verification**

Run: `zig build test && zig build test-full && zig build`
Expected: all exit 0, no test-failure lines.

- [ ] **Step 4: Commit**

```bash
git add src/renderer/overlays/startup_shortcuts.zig
git commit -m "docs(shortcuts): add focus-panel-by-number hint row"
```

---

## Self-Review

**Spec coverage:**
- Cmd/Ctrl+1..9 → focus panel N → Task 4 (actions+defaults) + Task 5 (dispatch). ✓
- Numbering by screen position, row-major top-left→bottom-right → Task 1 (`sortReadingOrder`) + Task 2 (`readingOrder`). ✓
- macOS renders as Cmd via existing remap → Task 4 default uses `Ctrl`; note + test assert. ✓
- Panels 1–9 only → `focusPanelNumber` maps 1..9; `panelHandleAt` range-checks. ✓
- Fall-through when no panel at index → `focusPanelByIndex`/`focusPanel` return bool; `input.zig` arm `return AppWindow.focusPanel(n)` (Task 5). ✓
- Reuse focus side-effects → `AppWindow.focusPanel` calls `handleActiveSurfaceChangeWithinTab()` (Task 3). ✓
- Independent of `focus_previous/next` and `Alt+Arrow` → no existing arms modified; only added. ✓
- Testing: pure sort (Task 1), readingOrder on real tree (Task 2), tab glue (Task 3), keybind mapping (Task 4), command resolve (Task 5). ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Task 6 Step 1 defers exact struct shape to the file's existing entries (cosmetic, non-load-bearing) with explicit fallback — acceptable.

**Type consistency:** `PanelPos{ handle: Node.Handle, x: f16, y: f16 }`, `sortReadingOrder([]PanelPos)`, `readingOrder(alloc) ![]Node.Handle`, `panelHandleAt(alloc, usize) !?Node.Handle`, `focusPanelByIndex(allocator, usize) bool`, `focusPanel(usize) bool`, `Command.focus_panel: usize`, `focusPanelNumber(action) ?usize`, `focus_panel_1..9` — names match across all tasks. Indices: `focusPanelNumber` and `panelHandleAt`/`focusPanelByIndex` are all **1-based**; `switchTabIndex` stays 0-based (unchanged). Consistent.

## Notes / out of scope

- GUI/runtime verification (macOS/Windows) is pending after implementation — no Linux GUI backend here.
- No panel-number overlay badges; no >9 panels; no reordering UI (per spec).
