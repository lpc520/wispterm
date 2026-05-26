//! Cell-grid render pipelines (bg / fg / color-emoji). Cell-specific
//! presentation, built from the gpu backend primitives + the backend GLSL.
//! Relocated from gl_init.initInstancedBuffers (A3). The vertex-attribute
//! layout matches the CellBg/CellFg memory layout exactly.
const std = @import("std");
const AppWindow = @import("../AppWindow.zig");
const Renderer = @import("Renderer.zig");
const gpu = AppWindow.gpu;
const c = gpu.c;

const Pipeline = gpu.Pipeline;
const Buffer = gpu.Buffer;

pub threadlocal var bg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var fg: Pipeline = .{ .program = 0, .vao = 0 };
pub threadlocal var color_fg: Pipeline = .{ .program = 0, .vao = 0 };

pub threadlocal var bg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var color_fg_instances: Buffer = .{ .handle = 0, .target = 0 };
pub threadlocal var quad: Buffer = .{ .handle = 0, .target = 0 };

/// Build the cell pipelines. Call once after the GL context is current.
/// On shader link failure a pipeline's `program` is 0 (draws are guarded on
/// `program != 0`); its VAO is still owned and released by `deinit()`.
pub fn init() void {
    const gl = gpu.glTable();
    const shaders = gpu.shaders;

    // Shared unit quad (triangle strip: 4 verts)
    const quad_verts = [4][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
    };
    quad = Buffer.init(c.GL_ARRAY_BUFFER);
    quad.uploadData(std.mem.sliceAsBytes(quad_verts[0..]), c.GL_STATIC_DRAW);

    // --- BG VAO ---
    var bg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &bg_vao);
    bg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(bg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    bg_instances.allocate(@sizeOf(Renderer.CellBg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const bg_stride: c.GLsizei = @sizeOf(Renderer.CellBg);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 3, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 1, c.GL_FLOAT, c.GL_FALSE, bg_stride, @ptrFromInt(5 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.BindVertexArray.?(0);

    // --- FG VAO ---
    var fg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &fg_vao);
    fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(fg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const fg_stride: c.GLsizei = @sizeOf(Renderer.CellFg);
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);
    gl.BindVertexArray.?(0);

    // --- Color FG VAO (same layout as FG) ---
    var color_fg_vao: c.GLuint = 0;
    gl.GenVertexArrays.?(1, &color_fg_vao);
    color_fg_instances = Buffer.init(c.GL_ARRAY_BUFFER);
    gl.BindVertexArray.?(color_fg_vao);
    quad.bind();
    gl.EnableVertexAttribArray.?(0);
    gl.VertexAttribPointer.?(0, 2, c.GL_FLOAT, c.GL_FALSE, 2 * @sizeOf(f32), null);
    color_fg_instances.allocate(@sizeOf(Renderer.CellFg) * Renderer.MAX_CELLS, c.GL_STREAM_DRAW);
    const color_fg_stride: c.GLsizei = @sizeOf(Renderer.CellFg); // same CellFg layout as fg
    gl.EnableVertexAttribArray.?(1);
    gl.VertexAttribPointer.?(1, 2, c.GL_FLOAT, c.GL_FALSE, color_fg_stride, @ptrFromInt(0));
    gl.VertexAttribDivisor.?(1, 1);
    gl.EnableVertexAttribArray.?(2);
    gl.VertexAttribPointer.?(2, 4, c.GL_FLOAT, c.GL_FALSE, color_fg_stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(2, 1);
    gl.EnableVertexAttribArray.?(3);
    gl.VertexAttribPointer.?(3, 4, c.GL_FLOAT, c.GL_FALSE, color_fg_stride, @ptrFromInt(6 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(3, 1);
    gl.EnableVertexAttribArray.?(4);
    gl.VertexAttribPointer.?(4, 3, c.GL_FLOAT, c.GL_FALSE, color_fg_stride, @ptrFromInt(10 * @sizeOf(f32)));
    gl.VertexAttribDivisor.?(4, 1);
    gl.BindVertexArray.?(0);

    bg = Pipeline.init(shaders.bg_vertex_source, shaders.bg_fragment_source, bg_vao);
    fg = Pipeline.init(shaders.fg_vertex_source, shaders.fg_fragment_source, fg_vao);
    color_fg = Pipeline.init(shaders.fg_vertex_source, shaders.color_fg_fragment_source, color_fg_vao);
    if (bg.program == 0) std.debug.print("BG instanced shader failed\n", .{});
    if (fg.program == 0) std.debug.print("FG instanced shader failed\n", .{});
    if (color_fg.program == 0) std.debug.print("Color FG instanced shader failed\n", .{});
}

pub fn deinit() void {
    bg.deinit();
    fg.deinit();
    color_fg.deinit();
    bg_instances.deinit();
    fg_instances.deinit();
    color_fg_instances.deinit();
    quad.deinit();
}
