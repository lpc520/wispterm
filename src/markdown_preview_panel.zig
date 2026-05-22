//! State for the right-side Markdown/text preview panel.

const std = @import("std");
const markdown_preview = @import("markdown_preview.zig");
const preview_source = @import("input/preview_source.zig");
const tab = @import("appwindow/tab.zig");

pub const DEFAULT_WIDTH: f32 = 440;
pub const MIN_WIDTH: f32 = 280;
pub const MAX_WIDTH: f32 = 1120;
pub const MIN_CONTENT_WIDTH: f32 = 180;
pub const RESIZE_HIT_WIDTH: f32 = 16;
const LOADING_SOURCE = "Loading preview...";
const FAILED_SOURCE = "Preview failed";
const TOO_LARGE_SOURCE = "Preview too large";

pub const PreviewSourceKind = preview_source.SourceKind;
pub const LoadStatus = enum { idle, loading, ready, failed, too_large };
pub const PreviewReadResult = union(enum) {
    ok: []u8,
    failed,
    too_large,
};
const PreviewReadFn = *const fn (std.mem.Allocator, PreviewSourceKind, []const u8) PreviewReadResult;

const PreviewJob = struct {
    request_id: u64 = 0,
    owner_tab: usize = 0,
    kind: markdown_preview.Kind = .markdown,
    source_kind: PreviewSourceKind = .local,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    path_buf: [512]u8 = undefined,
    path_len: usize = 0,
    status: LoadStatus = .failed,
    source: ?[]u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    read_fn: PreviewReadFn = defaultPreviewRead,
};

pub threadlocal var g_visible: bool = false;
pub threadlocal var g_owner_tab: ?usize = null;
pub threadlocal var g_width: f32 = DEFAULT_WIDTH;
pub threadlocal var g_kind: markdown_preview.Kind = .markdown;
pub threadlocal var g_scroll_offset: f32 = 0;
pub threadlocal var g_load_status: LoadStatus = .idle;

pub threadlocal var g_title_buf: [256]u8 = undefined;
pub threadlocal var g_title_len: usize = 0;
pub threadlocal var g_path_buf: [512]u8 = undefined;
pub threadlocal var g_path_len: usize = 0;
pub threadlocal var g_source_buf: [markdown_preview.MAX_SOURCE_BYTES]u8 = undefined;
pub threadlocal var g_source_len: usize = 0;
threadlocal var g_preview_request_id: u64 = 0;
threadlocal var g_preview_jobs: std.ArrayListUnmanaged(*PreviewJob) = .empty;

pub fn width() f32 {
    return if (isVisibleForActiveTab()) g_width else 0;
}

pub fn isVisibleForActiveTab() bool {
    const owner = g_owner_tab orelse return false;
    return g_visible and owner == tab.g_active_tab;
}

pub fn onTabClosed(closed_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == closed_idx) {
        close();
    } else if (owner > closed_idx) {
        g_owner_tab = owner - 1;
    }
}

pub fn onTabReordered(from_idx: usize, to_idx: usize) void {
    const owner = g_owner_tab orelse return;
    if (owner == from_idx) {
        g_owner_tab = to_idx;
    } else if (from_idx < to_idx and owner > from_idx and owner <= to_idx) {
        g_owner_tab = owner - 1;
    } else if (from_idx > to_idx and owner >= to_idx and owner < from_idx) {
        g_owner_tab = owner + 1;
    }
}

pub fn maxWidthForWindow(window_width: f32) f32 {
    return @max(MIN_WIDTH, @min(MAX_WIDTH, window_width - MIN_CONTENT_WIDTH));
}

pub fn setWidth(w: f32, window_width: f32) bool {
    const next = @max(MIN_WIDTH, @min(maxWidthForWindow(window_width), w));
    if (next == g_width) return false;
    g_width = next;
    return true;
}

pub fn open(kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_text: []const u8) void {
    g_preview_request_id +%= 1;
    applyContentForOwner(tab.g_active_tab, kind, preview_title, preview_path, source_text, .ready);
}

fn applyContentForOwner(owner_tab: usize, kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_text: []const u8, status: LoadStatus) void {
    g_visible = true;
    g_owner_tab = owner_tab;
    g_kind = kind;
    g_load_status = status;
    g_scroll_offset = 0;

    g_title_len = @min(preview_title.len, g_title_buf.len);
    @memcpy(g_title_buf[0..g_title_len], preview_title[0..g_title_len]);

    g_path_len = @min(preview_path.len, g_path_buf.len);
    @memcpy(g_path_buf[0..g_path_len], preview_path[0..g_path_len]);

    g_source_len = @min(source_text.len, g_source_buf.len);
    @memcpy(g_source_buf[0..g_source_len], source_text[0..g_source_len]);
}

