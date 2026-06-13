# Preview Gallery Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Focused image/PDF preview panes support `Left`/`Right` gallery navigation across sibling image/PDF files while `PageUp`/`PageDown` remain PDF page navigation.

**Architecture:** Add a pure `preview_gallery` helper that finds previous/next raster preview files from a directory listing. Store the current preview source kind on `PreviewPane`, then route focused preview `Left`/`Right` keys through the helper and reuse the current pane for the target file. Ghostty has terminal image rendering and input key encoding, but no file preview gallery; this follows Ghostty's relevant input pattern by consuming application UI keys only when that UI has focus and otherwise leaving arrows for terminal encoding.

**Tech Stack:** Zig, existing `file_backend`, `markdown_preview`, `PreviewPane`, `input.zig`, `zig build test`, `zig build test-full`.

---

## File Structure

- Create `src/preview_gallery.zig`: pure path/listing helper. It owns sibling ordering, media filtering, path joining, and tests.
- Modify `src/test_fast.zig`: include `preview_gallery.zig` in the fast native test suite.
- Modify `src/preview_pane.zig`: store the current `PreviewSourceKind` and expose it for input routing.
- Modify `src/input.zig`: route focused raster preview `Left`/`Right` to gallery navigation; keep `Up`/`Down` pan and PDF `PageUp`/`PageDown`.
- Modify `README.md`: document the new shortcut in the keyboard shortcut table.
- Modify `docs/file-explorer.md`: document image/PDF gallery navigation and clarify PDF page keys.

## Task 1: Pure Gallery Helper

**Files:**
- Create: `src/preview_gallery.zig`
- Modify: `src/test_fast.zig`

- [ ] **Step 1: Write the failing gallery tests**

Create `src/preview_gallery.zig` with tests first:

```zig
//! Gallery navigation helper for image/PDF preview panes.

const std = @import("std");
const file_backend = @import("file_backend.zig");
const markdown_preview = @import("markdown_preview.zig");

fn testEntry(name: []const u8, is_dir: bool) file_backend.Entry {
    var entry: file_backend.Entry = .{ .is_dir = is_dir };
    const len: u8 = @intCast(@min(name.len, entry.name_buf.len));
    @memcpy(entry.name_buf[0..len], name[0..len]);
    entry.name_len = len;
    return entry;
}

test "preview_gallery: finds previous and next raster siblings" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("a.png", false),
        testEntry("b.txt", false),
        testEntry("c.pdf", false),
        testEntry("d.jpg", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/c.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqual(markdown_preview.Kind.image, next.kind);
    try std.testing.expectEqualStrings("d.jpg", next.title());
    try std.testing.expectEqualStrings("/tmp/d.jpg", next.path);

    var prev = (try neighborFromEntriesForTest(allocator, "/tmp/c.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqual(markdown_preview.Kind.image, prev.kind);
    try std.testing.expectEqualStrings("a.png", prev.title());
    try std.testing.expectEqualStrings("/tmp/a.png", prev.path);
}

test "preview_gallery: filters directories and non-raster previews" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("alpha.png", true),
        testEntry("notes.md", false),
        testEntry("paper.pdf", false),
        testEntry("photo.webp", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/paper.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqualStrings("photo.webp", next.title());
    try std.testing.expectEqual(markdown_preview.Kind.image, next.kind);

    try std.testing.expect((try neighborFromEntriesForTest(allocator, "/tmp/photo.webp", entries[0..], true)) == null);
    try std.testing.expect((try neighborFromEntriesForTest(allocator, "/tmp/paper.pdf", entries[0..], false)) == null);
}

test "preview_gallery: treats a multi-page pdf as one gallery entry" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("01.png", false),
        testEntry("book.pdf", false),
        testEntry("02.png", false),
    };

    var next = (try neighborFromEntriesForTest(allocator, "/tmp/book.pdf", entries[0..], true)).?;
    defer next.deinit(allocator);
    try std.testing.expectEqualStrings("02.png", next.title());

    var prev = (try neighborFromEntriesForTest(allocator, "/tmp/book.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqualStrings("01.png", prev.title());
}

test "preview_gallery: supports windows-style backslash paths" {
    const allocator = std.testing.allocator;
    var entries = [_]file_backend.Entry{
        testEntry("a.bmp", false),
        testEntry("b.pdf", false),
    };

    var prev = (try neighborFromEntriesForTest(allocator, "C:\\Users\\me\\Pictures\\b.pdf", entries[0..], false)).?;
    defer prev.deinit(allocator);
    try std.testing.expectEqualStrings("a.bmp", prev.title());
    try std.testing.expectEqualStrings("C:\\Users\\me\\Pictures\\a.bmp", prev.path);
}
```

