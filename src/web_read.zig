//! Engine-agnostic web reader core. Pure request-build / response-parse / format
//! helpers plus one HTTP call (`executeRead`). Backed by Jina Reader (`r.jina.ai`):
//! an http(s) URL is fetched as a page; any other target is treated as a local
//! file path and uploaded (PDF + Office, MIME-sniffed by Reader). HTTP transport
//! goes through `platform/http_client.zig` so desktop builds can use system proxies.
//! Mirrors `web_search.zig`; intentionally does NOT depend on it — the Jina key is
//! passed in via `Options.api_key` (empty = anonymous).
const std = @import("std");
const platform_http = @import("platform/http_client.zig");

const reader_url = "https://r.jina.ai/";
const upload_boundary = "----WispTermReaderBoundary7MA4YWxkTrZu0gW";
const user_truncate_cap: usize = 8000;

pub const Options = struct {
    api_key: []const u8 = "", // "" = anonymous (no Authorization header)
    max_file_bytes: usize = 25 * 1024 * 1024, // reject larger local files (OOM guard)
};

pub const ReadResult = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    url: []const u8,
    content: []const u8,
    pub fn deinit(self: *ReadResult) void {
        self.arena.deinit();
    }
};

/// True when `target` is an http(s) URL (case-insensitive scheme).
pub fn isHttpUrl(target: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(target, "http://") or
        std.ascii.startsWithIgnoreCase(target, "https://");
}

/// JSON-escape `s` into `out` (mirrors web_search.appendJsonString; duplicated to
/// keep this module independent of web_search).
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

/// Build the Reader URL-mode request body: `{"url":<json-escaped url>}`.
pub fn buildUrlRequestBody(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"url\":");
    try appendJsonString(allocator, &out, url);
    try out.append(allocator, '}');
    return out.toOwnedSlice(allocator);
}

fn jsonStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

const ParsedFields = struct { title: []const u8, url: []const u8, content: []const u8 };

/// Parse a Jina Reader JSON response (`{"code":200,"data":{title,url,content,...}}`).
/// Strings are duped into `arena`. A missing/empty `content` → error.ParseFailed.
/// Duping into `arena` here means the result may safely alias `json_bytes`, which the
/// caller frees right after this returns.
pub fn parseReaderResponse(arena: std.mem.Allocator, json_bytes: []const u8) !ParsedFields {
    var parsed = std.json.parseFromSlice(std.json.Value, arena, json_bytes, .{}) catch return error.ParseFailed;
    defer parsed.deinit();
    if (parsed.value != .object) return error.ParseFailed;
    const data_val = parsed.value.object.get("data") orelse return error.ParseFailed;
    if (data_val != .object) return error.ParseFailed;
    const obj = data_val.object;
    const content = jsonStr(obj, "content") orelse return error.ParseFailed;
    if (content.len == 0) return error.ParseFailed;
    return .{
        .title = try arena.dupe(u8, jsonStr(obj, "title") orelse ""),
        .url = try arena.dupe(u8, jsonStr(obj, "url") orelse ""),
        .content = try arena.dupe(u8, content),
    };
}

test "isHttpUrl recognizes only http(s) schemes" {
    try std.testing.expect(isHttpUrl("http://x"));
    try std.testing.expect(isHttpUrl("HTTPS://x"));
    try std.testing.expect(!isHttpUrl("ftp://x"));
    try std.testing.expect(!isHttpUrl("/tmp/report.pdf"));
    try std.testing.expect(!isHttpUrl("report.pdf"));
}

test "buildUrlRequestBody json-escapes the url" {
    const a = std.testing.allocator;
    const body = try buildUrlRequestBody(a, "https://x/?q=\"a\"&b");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"url\":\"https://x/?q=\\\"a\\\"&b\"}", body);
}

test "parseReaderResponse extracts data object fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const json =
        \\{"code":200,"status":20000,"data":{"title":"Example","url":"https://e.example/","content":"# Example\nbody"}}
    ;
    const f = try parseReaderResponse(arena.allocator(), json);
    try std.testing.expectEqualStrings("Example", f.title);
    try std.testing.expectEqualStrings("https://e.example/", f.url);
    try std.testing.expectEqualStrings("# Example\nbody", f.content);
}

test "parseReaderResponse tolerates missing title/url, rejects empty content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ok = try parseReaderResponse(arena.allocator(), "{\"data\":{\"content\":\"hi\"}}");
    try std.testing.expectEqualStrings("", ok.title);
    try std.testing.expectEqualStrings("hi", ok.content);
    try std.testing.expectError(error.ParseFailed, parseReaderResponse(arena.allocator(), "{\"data\":{\"content\":\"\"}}"));
    try std.testing.expectError(error.ParseFailed, parseReaderResponse(arena.allocator(), "{\"data\":[]}"));
}
