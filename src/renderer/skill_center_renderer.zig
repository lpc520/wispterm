const std = @import("std");
const inv = @import("../skill_inventory.zig");
const ai_history_renderer = @import("ai_history_renderer.zig");

// Reuse the AI History renderer's drawing seam verbatim so AppWindow can call
// this renderer with the exact same DrawContext it already builds for the AI
// History panel (text-draw fn pointer, rect/quad fns, colors, cell height,
// glyph-advance metric). Keeping a single contract means no new wiring on the
// AppWindow side beyond choosing which renderer to call.
pub const DrawContext = ai_history_renderer.DrawContext;

const HEADER_H: f32 = 54;
const COLHEAD_H: f32 = 40;
const ROW_H: f32 = 30;
const PAD_X: f32 = 16;
const LEGEND_H: f32 = 36;
/// Left band holds the provider tag + skill name; columns start after it.
const NAME_W: f32 = 240;
/// Width reserved for each server column's cell glyph / header label.
const COL_W: f32 = 64;
const SMALL_GAP: f32 = 6;

/// Plain-data view of the Skill Center panel state. No threading or store
/// imports: AppWindow snapshots its skill_center state into one of these under
/// the appropriate lock and hands it to `render`.
pub const View = struct {
    matrix: ?*const inv.Matrix,
    sel_row: usize,
    sel_col: usize,
    scroll: usize,
    stale: bool,
    status: []const u8, // e.g. "Scanning… 2/5" or ""
};

/// Glyph drawn for a cell state. Kept pure so it can be unit-tested and so the
/// column header / legend share one source of truth.
fn glyphForState(state: inv.CellState) []const u8 {
    return switch (state) {
        .match => "✓",
        .differ => "≠",
        .absent => "✗",
        .unknown => "?",
    };
}

/// How many skill rows fit between the column-header row and the legend line.
pub fn bodyVisibleCapacity(window_height: f32, titlebar_offset: f32, cell_h: f32) usize {
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    const header_h = headerHeight(cell_h) + colHeaderHeight(cell_h);
    const usable = content_h - header_h - legendHeight(cell_h);
    if (usable <= 0) return 0;
    return @intFromFloat(@max(0.0, @floor(usable / rowHeight(cell_h))));
}

/// Clamp a requested scroll so the last page of rows stays anchored to the
/// bottom instead of scrolling past the end.
fn clampScroll(requested: usize, total: usize, visible: usize) usize {
    if (total <= visible) return 0;
    return @min(requested, total - visible);
}

// Vertical bands scale with the UI cell height (high-DPI) but never shrink
// below the fixed floors, mirroring ai_history_renderer.
fn headerHeight(cell_h: f32) f32 {
    return @max(HEADER_H, cell_h + 18);
}

fn colHeaderHeight(cell_h: f32) f32 {
    return @max(COLHEAD_H, cell_h + 14);
}

fn rowHeight(cell_h: f32) f32 {
    return @max(ROW_H, cell_h + 12);
}

fn legendHeight(cell_h: f32) f32 {
    return @max(LEGEND_H, cell_h + 18);
}

fn yFromTop(window_height: f32, top_px: f32, h: f32) f32 {
    return window_height - top_px - h;
}

fn yTextFromTop(draw: DrawContext, window_height: f32, top_px: f32) f32 {
    return window_height - top_px - draw.cell_h;
}

fn mixColor(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    const clamped = @max(0.0, @min(1.0, t));
    return .{
        a[0] + (b[0] - a[0]) * clamped,
        a[1] + (b[1] - a[1]) * clamped,
        a[2] + (b[2] - a[2]) * clamped,
    };
}

/// Color for a cell glyph: green match, yellow differs, red missing, dim
/// unknown. Derived from the theme fg/accent so it tracks the active palette
/// without a hardcoded palette of its own.
fn colorForState(state: inv.CellState, muted: [3]f32) [3]f32 {
    return switch (state) {
        .match => .{ 0.36, 0.74, 0.42 },
        .differ => .{ 0.86, 0.70, 0.28 },
        .absent => .{ 0.84, 0.36, 0.36 },
        .unknown => muted,
    };
}

