//! Pure layout math for the command palette panel.
//!
//! Extracted from renderer/overlays.zig so the geometry (box size/position, row
//! count, header/filter/footer bands) can be reasoned about and unit-tested in
//! isolation. Everything here is a pure function of its inputs: window
//! dimensions, the top offset of the content area, the font cell height, and the
//! number of result rows. There are NO global reads and NO AppWindow import — the
//! caller (overlays.zig) snapshots the font cell height and result count and
//! passes them in, then uses the returned numbers exactly as before.

const std = @import("std");

/// Hard cap on rows the palette ever renders at once. Must match the scratch
/// buffer size in overlays.zig.
pub const MAX_VISIBLE_ROWS: usize = 14;

/// Computed geometry for the command palette panel, in top-down client pixels.
pub const Layout = struct {
    box_x: f32,
    box_top_px: f32,
    box_w: f32,
    box_h: f32,
    header_h: f32,
    filter_h: f32,
    footer_h: f32,
    row_top_px: f32,
    row_h: f32,
    rendered_rows: usize,
};

/// Text height for an overlay line, derived from the font cell height.
/// Mirrors overlays.overlayTextHeight().
fn textHeight(cell_height: f32) f32 {
    return @max(1.0, cell_height);
}

/// Row height for list items. Mirrors overlays.overlayRowHeight().
fn rowHeight(cell_height: f32, min_h: f32) f32 {
    return @round(@max(min_h, textHeight(cell_height) + 14.0));
}

/// Control (input) height. Mirrors overlays.overlayControlHeight().
fn controlHeight(cell_height: f32, min_h: f32) f32 {
    return @round(@max(min_h, textHeight(cell_height) + 12.0));
}

/// Clamp an overlay box height so the centered panel never paints past the
/// content area on very short windows. Mirrors overlays.clampOverlayBoxHeight().
fn clampBoxHeight(box_h: f32, content_height: f32) f32 {
    return @max(1.0, @min(box_h, content_height - 32.0));
}

/// How many list rows fit in the available content height.
/// Mirrors overlays.commandPaletteRowCapacity().
fn rowCapacity(content_height: f32, base_h: f32, row_h: f32) usize {
    const usable_h = @max(row_h, content_height - 32.0 - base_h);
    if (usable_h <= row_h) return 1;
    const count_f = @floor(usable_h / row_h);
    const count: usize = @intFromFloat(@max(1.0, count_f));
    return @min(count, MAX_VISIBLE_ROWS);
}

/// Compute the full command-palette layout.
///
/// `cell_height` is the titlebar font cell height (overlays passes
/// font.g_titlebar_cell_height). `result_count` is the number of filtered result
/// rows (overlays passes commandPaletteResultCount()). The math is identical to
/// the previous in-overlays commandPaletteLayout().
pub fn compute(
    window_width: f32,
    window_height: f32,
    top_offset: f32,
    cell_height: f32,
    result_count: usize,
) Layout {
    const content_height = @max(1, window_height - top_offset);

    const box_w = @round(@min(@max(520, window_width - 64), 760));
    const row_h = rowHeight(cell_height, 38);
    const header_h = @round(@max(48.0, textHeight(cell_height) + 30.0));
    const filter_h = controlHeight(cell_height, 42);
    const footer_h = @round(@max(34.0, textHeight(cell_height) + 18.0));
    const base_h = header_h + filter_h + 12 + footer_h;
    const max_rows = rowCapacity(content_height, base_h, row_h);
    const rendered_rows = @min(result_count, max_rows);
    const row_area_h = row_h * @as(f32, @floatFromInt(@max(rendered_rows, 1)));
    const box_h = @round(clampBoxHeight(base_h + row_area_h, content_height));
    const box_x = @round(@max(16, (window_width - box_w) / 2));
    const box_top_px = @round(top_offset + @max(16, (content_height - box_h) / 2));
    const row_top_px = @round(box_top_px + header_h + filter_h + 12);

    return .{
        .box_x = box_x,
        .box_top_px = box_top_px,
        .box_w = box_w,
        .box_h = box_h,
        .header_h = header_h,
        .filter_h = filter_h,
        .footer_h = footer_h,
        .row_top_px = row_top_px,
        .row_h = row_h,
        .rendered_rows = rendered_rows,
    };
}

