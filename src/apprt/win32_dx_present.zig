//! DXGI flip-model presenter for the Win32 OpenGL host.
//!
//! Replaces the legacy GDI `SwapBuffers` present (BLT into the DWM
//! redirection surface) with a D3D11 flip-model swapchain shared with GL via
//! `WGL_NV_DX_interop2`. The legacy path is the source of the cross-DPI /
//! resize artifacts in issues #46/#47/#88: with the frame extended into the
//! whole client area, DWM composites the redirection surface using the GL
//! backbuffer's alpha and stale-surface contents on some drivers (Intel Arc,
//! AMD iGPU). A flip-model swapchain with `DXGI_ALPHA_MODE_IGNORE` is
//! composited opaquely and never goes through the redirection surface.
//!
//! Frame flow (per present):
//!   renderer draws to GL FBO 0 exactly as before →
//!   `presentFrame` blits FBO 0 into an interop renderbuffer (Y-flipped:
//!   GL rows are bottom-up, D3D rows top-down) backed by a shared D3D11
//!   texture → `CopyResource` into swapchain buffer 0 → `Present`.
//!
//! Every failure latches `PresentPolicy.fail()` and the caller reverts to
//! GDI `SwapBuffers` for the rest of the session, so machines without
//! `WGL_NV_DX_interop2` (or with a broken driver) keep the old behavior.

const std = @import("std");
const windows = std.os.windows;
const core = @import("../platform/dxgi_core.zig");
const render_diagnostics = @import("../render_diagnostics.zig");

const HWND = windows.HWND;
const HANDLE = windows.HANDLE;
const HMODULE = windows.HMODULE;
const BOOL = windows.BOOL;
const HRESULT = windows.HRESULT;

extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// ============================================================================
// GL constants + function pointers (loaded per presenter, context current)
// ============================================================================

const GL_FRAMEBUFFER: u32 = 0x8D40;
const GL_READ_FRAMEBUFFER: u32 = 0x8CA8;
const GL_DRAW_FRAMEBUFFER: u32 = 0x8CA9;
const GL_RENDERBUFFER: u32 = 0x8D41;
const GL_COLOR_ATTACHMENT0: u32 = 0x8CE0;
const GL_COLOR_BUFFER_BIT: u32 = 0x00004000;
const GL_NEAREST: u32 = 0x2600;
const GL_FRAMEBUFFER_COMPLETE: u32 = 0x8CD5;
const GL_SCISSOR_TEST: u32 = 0x0C11;

const WGL_ACCESS_WRITE_DISCARD_NV: u32 = 0x0002;

const DXGI_MWA_NO_ALT_ENTER: u32 = 0x2;

const GlFns = struct {
    gen_framebuffers: *const fn (i32, [*]u32) callconv(.winapi) void,
    delete_framebuffers: *const fn (i32, [*]const u32) callconv(.winapi) void,
    bind_framebuffer: *const fn (u32, u32) callconv(.winapi) void,
    framebuffer_renderbuffer: *const fn (u32, u32, u32, u32) callconv(.winapi) void,
    gen_renderbuffers: *const fn (i32, [*]u32) callconv(.winapi) void,
    delete_renderbuffers: *const fn (i32, [*]const u32) callconv(.winapi) void,
    blit_framebuffer: *const fn (i32, i32, i32, i32, i32, i32, i32, i32, u32, u32) callconv(.winapi) void,
    check_framebuffer_status: *const fn (u32) callconv(.winapi) u32,
    // GL 1.0 entry point: comes from opengl32.dll directly, not wglGetProcAddress.
    disable: *const fn (u32) callconv(.winapi) void,

    fn load() error{GlFunctionsMissing}!GlFns {
        const opengl32 = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll")) orelse
            return error.GlFunctionsMissing;
        return .{
            .gen_framebuffers = @ptrCast(wglGetProcAddress("glGenFramebuffers") orelse return error.GlFunctionsMissing),
            .delete_framebuffers = @ptrCast(wglGetProcAddress("glDeleteFramebuffers") orelse return error.GlFunctionsMissing),
            .bind_framebuffer = @ptrCast(wglGetProcAddress("glBindFramebuffer") orelse return error.GlFunctionsMissing),
            .framebuffer_renderbuffer = @ptrCast(wglGetProcAddress("glFramebufferRenderbuffer") orelse return error.GlFunctionsMissing),
            .gen_renderbuffers = @ptrCast(wglGetProcAddress("glGenRenderbuffers") orelse return error.GlFunctionsMissing),
            .delete_renderbuffers = @ptrCast(wglGetProcAddress("glDeleteRenderbuffers") orelse return error.GlFunctionsMissing),
            .blit_framebuffer = @ptrCast(wglGetProcAddress("glBlitFramebuffer") orelse return error.GlFunctionsMissing),
            .check_framebuffer_status = @ptrCast(wglGetProcAddress("glCheckFramebufferStatus") orelse return error.GlFunctionsMissing),
            .disable = @ptrCast(GetProcAddress(opengl32, "glDisable") orelse return error.GlFunctionsMissing),
        };
    }
};

