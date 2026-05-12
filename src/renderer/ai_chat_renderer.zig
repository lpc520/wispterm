//! Native renderer for AI Chat sessions.

const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const ai_chat = @import("../ai_chat.zig");
const font = AppWindow.font;
const gl_init = AppWindow.gl_init;
const titlebar = AppWindow.titlebar;

const c = @cImport({
    @cInclude("glad/gl.h");
});

pub const LINE_PAD_X: f32 = 18;
const HEADER_H: f32 = 54;
pub const INPUT_H: f32 = 92;
const PERMISSION_CHIP_W: f32 = 104;
const PERMISSION_CHIP_H: f32 = 24;
const STATUS_SLOT_W: f32 = 120;
const STOP_BUTTON_W: f32 = 86;
const STOP_BUTTON_H: f32 = 28;
const MODE_SLOT_W: f32 = 112;
const BUBBLE_PAD_X: f32 = 14;
const BUBBLE_PAD_Y: f32 = 10;
const BUBBLE_GAP: f32 = 12;
const APPROVAL_H: f32 = 128;
const APPROVAL_GAP: f32 = 12;
const REASONING_PAD_Y: f32 = 6;
const REASONING_LEFT: f32 = 22;
const REASONING_RIGHT: f32 = 12;
const REASONING_LINE_SCALE: f32 = 0.95;
const COPY_BUTTON_SIZE: f32 = 24;
const COPY_BUTTON_PAD: f32 = 8;