pub fn render(
    draw: DrawContext,
    view: View,
    window_width: f32,
    window_height: f32,
    titlebar_offset: f32,
    x: f32,
    width: f32,
) void {
    _ = window_width;
    const content_x = @round(x);
    const content_w = @round(@max(1.0, width));
    const top = @round(titlebar_offset);
    const content_h = @round(@max(1.0, window_height - top));
    if (content_w <= 1 or content_h <= 1) return;

    const bg = draw.bg;
    const fg = draw.fg;
    const accent = draw.accent;
    const panel_strong = mixColor(bg, fg, 0.075);
    const line = mixColor(bg, fg, 0.18);
    const muted = mixColor(bg, fg, 0.58);
    const selected_bg = mixColor(bg, accent, 0.18);

    draw.fillQuad(content_x, 0, content_w, content_h, bg);

    // --- Header band: title + summary (+ cached marker) + status. ---
    const header_h = headerHeight(draw.cell_h);
    draw.fillQuadAlpha(content_x, yFromTop(window_height, top, header_h), content_w, header_h, panel_strong, 0.9);
    draw.fillQuad(content_x, yFromTop(window_height, top + header_h, 1), content_w, 1, line);

    const title = "Skill Center";
    const title_y = yTextFromTop(draw, window_height, top + 11);
    const title_end = draw.renderTextLimited(title, content_x + PAD_X, title_y, fg, content_w - PAD_X * 2);

    const servers_len = if (view.matrix) |m| m.servers.len else 0;
    const skills_len = if (view.matrix) |m| m.skills.len else 0;
    var summary_buf: [96]u8 = undefined;
    const summary = if (view.stale)
        std.fmt.bufPrint(&summary_buf, "{d} servers · {d} skills (cached)", .{ servers_len, skills_len }) catch ""
    else
        std.fmt.bufPrint(&summary_buf, "{d} servers · {d} skills", .{ servers_len, skills_len }) catch "";
    const summary_x = title_end + 16;
    _ = draw.renderTextLimited(summary, summary_x, title_y, muted, @max(0, content_x + content_w - PAD_X - summary_x));

    // Status (e.g. "Scanning… 2/5"): right-aligned in the header, accent color.
    if (view.status.len > 0) {
        const status_w: f32 = 220;
        const status_x = content_x + content_w - PAD_X - status_w;
        if (status_x > summary_x) {
            _ = draw.renderTextLimited(view.status, status_x, title_y, accent, status_w);
        }
    }

    // --- Empty / null matrix state. ---
    const matrix = view.matrix orelse {
        _ = draw.renderTextLimited(
            "No skills found. Scanning…",
            content_x + PAD_X,
            yTextFromTop(draw, window_height, top + header_h + 24),
            muted,
            content_w - PAD_X * 2,
        );
        renderLegend(draw, content_x, content_w, muted, line);
        return;
    };
    if (matrix.skills.len == 0 or matrix.servers.len == 0) {
        const empty = if (matrix.servers.len == 0) "No servers configured." else "No skills found. Scanning…";
        _ = draw.renderTextLimited(
            empty,
            content_x + PAD_X,
            yTextFromTop(draw, window_height, top + header_h + 24),
            muted,
            content_w - PAD_X * 2,
        );
        renderLegend(draw, content_x, content_w, muted, line);
        return;
    }

    // --- Column header row: one short label per server. ---
    const colhead_h = colHeaderHeight(draw.cell_h);
    const colhead_top = top + header_h;
    draw.fillQuadAlpha(content_x, yFromTop(window_height, colhead_top, colhead_h), content_w, colhead_h, mixColor(bg, fg, 0.04), 0.95);
    draw.fillQuad(content_x, yFromTop(window_height, colhead_top + colhead_h, 1), content_w, 1, line);

    const cols_x = content_x + PAD_X + NAME_W;
    const colhead_text_y = yTextFromTop(draw, window_height, colhead_top + (colhead_h - draw.cell_h) / 2);
    for (matrix.servers, 0..) |srv, ci| {
        const cx = cols_x + @as(f32, @floatFromInt(ci)) * COL_W;
        if (cx >= content_x + content_w) break;
        // Unreachable servers are dimmed to muted; reachable use fg.
        const col_color = if (srv.reachable) fg else muted;
        _ = draw.renderTextLimited(srv.source_id, cx, colhead_text_y, col_color, COL_W - SMALL_GAP);
    }

    // --- Body rows. ---
    const row_h = rowHeight(draw.cell_h);
    const body_top = colhead_top + colhead_h;
    const cap = bodyVisibleCapacity(window_height, top, draw.cell_h);
    const scroll = clampScroll(view.scroll, matrix.skills.len, cap);

    var rendered: usize = 0;
    var ri: usize = scroll;
    while (ri < matrix.skills.len and rendered < cap) : (ri += 1) {
        const row_top_px = body_top + @as(f32, @floatFromInt(rendered)) * row_h;
        const row_y = yFromTop(window_height, row_top_px, row_h);

        if (ri == view.sel_row) {
            draw.fillQuadAlpha(content_x, row_y, content_w, row_h, selected_bg, 0.55);
            draw.fillQuad(content_x, row_y, 3, row_h, accent);
        }
        // Zebra separator under each row.
        draw.fillQuadAlpha(content_x, row_y, content_w, 1, line, 0.4);

        const skill = matrix.skills[ri];
        const text_y = yTextFromTop(draw, window_height, row_top_px + (row_h - draw.cell_h) / 2);

        // Provider tag (accent) + skill name (fg) on the left band.
        const tag = skill.provider.toString();
        const tag_end = draw.renderTextLimited(tag, content_x + PAD_X, text_y, accent, 70);
        const name_x = tag_end + 8;
        _ = draw.renderTextLimited(skill.name, name_x, text_y, fg, @max(0, content_x + PAD_X + NAME_W - name_x - 8));

        // One glyph per server column.
        for (matrix.servers, 0..) |_, ci| {
            const cx = cols_x + @as(f32, @floatFromInt(ci)) * COL_W;
            if (cx >= content_x + content_w) break;
            const cell = matrix.cellAt(ri, ci);

            // Highlight the focused cell with an accent underline.
            if (ri == view.sel_row and ci == view.sel_col) {
                draw.fillQuad(cx - 2, yFromTop(window_height, row_top_px + row_h - 2, 2), COL_W - SMALL_GAP, 2, accent);
            }

            const gly = glyphForState(cell.state);
            const color = colorForState(cell.state, muted);
            _ = draw.renderTextLimited(gly, cx, text_y, color, COL_W - SMALL_GAP);
        }

        rendered += 1;
    }

    renderLegend(draw, content_x, content_w, muted, line);
}

