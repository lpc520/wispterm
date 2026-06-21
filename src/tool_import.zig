const std = @import("std");
const builtin = @import("builtin");
const platform_process = @import("platform/process.zig");
const tool_registry = @import("tool_registry.zig");

pub const PROBE_TIMEOUT_MS: u32 = 3000;
pub const PROBE_OUTPUT_LIMIT: u32 = 64 * 1024;

pub const DocSource = enum { skill_flag, sibling_skill, generated_from_help, ai_draft };

pub const ResolveDocsInput = struct {
    tool_name: []const u8,
    help_output: []const u8,
    skill_output: []const u8,
    sibling_skill: ?[]const u8,
    ai_draft: ?[]const u8,
};

pub const ResolvedDocs = struct {
    source: DocSource,
    skill_md: []u8,
};

pub const ProbeOutput = struct {
    help: []u8,
    skill: []u8,

    pub fn deinit(self: *ProbeOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.help);
        allocator.free(self.skill);
        self.* = undefined;
    }
};

pub fn resolveDocs(allocator: std.mem.Allocator, input: ResolveDocsInput) !ResolvedDocs {
    const skill = trimAscii(input.skill_output);
    if (skill.len != 0) {
        return .{ .source = .skill_flag, .skill_md = try allocator.dupe(u8, skill) };
    }

    if (input.sibling_skill) |sibling_raw| {
        const sibling = trimAscii(sibling_raw);
        if (sibling.len != 0) {
            return .{ .source = .sibling_skill, .skill_md = try allocator.dupe(u8, sibling) };
        }
    }

    const help = trimAscii(input.help_output);
    if (help.len != 0) {
        const description = firstUsefulLine(help, 180) orelse input.tool_name;
        return .{
            .source = .generated_from_help,
            .skill_md = try tool_registry.generateSkillMdFromHelp(allocator, .{
                .name = input.tool_name,
                .description = description,
                .help = help,
            }),
        };
    }

    if (input.ai_draft) |draft_raw| {
        const draft = trimAscii(draft_raw);
        if (draft.len != 0) {
            return .{
                .source = .ai_draft,
                .skill_md = try tool_registry.generateSkillMdFromAiDraft(
                    allocator,
                    input.tool_name,
                    "No --help, --skill, or sibling SKILL.md was available.",
                    draft,
                ),
            };
        }
    }

    return error.MissingToolDocumentation;
}

pub fn probeBinary(allocator: std.mem.Allocator, binary_path: []const u8) !ProbeOutput {
    const help = try runArgvProbe(allocator, &.{ binary_path, "--help" });
    errdefer allocator.free(help);
    const skill = try runArgvProbe(allocator, &.{ binary_path, "--skill" });
    return .{ .help = help, .skill = skill };
}

pub fn readSiblingSkillMd(allocator: std.mem.Allocator, binary_path: []const u8) ?[]u8 {
    const parent = std.fs.path.dirname(binary_path) orelse ".";
    const skill_path = std.fs.path.join(allocator, &.{ parent, "SKILL.md" }) catch return null;
    defer allocator.free(skill_path);
    var file = openFileAny(skill_path) catch return null;
    defer file.close();
    return file.readToEndAlloc(allocator, tool_registry.MAX_SKILL_MD_BYTES) catch null;
}

pub fn sha256FileHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try openFileAny(path);
    defer file.close();
    const hex = try allocator.alloc(u8, 64);
    errdefer allocator.free(hex);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const stack_hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(hex, &stack_hex);
    return hex;
}

