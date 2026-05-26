//! Native macOS CoreText font backend smoke-test entry point.

const std = @import("std");
const font_backend = @import("platform/font_backend.zig");

test "CoreText backend discovers family paths and glyph fallback" {
    var discovery = try font_backend.FontDiscovery.init();
    defer discovery.deinit();

    const families = try discovery.listFontFamilies(std.testing.allocator);
    defer {
        for (families) |family| std.testing.allocator.free(family);
        std.testing.allocator.free(families);
    }
    try std.testing.expect(families.len > 0);

    var result = (try discovery.findFontFilePath(
        std.testing.allocator,
        "Menlo",
        .NORMAL,
        .NORMAL,
    )) orelse return error.ExpectedMenloFont;
    defer result.deinit();
    try std.testing.expect(result.path.len > 0);

    const font = (try discovery.findFallbackFont('A')) orelse return error.ExpectedFallbackFont;
    defer font.release();
    try std.testing.expect(font.hasCharacter('A'));

    var loaded = try font_backend.LoadedFont.init(font);
    defer loaded.deinit();
    try std.testing.expect(loaded.hasGlyph('A'));
}

test "CoreText backend honors preferred fallback families" {
    var discovery = try font_backend.FontDiscovery.init();
    defer discovery.deinit();

    const preferred = [_][]const u8{ "Menlo", "Helvetica" };
    const font = (try discovery.findPreferredFallbackFont('A', &preferred)) orelse return error.ExpectedPreferredFallbackFont;
    defer font.release();
    var path = font_backend.fontFilePathAlloc(std.testing.allocator, font) orelse return error.ExpectedPreferredFallbackPath;
    defer path.deinit();

    try std.testing.expect(path.path.len > 0);
}

test {
    _ = font_backend;
}
