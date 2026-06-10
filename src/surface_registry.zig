//! Process-wide registry of live Surface pointers.
//!
//! The agent request worker holds raw `*Surface` pointers captured at request
//! start (ToolSurface.ptr) and dereferences them for up to the tool timeout,
//! while the UI thread may free the surface at any moment (close tab / close
//! split). This registry is the liveness guard between the two threads:
//!
//!  - the UI thread `register`s a surface when it is created and
//!    `unregister`s it right before it is freed;
//!  - a worker wraps every dereference in `acquire`/`release`. `acquire`
//!    returns true with the registry lock HELD, and `unregister` takes the
//!    same lock, so a surface can never be freed while a guarded access is
//!    in flight — and a freed surface can never be acquired again.
//!
//! Accesses inside the guarded section must be short (snapshot serialization,
//! queueing PTY input); the lock is global, not per-surface.

const std = @import("std");

/// Upper bound on simultaneously live surfaces (tabs × splits). Registration
/// beyond this is dropped, which fails safe: acquire() then reports the
/// surface as gone and agent tools degrade to an error instead of a deref.
const MAX_SURFACES = 1024;

var g_mutex: std.Thread.Mutex = .{};
var g_entries: [MAX_SURFACES]?*anyopaque = @splat(null);

/// Record a live surface pointer (UI thread, surface creation).
pub fn register(ptr: *anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    var free_slot: ?*?*anyopaque = null;
    for (&g_entries) |*entry| {
        if (entry.* == ptr) return;
        if (entry.* == null and free_slot == null) free_slot = entry;
    }
    if (free_slot) |slot| slot.* = ptr;
}

/// Drop a surface pointer (UI thread, right before the surface is freed).
/// Blocks while any acquire() holder is inside the guarded section, so the
/// caller may free the surface immediately after this returns.
pub fn unregister(ptr: *anyopaque) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    for (&g_entries) |*entry| {
        if (entry.* == ptr) {
            entry.* = null;
            return;
        }
    }
}

/// If `ptr` is a live registered surface, returns true with the registry
/// lock held — the caller MUST call release() when done with the surface.
/// Returns false (lock not held) when the surface is gone.
pub fn acquire(ptr: *anyopaque) bool {
    g_mutex.lock();
    for (g_entries) |entry| {
        if (entry == ptr) return true;
    }
    g_mutex.unlock();
    return false;
}

/// Release the lock taken by a successful acquire().
pub fn release() void {
    g_mutex.unlock();
}

// ---- Tests ----

// Dummy registration targets with process-unique, stable addresses; stack
// addresses could collide across tests if a test ever leaked an entry.
var test_target_a: u8 = 0;
var test_target_b: u8 = 0;

test "registered pointer can be acquired (and re-acquired after release)" {
    register(&test_target_a);
    defer unregister(&test_target_a);

    try std.testing.expect(acquire(&test_target_a));
    release();
    try std.testing.expect(acquire(&test_target_a));
    release();
}

test "unregistered pointer cannot be acquired" {
    try std.testing.expect(!acquire(&test_target_b));
}

test "unregister makes a pointer unacquirable" {
    register(&test_target_a);
    unregister(&test_target_a);
    try std.testing.expect(!acquire(&test_target_a));
}

test "registering the same pointer twice does not duplicate the entry" {
    register(&test_target_a);
    register(&test_target_a);
    unregister(&test_target_a);
    try std.testing.expect(!acquire(&test_target_a));
}

test "unregister blocks until an in-flight guarded access releases" {
    register(&test_target_a);

    try std.testing.expect(acquire(&test_target_a));

    var unregistered = std.atomic.Value(bool).init(false);
    const Closure = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            unregister(&test_target_a);
            flag.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Closure.run, .{&unregistered});

    // While we hold the guard the unregistering thread must stay blocked.
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expect(!unregistered.load(.acquire));

    release();
    thread.join();
    try std.testing.expect(unregistered.load(.acquire));
    try std.testing.expect(!acquire(&test_target_a));
}
