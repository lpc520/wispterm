const std = @import("std");

pub const NAME_MAX: usize = 96;
pub const PROFILE_MAX: usize = 128;
pub const HOST_MAX: usize = 64;

pub const Direction = enum {
    local,
    reverse,

    pub fn flag(self: Direction) []const u8 {
        return switch (self) {
            .local => "-L",
            .reverse => "-R",
        };
    }

    pub fn text(self: Direction) []const u8 {
        return switch (self) {
            .local => "local",
            .reverse => "reverse",
        };
    }

    pub fn parse(value: []const u8) ?Direction {
        if (std.ascii.eqlIgnoreCase(value, "local")) return .local;
        if (std.ascii.eqlIgnoreCase(value, "reverse")) return .reverse;
        return null;
    }
};

pub const Rule = struct {
    name_buf: [NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    profile_buf: [PROFILE_MAX]u8 = undefined,
    profile_len: usize = 0,
    direction: Direction = .reverse,
    local_host_buf: [HOST_MAX]u8 = undefined,
    local_host_len: usize = 0,
    local_port: u16 = 7890,
    remote_host_buf: [HOST_MAX]u8 = undefined,
    remote_host_len: usize = 0,
    remote_port: u16 = 7890,
    enabled: bool = true,
    auto_start: bool = true,

    pub fn name(self: *const Rule) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn profileName(self: *const Rule) []const u8 {
        return self.profile_buf[0..self.profile_len];
    }

    pub fn localHost(self: *const Rule) []const u8 {
        return self.local_host_buf[0..self.local_host_len];
    }

    pub fn remoteHost(self: *const Rule) []const u8 {
        return self.remote_host_buf[0..self.remote_host_len];
    }

    pub fn setName(self: *Rule, value: []const u8) void {
        self.name_len = copyBounded(self.name_buf[0..], value);
    }

    pub fn setProfileName(self: *Rule, value: []const u8) void {
        self.profile_len = copyBounded(self.profile_buf[0..], value);
    }

    pub fn setLocalHost(self: *Rule, value: []const u8) void {
        self.local_host_len = copyBounded(self.local_host_buf[0..], value);
    }

    pub fn setRemoteHost(self: *Rule, value: []const u8) void {
        self.remote_host_len = copyBounded(self.remote_host_buf[0..], value);
    }

    pub fn validate(self: *const Rule) bool {
        return self.profileName().len > 0 and
            validateHost(self.localHost()) and
            validateHost(self.remoteHost()) and
            self.local_port != 0 and
            self.remote_port != 0;
    }

    pub fn forwardSpec(self: *const Rule, buf: []u8) ?[]const u8 {
        if (!self.validate()) return null;
        return switch (self.direction) {
            .local => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.localHost(), self.local_port, self.remoteHost(), self.remote_port },
            ) catch null,
            .reverse => std.fmt.bufPrint(
                buf,
                "{s}:{d}:{s}:{d}",
                .{ self.remoteHost(), self.remote_port, self.localHost(), self.local_port },
            ) catch null,
        };
    }
};

pub fn defaultReverseProxy(profile_name: []const u8) Rule {
    var rule: Rule = .{};
    rule.setName("Local proxy");
    rule.setProfileName(profile_name);
    rule.direction = .reverse;
    rule.setLocalHost("127.0.0.1");
    rule.local_port = 7890;
    rule.setRemoteHost("127.0.0.1");
    rule.remote_port = 7890;
    rule.enabled = true;
    rule.auto_start = true;
    return rule;
}

pub fn validateHost(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

pub fn parsePort(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    const value = std.fmt.parseInt(u32, trimmed, 10) catch return null;
    if (value == 0 or value > std.math.maxInt(u16)) return null;
    return @intCast(value);
}

pub fn freeRules(allocator: std.mem.Allocator, rules: []Rule) void {
    allocator.free(rules);
}

pub fn encodeRules(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), rules: []const Rule) !void {
    try out.appendSlice(allocator, "# WispTerm port forwarding rules. Fields are hex encoded: name, profile, direction, local_host, local_port, remote_host, remote_port, enabled, auto_start.\n");
    for (rules) |rule| {
        try appendHexField(allocator, out, rule.name());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.profileName());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.direction.text());
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.localHost());
        try out.append(allocator, '\t');
        var local_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&local_port_buf, "{d}", .{rule.local_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, rule.remoteHost());
        try out.append(allocator, '\t');
        var remote_port_buf: [8]u8 = undefined;
        try appendHexField(allocator, out, std.fmt.bufPrint(&remote_port_buf, "{d}", .{rule.remote_port}) catch unreachable);
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.enabled) "true" else "false");
        try out.append(allocator, '\t');
        try appendHexField(allocator, out, if (rule.auto_start) "true" else "false");
        try out.append(allocator, '\n');
    }
}