fn renderLegend(
    draw: DrawContext,
    content_x: f32,
    content_w: f32,
    muted: [3]f32,
    line: [3]f32,
) void {
    const legend_h = legendHeight(draw.cell_h);
    // Pinned to the bottom of the panel (top_px measured from the panel top is 0
    // at the bottom edge; the legend band occupies y in [0, legend_h)).
    draw.fillQuad(content_x, legend_h, content_w, 1, line);
    const text_y = (legend_h - draw.cell_h) / 2;
    var buf: [128]u8 = undefined;
    const legend = std.fmt.bufPrint(
        &buf,
        "{s} match   {s} differs   {s} missing   {s} unknown",
        .{ glyphForState(.match), glyphForState(.differ), glyphForState(.absent), glyphForState(.unknown) },
    ) catch "";
    _ = draw.renderTextLimited(legend, content_x + PAD_X, text_y, muted, content_w - PAD_X * 2);
}

// --- Tests ---

test "skill_center_renderer: glyphForState maps cell states" {
    try std.testing.expectEqualStrings("✓", glyphForState(.match));
    try std.testing.expectEqualStrings("≠", glyphForState(.differ));
    try std.testing.expectEqualStrings("✗", glyphForState(.absent));
    try std.testing.expectEqualStrings("?", glyphForState(.unknown));
}

test "skill_center_renderer: clampScroll keeps scroll within range" {
    try std.testing.expectEqual(@as(usize, 0), clampScroll(5, 3, 10)); // everything fits
    try std.testing.expectEqual(@as(usize, 2), clampScroll(5, 12, 10)); // clamped to max
    try std.testing.expectEqual(@as(usize, 1), clampScroll(1, 12, 10)); // within range
}

test "skill_center_renderer: bodyVisibleCapacity is non-negative and grows with height" {
    const cell_h: f32 = 16;
    const small = bodyVisibleCapacity(200, 40, cell_h);
    const large = bodyVisibleCapacity(800, 40, cell_h);
    try std.testing.expect(large >= small);
    // A 0-height content area yields no rows.
    try std.testing.expectEqual(@as(usize, 0), bodyVisibleCapacity(40, 40, cell_h));
}