pub fn close() void {
    g_preview_request_id +%= 1;
    g_visible = false;
    g_owner_tab = null;
    g_load_status = .idle;
    g_scroll_offset = 0;
    g_source_len = 0;
    g_title_len = 0;
    g_path_len = 0;
}

pub fn title() []const u8 {
    return g_title_buf[0..g_title_len];
}

pub fn path() []const u8 {
    return g_path_buf[0..g_path_len];
}

pub fn source() []const u8 {
    return g_source_buf[0..g_source_len];
}

pub fn scrollBy(delta: f32) void {
    const max_scroll = estimatedMaxScroll();
    g_scroll_offset = @max(0, @min(max_scroll, g_scroll_offset + delta));
}

fn estimatedMaxScroll() f32 {
    const line_count = @max(@as(usize, 1), std.mem.count(u8, source(), "\n") + 1);
    return @max(0, @as(f32, @floatFromInt(line_count)) * 28 - 360);
}

pub fn beginAsyncLoad(kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_kind: PreviewSourceKind) bool {
    return beginAsyncLoadWithReader(kind, preview_title, preview_path, source_kind, defaultPreviewRead);
}

fn beginAsyncLoadWithReader(kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_kind: PreviewSourceKind, read_fn: PreviewReadFn) bool {
    g_preview_request_id +%= 1;
    const request_id = g_preview_request_id;
    const owner_tab = tab.g_active_tab;

    if (preview_path.len > 512) {
        applyContentForOwner(owner_tab, kind, preview_title, preview_path, FAILED_SOURCE, .failed);
        return false;
    }

    applyContentForOwner(owner_tab, kind, preview_title, preview_path, LOADING_SOURCE, .loading);

    const allocator = std.heap.page_allocator;
    const job = allocator.create(PreviewJob) catch {
        applyContentForOwner(owner_tab, kind, preview_title, preview_path, FAILED_SOURCE, .failed);
        return false;
    };

    job.* = .{
        .request_id = request_id,
        .owner_tab = owner_tab,
        .kind = kind,
        .source_kind = source_kind,
        .title_len = @min(preview_title.len, 256),
        .path_len = preview_path.len,
        .read_fn = read_fn,
    };
    @memcpy(job.title_buf[0..job.title_len], preview_title[0..job.title_len]);
    @memcpy(job.path_buf[0..preview_path.len], preview_path);

    g_preview_jobs.append(allocator, job) catch {
        destroyPreviewJob(job);
        applyContentForOwner(owner_tab, kind, preview_title, preview_path, FAILED_SOURCE, .failed);
        return false;
    };

    const thread = std.Thread.spawn(.{}, previewJobThread, .{job}) catch {
        _ = g_preview_jobs.pop();
        destroyPreviewJob(job);
        applyContentForOwner(owner_tab, kind, preview_title, preview_path, FAILED_SOURCE, .failed);
        return false;
    };
    job.thread = thread;
    return true;
}

pub fn tickAsync() bool {
    var changed = false;
    var idx: usize = 0;
    while (idx < g_preview_jobs.items.len) {
        const job = g_preview_jobs.items[idx];
        if (!job.done.load(.acquire)) {
            idx += 1;
            continue;
        }

        if (job.thread) |thread| thread.join();
        _ = g_preview_jobs.orderedRemove(idx);
        defer destroyPreviewJob(job);

        if (job.request_id != g_preview_request_id) continue;
        if (!g_visible or g_owner_tab != job.owner_tab) continue;

        const result_source = switch (job.status) {
            .ready => job.source orelse FAILED_SOURCE,
            .too_large => TOO_LARGE_SOURCE,
            else => FAILED_SOURCE,
        };
        const result_status: LoadStatus = if (job.status == .ready and job.source == null) .failed else job.status;
        applyContentForOwner(
            job.owner_tab,
            job.kind,
            job.title_buf[0..job.title_len],
            job.path_buf[0..job.path_len],
            result_source,
            result_status,
        );
        changed = changed or job.owner_tab == tab.g_active_tab;
    }
    return changed;
}

pub fn deinit() void {
    resetPreviewJobs();
}

fn previewJobThread(job: *PreviewJob) void {
    switch (job.read_fn(std.heap.page_allocator, job.source_kind, job.path_buf[0..job.path_len])) {
        .ok => |source_text| {
            job.source = source_text;
            job.status = .ready;
        },
        .too_large => job.status = .too_large,
        .failed => job.status = .failed,
    }
    job.done.store(true, .release);
}

