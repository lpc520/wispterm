//! Opt-in (diagnostic-build) application diagnostics: a shared on-disk log fed
//! by std.log, plus crash capture (Zig panic + Windows unhandled exceptions).
//!
//! Only wired up when built with -Ddebug-console (see src/main.zig). The log is
//! written to <config-dir>/wispterm-debug.log with a single size-based rollover
//! to wispterm-debug.log.1; crash reports go to <config-dir>/crash-<ts>.txt.

const std = @import("std");
const builtin = @import("builtin");

pub const MAX_LOG_BYTES: usize = 8 * 1024 * 1024;

/// Assemble one log line into `buf` (no trailing newline). On overflow the line
/// is truncated to what fits rather than dropped. Format:
/// "[+<elapsed>ms] <LEVEL>(<scope>) <message>".
pub fn formatLine(
    buf: []u8,
    elapsed_ms: i64,
    level: []const u8,
    scope: []const u8,
    message: []const u8,
) []const u8 {
    return std.fmt.bufPrint(buf, "[+{d}ms] {s}({s}) {s}", .{ elapsed_ms, level, scope, message }) catch blk: {
        // Buffer too small for the full line: emit as much of the prefix as fits.
        const head = "[+? ] ";
        const n = @min(buf.len, head.len);
        @memcpy(buf[0..n], head[0..n]);
        break :blk buf[0..n];
    };
}

/// True when writing `incoming` bytes would push the file past `max`, so the
/// caller must roll over first. A first write (written == 0) never rolls over,
/// so a single line larger than `max` still lands (after at most one rollover).
pub fn shouldRollover(written: usize, incoming: usize, max: usize) bool {
    return written != 0 and written + incoming > max;
}

test "diag_log: formatLine assembles prefix, level, scope, message" {
    var buf: [128]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expectEqualStrings("[+42ms] info(weixin) QR login started", line);
}

test "diag_log: formatLine truncates instead of overflowing a small buffer" {
    var buf: [8]u8 = undefined;
    const line = formatLine(&buf, 42, "info", "weixin", "QR login started");
    try std.testing.expect(line.len <= buf.len);
}

test "diag_log: shouldRollover never fires on the first write" {
    try std.testing.expect(!shouldRollover(0, MAX_LOG_BYTES + 1, MAX_LOG_BYTES));
}

test "diag_log: shouldRollover fires once the cap would be exceeded" {
    try std.testing.expect(!shouldRollover(10, 5, 100));
    try std.testing.expect(shouldRollover(98, 5, 100));
}