/// Install a binary tool package and return the installed directory path as an
/// owned string. The caller owns the returned path and must free it.
pub fn installToolPackage(
    allocator: std.mem.Allocator,
    tools_root: []const u8,
    source_binary_path: []const u8,
    function_name: []const u8,
    skill_md: []const u8,
    enabled: bool,
) ![]u8 {
    try validatePackageName(function_name);
    const basename = std.fs.path.basename(source_binary_path);
    try validatePackageName(basename);

    try ensureDirAbsolute(tools_root);

    const target = try std.fs.path.join(allocator, &.{ tools_root, function_name });
    errdefer allocator.free(target);
    if (pathExists(target)) return error.ToolAlreadyExists;

    const staging_name = try std.fmt.allocPrint(allocator, ".staging-{s}", .{function_name});
    defer allocator.free(staging_name);
    const staging = try std.fs.path.join(allocator, &.{ tools_root, staging_name });
    defer allocator.free(staging);
    std.fs.deleteTreeAbsolute(staging) catch {};
    errdefer std.fs.deleteTreeAbsolute(staging) catch {};

    const bin_dir = try std.fs.path.join(allocator, &.{ staging, "bin" });
    defer allocator.free(bin_dir);
    try ensureDirAbsolute(bin_dir);

    const dest_binary = try std.fs.path.join(allocator, &.{ bin_dir, basename });
    defer allocator.free(dest_binary);
    try copyFilePreserveMode(source_binary_path, dest_binary);

    const skill_path = try std.fs.path.join(allocator, &.{ staging, "SKILL.md" });
    defer allocator.free(skill_path);
    try writeFileAbsolute(skill_path, skill_md);

    const executable_rel = try std.fmt.allocPrint(allocator, "bin/{s}", .{basename});
    defer allocator.free(executable_rel);
    const sha256 = try sha256FileHex(allocator, source_binary_path);
    defer allocator.free(sha256);
    const description = manifestDescription(skill_md);
    const manifest_json = try tool_registry.manifestToJson(allocator, .{
        .id = function_name,
        .function_name = function_name,
        .enabled = enabled,
        .executable = executable_rel,
        .source_path = source_binary_path,
        .sha256 = sha256,
        .imported_at_ms = std.time.milliTimestamp(),
        .description = description,
    });
    defer allocator.free(manifest_json);

    const manifest_path = try std.fs.path.join(allocator, &.{ staging, "manifest.json" });
    defer allocator.free(manifest_path);
    try writeFileAbsolute(manifest_path, manifest_json);

    std.fs.renameAbsolute(staging, target) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ToolAlreadyExists,
        else => return err,
    };
    return target;
}

const CaptureOutput = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    max_bytes: usize,
    data: []u8 = &.{},
    failed: bool = false,

    fn deinit(self: *CaptureOutput) void {
        self.allocator.free(self.data);
        self.data = &.{};
    }
};

fn runArgvProbe(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.create_no_window = true;
    child.spawn() catch return allocator.dupe(u8, "");

    var stdout_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stdout.?,
        .max_bytes = PROBE_OUTPUT_LIMIT,
    };
    errdefer stdout_capture.deinit();
    var stderr_capture = CaptureOutput{
        .allocator = allocator,
        .file = child.stderr.?,
        .max_bytes = PROBE_OUTPUT_LIMIT,
    };
    errdefer stderr_capture.deinit();

    const stdout_thread = std.Thread.spawn(.{}, captureOutputThread, .{&stdout_capture}) catch |err| {
        _ = child.kill() catch {};
        return err;
    };
    const stderr_thread = std.Thread.spawn(.{}, captureOutputThread, .{&stderr_capture}) catch |err| {
        _ = child.kill() catch {};
        stdout_thread.join();
        return err;
    };

    const deadline = std.time.milliTimestamp() + PROBE_TIMEOUT_MS;
    var timed_out = false;
    var exit_code: i32 = -1;
    while (true) {
        switch (platform_process.childExited(child.id, 25)) {
            .running => {},
            .exited => |code| {
                if (builtin.os.tag != .windows) child.term = .{ .Exited = @intCast(code) };
                exit_code = @intCast(code);
                break;
            },
            .gone => {
                if (builtin.os.tag != .windows) child.term = .{ .Unknown = 0 };
                break;
            },
        }
        if (std.time.milliTimestamp() >= deadline) {
            timed_out = true;
            _ = child.kill() catch {};
            break;
        }
    }

    stdout_thread.join();
    stderr_thread.join();
    if (stdout_capture.failed or stderr_capture.failed) return error.OutOfMemory;

    if (!timed_out) {
        const term = try child.wait();
        exit_code = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => |code| @intCast(code),
        };
    }

    if (timed_out or exit_code != 0) {
        stdout_capture.deinit();
        stderr_capture.deinit();
        return allocator.dupe(u8, "");
    }

    if (stdout_capture.data.len != 0 or stderr_capture.data.len == 0) {
        const out = stdout_capture.data;
        stdout_capture.data = &.{};
        stderr_capture.deinit();
        return out;
    }
    const out = stderr_capture.data;
    stderr_capture.data = &.{};
    stdout_capture.deinit();
    return out;
}

