//! Metal backend render-state + frame seam. Mirrors
//! `gpu/opengl/render_state.zig`; the state recorded here feeds the real Metal
//! render command encoder as D1 grows.

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };
pub const Size = struct { w: i32, h: i32 };
pub const BlendMode = enum { alpha, premultiplied };
pub const ScissorState = struct { enabled: bool, box: Rect };

threadlocal var frame_active = false;
threadlocal var blend_enabled = false;
threadlocal var blend_mode: BlendMode = .alpha;
threadlocal var viewport: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
threadlocal var scissor: ScissorState = .{
    .enabled = false,
    .box = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};
threadlocal var clear_color: [4]f32 = .{ 0, 0, 0, 0 };

/// Frame seam — the Metal backend owns the command buffer / drawable here.
pub fn beginFrame() void {
    frame_active = true;
}
pub fn endFrame() void {
    frame_active = false;
}

pub fn setBlendEnabled(enabled: bool) void {
    blend_enabled = enabled;
}

pub fn setBlendMode(mode: BlendMode) void {
    blend_mode = mode;
}

pub fn clear(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{ r, g, b, a };
}

pub fn setViewport(x: i32, y: i32, w: i32, h: i32) void {
    viewport = .{ .x = x, .y = y, .w = w, .h = h };
}

pub fn viewportSize() Size {
    return .{ .w = viewport.w, .h = viewport.h };
}

pub fn setScissor(rect: Rect) void {
    scissor = .{ .enabled = true, .box = rect };
}

pub fn disableScissor() void {
    scissor.enabled = false;
}

pub fn scissorState() ScissorState {
    return scissor;
}

pub fn restoreScissor(s: ScissorState) void {
    scissor = s;
}

pub fn isFrameActive() bool {
    return frame_active;
}

pub fn isBlendEnabled() bool {
    return blend_enabled;
}

pub fn currentBlendMode() BlendMode {
    return blend_mode;
}

pub fn currentClearColor() [4]f32 {
    return clear_color;
}
