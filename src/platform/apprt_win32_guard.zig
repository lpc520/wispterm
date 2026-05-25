//! Compile-time guard for the Windows apprt runtime. Lives under `platform/`
//! — the only place allowed to reference a platform runtime — so that shared
//! and test code never has to embed `apprt/win32.zig` to police its API
//! surface.
//!
//! `apprt/win32.zig` must not publicly expose platform APIs that `platform/*`
//! backends own, nor leak raw Win32 message/key/window constants. These are
//! source-text scans rather than imports, so they run at comptime on every
//! target without compiling the Windows-only runtime.

const std = @import("std");

comptime {
    @setEvalBranchQuota(8_000_000);
    const apprt_win32_source = @embedFile("../apprt/win32.zig");

    const public_platform_api_leaks = .{
        "pub extern \"shell32\" fn ShellExecuteW",
        "pub extern \"user32\" fn OpenClipboard",
        "pub extern \"kernel32\" fn GlobalAlloc",
        "pub extern \"comdlg32\" fn GetSaveFileNameW",
        "pub extern \"gdiplus\" fn GdiplusStartup",
        "pub extern \"kernel32\" fn CreatePipe",
        "pub extern \"kernel32\" fn CreateNamedPipeW",
        "pub extern \"kernel32\" fn CreateFileW",
        "pub extern \"kernel32\" fn CreatePseudoConsole",
        "pub extern \"kernel32\" fn CreateProcessW",
        "pub extern \"kernel32\" fn PeekNamedPipe",
        "pub extern \"kernel32\" fn CancelIoEx",
        "pub extern \"kernel32\" fn WaitForSingleObject",
        "pub extern \"kernel32\" fn GetExitCodeProcess",
        "pub const OPENFILENAME",
        "pub const GpImage",
        "pub const HPCON",
        "pub const STARTUPINFOEXW",
        "pub const EXTENDED_STARTUPINFO_PRESENT",
        "pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE",
        "pub const FILE_FLAG_OVERLAPPED",
        "pub const PIPE_ACCESS_OUTBOUND",
        "pub const GENERIC_READ",
        "pub const WAIT_OBJECT_0",
    };
    for (public_platform_api_leaks) |leak| {
        if (std.mem.indexOf(u8, apprt_win32_source, leak) != null) {
            @compileError("apprt/win32.zig must not publicly expose platform APIs owned by platform/* backends");
        }
    }

    const public_backend_detail_leaks = .{
        "pub extern \"",
        "pub const WM_",
        "pub const VK_",
        "pub const HT",
        "pub const SW_",
        "pub const SWP_",
        "pub const SIZE_",
        "pub const CFS_",
        "pub const TME_",
        "pub const KEY_PRESSED",
        "pub const OFN_",
        "pub const IDC_",
        "pub const MOD_",
        "pub const FLASHW_",
        "pub const MB_",
        "pub const SM_",
        "pub const HWND_TOP",
    };
    for (public_backend_detail_leaks) |leak| {
        if (std.mem.indexOf(u8, apprt_win32_source, leak) != null) {
            @compileError("apprt/win32.zig must keep raw Win32 message/key/window constants private to the backend");
        }
    }
}