fn captureOutputThread(capture: *CaptureOutput) void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer if (capture.failed) out.deinit(capture.allocator);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = capture.file.read(&buf) catch break;
        if (n == 0) break;
        if (out.items.len >= capture.max_bytes) continue;
        const remaining = capture.max_bytes - out.items.len;
        const take = @min(remaining, n);
        out.appendSlice(capture.allocator, buf[0..take]) catch {
            capture.failed = true;
            return;
        };
    }
    capture.data = out.toOwnedSlice(capture.allocator) catch {
        capture.failed = true;
        return;
    };
}

fn trimAscii(bytes: []const u8) []const u8 {
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn firstUsefulLine(bytes: []const u8, max_bytes: usize) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line_raw| {
        const line = trimAscii(line_raw);
        if (line.len == 0) continue;
        return line[0..@min(line.len, max_bytes)];
    }
    return null;
}

fn manifestDescription(skill_md: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, skill_md, '\n');
    while (lines.next()) |line_raw| {
        const line = trimAscii(line_raw);
        if (std.mem.startsWith(u8, line, "description:")) {
            const value = trimAscii(line["description:".len..]);
            if (value.len != 0) return value[0..@min(value.len, tool_registry.MAX_TOOL_DESCRIPTION_BYTES)];
        }
    }
    if (firstUsefulLine(skill_md, tool_registry.MAX_TOOL_DESCRIPTION_BYTES)) |line| return line;
    return "Local executable tool";
}

fn validatePackageName(name: []const u8) !void {
    if (name.len == 0) return error.UnsafeToolPath;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsafeToolPath;
    if (name[0] == '/' or name[0] == '\\') return error.UnsafeToolPath;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return error.UnsafeToolPath;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.UnsafeToolPath;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.UnsafeToolPath;
}

fn pathExists(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn ensureDirAbsolute(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            const parent = std.fs.path.dirname(path) orelse return err;
            try ensureDirAbsolute(parent);
            std.fs.makeDirAbsolute(path) catch |err2| switch (err2) {
                error.PathAlreadyExists => {},
                else => return err2,
            };
        },
        else => return err,
    };
}

fn openFileAny(path: []const u8) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) return std.fs.openFileAbsolute(path, .{});
    return std.fs.cwd().openFile(path, .{});
}

fn createFileAbsolute(path: []const u8, mode: std.fs.File.Mode) !std.fs.File {
    return std.fs.createFileAbsolute(path, .{ .truncate = true, .mode = mode });
}

fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    var file = try createFileAbsolute(path, std.fs.File.default_mode);
    defer file.close();
    try file.writeAll(data);
}

fn copyFilePreserveMode(src_path: []const u8, dst_path: []const u8) !void {
    var src = try openFileAny(src_path);
    defer src.close();
    const src_mode = if (builtin.os.tag == .windows) std.fs.File.default_mode else (try src.stat()).mode;
    var dst = try createFileAbsolute(dst_path, src_mode);
    defer dst.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dst.writeAll(buf[0..n]);
    }
}

test "tool_import: resolveDocs prefers --skill over sibling skill and help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "---\nname: docx\n---\nAuthor skill.",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.skill_flag, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Author skill") != null);
}

test "tool_import: resolveDocs uses sibling SKILL.md when --skill is unavailable" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "help text",
        .skill_output = "",
        .sibling_skill = "---\nname: docx\n---\nSibling skill.",
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.sibling_skill, docs.source);
}

