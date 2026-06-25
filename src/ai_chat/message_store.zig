//! Owns the AI Chat session's ordered message list.
//!
//! Extracted from the `ai_chat.Session` god-object so the "what messages does
//! this session hold, and how do we append/truncate them?" responsibility lives
//! in one std-only, unit-testable place instead of being spread across ~150
//! `self.messages.items` / `.append` / `.pop` references in ai_chat.zig.
//!
//! To avoid a circular import (ai_chat.zig defines `Message`, and a non-generic
//! store here would have to import ai_chat.zig back for that type) this module is
//! GENERIC over the message type, mirroring the pattern used by
//! input/mouse_dispatch.zig's `TerminalMouseReportState(comptime SurfacePtr)`.
//!
//! This module owns NO I/O: it never touches a PTY, a surface mutex, the
//! renderer, or AppWindow. It is a pure container over the allocator the caller
//! hands in on each mutating call (matching `std.ArrayListUnmanaged`'s shape so
//! existing call sites keep their `append(allocator, msg)` / `deinit(allocator)`
//! ergonomics unchanged).
//!
//! `Message` must expose `fn deinit(self: Message, allocator: std.mem.Allocator)`
//! so the store can free owned entries on `truncateFrom` / `deinitAll`.

const std = @import("std");

/// A message list keyed by insertion order. `Message` is supplied by the caller
/// (ai_chat.zig passes its own `Message` struct) to keep this module free of any
/// dependency on the session module.
pub fn MessageStore(comptime Message: type) type {
    return struct {
        const Self = @This();

        /// Backing storage. Public so the rare call site that must move a freshly
        /// built list in wholesale (e.g. the context-summary fold) can assign
        /// `store.list = new_list` without the store re-allocating. Prefer the
        /// methods below for everything else.
        list: std.ArrayListUnmanaged(Message) = .empty,

        /// An empty store. Equivalent to `.{}` but reads intentionally at call
        /// sites that construct a Session.
        pub const empty: Self = .{};

        /// Wrap an already-populated `ArrayListUnmanaged` (ownership moves in).
        pub fn fromList(list: std.ArrayListUnmanaged(Message)) Self {
            return .{ .list = list };
        }

        /// Append one message to the tail. Signature mirrors
        /// `std.ArrayListUnmanaged.append` so existing call sites are unchanged.
        pub fn append(self: *Self, allocator: std.mem.Allocator, msg: Message) std.mem.Allocator.Error!void {
            return self.list.append(allocator, msg);
        }

        /// Remove and return the tail message, or null if empty. Mirrors
        /// `std.ArrayListUnmanaged.pop`. The caller owns the returned message and
        /// is responsible for freeing it.
        pub fn pop(self: *Self) ?Message {
            return self.list.pop();
        }

        /// Number of messages currently held.
        pub fn len(self: *const Self) usize {
            return self.list.items.len;
        }

        /// The backing slice. Mutating an element through this slice (e.g.
        /// `store.items()[i].content = ...` or `&store.items()[i]`) is valid; the
        /// slice aliases the backing buffer until the next structural change.
        pub fn items(self: *const Self) []Message {
            return self.list.items;
        }

        /// The message at `index`, or null when out of bounds. Pure read; the
        /// returned value is a copy of the struct (its owned slices still alias
        /// the store's allocations).
        pub fn at(self: *const Self, index: usize) ?Message {
            if (index >= self.list.items.len) return null;
            return self.list.items[index];
        }

        /// Drop and `deinit` every message at or after `index`, leaving the head
        /// `[0, index)` intact. Capacity is retained. No-op when `index` is past
        /// the end. This is the structural primitive behind /clear-tail and the
        /// rewind picker's "fold from here" behavior.
        pub fn truncateFrom(self: *Self, allocator: std.mem.Allocator, index: usize) void {
            while (self.list.items.len > index) {
                if (self.list.pop()) |msg| {
                    msg.deinit(allocator);
                } else break;
            }
        }

        /// `deinit` every held message and empty the list, keeping capacity. The
        /// store stays usable afterward.
        pub fn clearAndDeinit(self: *Self, allocator: std.mem.Allocator) void {
            for (self.list.items) |msg| msg.deinit(allocator);
            self.list.clearRetainingCapacity();
        }

        /// Empty the list keeping capacity, WITHOUT freeing the messages. The
        /// caller has already taken ownership of the elements elsewhere. Mirrors
        /// `std.ArrayListUnmanaged.clearRetainingCapacity`.
        pub fn clearRetainingCapacity(self: *Self) void {
            self.list.clearRetainingCapacity();
        }

        /// Release the backing buffer. Does NOT free the individual messages —
        /// callers that own message contents must drain them first (the existing
        /// ai_chat.zig teardown loops free each message, then call this).
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }
    };
}