/// First visible result index that keeps `selected` inside a window of
/// `rendered_rows` rows out of `count` total. Pure scroll-clamp math, shared by
/// the keyboard/list view and the hit-test. Mirrors the body of
/// overlays.commandPaletteFirstVisibleIndex() (the caller still resolves which
/// `selected` value — command vs history — to pass in).
pub fn firstVisibleIndex(rendered_rows: usize, count: usize, selected_in: usize) usize {
    if (rendered_rows == 0 or count <= rendered_rows) return 0;
    const selected = @min(selected_in, count - 1);
    if (selected < rendered_rows) return 0;
    return @min(selected - rendered_rows + 1, count - rendered_rows);
}

test "row capacity is capped at MAX_VISIBLE_ROWS" {
    // A very tall window with a small base/row height would otherwise fit more
    // than the cap; the result must clamp to MAX_VISIBLE_ROWS.
    const row_h: f32 = 38;
    const big = rowCapacity(10000, 100, row_h);
    try std.testing.expectEqual(@as(usize, MAX_VISIBLE_ROWS), big);
}

test "row capacity is at least one row even when cramped" {
    const row_h: f32 = 38;
    // base_h consumes nearly all of a short window.
    try std.testing.expectEqual(@as(usize, 1), rowCapacity(80, 200, row_h));
}

test "layout box width clamps between 520 and 760" {
    const cell: f32 = 20;
    // Narrow window (width-64 < 520) -> min width 520.
    const narrow = compute(560, 800, 0, cell, 5);
    try std.testing.expectEqual(@as(f32, 520), narrow.box_w);
    // Wide window -> capped at 760.
    const wide = compute(2000, 800, 0, cell, 5);
    try std.testing.expectEqual(@as(f32, 760), wide.box_w);
    // Middle window -> window_width - 64.
    const mid = compute(700, 800, 0, cell, 5);
    try std.testing.expectEqual(@as(f32, 700 - 64), mid.box_w);
}

test "layout box is horizontally centered" {
    const cell: f32 = 20;
    const l = compute(1200, 800, 0, cell, 5);
    const expected_x = @round(@max(16, (@as(f32, 1200) - l.box_w) / 2));
    try std.testing.expectEqual(expected_x, l.box_x);
}

test "rendered rows never exceeds result count or capacity" {
    const cell: f32 = 20;
    // Few results: rendered_rows == result_count.
    const few = compute(1200, 1200, 0, cell, 3);
    try std.testing.expectEqual(@as(usize, 3), few.rendered_rows);
    // Many results in a tall window: clamped at MAX_VISIBLE_ROWS.
    const many = compute(1200, 4000, 0, cell, 100);
    try std.testing.expect(many.rendered_rows <= MAX_VISIBLE_ROWS);
    try std.testing.expectEqual(@as(usize, MAX_VISIBLE_ROWS), many.rendered_rows);
}

test "row band starts below the header and filter" {
    const cell: f32 = 20;
    const l = compute(1200, 1000, 40, cell, 8);
    const expected_row_top = @round(l.box_top_px + l.header_h + l.filter_h + 12);
    try std.testing.expectEqual(expected_row_top, l.row_top_px);
    // Row band sits strictly below the box top.
    try std.testing.expect(l.row_top_px > l.box_top_px);
}

test "first visible index keeps selection in view" {
    // count <= rendered: window starts at 0.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(14, 10, 9));
    // selection within the first window: no scroll.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(5, 20, 4));
    // selection past the window: scroll so selection is the last visible row.
    try std.testing.expectEqual(@as(usize, 1), firstVisibleIndex(5, 20, 5));
    try std.testing.expectEqual(@as(usize, 6), firstVisibleIndex(5, 20, 10));
    // selection at the very end: clamp to count - rendered.
    try std.testing.expectEqual(@as(usize, 15), firstVisibleIndex(5, 20, 19));
    // out-of-range selection is clamped to the last item.
    try std.testing.expectEqual(@as(usize, 15), firstVisibleIndex(5, 20, 99));
    // rendered_rows == 0: degenerate, no scroll.
    try std.testing.expectEqual(@as(usize, 0), firstVisibleIndex(0, 20, 5));
}