pub fn render(
    session: *ai_chat.Session,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) void {
    const gl = &AppWindow.gl;
    gl.Enable.?(c.GL_BLEND);
    gl.BlendFunc.?(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
    gl.UseProgram.?(gl_init.shader_program);
    gl.ActiveTexture.?(c.GL_TEXTURE0);
    gl.BindVertexArray.?(gl_init.vao);

    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const muted = mixColor(bg, fg, 0.62);
    const panel = mixColor(bg, fg, 0.045);
    const line = mixColor(bg, fg, 0.18);

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const top = @round(titlebar_offset);
    const bottom: f32 = 0;
    const h = @round(@max(1.0, window_height - top));
    if (w <= 1 or h <= 1) return;

    gl_init.renderQuad(x, bottom, w, h, bg);

    session.mutex.lock();
    defer session.mutex.unlock();

    const header_y = window_height - top - HEADER_H;
    gl_init.renderQuadAlpha(x, header_y, w, HEADER_H, panel, 0.95);
    gl_init.renderQuadAlpha(x, header_y, w, 1, line, 0.8);
    _ = titlebar.renderTextLimited(session.model(), x + LINE_PAD_X, header_y + 10, mixColor(fg, accent, 0.12), w * 0.48);

    const permission = ai_chat.agentPermission();
    const chip_x = permissionChipX(x, w);
    const mode_text = if (session.agent_enabled) "Agent" else "Chat";
    const mode_x = chip_x - MODE_SLOT_W - 8;
    _ = titlebar.renderTextLimited(mode_text, mode_x, header_y + 10, mixColor(fg, accent, 0.18), MODE_SLOT_W);

    const perm_text = permissionDisplayName(permission);
    const perm_color = if (permission == .full) mixColor(fg, accent, 0.25) else mixColor(bg, fg, 0.66);
    _ = titlebar.renderTextLimited(perm_text, chip_x, header_y + 10, perm_color, PERMISSION_CHIP_W);
    gl_init.renderQuadAlpha(chip_x, header_y + 8, PERMISSION_CHIP_W - 8, 1, accent, if (permission == .full) 0.38 else 0.16);

    if (session.request_inflight) {
        renderStopButton(stopButtonRect(x, w, top), window_height, session.request_stopping);
    } else {
        const status_w = measureText(session.status());
        const status_limit = STATUS_SLOT_W;
        _ = titlebar.renderTextLimited(session.status(), x + w - LINE_PAD_X - @min(status_w, status_limit), header_y + 10, muted, status_limit);
    }

    const input_y: f32 = 0;
    gl_init.renderQuadAlpha(x, input_y, w, INPUT_H, panel, 0.98);
    gl_init.renderQuadAlpha(x, input_y + INPUT_H - 1, w, 1, line, 0.8);

    const field_x = x + LINE_PAD_X;
    const field_y = input_y + 16;
    const field_w = w - LINE_PAD_X * 2;
    const field_h = INPUT_H - 32;
    const field_bg = mixColor(bg, fg, 0.075);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, field_h, field_bg, 0.95);
    gl_init.renderQuadAlpha(field_x, field_y, field_w, 1, mixColor(bg, accent, 0.38), 0.6);

    const input_text = session.input();
    if (input_text.len == 0) {
        const placeholder = if (session.agent_enabled) "Ask Agent" else "Ask AI Chat";
        _ = titlebar.renderTextLimited(placeholder, field_x + 12, field_y + (field_h - font.g_titlebar_cell_height) / 2, mixColor(bg, fg, 0.42), field_w - 24);
    } else {
        if (session.input_select_all) {
            gl_init.renderQuadAlpha(field_x + 8, field_y + 8, field_w - 16, field_h - 16, accent, 0.22);
        }
        _ = renderWrappedText(input_text, field_x + 12, window_height - field_y - field_h + 10, field_w - 24, lineHeight(), fg, window_height, window_height);
    }
    if (!session.request_inflight and AppWindow.g_cursor_blink_visible) {
        const cursor_x = inputCursorX(input_text, field_x + 12, field_w - 24);
        gl_init.renderQuad(cursor_x, field_y + 14, 1, field_h - 28, accent);
    }

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;

    const transcript_top = top + HEADER_H + 18;
    const transcript_bottom = INPUT_H + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageHeight(msg.content, content_w);
        if (msg.reasoning) |reasoning| content_h += reasoningHeight(reasoning, content_w);
        content_h += BUBBLE_GAP;
    }
    const max_scroll = @max(0.0, content_h - transcript_h);
    session.scroll_px = @min(session.scroll_px, max_scroll);

    const scissor_y: c.GLint = @intFromFloat(@round(transcript_bottom));
    const scissor_h: c.GLsizei = @intFromFloat(@round(transcript_h));
    gl.Enable.?(c.GL_SCISSOR_TEST);
    gl.Scissor.?(
        @intFromFloat(@round(x)),
        scissor_y,
        @intFromFloat(@round(w)),
        scissor_h,
    );

    const gravity_offset = @max(0.0, transcript_h - content_h);
    var cursor_top = transcript_top + gravity_offset - session.scroll_px;
    const transcript_selected = session.transcript_select_all;
    for (session.messages.items) |msg| {
        const bubble_h = messageHeight(msg.content, content_w);
        const visible = cursor_top + bubble_h >= transcript_top and cursor_top <= window_height - transcript_bottom;
        if (visible) {
            renderMessageBubble(
                msg.role,
                msg.content,
                content_x,
                cursor_top,
                content_w,
                bubble_h,
                window_height,
                transcript_selected,
            );
        }
        cursor_top += bubble_h;
        if (msg.reasoning) |reasoning| {
            const r_h = reasoningHeight(reasoning, content_w);
            const reasoning_visible = cursor_top + r_h >= transcript_top and cursor_top <= window_height - transcript_bottom;
            if (reasoning_visible and reasoning.len > 0) {
                renderReasoning(reasoning, content_x, cursor_top, content_w, r_h, window_height, transcript_selected);
            }
            cursor_top += r_h;
        }
        cursor_top += BUBBLE_GAP;
    }

    gl.Disable.?(c.GL_SCISSOR_TEST);

    if (approval) |view| {
        renderApprovalCard(view, x + LINE_PAD_X, INPUT_H + APPROVAL_GAP, w - LINE_PAD_X * 2, APPROVAL_H);
    }
}

pub fn messageCopyHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) ?usize {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    if (w <= 1) return null;

    session.mutex.lock();
    defer session.mutex.unlock();

    const approval = session.approvalView();
    const approval_h: f32 = if (approval != null) APPROVAL_H + APPROVAL_GAP else 0;
    const transcript_top = titlebar_offset + HEADER_H + 18;
    const transcript_bottom = INPUT_H + approval_h + 18;
    const transcript_h = @max(1.0, window_height - transcript_top - transcript_bottom);
    const content_w = w - LINE_PAD_X * 2;
    const content_x = x + LINE_PAD_X;

    var content_h: f32 = 0;
    for (session.messages.items) |msg| {
        content_h += messageHeight(msg.content, content_w);
        if (msg.reasoning) |reasoning| content_h += reasoningHeight(reasoning, content_w);
        content_h += BUBBLE_GAP;
    }

    const scroll_px = @min(session.scroll_px, @max(0.0, content_h - transcript_h));
    const gravity_offset = @max(0.0, transcript_h - content_h);
    var cursor_top = transcript_top + gravity_offset - scroll_px;
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);

    for (session.messages.items, 0..) |msg, message_index| {
        const bubble_h = messageHeight(msg.content, content_w);
        const visible = cursor_top + bubble_h >= transcript_top and cursor_top <= window_height - transcript_bottom;
        if (visible) {
            const rect = copyButtonRect(msg.role, content_x, cursor_top, content_w);
            const viewport_bottom_top_px = window_height - transcript_bottom;
            if (py >= transcript_top and py <= viewport_bottom_top_px and
                px >= rect.x and px <= rect.x + rect.w and py >= rect.top_px and py <= rect.top_px + rect.h)
            {
                return message_index;
            }
        }
        cursor_top += bubble_h;
        if (msg.reasoning) |reasoning| cursor_top += reasoningHeight(reasoning, content_w);
        cursor_top += BUBBLE_GAP;
    }
    return null;
}