test "tool_import: resolveDocs generates deterministic skill from help" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "docx",
        .help_output = "docx edits files\nUsage: docx review input output",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.generated_from_help, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "Usage: docx review") != null);
}

test "tool_import: resolveDocs accepts AI draft when no authored docs exist" {
    const a = std.testing.allocator;
    const docs = try resolveDocs(a, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = "Use cautiously after the user explains what arguments are needed.",
    });
    defer a.free(docs.skill_md);
    try std.testing.expectEqual(DocSource.ai_draft, docs.source);
    try std.testing.expect(std.mem.indexOf(u8, docs.skill_md, "limited metadata") != null);
}

test "tool_import: resolveDocs blocks when no docs and no AI draft exist" {
    try std.testing.expectError(error.MissingToolDocumentation, resolveDocs(std.testing.allocator, .{
        .tool_name = "mystery",
        .help_output = "",
        .skill_output = "",
        .sibling_skill = null,
        .ai_draft = null,
    }));
}

test "tool_import: sha256FileHex streams lowercase digest" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "payload.bin", .data = "abc" });
    const path = try tmp.dir.realpathAlloc(a, "payload.bin");
    defer a.free(path);

    const hex = try sha256FileHex(a, path);
    defer a.free(hex);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", hex);
}

test "tool_import: readSiblingSkillMd reads SKILL.md beside binary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tool", .data = "bin" });
    try tmp.dir.writeFile(.{ .sub_path = "SKILL.md", .data = "---\nname: tool\n---\nSibling docs.\n" });
    const binary_path = try tmp.dir.realpathAlloc(a, "tool");
    defer a.free(binary_path);

    const skill = readSiblingSkillMd(a, binary_path) orelse return error.ExpectedSiblingSkill;
    defer a.free(skill);
    try std.testing.expect(std.mem.indexOf(u8, skill, "Sibling docs") != null);
}

test "tool_import: installToolPackage stages package with manifest and binary" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("tools");
    try tmp.dir.writeFile(.{ .sub_path = "src/docx", .data = "binary bytes" });
    const source_path = try tmp.dir.realpathAlloc(a, "src/docx");
    defer a.free(source_path);
    const tools_root = try tmp.dir.realpathAlloc(a, "tools");
    defer a.free(tools_root);

    const installed = try installToolPackage(
        a,
        tools_root,
        source_path,
        "docx",
        "---\nname: docx\ndescription: DOCX helper\n---\nUse docs.\n",
        true,
    );
    defer a.free(installed);
    const expected_dir = try std.fs.path.join(a, &.{ tools_root, "docx" });
    defer a.free(expected_dir);
    try std.testing.expectEqualStrings(expected_dir, installed);

    const copied_path = try std.fs.path.join(a, &.{ installed, "bin", "docx" });
    defer a.free(copied_path);
    const copied = try std.fs.cwd().readFileAlloc(a, copied_path, 1024);
    defer a.free(copied);
    try std.testing.expectEqualStrings("binary bytes", copied);

    const manifest_path = try std.fs.path.join(a, &.{ installed, "manifest.json" });
    defer a.free(manifest_path);
    const manifest_json = try std.fs.cwd().readFileAlloc(a, manifest_path, 16 * 1024);
    defer a.free(manifest_json);
    var manifest = try tool_registry.parseManifestJson(a, manifest_json);
    defer manifest.deinit(a);
    try std.testing.expectEqualStrings("docx", manifest.id);
    try std.testing.expectEqualStrings("docx", manifest.function_name);
    try std.testing.expect(manifest.enabled);
    try std.testing.expectEqualStrings("bin/docx", manifest.executable);
    try std.testing.expectEqualStrings(source_path, manifest.source_path);

    try std.testing.expectError(error.ToolAlreadyExists, installToolPackage(
        a,
        tools_root,
        source_path,
        "docx",
        "---\nname: docx\n---\nUse docs.\n",
        false,
    ));
}
