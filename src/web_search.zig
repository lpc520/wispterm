//! Engine-agnostic web search core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeSearch`). Only the `jina` engine exists
//! today; a new engine is a new branch in `executeSearch`. Leaf module: std only.
const std = @import("std");

pub const Engine = enum { jina };

pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    description: []const u8,
    content: ?[]const u8 = null,
};

pub const Options = struct {
    engine: Engine = .jina,
    api_key: []const u8,
    with_content: bool,
    max_results: usize = 10,
};

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try out.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => |ch| if (ch < 0x20)
            try out.writer(allocator).print("\\u{x:0>4}", .{ch})
        else
            try out.append(allocator, ch),
    };
    try out.append(allocator, '"');
}

/// Build the Jina search request body: `{"q":<json-escaped query>}`.
pub fn buildJinaRequestBody(allocator: std.mem.Allocator, query: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"q\":");
    try appendJsonString(allocator, &out, query);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

test "buildJinaRequestBody json-escapes the query" {
    const a = std.testing.allocator;
    const body = try buildJinaRequestBody(a, "say \"hi\"\nbye");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"q\":\"say \\\"hi\\\"\\nbye\"}", body);
}
