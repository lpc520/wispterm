const std = @import("std");
const Config = @import("../config.zig");
const resize_throttle = @import("resize_throttle.zig");
const UiEffect = @import("ui_effect.zig").UiEffect;

pub const GridSize = struct {
    cols: u16,
    rows: u16,
};

pub const PendingResize = struct {
    pending: bool = false,
    cols: u16 = 0,
    rows: u16 = 0,
    last_ms: i64 = 0,
};

pub const State = struct {
    term_cols: u16 = 80,
    term_rows: u16 = 24,
    cells_valid: bool = false,
    force_rebuild: bool = true,
    present_bringup_settled: bool = false,
    focused: bool = true,
    pending_resize: PendingResize = .{},
    layout_resize_immediate: bool = false,
    cursor_style: Config.CursorStyle = .block,
    cursor_blink: bool = true,
    cursor_blink_visible: bool = true,
    last_blink_time_ms: i64 = 0,
    focus_follows_mouse: bool = false,
    copy_on_select: bool = false,
    copilot_hint: bool = true,
    copilot_shimmer_checked: bool = false,
    right_click_action: Config.RightClickAction = .copy,
    ssh_legacy_algorithms: bool = false,
    desktop_notifications: bool = true,
    confirm_close_running_program: bool = true,
    weixin_notify_forward: bool = false,
    notification_auth_requested: bool = false,
    resize_throttle: resize_throttle.ResizeThrottle = .{},

    pub fn markDirty(self: *State) void {
        self.force_rebuild = true;
        self.cells_valid = false;
    }

    pub fn clearDirty(self: *State) void {
        self.force_rebuild = false;
        self.cells_valid = true;
    }

    pub fn applyUiEffect(self: *State, effect: UiEffect) void {
        if (effect.needs_rebuild) self.force_rebuild = true;
        if (effect.cells_invalid) self.cells_valid = false;
    }

    pub fn requestImmediateLayoutResize(self: *State) void {
        self.layout_resize_immediate = true;
    }

    pub fn consumeImmediateLayoutResize(self: *State) bool {
        const immediate = self.layout_resize_immediate;
        self.layout_resize_immediate = false;
        return immediate;
    }

    pub fn queueResize(self: *State, cols: u16, rows: u16, now_ms: i64) void {
        self.pending_resize = .{ .pending = true, .cols = cols, .rows = rows, .last_ms = now_ms };
    }

    pub fn clearPendingResize(self: *State) void {
        self.pending_resize.pending = false;
    }

    pub fn consumeCoalescedResize(self: *State, now_ms: i64, interval_ms: i64, current_cols: u16, current_rows: u16) ?GridSize {
        if (!self.pending_resize.pending) return null;
        if (now_ms - self.pending_resize.last_ms < interval_ms) return null;
        const next = GridSize{ .cols = self.pending_resize.cols, .rows = self.pending_resize.rows };
        self.pending_resize.pending = false;
        if (next.cols == current_cols and next.rows == current_rows) return null;
        return next;
    }

    pub fn updateFocus(self: *State, focused: bool) bool {
        const changed = self.focused != focused;
        self.focused = focused;
        return changed;
    }

    pub fn resetCursorBlink(self: *State, now_ms: i64) void {
        self.cursor_blink_visible = true;
        self.last_blink_time_ms = now_ms;
    }

    pub fn updateCursorBlink(self: *State, now_ms: i64, interval_ms: i64) bool {
        if (!self.cursor_blink) {
            self.cursor_blink_visible = true;
            return false;
        }
        if (now_ms - self.last_blink_time_ms < interval_ms) return false;
        self.cursor_blink_visible = !self.cursor_blink_visible;
        self.last_blink_time_ms = now_ms;
        return true;
    }

    pub fn takePresentBringupSettlement(self: *State) bool {
        if (self.present_bringup_settled) return false;
        self.present_bringup_settled = true;
        return true;
    }
};

test "window state dirty helpers mirror UiEffect repaint" {
    var state = State{ .force_rebuild = false, .cells_valid = true };

    state.applyUiEffect(UiEffect.repaint);

    try std.testing.expect(state.force_rebuild);
    try std.testing.expect(!state.cells_valid);

    state.clearDirty();
    try std.testing.expect(!state.force_rebuild);
    try std.testing.expect(state.cells_valid);
}

test "window state pending resize coalesces and ignores unchanged grid" {
    var state = State{ .term_cols = 80, .term_rows = 24 };

    state.queueResize(100, 40, 1_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(1_010, 25, 80, 24));
    try std.testing.expect(state.pending_resize.pending);

    const consumed = state.consumeCoalescedResize(1_030, 25, 80, 24).?;
    try std.testing.expectEqual(@as(u16, 100), consumed.cols);
    try std.testing.expectEqual(@as(u16, 40), consumed.rows);
    try std.testing.expect(!state.pending_resize.pending);

    state.queueResize(100, 40, 2_000);
    try std.testing.expectEqual(@as(?GridSize, null), state.consumeCoalescedResize(2_030, 25, 100, 40));
    try std.testing.expect(!state.pending_resize.pending);
}

test "window state immediate layout resize is one-shot" {
    var state = State{};

    state.requestImmediateLayoutResize();
    try std.testing.expect(state.layout_resize_immediate);
    try std.testing.expect(state.consumeImmediateLayoutResize());
    try std.testing.expect(!state.consumeImmediateLayoutResize());
}

test "window state cursor blink toggles only when enabled and due" {
    var state = State{ .cursor_blink = true, .cursor_blink_visible = true, .last_blink_time_ms = 100 };

    try std.testing.expect(!state.updateCursorBlink(650, 600));
    try std.testing.expect(state.cursor_blink_visible);

    try std.testing.expect(state.updateCursorBlink(700, 600));
    try std.testing.expect(!state.cursor_blink_visible);
    try std.testing.expectEqual(@as(i64, 700), state.last_blink_time_ms);

    state.cursor_blink = false;
    state.cursor_blink_visible = false;
    try std.testing.expect(!state.updateCursorBlink(2_000, 600));
    try std.testing.expect(state.cursor_blink_visible);
}

test "window state present bringup settlement fires once" {
    var state = State{};

    try std.testing.expect(state.takePresentBringupSettlement());
    try std.testing.expect(!state.takePresentBringupSettlement());
}