- [ ] **Step 2: Run the helper test to verify RED**

Run:

```bash
zig test src/preview_gallery.zig
```

Expected: FAIL because `neighborFromEntriesForTest` is not defined.

- [ ] **Step 3: Implement minimal gallery helper**

Replace `src/preview_gallery.zig` with the tests plus this implementation above the test helpers:

```zig
//! Gallery navigation helper for image/PDF preview panes.

const std = @import("std");
const file_backend = @import("file_backend.zig");
const markdown_preview = @import("markdown_preview.zig");

pub const MAX_GALLERY_ENTRIES: usize = 2048;
pub const MAX_TARGET_PATH_BYTES: usize = 512;

pub const Target = struct {
    kind: markdown_preview.Kind,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,
    path: []u8,

    pub fn title(self: *const Target) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub fn findNeighbor(
    allocator: std.mem.Allocator,
    backend: file_backend.Backend,
    current_path: []const u8,
    forward: bool,
) !?Target {
    const parent = parentPath(current_path) orelse return null;
    const entries = try allocator.alloc(file_backend.Entry, MAX_GALLERY_ENTRIES);
    defer allocator.free(entries);

    const result = file_backend.list(allocator, backend, parent, entries);
    if (result.status != .ok) return null;
    return neighborFromEntries(allocator, current_path, entries[0..result.count], forward);
}

pub fn neighborFromEntriesForTest(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    entries: []const file_backend.Entry,
    forward: bool,
) !?Target {
    return neighborFromEntries(allocator, current_path, entries, forward);
}

fn neighborFromEntries(
    allocator: std.mem.Allocator,
    current_path: []const u8,
    entries: []const file_backend.Entry,
    forward: bool,
) !?Target {
    const parent = parentPath(current_path) orelse return null;
    const current_name = basename(current_path);
    var previous: ?Candidate = null;
    var found_current = false;

    for (entries) |*entry| {
        if (entry.is_dir) continue;
        const name = entry.name();
        const kind = markdown_preview.detectKind(name) orelse continue;
        if (!kind.isRaster()) continue;

        if (found_current and forward) {
            return try makeTarget(allocator, parent, separatorForPath(current_path), name, kind);
        }

        if (std.mem.eql(u8, name, current_name)) {
            if (!forward) {
                if (previous) |candidate| {
                    return try makeTarget(allocator, parent, separatorForPath(current_path), candidate.name, candidate.kind);
                }
                return null;
            }
            found_current = true;
        }

        previous = .{ .name = name, .kind = kind };
    }

    return null;
}

const Candidate = struct {
    name: []const u8,
    kind: markdown_preview.Kind,
};

fn makeTarget(
    allocator: std.mem.Allocator,
    parent: []const u8,
    sep: u8,
    name: []const u8,
    kind: markdown_preview.Kind,
) !?Target {
    const add_sep = parent.len > 0 and !endsWithSeparator(parent, sep);
    const path_len = parent.len + @as(usize, if (add_sep) 1 else 0) + name.len;
    if (path_len > MAX_TARGET_PATH_BYTES) return null;

    var target: Target = .{
        .kind = kind,
        .path = try allocator.alloc(u8, path_len),
    };
    errdefer allocator.free(target.path);

    var pos: usize = 0;
    @memcpy(target.path[pos..][0..parent.len], parent);
    pos += parent.len;
    if (add_sep) {
        target.path[pos] = sep;
        pos += 1;
    }
    @memcpy(target.path[pos..][0..name.len], name);

    target.title_len = @min(name.len, target.title_buf.len);
    @memcpy(target.title_buf[0..target.title_len], name[0..target.title_len]);
    return target;
}

fn parentPath(path: []const u8) ?[]const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (isSeparator(path[i])) {
            if (i == 0) return path[0..1];
            return path[0..i];
        }
    }
    return null;
}

fn basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (isSeparator(ch)) start = i + 1;
    }
    return path[start..];
}

fn separatorForPath(path: []const u8) u8 {
    for (path) |ch| {
        if (ch == '\\') return '\\';
    }
    return '/';
}

fn isSeparator(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

fn endsWithSeparator(path: []const u8, sep: u8) bool {
    if (path.len == 0) return false;
    const last = path[path.len - 1];
    if (sep == '\\') return last == '\\' or last == '/';
    return last == sep;
}
```

Keep the tests from Step 1 below this implementation.

- [ ] **Step 4: Run helper tests to verify GREEN**

Run:

```bash
zig test src/preview_gallery.zig
```

Expected: PASS.

- [ ] **Step 5: Add helper to the fast test suite**