const InteropFns = struct {
    open_device: *const fn (*anyopaque) callconv(.winapi) ?HANDLE,
    close_device: *const fn (HANDLE) callconv(.winapi) BOOL,
    set_resource_share_handle: *const fn (*anyopaque, HANDLE) callconv(.winapi) BOOL,
    register_object: *const fn (HANDLE, *anyopaque, u32, u32, u32) callconv(.winapi) ?HANDLE,
    unregister_object: *const fn (HANDLE, HANDLE) callconv(.winapi) BOOL,
    lock_objects: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) BOOL,
    unlock_objects: *const fn (HANDLE, i32, [*]HANDLE) callconv(.winapi) BOOL,

    fn load() error{InteropUnavailable}!InteropFns {
        return .{
            .open_device = @ptrCast(wglGetProcAddress("wglDXOpenDeviceNV") orelse return error.InteropUnavailable),
            .close_device = @ptrCast(wglGetProcAddress("wglDXCloseDeviceNV") orelse return error.InteropUnavailable),
            .set_resource_share_handle = @ptrCast(wglGetProcAddress("wglDXSetResourceShareHandleNV") orelse return error.InteropUnavailable),
            .register_object = @ptrCast(wglGetProcAddress("wglDXRegisterObjectNV") orelse return error.InteropUnavailable),
            .unregister_object = @ptrCast(wglGetProcAddress("wglDXUnregisterObjectNV") orelse return error.InteropUnavailable),
            .lock_objects = @ptrCast(wglGetProcAddress("wglDXLockObjectsNV") orelse return error.InteropUnavailable),
            .unlock_objects = @ptrCast(wglGetProcAddress("wglDXUnlockObjectsNV") orelse return error.InteropUnavailable),
        };
    }
};

// ============================================================================
// COM dispatch helpers (slot indices from dxgi_core)
// ============================================================================

fn vtable(obj: *anyopaque) [*]const *const anyopaque {
    const pp: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return pp.*;
}

fn comCall(obj: *anyopaque, comptime slot_index: usize, comptime Fn: type) Fn {
    return @ptrCast(vtable(obj)[slot_index]);
}

fn comRelease(obj: *anyopaque) void {
    const f = comCall(obj, core.slot.Release, *const fn (*anyopaque) callconv(.winapi) u32);
    _ = f(obj);
}

