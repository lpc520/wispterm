//! tmux pane I/O bridge.
//!
//! Owns the controller-side fd of each pane's virtual PTY (the other end of a
//! `Pty.openVirtual` socketpair, whose `pty` end feeds a `Surface.initVirtual`
//! surface). Backs the Phase 2 `session.PaneSink` — pane `%output` is written
//! to the matching `controller_fd`, where the pane's Surface reads it via its
//! normal `ReadThread` (render path unchanged) — and drains pane keystrokes
//! (`controller_fd` → `Session.sendKeys`).
//!
//! Surface-agnostic: it touches only fds and the `Session`, so it is
//! unit-testable with bare `Pty.openVirtual` socketpairs (see
//! `pane_io_test.zig`). Phase 3c/3d pair each `controller_fd`'s other end with
//! a real Surface and poll all fds alongside the ssh stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const session = @import("session.zig");

pub const PaneMap = struct {
    alloc: Allocator,
    panes: std.ArrayListUnmanaged(Pane) = .empty,
    /// Drain scratch for pumpKeystrokes. The pump is single-threaded (the
    /// controller loop), so one shared buffer is safe.
    read_buf: [4096]u8 = undefined,

    pub const Pane = struct {
        id: usize,
        controller_fd: std.posix.fd_t,
        /// Borrowed pointer to this pane's `*Surface` (owned by the SplitTree
        /// that holds it; the bridge sets it via `setSurface`). Stored as an
        /// opaque pointer so `pane.zig` stays Surface-free and posix-testable.
        /// `removePane`/`deinit` never touch it — the tree owns the ref.
        surface: ?*anyopaque = null,
    };

    pub fn init(alloc: Allocator) PaneMap {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *PaneMap) void {
        for (self.panes.items) |p| std.posix.close(p.controller_fd);
        self.panes.deinit(self.alloc);
    }

    /// Register a pane and take ownership of its controller-side fd.
    /// `removePane`/`deinit` close it, which gives the pane's Surface an EOF.
    pub fn addPane(self: *PaneMap, id: usize, controller_fd: std.posix.fd_t) Allocator.Error!void {
        try self.panes.append(self.alloc, .{ .id = id, .controller_fd = controller_fd });
    }

    pub fn find(self: *PaneMap, id: usize) ?*Pane {
        for (self.panes.items) |*p| {
            if (p.id == id) return p;
        }
        return null;
    }

    /// Attach a borrowed `*Surface` (as an opaque pointer) to a registered
    /// pane. No-op if the pane is unknown. The bridge owns the lifecycle; this
    /// map never refs/unrefs/frees it.
    pub fn setSurface(self: *PaneMap, id: usize, surface: *anyopaque) void {
        if (self.find(id)) |p| p.surface = surface;
    }

    /// Reverse lookup: the pane id whose borrowed surface pointer matches.
    pub fn findIdBySurface(self: *PaneMap, surface: *anyopaque) ?usize {
        for (self.panes.items) |p| {
            if (p.surface) |s| if (s == surface) return p.id;
        }
        return null;
    }

    /// Drop a pane and close its `controller_fd`. Closing the controller end
    /// gives the pane's Surface an EOF on its next read, so its ReadThread
    /// marks the surface exited. No-op if the pane is unknown.
    pub fn removePane(self: *PaneMap, id: usize) void {
        var i: usize = 0;
        while (i < self.panes.items.len) : (i += 1) {
            if (self.panes.items[i].id == id) {
                std.posix.close(self.panes.items[i].controller_fd);
                _ = self.panes.orderedRemove(i);
                return;
            }
        }
    }

    /// A `session.PaneSink` that delivers `%output` bytes to each pane's
    /// `controller_fd`. Output for an unknown pane is dropped.
    pub fn sink(self: *PaneMap) session.PaneSink {
        return .{ .ctx = self, .writeFn = writeImpl };
    }

    /// Non-blocking drain: forward any keystrokes the panes' Surfaces have
    /// written into their virtual PTYs as hex `send-keys` on the Session's
    /// command queue. Intended to be called from the controller loop after a
    /// poll; safe to call when nothing is pending. A `read` of 0 (the Surface
    /// closed its end) stops draining that pane — its removal is driven by the
    /// layout reconcile, not here.
    pub fn pumpKeystrokes(self: *PaneMap, s: *session.Session) Allocator.Error!void {
        for (self.panes.items) |p| {
            while (readable(p.controller_fd)) {
                const n = std.posix.read(p.controller_fd, &self.read_buf) catch break;
                if (n == 0) break;
                try s.sendKeys(p.id, self.read_buf[0..n]);
            }
        }
    }

    fn writeImpl(ctx: *anyopaque, pane_id: usize, bytes: []const u8) void {
        const self: *PaneMap = @ptrCast(@alignCast(ctx));
        const pane = self.find(pane_id) orelse return;
        writeAll(pane.controller_fd, bytes);
    }
};

/// Best-effort write of all bytes; partial writes are retried, errors dropped
/// (matches Surface's PTY write path, which also swallows write errors).
fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.posix.write(fd, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

/// True if `fd` has bytes ready to read right now (poll, zero timeout).
/// POLLHUP-without-data (the Surface closed its end) reads as not-readable, so
/// pumpKeystrokes never spins on a dead pane.
fn readable(fd: std.posix.fd_t) bool {
    var fds = [1]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 0) catch return false;
    if (ready == 0) return false;
    return fds[0].revents & std.posix.POLL.IN != 0;
}

// ----- tests -----

test "setSurface stores a borrowed pointer and findIdBySurface reverses it" {
    var sentinels: [4]u8 = undefined;
    const a: *anyopaque = @ptrCast(&sentinels[0]);
    const b: *anyopaque = @ptrCast(&sentinels[1]);

    var map = PaneMap.init(std.testing.allocator);
    // Free only the backing array, NOT via map.deinit(): these are fake fds and
    // std.posix.close treats EBADF as unreachable, so closing -1 would panic.
    defer map.panes.deinit(map.alloc);

    try map.panes.append(map.alloc, .{ .id = 1, .controller_fd = -1 });
    try map.panes.append(map.alloc, .{ .id = 2, .controller_fd = -1 });

    map.setSurface(1, a);
    map.setSurface(2, b);

    try std.testing.expectEqual(@as(?usize, 1), map.findIdBySurface(a));
    try std.testing.expectEqual(@as(?usize, 2), map.findIdBySurface(b));
    try std.testing.expectEqual(a, map.find(1).?.surface.?);

    const c: *anyopaque = @ptrCast(&sentinels[2]);
    try std.testing.expectEqual(@as(?usize, null), map.findIdBySurface(c));
}