pub fn stopButtonHitTest(
    session: *ai_chat.Session,
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    session.mutex.lock();
    const visible = session.request_inflight;
    session.mutex.unlock();
    if (!visible) return false;

    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const rect = stopButtonRect(x, w, titlebar_offset);
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    return px >= rect.x and px <= rect.x + rect.w and
        py >= rect.top_px and py <= rect.top_px + rect.h;
}

pub fn permissionChipHitTest(
    xpos: f64,
    ypos: f64,
    window_width: f32,
    titlebar_offset: f32,
    left_panels_w: f32,
    right_panels_w: f32,
) bool {
    const x = @round(left_panels_w);
    const w = @round(@max(1.0, window_width - left_panels_w - right_panels_w));
    const chip_x = permissionChipX(x, w);
    const chip_top = titlebar_offset + 12;
    const px: f32 = @floatCast(xpos);
    const py: f32 = @floatCast(ypos);
    return px >= chip_x and px <= chip_x + PERMISSION_CHIP_W and
        py >= chip_top and py <= chip_top + PERMISSION_CHIP_H;
}

fn permissionChipX(x: f32, w: f32) f32 {
    return x + w - LINE_PAD_X - STATUS_SLOT_W - 12 - PERMISSION_CHIP_W;
}

const HeaderButtonRect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

fn stopButtonRect(x: f32, w: f32, titlebar_offset: f32) HeaderButtonRect {
    return .{
        .x = x + w - LINE_PAD_X - STOP_BUTTON_W,
        .top_px = titlebar_offset + @round((HEADER_H - STOP_BUTTON_H) / 2),
        .w = STOP_BUTTON_W,
        .h = STOP_BUTTON_H,
    };
}

fn renderStopButton(rect: HeaderButtonRect, window_height: f32, stopping: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - rect.top_px - rect.h;
    const fill = if (stopping) mixColor(bg, fg, 0.12) else mixColor(bg, accent, 0.20);
    const stroke = if (stopping) mixColor(bg, fg, 0.42) else accent;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, fill, 0.92);
    gl_init.renderQuadAlpha(rect.x, y + rect.h - 1, rect.w, 1, stroke, 0.70);
    gl_init.renderQuadAlpha(rect.x, y, rect.w, 1, mixColor(bg, fg, 0.20), 0.70);

    const icon_size: f32 = 8;
    const icon_x = rect.x + 12;
    const icon_y = y + @round((rect.h - icon_size) / 2);
    gl_init.renderQuad(icon_x, icon_y, icon_size, icon_size, if (stopping) mixColor(bg, fg, 0.62) else mixColor(fg, accent, 0.10));

    const label = if (stopping) "Stopping" else "Stop";
    _ = titlebar.renderTextLimited(label, rect.x + 28, y + @round((rect.h - font.g_titlebar_cell_height) / 2), if (stopping) mixColor(bg, fg, 0.72) else fg, rect.w - 34);
}

fn permissionDisplayName(permission: ai_chat.AgentPermission) []const u8 {
    return switch (permission) {
        .confirm => "Ask",
        .full => "Full",
    };
}