Modify `src/test_fast.zig` in the existing `test { ... }` import list near `pdf_preview.zig` and `file_backend.zig`:

```zig
    _ = @import("pdf_preview.zig");
    _ = @import("preview_gallery.zig");
    _ = @import("file_backend.zig");
```

- [ ] **Step 6: Run fast tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit Task 1**

```bash
git add src/preview_gallery.zig src/test_fast.zig
git commit -m "feat(preview): add gallery sibling selection"
```

## Task 2: Preserve Preview Source Kind

**Files:**
- Modify: `src/preview_pane.zig`

- [ ] **Step 1: Write failing source-kind test**

Add this test near the other `PreviewPane` tests:

```zig
test "PreviewPane: async load stores current source kind" {
    const gpa = std.testing.allocator;
    var p = try create(gpa);
    defer p.unref(gpa);

    try std.testing.expect(switch (p.currentSourceKind()) {
        .local => true,
        else => false,
    });
    try std.testing.expect(p.beginAsyncLoadWith(.image, "a.png", "/tmp/a.png", .wsl, previewReadOkForTest));
    try std.testing.expect(switch (p.currentSourceKind()) {
        .wsl => true,
        else => false,
    });
    drainJobs(p);
}
```

- [ ] **Step 2: Run preview pane test to verify RED**

Run:

```bash
zig build test-full
```

Expected: FAIL because `currentSourceKind` is not defined.

- [ ] **Step 3: Add source kind state and accessor**

In `src/preview_pane.zig`, add the field near `kind`:

```zig
kind: markdown_preview.Kind = .markdown,
source_kind: PreviewSourceKind = .local,
load_status: LoadStatus = .idle,
```

Add an accessor near the existing accessors:

```zig
pub fn currentSourceKind(self: *const PreviewPane) PreviewSourceKind { return self.source_kind; }
```

Update `open` so synchronous opens have a deterministic local source:

```zig
pub fn open(self: *PreviewPane, kind: markdown_preview.Kind, t: []const u8, p: []const u8, source_text: []const u8) void {
    self.request_id +%= 1;
    self.source_kind = .local;
    self.applyOwned(kind, t, p, std.heap.page_allocator.dupe(u8, source_text) catch null, .ready);
}
```

Update `beginAsyncLoadWith` immediately after `self.request_id +%= 1;`:

```zig
    self.source_kind = source_kind;
```

- [ ] **Step 4: Run the preview pane test to verify GREEN**

Run the same command from Step 2.

Expected: PASS for the new source-kind test.

- [ ] **Step 5: Run fast tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit Task 2**

```bash
git add src/preview_pane.zig
git commit -m "feat(preview): remember preview source kind"
```

## Task 3: Wire Focused Preview Arrow Navigation

**Files:**
- Modify: `src/input.zig`

- [ ] **Step 1: Add imports and helper, expecting compile failure before the helper exists**

Add imports near the other preview imports:

```zig
const file_backend = @import("file_backend.zig");
const preview_gallery = @import("preview_gallery.zig");
```

Add this helper near `openPreviewAsync`:

```zig
fn openPreviewGalleryNeighbor(p: *PreviewPane, forward: bool) bool {
    const gpa = AppWindow.g_allocator orelse return false;
    var target = findPreviewGalleryNeighbor(gpa, p, forward) orelse return false;
    defer target.deinit(gpa);

    if (!p.beginAsyncLoad(target.kind, target.title(), target.path, p.currentSourceKind())) {
        file_explorer.setTransferStatus(.failed, "Preview failed");
        return false;
    }

    AppWindow.g_force_rebuild = true;
    AppWindow.g_cells_valid = false;
    return true;
}

fn findPreviewGalleryNeighbor(allocator: std.mem.Allocator, p: *const PreviewPane, forward: bool) ?preview_gallery.Target {
    return switch (p.currentSourceKind()) {
        .local => preview_gallery.findNeighbor(allocator, .local, p.path(), forward) catch null,
        .wsl => preview_gallery.findNeighbor(allocator, .wsl, p.path(), forward) catch null,
        .remote => |conn| preview_gallery.findNeighbor(allocator, .{ .ssh = &conn }, p.path(), forward) catch null,
    };
}
```

- [ ] **Step 2: Run full compile/test to verify RED if Task 1 or Task 2 was skipped**

Run:

```bash
zig build test-full
```

Expected if earlier tasks are complete: PASS. If earlier tasks were skipped: compile FAIL on missing `preview_gallery` or `currentSourceKind`; do not continue until Task 1 and Task 2 are complete.

- [ ] **Step 3: Route left/right keys to gallery navigation**