pub fn decodeRules(allocator: std.mem.Allocator, content: []const u8) ![]Rule {
    var rules: std.ArrayListUnmanaged(Rule) = .empty;
    errdefer rules.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (decodeRuleLine(line)) |rule| {
            try rules.append(allocator, rule);
        }
    }
    return rules.toOwnedSlice(allocator);
}

pub fn decodeRuleLine(line: []const u8) ?Rule {
    var fields: [9][128]u8 = undefined;
    var lens: [9]usize = .{0} ** 9;
    var parts = std.mem.splitScalar(u8, line, '\t');
    var idx: usize = 0;
    while (idx < fields.len) : (idx += 1) {
        const part = parts.next() orelse return null;
        lens[idx] = decodeHexField(part, fields[idx][0..]) orelse return null;
    }
    var rule: Rule = .{};
    rule.setName(fields[0][0..lens[0]]);
    rule.setProfileName(fields[1][0..lens[1]]);
    rule.direction = Direction.parse(fields[2][0..lens[2]]) orelse return null;
    rule.setLocalHost(fields[3][0..lens[3]]);
    rule.local_port = parsePort(fields[4][0..lens[4]]) orelse return null;
    rule.setRemoteHost(fields[5][0..lens[5]]);
    rule.remote_port = parsePort(fields[6][0..lens[6]]) orelse return null;
    rule.enabled = parseBool(fields[7][0..lens[7]]) orelse return null;
    rule.auto_start = parseBool(fields[8][0..lens[8]]) orelse return null;
    return rule;
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

fn appendHexField(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), field: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (field) |ch| {
        try out.append(allocator, hex[ch >> 4]);
        try out.append(allocator, hex[ch & 0x0f]);
    }
}

fn decodeHexField(value: []const u8, out: []u8) ?usize {
    if (value.len % 2 != 0) return null;
    const len = @min(value.len / 2, out.len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const hi = hexValue(value[i * 2]) orelse return null;
        const lo = hexValue(value[i * 2 + 1]) orelse return null;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

fn hexValue(ch: u8) ?u8 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return null;
}

fn copyBounded(dest: []u8, text: []const u8) usize {
    const n = @min(dest.len, text.len);
    @memcpy(dest[0..n], text[0..n]);
    return n;
}

test "port_forward_rule: default reverse rule targets local proxy" {
    const rule = defaultReverseProxy("devbox");
    try std.testing.expectEqual(Direction.reverse, rule.direction);
    try std.testing.expectEqualStrings("devbox", rule.profileName());
    try std.testing.expectEqualStrings("127.0.0.1", rule.localHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.local_port);
    try std.testing.expectEqualStrings("127.0.0.1", rule.remoteHost());
    try std.testing.expectEqual(@as(u16, 7890), rule.remote_port);
    try std.testing.expect(rule.enabled);
    try std.testing.expect(rule.auto_start);
}

test "port_forward_rule: validates loopback hosts and port range" {
    try std.testing.expect(validateHost("127.0.0.1"));
    try std.testing.expect(validateHost("localhost"));
    try std.testing.expect(!validateHost("0.0.0.0"));
    try std.testing.expect(!validateHost("10.0.0.1"));
    try std.testing.expect(parsePort("1").? == 1);
    try std.testing.expect(parsePort("65535").? == 65535);
    try std.testing.expect(parsePort("0") == null);
    try std.testing.expect(parsePort("65536") == null);
    try std.testing.expect(parsePort("abc") == null);
}

test "port_forward_rule: forward specs match ssh -L and -R semantics" {
    var rule = defaultReverseProxy("devbox");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "127.0.0.1:7890:127.0.0.1:7890",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-R", rule.direction.flag());

    rule.direction = .local;
    rule.local_port = 8888;
    rule.remote_port = 8888;
    try std.testing.expectEqualStrings(
        "127.0.0.1:8888:127.0.0.1:8888",
        rule.forwardSpec(&buf).?,
    );
    try std.testing.expectEqualStrings("-L", rule.direction.flag());
}

test "port_forward_rule: storage round trips two rules" {
    var rules = [_]Rule{
        defaultReverseProxy("devbox"),
        defaultReverseProxy("lab"),
    };
    rules[1].direction = .local;
    rules[1].local_port = 8888;
    rules[1].remote_port = 8888;
    rules[1].auto_start = false;
    rules[1].setName("Jupyter");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try encodeRules(std.testing.allocator, &out, rules[0..]);

    var decoded = try decodeRules(std.testing.allocator, out.items);
    defer freeRules(std.testing.allocator, decoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.len);
    try std.testing.expectEqual(Direction.reverse, decoded[0].direction);
    try std.testing.expectEqualStrings("devbox", decoded[0].profileName());
    try std.testing.expectEqual(Direction.local, decoded[1].direction);
    try std.testing.expectEqualStrings("Jupyter", decoded[1].name());
    try std.testing.expect(!decoded[1].auto_start);
}