fn renderApprovalCard(view: ai_chat.ApprovalView, x: f32, y: f32, w: f32, h: f32) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const card_bg = mixColor(bg, accent, 0.08);
    gl_init.renderQuadAlpha(x, y, w, h, card_bg, 0.98);
    gl_init.renderQuadAlpha(x, y + h - 1, w, 1, accent, 0.65);
    gl_init.renderQuadAlpha(x, y, w, 1, mixColor(bg, fg, 0.18), 0.8);
    gl_init.renderQuadAlpha(x, y, 4, h, accent, 0.85);

    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "Approve {s}?", .{view.tool}) catch "Approve tool?";
    _ = titlebar.renderTextLimited(title, x + 16, y + h - 26, mixColor(fg, accent, 0.20), w - 32);
    _ = titlebar.renderTextLimited("Enter/Y to run, Esc/N to deny", x + 16, y + h - 50, mixColor(bg, fg, 0.62), w - 32);
    if (view.reason.len > 0) {
        _ = titlebar.renderTextLimited(view.reason, x + 16, y + h - 74, mixColor(bg, fg, 0.70), w - 32);
    }
    const command_bg = mixColor(bg, fg, 0.065);
    gl_init.renderQuadAlpha(x + 12, y + 10, w - 24, 34, command_bg, 0.95);
    _ = titlebar.renderTextLimited(view.command, x + 20, y + 18, fg, w - 40);
}

fn renderMessageBubble(role: ai_chat.Role, text: []const u8, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const is_user = role == .user;
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    const bubble_x = if (is_user) x + w - bubble_w else x;
    const bubble_y = window_height - top_px - h;
    const bubble_bg = if (selected) mixColor(bg, accent, 0.30) else if (is_user) mixColor(bg, accent, 0.20) else mixColor(bg, fg, 0.07);
    gl_init.renderQuadAlpha(bubble_x, bubble_y, bubble_w, h, bubble_bg, 0.92);
    gl_init.renderQuadAlpha(bubble_x, bubble_y + h - 1, bubble_w, 1, if (is_user) accent else mixColor(bg, fg, 0.18), 0.55);
    if (selected) gl_init.renderQuadAlpha(bubble_x, bubble_y, 3, h, accent, 0.72);

    const label_color = if (is_user) mixColor(fg, accent, 0.18) else mixColor(fg, accent, 0.05);
    _ = titlebar.renderTextLimited(role.label(), bubble_x + BUBBLE_PAD_X, bubble_y + h - BUBBLE_PAD_Y - font.g_titlebar_cell_height, label_color, bubble_w - BUBBLE_PAD_X * 2);
    const copy_rect = copyButtonRectForBubble(bubble_x, top_px, bubble_w);
    renderCopyButton(copy_rect, window_height, selected);
    _ = renderWrappedText(
        text,
        bubble_x + BUBBLE_PAD_X,
        top_px + BUBBLE_PAD_Y + lineHeight(),
        bubble_w - BUBBLE_PAD_X * 2,
        lineHeight(),
        fg,
        window_height,
        window_height,
    );
}

const CopyButtonRect = struct {
    x: f32,
    top_px: f32,
    w: f32,
    h: f32,
};

fn copyButtonRect(role: ai_chat.Role, x: f32, top_px: f32, w: f32) CopyButtonRect {
    const is_user = role == .user;
    const bubble_w = @min(w, if (is_user) w * 0.82 else w);
    const bubble_x = if (is_user) x + w - bubble_w else x;
    return copyButtonRectForBubble(bubble_x, top_px, bubble_w);
}

fn copyButtonRectForBubble(bubble_x: f32, top_px: f32, bubble_w: f32) CopyButtonRect {
    return .{
        .x = bubble_x + bubble_w - BUBBLE_PAD_X - COPY_BUTTON_SIZE,
        .top_px = top_px + COPY_BUTTON_PAD,
        .w = COPY_BUTTON_SIZE,
        .h = COPY_BUTTON_SIZE,
    };
}

fn renderCopyButton(rect: CopyButtonRect, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const button_bg = if (selected) mixColor(bg, accent, 0.24) else mixColor(bg, fg, 0.10);
    const icon = if (selected) mixColor(fg, accent, 0.14) else mixColor(bg, fg, 0.72);
    const y = window_height - rect.top_px - rect.h;
    gl_init.renderQuadAlpha(rect.x, y, rect.w, rect.h, button_bg, 0.72);

    const t: f32 = 1.3;
    const back_x = rect.x + 7;
    const back_y = y + 7;
    const front_x = rect.x + 5;
    const front_y = y + 5;
    const box_w: f32 = 9;
    const box_h: f32 = 10;
    drawOutlineRect(back_x, back_y, box_w, box_h, t, mixColor(icon, bg, 0.22));
    drawOutlineRect(front_x, front_y + 3, box_w, box_h, t, icon);
}

fn drawOutlineRect(x: f32, y: f32, w: f32, h: f32, t: f32, color: [3]f32) void {
    gl_init.renderQuad(x, y + h - t, w, t, color);
    gl_init.renderQuad(x, y, w, t, color);
    gl_init.renderQuad(x, y, t, h, color);
    gl_init.renderQuad(x + w - t, y, t, h, color);
}

