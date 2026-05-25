const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn CancelSynchronousIo(hThread: windows.HANDLE) callconv(.winapi) windows.BOOL;

/// Best-effort cancellation for blocking synchronous Win32 I/O issued by
/// `thread`. This is intentionally advisory; callers still need to wait or
/// detach according to their shutdown policy.
pub fn requestSynchronousIoCancel(thread: std.Thread) bool {
    return CancelSynchronousIo(thread.getHandle()) != 0;
}

pub fn waitForExit(thread: std.Thread, timeout_ms: u32) bool {
    windows.WaitForSingleObject(thread.getHandle(), timeout_ms) catch |err| switch (err) {
        error.WaitTimeOut => return false,
        else => return false,
    };
    return true;
}