In the focused preview key branch, replace the `key_left` / `key_right` cases with gallery navigation. The full raster navigation part should read:

```zig
                platform_input.key_up => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, 40);
                } else p.scrollBy(-60),
                platform_input.key_down => if (p.kind.isRaster()) {
                    _ = p.panImageBy(0, -40);
                } else p.scrollBy(60),
                platform_input.key_left => if (p.kind.isRaster()) {
                    _ = openPreviewGalleryNeighbor(p, false);
                } else {
                    consumed = false;
                },
                platform_input.key_right => if (p.kind.isRaster()) {
                    _ = openPreviewGalleryNeighbor(p, true);
                } else {
                    consumed = false;
                },
```

Leave the existing `PageUp` / `PageDown` PDF cases unchanged:

```zig
                platform_input.key_page_up => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(false);
                } else p.scrollBy(-360),
                platform_input.key_page_down => if (p.kind == .pdf) {
                    _ = p.flipPdfPage(true);
                } else p.scrollBy(360),
```

This preserves multi-page PDF behavior: `PageUp`/`PageDown` call `flipPdfPage`, while `Left`/`Right` never call it.

- [ ] **Step 4: Run full tests**

Run:

```bash
zig build test-full
```

Expected: PASS. If it fails, stop and debug the failure before continuing.

- [ ] **Step 5: Commit Task 3**

```bash
git add src/input.zig
git commit -m "feat(preview): navigate gallery with arrows"
```

## Task 4: Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/file-explorer.md`

- [ ] **Step 1: Update README keyboard shortcuts**

In `README.md`, replace the current PDF row:

```markdown
| Previous / next PDF page (PDF preview focused) | PageUp / PageDown | PageUp / PageDown |
```

with:

```markdown
| Previous / next image/PDF in gallery (preview focused) | Left / Right | Left / Right |
| Previous / next PDF page (PDF preview focused) | PageUp / PageDown | PageUp / PageDown |
```

- [ ] **Step 2: Update file explorer preview docs**

In `docs/file-explorer.md`, replace:

```markdown
PDF previews rasterize one page at a time with the operating system's own
PDF engine: `Windows.Data.Pdf` on Windows 10+, CoreGraphics on macOS, and the
`poppler-utils` tools (`pdfinfo` / `pdftoppm`) on Linux — install them with
your package manager (for example `sudo apt install poppler-utils`) if the
preview reports they are missing. With the PDF preview focused, `PageUp` /
`PageDown` turn pages; the footer shows the current page as `N/M` next to the
`PDF` badge. Zoom and pan work like image previews. Encrypted PDFs are not
supported.
```

with:

```markdown
PDF previews rasterize one page at a time with the operating system's own
PDF engine: `Windows.Data.Pdf` on Windows 10+, CoreGraphics on macOS, and the
`poppler-utils` tools (`pdfinfo` / `pdftoppm`) on Linux — install them with
your package manager (for example `sudo apt install poppler-utils`) if the
preview reports they are missing. With an image or PDF preview focused,
`Left` / `Right` open the previous or next supported image/PDF in the same
directory. With a PDF preview focused, `PageUp` / `PageDown` turn pages inside
the current PDF; the footer shows the current page as `N/M` next to the `PDF`
badge. Zoom and pan work like image previews. Encrypted PDFs are not supported.
```

- [ ] **Step 3: Run docs-sensitive tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 4: Commit Task 4**

```bash
git add README.md docs/file-explorer.md
git commit -m "docs: document preview gallery keys"
```

## Task 5: Final Verification

**Files:**
- No edits expected.

- [ ] **Step 1: Run fast suite**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 2: Run full pre-merge suite**

Run:

```bash
zig build test-full
```

Expected: PASS.

- [ ] **Step 3: Check worktree**

Run:

```bash
git status --short
```

Expected: no uncommitted changes.

- [ ] **Step 4: Manual smoke test on Windows PowerShell**

Build and launch the app on Windows, then verify:

```powershell
zig build
```

Manual checks:

- Open a directory containing `a.png`, `b.pdf`, and `c.jpg`.
- Open `b.pdf` in a preview pane.
- Focus the preview pane.
- Press `PageDown`: the PDF advances to the next page and the footer changes.
- Press `Right`: the preview opens `c.jpg`.
- Press `Left`: the preview opens `b.pdf` again.
- Press `Left`: the preview opens `a.png`.
- Press `Left` at the first item: nothing changes and no characters appear in the terminal.

- [ ] **Step 5: Windows checkout safety if files were added**

Because this plan adds `src/preview_gallery.zig`, run the Windows path-safety checks documented in `docs/development.md#windows-checkout-safety` before merging.