fn renderReasoning(text: []const u8, x: f32, top_px: f32, w: f32, h: f32, window_height: f32, selected: bool) void {
    const bg = AppWindow.g_theme.background;
    const fg = AppWindow.g_theme.foreground;
    const accent = AppWindow.g_theme.cursor_color;
    const y = window_height - top_px - h;
    gl_init.renderQuadAlpha(x, y, w, h, if (selected) mixColor(bg, accent, 0.18) else mixColor(bg, fg, 0.04), 0.85);
    gl_init.renderQuadAlpha(x + 8, y, 3, h, accent, if (selected) 0.60 else 0.32);
    _ = renderWrappedText(text, x + REASONING_LEFT, top_px + REASONING_PAD_Y, w - REASONING_LEFT - REASONING_RIGHT, lineHeight() * REASONING_LINE_SCALE, mixColor(bg, fg, 0.58), window_height, window_height);
}

fn messageHeight(text: []const u8, max_w: f32) f32 {
    const wrapped = countWrappedLines(text, max_w - BUBBLE_PAD_X * 2);
    return BUBBLE_PAD_Y * 2 + lineHeight() + @as(f32, @floatFromInt(@max(1, wrapped))) * lineHeight();
}

fn reasoningHeight(text: []const u8, max_w: f32) f32 {
    const text_w = max_w - REASONING_LEFT - REASONING_RIGHT;
    const lines = countWrappedLines(text, text_w);
    const lh = lineHeight() * REASONING_LINE_SCALE;
    return REASONING_PAD_Y * 2 + @as(f32, @floatFromInt(@max(1, lines))) * lh;
}

fn countWrappedLines(text: []const u8, max_w: f32) usize {
    if (text.len == 0) return 1;
    var lines: usize = 1;
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\n') {
            lines += 1;
            width = 0;
            i += 1;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (width > 0 and width + item.advance > max_w) {
            lines += 1;
            width = 0;
        }
        width += item.advance;
        i += item.len;
    }
    return lines;
}

fn renderWrappedText(
    text: []const u8,
    x: f32,
    top_px: f32,
    max_w: f32,
    line_h: f32,
    color: [3]f32,
    window_height: f32,
    clip_bottom_top_px: f32,
) f32 {
    var line_start: usize = 0;
    var line_width: f32 = 0;
    var i: usize = 0;
    var current_top = top_px;
    while (i < text.len) {
        if (text[i] == '\n') {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            i += 1;
            line_start = i;
            line_width = 0;
            continue;
        }
        const item = nextCodepoint(text, i);
        if (line_width > 0 and line_width + item.advance > max_w) {
            renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
            current_top += line_h;
            line_start = i;
            line_width = 0;
            continue;
        }
        line_width += item.advance;
        i += item.len;
    }
    renderTextLine(text[line_start..i], x, current_top, max_w, color, window_height, clip_bottom_top_px);
    return current_top + line_h;
}

fn renderTextLine(text: []const u8, x: f32, top_px: f32, max_w: f32, color: [3]f32, window_height: f32, clip_bottom_top_px: f32) void {
    if (top_px + lineHeight() < 0 or top_px > clip_bottom_top_px) return;
    const y = window_height - top_px - font.g_titlebar_cell_height;
    _ = titlebar.renderTextLimited(text, x, y, color, max_w);
}

const CodepointItem = struct {
    len: usize,
    advance: f32,
};

fn nextCodepoint(text: []const u8, i: usize) CodepointItem {
    const first = text[i];
    const len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    if (i + len > text.len) return .{ .len = 1, .advance = titlebar.titlebarGlyphAdvance('?') };
    const cp = std.unicode.utf8Decode(text[i .. i + len]) catch @as(u21, '?');
    return .{ .len = len, .advance = titlebar.titlebarGlyphAdvance(@intCast(cp)) };
}

pub fn inputCursorX(text: []const u8, x: f32, max_w: f32) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        if (width + item.advance > max_w) break;
        width += item.advance;
        i += item.len;
    }
    return x + width + 2;
}

fn measureText(text: []const u8) f32 {
    var width: f32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const item = nextCodepoint(text, i);
        width += item.advance;
        i += item.len;
    }
    return width;
}

fn lineHeight() f32 {
    return @round(@max(23.0, font.g_titlebar_cell_height + 8.0));
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}