fn comQueryInterface(obj: *anyopaque, iid: *const core.Guid) ?*anyopaque {
    const f = comCall(obj, core.slot.QueryInterface, *const fn (*anyopaque, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
    var out: ?*anyopaque = null;
    if (f(obj, iid, &out) < 0) return null;
    return out;
}

const D3D11CreateDeviceFn = *const fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?HMODULE,
    flags: u32,
    feature_levels: ?[*]const u32,
    num_feature_levels: u32,
    sdk_version: u32,
    device: *?*anyopaque,
    feature_level: ?*u32,
    immediate_context: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub const InitError = error{
    D3D11Unavailable,
    DeviceCreateFailed,
    FactoryUnavailable,
    SwapchainCreateFailed,
    InteropUnavailable,
    InteropOpenFailed,
    GlFunctionsMissing,
    TextureCreateFailed,
    ShareHandleFailed,
    RegisterFailed,
    BackbufferUnavailable,
    FramebufferIncomplete,
    LockFailed,
};

const PresentError = error{
    LockFailed,
    PresentFailed,
};

// ============================================================================
// Presenter
// ============================================================================

pub const Presenter = struct {
    gl: GlFns,
    interop: InteropFns,

    device: *anyopaque, // ID3D11Device
    context: *anyopaque, // ID3D11DeviceContext (immediate)
    swapchain: *anyopaque, // IDXGISwapChain1
    interop_device: HANDLE,

    // Sized resources, rebuilt on every swapchain resize.
    backbuffer: ?*anyopaque = null, // ID3D11Texture2D (buffer 0)
    shared_tex: ?*anyopaque = null, // ID3D11Texture2D (interop target)
    interop_object: ?HANDLE = null,
    gl_fbo: u32 = 0,
    gl_rbo: u32 = 0,

    policy: core.PresentPolicy,

    /// Requires the window's GL context to be current (interop + GL function
    /// loading both depend on it).
    pub fn init(hwnd: HWND, width: i32, height: i32) InitError!Presenter {
        if (width <= 0 or height <= 0) return error.SwapchainCreateFailed;

        const gl = try GlFns.load();
        const interop = try InteropFns.load();

        const d3d11 = LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("d3d11.dll")) orelse
            return error.D3D11Unavailable;
        const create_device: D3D11CreateDeviceFn = @ptrCast(GetProcAddress(d3d11, "D3D11CreateDevice") orelse
            return error.D3D11Unavailable);

        var device: ?*anyopaque = null;
        var context: ?*anyopaque = null;
        if (create_device(
            null,
            core.D3D_DRIVER_TYPE_HARDWARE,
            null,
            core.D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            null,
            0,
            core.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        ) < 0 or device == null or context == null) return error.DeviceCreateFailed;
        errdefer {
            comRelease(context.?);
            comRelease(device.?);
        }

        const swapchain = try createSwapchain(device.?, hwnd, width, height);
        errdefer comRelease(swapchain);

        const interop_device = interop.open_device(device.?) orelse return error.InteropOpenFailed;
        errdefer _ = interop.close_device(interop_device);

        var self = Presenter{
            .gl = gl,
            .interop = interop,
            .device = device.?,
            .context = context.?,
            .swapchain = swapchain,
            .interop_device = interop_device,
            .policy = core.PresentPolicy.init(width, height),
        };
        try self.createSizedResources(width, height);
        return self;
    }

    fn createSwapchain(device: *anyopaque, hwnd: HWND, width: i32, height: i32) InitError!*anyopaque {
        const dxgi_device = comQueryInterface(device, &core.IID_IDXGIDevice) orelse
            return error.FactoryUnavailable;
        defer comRelease(dxgi_device);

        const get_adapter = comCall(dxgi_device, core.slot.DXGIDevice_GetAdapter, *const fn (*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var adapter: ?*anyopaque = null;
        if (get_adapter(dxgi_device, &adapter) < 0 or adapter == null) return error.FactoryUnavailable;
        defer comRelease(adapter.?);

        const get_parent = comCall(adapter.?, core.slot.DXGIObject_GetParent, *const fn (*anyopaque, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
        var factory: ?*anyopaque = null;
        if (get_parent(adapter.?, &core.IID_IDXGIFactory2, &factory) < 0 or factory == null)
            return error.FactoryUnavailable;
        defer comRelease(factory.?);

        const desc = core.DXGI_SWAP_CHAIN_DESC1{
            .width = @intCast(width),
            .height = @intCast(height),
            .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
            .stereo = 0,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .buffer_usage = core.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .buffer_count = 2,
            .scaling = core.DXGI_SCALING_NONE,
            .swap_effect = core.DXGI_SWAP_EFFECT_FLIP_DISCARD,
            .alpha_mode = core.DXGI_ALPHA_MODE_IGNORE,
            .flags = 0,
        };
        const create_for_hwnd = comCall(factory.?, core.slot.DXGIFactory2_CreateSwapChainForHwnd, *const fn (
            *anyopaque,
            *anyopaque,
            HWND,
            *const core.DXGI_SWAP_CHAIN_DESC1,
            ?*const anyopaque,
            ?*anyopaque,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT);
        var swapchain: ?*anyopaque = null;
        if (create_for_hwnd(factory.?, device, hwnd, &desc, null, null, &swapchain) < 0 or swapchain == null)
            return error.SwapchainCreateFailed;

        // DXGI grabs Alt+Enter for exclusive fullscreen by default; the app
        // has its own borderless-fullscreen handling.
        const make_assoc = comCall(factory.?, core.slot.DXGIFactory_MakeWindowAssociation, *const fn (*anyopaque, HWND, u32) callconv(.winapi) HRESULT);
        _ = make_assoc(factory.?, hwnd, DXGI_MWA_NO_ALT_ENTER);

        return swapchain.?;
    }

    /// Create the shared texture + interop registration + GL FBO for the
    /// current swapchain size, and cache swapchain buffer 0.
    fn createSizedResources(self: *Presenter, width: i32, height: i32) InitError!void {
        const desc = core.D3D11_TEXTURE2D_DESC{
            .width = @intCast(width),
            .height = @intCast(height),
            .mip_levels = 1,
            .array_size = 1,
            .format = core.DXGI_FORMAT_B8G8R8A8_UNORM,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .usage = core.D3D11_USAGE_DEFAULT,
            .bind_flags = core.D3D11_BIND_RENDER_TARGET,
            .cpu_access_flags = 0,
            .misc_flags = core.D3D11_RESOURCE_MISC_SHARED,
        };
        const create_tex = comCall(self.device, core.slot.D3D11Device_CreateTexture2D, *const fn (*anyopaque, *const core.D3D11_TEXTURE2D_DESC, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT);
        var tex: ?*anyopaque = null;
        if (create_tex(self.device, &desc, null, &tex) < 0 or tex == null) return error.TextureCreateFailed;
        errdefer comRelease(tex.?);

        // WGL_NV_DX_interop2 requires the share handle to be communicated
        // before registering a DX10/11 resource.
        const dxgi_resource = comQueryInterface(tex.?, &core.IID_IDXGIResource) orelse
            return error.ShareHandleFailed;
        defer comRelease(dxgi_resource);
        const get_shared = comCall(dxgi_resource, core.slot.DXGIResource_GetSharedHandle, *const fn (*anyopaque, *?HANDLE) callconv(.winapi) HRESULT);
        var share_handle: ?HANDLE = null;
        if (get_shared(dxgi_resource, &share_handle) < 0 or share_handle == null)
            return error.ShareHandleFailed;
        if (self.interop.set_resource_share_handle(tex.?, share_handle.?) == 0)
            return error.ShareHandleFailed;

        var rbo: u32 = 0;
        self.gl.gen_renderbuffers(1, @ptrCast(&rbo));
        errdefer self.gl.delete_renderbuffers(1, @ptrCast(&rbo));

        const interop_object = self.interop.register_object(
            self.interop_device,
            tex.?,
            rbo,
            GL_RENDERBUFFER,
            WGL_ACCESS_WRITE_DISCARD_NV,
        ) orelse return error.RegisterFailed;
        errdefer _ = self.interop.unregister_object(self.interop_device, interop_object);

        var fbo: u32 = 0;
        self.gl.gen_framebuffers(1, @ptrCast(&fbo));
        errdefer self.gl.delete_framebuffers(1, @ptrCast(&fbo));

        // Attachment + completeness check require the interop object locked.
        var lock_handle = [1]HANDLE{interop_object};
        if (self.interop.lock_objects(self.interop_device, 1, &lock_handle) == 0)
            return error.LockFailed;
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, fbo);
        self.gl.framebuffer_renderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo);
        const status = self.gl.check_framebuffer_status(GL_FRAMEBUFFER);
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, 0);
        _ = self.interop.unlock_objects(self.interop_device, 1, &lock_handle);
        if (status != GL_FRAMEBUFFER_COMPLETE) return error.FramebufferIncomplete;

        const get_buffer = comCall(self.swapchain, core.slot.DXGISwapChain_GetBuffer, *const fn (*anyopaque, u32, *const core.Guid, *?*anyopaque) callconv(.winapi) HRESULT);
        var backbuffer: ?*anyopaque = null;
        if (get_buffer(self.swapchain, 0, &core.IID_ID3D11Texture2D, &backbuffer) < 0 or backbuffer == null)
            return error.BackbufferUnavailable;

        self.shared_tex = tex;
        self.interop_object = interop_object;
        self.gl_fbo = fbo;
        self.gl_rbo = rbo;
        self.backbuffer = backbuffer;
    }

    fn destroySizedResources(self: *Presenter) void {
        if (self.backbuffer) |b| {
            comRelease(b);
            self.backbuffer = null;
        }
        if (self.interop_object) |obj| {
            _ = self.interop.unregister_object(self.interop_device, obj);
            self.interop_object = null;
        }
        if (self.gl_fbo != 0) {
            self.gl.delete_framebuffers(1, @ptrCast(&self.gl_fbo));
            self.gl_fbo = 0;
        }
        if (self.gl_rbo != 0) {
            self.gl.delete_renderbuffers(1, @ptrCast(&self.gl_rbo));
            self.gl_rbo = 0;
        }
        if (self.shared_tex) |t| {
            comRelease(t);
            self.shared_tex = null;
        }
    }

    fn resize(self: *Presenter, width: i32, height: i32) InitError!void {
        // ResizeBuffers fails while buffer references are outstanding.
        self.destroySizedResources();
        const resize_buffers = comCall(self.swapchain, core.slot.DXGISwapChain_ResizeBuffers, *const fn (*anyopaque, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT);
        if (resize_buffers(self.swapchain, 0, @intCast(width), @intCast(height), 0, 0) < 0)
            return error.SwapchainCreateFailed;
        try self.createSizedResources(width, height);
        self.policy.noteResized(width, height);
        render_diagnostics.log("dx-present resized swapchain to {}x{}", .{ width, height });
    }

    /// Blit the rendered frame (GL FBO 0) into the swapchain and present.
    /// Returns false once the presenter has failed; the caller must revert to
    /// GDI SwapBuffers for the rest of the session.
    pub fn presentFrame(self: *Presenter, width: i32, height: i32, interval: i32) bool {
        switch (self.policy.frameAction(width, height)) {
            .fallback => return false,
            .skip => return true,
            .resize_then_present => self.resize(width, height) catch |err| {
                self.policy.fail();
                render_diagnostics.log("dx-present resize failed: {s}", .{@errorName(err)});
                return false;
            },
            .present => {},
        }
        self.blitAndPresent(width, height, interval) catch |err| {
            self.policy.fail();
            render_diagnostics.log("dx-present present failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn blitAndPresent(self: *Presenter, width: i32, height: i32, interval: i32) PresentError!void {
        var lock_handle = [1]HANDLE{self.interop_object.?};
        if (self.interop.lock_objects(self.interop_device, 1, &lock_handle) == 0)
            return error.LockFailed;

        // Scissor clips glBlitFramebuffer; the frame's present prep disables
        // it, but the presenter must not depend on renderer state.
        self.gl.disable(GL_SCISSOR_TEST);
        self.gl.bind_framebuffer(GL_READ_FRAMEBUFFER, 0);
        self.gl.bind_framebuffer(GL_DRAW_FRAMEBUFFER, self.gl_fbo);
        // Y-flip: GL FBO 0 rows are bottom-up, the D3D texture is top-down.
        self.gl.blit_framebuffer(0, 0, width, height, 0, height, width, 0, GL_COLOR_BUFFER_BIT, GL_NEAREST);
        // Leave FBO 0 bound so the renderer's next frame is unaffected.
        self.gl.bind_framebuffer(GL_FRAMEBUFFER, 0);

        _ = self.interop.unlock_objects(self.interop_device, 1, &lock_handle);

        const copy_resource = comCall(self.context, core.slot.D3D11DeviceContext_CopyResource, *const fn (*anyopaque, *anyopaque, *anyopaque) callconv(.winapi) void);
        copy_resource(self.context, self.backbuffer.?, self.shared_tex.?);

        const present = comCall(self.swapchain, core.slot.DXGISwapChain_Present, *const fn (*anyopaque, u32, u32) callconv(.winapi) HRESULT);
        const interval_u: u32 = if (interval > 0) 1 else 0;
        if (present(self.swapchain, interval_u, 0) < 0) return error.PresentFailed;
    }

    /// Requires the GL context to still be current (interop teardown).
    pub fn deinit(self: *Presenter) void {
        self.destroySizedResources();
        _ = self.interop.close_device(self.interop_device);
        comRelease(self.swapchain);
        comRelease(self.context);
        comRelease(self.device);
    }
};