// --- tests -----------------------------------------------------------------

/// Minimal message stand-in: owns a heap string so we can exercise the
/// store's free-on-truncate contract without pulling in ai_chat.Message.
const TestMsg = struct {
    content: []u8,

    fn make(allocator: std.mem.Allocator, text: []const u8) TestMsg {
        return .{ .content = allocator.dupe(u8, text) catch unreachable };
    }

    fn deinit(self: TestMsg, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

const TestStore = MessageStore(TestMsg);

test "append increments len and at returns the right item" {
    const a = std.testing.allocator;
    var store: TestStore = .empty;
    defer {
        store.clearAndDeinit(a);
        store.deinit(a);
    }

    try std.testing.expectEqual(@as(usize, 0), store.len());
    try std.testing.expect(store.at(0) == null);

    try store.append(a, TestMsg.make(a, "first"));
    try store.append(a, TestMsg.make(a, "second"));

    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqualStrings("first", store.at(0).?.content);
    try std.testing.expectEqualStrings("second", store.at(1).?.content);
    try std.testing.expect(store.at(2) == null);
}

test "items() exposes the backing slice and allows mutation" {
    const a = std.testing.allocator;
    var store: TestStore = .empty;
    defer {
        store.clearAndDeinit(a);
        store.deinit(a);
    }

    try store.append(a, TestMsg.make(a, "x"));
    try std.testing.expectEqual(@as(usize, 1), store.items().len);

    // Mutating through the slice must reach the stored element.
    a.free(store.items()[0].content);
    store.items()[0].content = a.dupe(u8, "y") catch unreachable;
    try std.testing.expectEqualStrings("y", store.at(0).?.content);
}

test "pop returns and detaches the tail" {
    const a = std.testing.allocator;
    var store: TestStore = .empty;
    defer {
        store.clearAndDeinit(a);
        store.deinit(a);
    }

    try store.append(a, TestMsg.make(a, "keep"));
    try store.append(a, TestMsg.make(a, "drop"));

    const popped = store.pop().?;
    try std.testing.expectEqualStrings("drop", popped.content);
    popped.deinit(a); // caller owns it now
    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expectEqualStrings("keep", store.at(0).?.content);

    // Drain the rest, freeing each popped message (caller owns it), so the
    // empty-store branch is exercised without leaking.
    const last = store.pop().?;
    last.deinit(a);
    try std.testing.expect(store.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), store.len());
}

test "truncateFrom frees the tail and keeps the head" {
    const a = std.testing.allocator;
    var store: TestStore = .empty;
    defer {
        store.clearAndDeinit(a);
        store.deinit(a);
    }

    try store.append(a, TestMsg.make(a, "0"));
    try store.append(a, TestMsg.make(a, "1"));
    try store.append(a, TestMsg.make(a, "2"));
    try store.append(a, TestMsg.make(a, "3"));

    store.truncateFrom(a, 2);
    try std.testing.expectEqual(@as(usize, 2), store.len());
    try std.testing.expectEqualStrings("0", store.at(0).?.content);
    try std.testing.expectEqualStrings("1", store.at(1).?.content);

    // Out-of-range index is a no-op.
    store.truncateFrom(a, 99);
    try std.testing.expectEqual(@as(usize, 2), store.len());

    // Truncating from 0 empties everything (and frees it).
    store.truncateFrom(a, 0);
    try std.testing.expectEqual(@as(usize, 0), store.len());
}

test "clearAndDeinit empties and frees while keeping the store usable" {
    const a = std.testing.allocator;
    var store: TestStore = .empty;
    defer store.deinit(a);

    try store.append(a, TestMsg.make(a, "a"));
    try store.append(a, TestMsg.make(a, "b"));
    store.clearAndDeinit(a);
    try std.testing.expectEqual(@as(usize, 0), store.len());

    // Reusable afterward.
    try store.append(a, TestMsg.make(a, "c"));
    try std.testing.expectEqual(@as(usize, 1), store.len());
    store.clearAndDeinit(a);
}

test "fromList adopts an existing ArrayList" {
    const a = std.testing.allocator;
    var raw: std.ArrayListUnmanaged(TestMsg) = .empty;
    try raw.append(a, TestMsg.make(a, "adopted"));

    var store = TestStore.fromList(raw);
    defer {
        store.clearAndDeinit(a);
        store.deinit(a);
    }

    try std.testing.expectEqual(@as(usize, 1), store.len());
    try std.testing.expectEqualStrings("adopted", store.at(0).?.content);
}
