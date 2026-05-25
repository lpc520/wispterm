const std = @import("std");

pub fn requestSynchronousIoCancel(thread: std.Thread) bool {
    _ = thread;
    return false;
}

pub fn waitForExit(thread: std.Thread, timeout_ms: u32) bool {
    _ = thread;
    _ = timeout_ms;
    return false;
}