fn defaultPreviewRead(allocator: std.mem.Allocator, source_kind: PreviewSourceKind, preview_path: []const u8) PreviewReadResult {
    const source_text = preview_source.readPreviewSourceForKind(allocator, source_kind, preview_path) catch |err| {
        return if (err == error.PreviewTooLarge) .too_large else .failed;
    };
    return .{ .ok = source_text };
}

fn destroyPreviewJob(job: *PreviewJob) void {
    if (job.source) |source_text| std.heap.page_allocator.free(source_text);
    std.heap.page_allocator.destroy(job);
}

fn resetPreviewJobs() void {
    for (g_preview_jobs.items) |job| {
        if (job.thread) |thread| thread.join();
        destroyPreviewJob(job);
    }
    g_preview_jobs.clearAndFree(std.heap.page_allocator);
}

fn beginAsyncLoadForTest(kind: markdown_preview.Kind, preview_title: []const u8, preview_path: []const u8, source_kind: PreviewSourceKind, read_fn: PreviewReadFn) bool {
    return beginAsyncLoadWithReader(kind, preview_title, preview_path, source_kind, read_fn);
}

fn previewJobCountForTest() usize {
    return g_preview_jobs.items.len;
}

fn resetAsyncForTest() void {
    resetPreviewJobs();
    g_visible = false;
    g_owner_tab = null;
    g_load_status = .idle;
    g_scroll_offset = 0;
    g_title_len = 0;
    g_path_len = 0;
    g_source_len = 0;
    g_preview_request_id = 0;
}

test "markdown_preview_panel: visible only on owning active tab" {
    const saved_visible = g_visible;
    const saved_owner = g_owner_tab;
    const saved_active_tab = tab.g_active_tab;
    defer {
        g_visible = saved_visible;
        g_owner_tab = saved_owner;
        tab.g_active_tab = saved_active_tab;
    }

    tab.g_active_tab = 0;
    open(.markdown, "README.md", "README.md", "# Title\n");

    try std.testing.expect(isVisibleForActiveTab());
    try std.testing.expectEqual(DEFAULT_WIDTH, width());

    tab.g_active_tab = 1;
    try std.testing.expect(!isVisibleForActiveTab());
    try std.testing.expectEqual(@as(f32, 0), width());

    tab.g_active_tab = 0;
    try std.testing.expect(isVisibleForActiveTab());
}

fn previewReadOkForTest(allocator: std.mem.Allocator, _: PreviewSourceKind, _: []const u8) PreviewReadResult {
    const source_text = allocator.dupe(u8, "# Loaded\n") catch return .failed;
    return .{ .ok = source_text };
}

fn previewReadSlowOkForTest(allocator: std.mem.Allocator, source_kind: PreviewSourceKind, preview_path: []const u8) PreviewReadResult {
    std.Thread.sleep(10 * std.time.ns_per_ms);
    return previewReadOkForTest(allocator, source_kind, preview_path);
}

fn tickPreviewJobsUntilIdleForTest() void {
    var attempts: usize = 0;
    while (previewJobCountForTest() > 0 and attempts < 200) : (attempts += 1) {
        _ = tickAsync();
        if (previewJobCountForTest() > 0) std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "markdown_preview_panel: async load shows loading then applies content" {
    const saved_active_tab = tab.g_active_tab;
    resetAsyncForTest();
    defer {
        resetAsyncForTest();
        tab.g_active_tab = saved_active_tab;
    }

    tab.g_active_tab = 0;
    try std.testing.expect(beginAsyncLoadForTest(.markdown, "README.md", "README.md", .local, previewReadOkForTest));
    try std.testing.expectEqual(LoadStatus.loading, g_load_status);
    try std.testing.expectEqualStrings("Loading preview...", source());

    tickPreviewJobsUntilIdleForTest();

    try std.testing.expectEqual(LoadStatus.ready, g_load_status);
    try std.testing.expectEqualStrings("# Loaded\n", source());
    try std.testing.expectEqual(@as(?usize, 0), g_owner_tab);
}

test "markdown_preview_panel: stale async load does not overwrite newer request" {
    const saved_active_tab = tab.g_active_tab;
    resetAsyncForTest();
    defer {
        resetAsyncForTest();
        tab.g_active_tab = saved_active_tab;
    }

    tab.g_active_tab = 0;
    try std.testing.expect(beginAsyncLoadForTest(.markdown, "old.md", "old.md", .local, previewReadSlowOkForTest));
    try std.testing.expect(beginAsyncLoadForTest(.markdown, "new.md", "new.md", .local, previewReadOkForTest));

    tickPreviewJobsUntilIdleForTest();

    try std.testing.expectEqual(LoadStatus.ready, g_load_status);
    try std.testing.expectEqualStrings("new.md", title());
    try std.testing.expectEqualStrings("new.md", path());
    try std.testing.expectEqualStrings("# Loaded\n", source());
}
