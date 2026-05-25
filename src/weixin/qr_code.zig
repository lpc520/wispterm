//! Minimal QR Code Model 2 encoder for the WeChat login panel.
//!
//! The ilink API returns the text that should be encoded into the QR code, not
//! a PNG. We only need byte mode and low error correction for this UI.

const std = @import("std");

const MAX_VERSION = 10;
const MAX_SIZE = 17 + 4 * MAX_VERSION;
const MAX_DATA_CODEWORDS = 274;
const MAX_BLOCKS = 4;
const MAX_BLOCK_DATA_CODEWORDS = 116;
const MAX_ECC_CODEWORDS = 30;
const MAX_RAW_CODEWORDS = 346;

pub const EncodeError = error{
    EmptyPayload,
    PayloadTooLong,
};

pub const Matrix = struct {
    allocator: std.mem.Allocator,
    size: usize,
    version: u8,
    modules: []u8,

    pub fn deinit(self: *Matrix) void {
        if (self.modules.len != 0) self.allocator.free(self.modules);
        self.* = .{
            .allocator = self.allocator,
            .size = 0,
            .version = 0,
            .modules = &.{},
        };
    }

    pub fn isBlack(self: Matrix, x: usize, y: usize) bool {
        return x < self.size and y < self.size and self.modules[y * self.size + x] != 0;
    }
};

const BlockGroup = struct {
    count: usize,
    data_codewords: usize,
};

const VersionSpec = struct {
    data_codewords: usize,
    ecc_codewords_per_block: usize,
    groups: []const BlockGroup,
};

const Block = struct {
    data_len: usize = 0,
    data: [MAX_BLOCK_DATA_CODEWORDS]u8 = undefined,
    ecc: [MAX_ECC_CODEWORDS]u8 = undefined,
};

pub fn encodeText(allocator: std.mem.Allocator, payload: []const u8) (EncodeError || std.mem.Allocator.Error)!Matrix {
    if (payload.len == 0) return EncodeError.EmptyPayload;

    const version = chooseVersion(payload.len) orelse return EncodeError.PayloadTooLong;
    const spec = versionSpec(version);

    var data_codewords: [MAX_DATA_CODEWORDS]u8 = undefined;
    const data_len = try encodePayloadBits(payload, version, spec.data_codewords, &data_codewords);
    std.debug.assert(data_len == spec.data_codewords);

    var raw_codewords: [MAX_RAW_CODEWORDS]u8 = undefined;
    const raw_len = makeRawCodewords(spec, data_codewords[0..data_len], &raw_codewords);

    const size: usize = 17 + 4 * @as(usize, version);
    const modules = try allocator.alloc(u8, size * size);
    errdefer allocator.free(modules);
    @memset(modules, 0);

    const function_modules = try allocator.alloc(u8, size * size);
    defer allocator.free(function_modules);
    @memset(function_modules, 0);

    drawFunctionPatterns(modules, function_modules, size, version);
    drawCodewords(modules, function_modules, size, raw_codewords[0..raw_len], 0);
    drawFormatBits(modules, function_modules, size, 0);

    return .{
        .allocator = allocator,
        .size = size,
        .version = version,
        .modules = modules,
    };
}

fn chooseVersion(payload_len: usize) ?u8 {
    for (1..MAX_VERSION + 1) |version_usize| {
        const version: u8 = @intCast(version_usize);
        const spec = versionSpec(version);
        const count_bits: usize = if (version <= 9) 8 else 16;
        if (payload_len > std.math.maxInt(u16)) return null;
        const needed_bits = 4 + count_bits + payload_len * 8;
        if (needed_bits <= spec.data_codewords * 8) return version;
    }
    return null;
}

fn versionSpec(version: u8) VersionSpec {
    return switch (version) {
        1 => .{ .data_codewords = 19, .ecc_codewords_per_block = 7, .groups = &.{.{ .count = 1, .data_codewords = 19 }} },
        2 => .{ .data_codewords = 34, .ecc_codewords_per_block = 10, .groups = &.{.{ .count = 1, .data_codewords = 34 }} },
        3 => .{ .data_codewords = 55, .ecc_codewords_per_block = 15, .groups = &.{.{ .count = 1, .data_codewords = 55 }} },
        4 => .{ .data_codewords = 80, .ecc_codewords_per_block = 20, .groups = &.{.{ .count = 1, .data_codewords = 80 }} },
        5 => .{ .data_codewords = 108, .ecc_codewords_per_block = 26, .groups = &.{.{ .count = 1, .data_codewords = 108 }} },
        6 => .{ .data_codewords = 136, .ecc_codewords_per_block = 18, .groups = &.{.{ .count = 2, .data_codewords = 68 }} },
        7 => .{ .data_codewords = 156, .ecc_codewords_per_block = 20, .groups = &.{.{ .count = 2, .data_codewords = 78 }} },
        8 => .{ .data_codewords = 194, .ecc_codewords_per_block = 24, .groups = &.{.{ .count = 2, .data_codewords = 97 }} },
        9 => .{ .data_codewords = 232, .ecc_codewords_per_block = 30, .groups = &.{.{ .count = 2, .data_codewords = 116 }} },
        10 => .{ .data_codewords = 274, .ecc_codewords_per_block = 18, .groups = &.{
            .{ .count = 2, .data_codewords = 68 },
            .{ .count = 2, .data_codewords = 69 },
        } },
        else => unreachable,
    };
}

fn encodePayloadBits(payload: []const u8, version: u8, capacity_codewords: usize, out: *[MAX_DATA_CODEWORDS]u8) EncodeError!usize {
    var bits: [MAX_DATA_CODEWORDS * 8]u8 = undefined;
    var bit_len: usize = 0;
    const capacity_bits = capacity_codewords * 8;

    appendBits(&bits, &bit_len, 0b0100, 4); // byte mode
    appendBits(&bits, &bit_len, @intCast(payload.len), if (version <= 9) 8 else 16);
    for (payload) |byte| appendBits(&bits, &bit_len, byte, 8);
    if (bit_len > capacity_bits) return EncodeError.PayloadTooLong;

    const terminator_len = @min(@as(usize, 4), capacity_bits - bit_len);
    appendBits(&bits, &bit_len, 0, terminator_len);
    while (bit_len % 8 != 0) appendBits(&bits, &bit_len, 0, 1);

    @memset(out[0..capacity_codewords], 0);
    for (0..bit_len) |i| {
        if (bits[i] != 0) out[i / 8] |= @as(u8, 1) << @intCast(7 - (i % 8));
    }

    var used_codewords = bit_len / 8;
    var pad: u8 = 0xEC;
    while (used_codewords < capacity_codewords) {
        out[used_codewords] = pad;
        used_codewords += 1;
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }
    return used_codewords;
}

fn appendBits(bits: *[MAX_DATA_CODEWORDS * 8]u8, bit_len: *usize, value: u32, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const shift: u5 = @intCast(count - 1 - i);
        bits[bit_len.*] = @intCast((value >> shift) & 1);
        bit_len.* += 1;
    }
}

fn makeRawCodewords(spec: VersionSpec, data_codewords: []const u8, out: *[MAX_RAW_CODEWORDS]u8) usize {
    var blocks: [MAX_BLOCKS]Block = undefined;
    var block_count: usize = 0;
    var data_pos: usize = 0;

    for (spec.groups) |group| {
        for (0..group.count) |_| {
            std.debug.assert(block_count < blocks.len);
            var block = Block{ .data_len = group.data_codewords };
            @memcpy(block.data[0..group.data_codewords], data_codewords[data_pos..][0..group.data_codewords]);
            reedSolomonRemainder(block.data[0..group.data_codewords], spec.ecc_codewords_per_block, block.ecc[0..spec.ecc_codewords_per_block]);
            blocks[block_count] = block;
            block_count += 1;
            data_pos += group.data_codewords;
        }
    }
    std.debug.assert(data_pos == data_codewords.len);

    var out_len: usize = 0;
    var max_data_len: usize = 0;
    for (blocks[0..block_count]) |block| max_data_len = @max(max_data_len, block.data_len);

    for (0..max_data_len) |i| {
        for (blocks[0..block_count]) |block| {
            if (i < block.data_len) {
                out[out_len] = block.data[i];
                out_len += 1;
            }
        }
    }
    for (0..spec.ecc_codewords_per_block) |i| {
        for (blocks[0..block_count]) |block| {
            out[out_len] = block.ecc[i];
            out_len += 1;
        }
    }
    return out_len;
}

fn drawFunctionPatterns(modules: []u8, function_modules: []u8, size: usize, version: u8) void {
    drawFinderPattern(modules, function_modules, size, 0, 0);
    drawFinderPattern(modules, function_modules, size, size - 7, 0);
    drawFinderPattern(modules, function_modules, size, 0, size - 7);

    for (8..size - 8) |i| {
        const black = i % 2 == 0;
        setFunction(modules, function_modules, size, i, 6, black);
        setFunction(modules, function_modules, size, 6, i, black);
    }

    const positions = alignmentPatternPositions(version);
    for (positions) |cy| {
        for (positions) |cx| {
            if (function_modules[index(size, cx, cy)] != 0) continue;
            drawAlignmentPattern(modules, function_modules, size, cx, cy);
        }
    }

    drawFormatBits(modules, function_modules, size, 0);
    drawVersionBits(modules, function_modules, size, version);
}

fn drawFinderPattern(modules: []u8, function_modules: []u8, size: usize, left: usize, top: usize) void {
    const left_i: i32 = @intCast(left);
    const top_i: i32 = @intCast(top);
    var dy: i32 = -1;
    while (dy <= 7) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 7) : (dx += 1) {
            const x = left_i + dx;
            const y = top_i + dy;
            if (x < 0 or y < 0 or x >= @as(i32, @intCast(size)) or y >= @as(i32, @intCast(size))) continue;
            const in_finder = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6;
            const black = in_finder and
                (dx == 0 or dx == 6 or dy == 0 or dy == 6 or
                    (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4));
            setFunction(modules, function_modules, size, @intCast(x), @intCast(y), black);
        }
    }
}

fn drawAlignmentPattern(modules: []u8, function_modules: []u8, size: usize, cx: usize, cy: usize) void {
    const cx_i: i32 = @intCast(cx);
    const cy_i: i32 = @intCast(cy);
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const dist = @max(@abs(dx), @abs(dy));
            const black = dist != 1;
            setFunction(modules, function_modules, size, @intCast(cx_i + dx), @intCast(cy_i + dy), black);
        }
    }
}

fn alignmentPatternPositions(version: u8) []const usize {
    return switch (version) {
        1 => &.{},
        2 => &.{ 6, 18 },
        3 => &.{ 6, 22 },
        4 => &.{ 6, 26 },
        5 => &.{ 6, 30 },
        6 => &.{ 6, 34 },
        7 => &.{ 6, 22, 38 },
        8 => &.{ 6, 24, 42 },
        9 => &.{ 6, 26, 46 },
        10 => &.{ 6, 28, 50 },
        else => unreachable,
    };
}

fn drawCodewords(modules: []u8, function_modules: []u8, size: usize, data: []const u8, mask: u3) void {
    var bit_index: usize = 0;
    var right: i32 = @intCast(size - 1);
    var y: i32 = @intCast(size - 1);
    var upward = true;

    while (right > 0) : (right -= 2) {
        if (right == 6) right -= 1;
        while (true) {
            for (0..2) |dx| {
                const x: usize = @intCast(right - @as(i32, @intCast(dx)));
                const y_usize: usize = @intCast(y);
                const idx = index(size, x, y_usize);
                if (function_modules[idx] == 0) {
                    var black = false;
                    if (bit_index < data.len * 8) {
                        black = ((data[bit_index / 8] >> @intCast(7 - (bit_index % 8))) & 1) != 0;
                    }
                    if (maskCondition(mask, x, y_usize)) black = !black;
                    modules[idx] = if (black) 1 else 0;
                    bit_index += 1;
                }
            }

            if (upward) {
                if (y == 0) {
                    upward = false;
                    break;
                }
                y -= 1;
            } else {
                if (y == @as(i32, @intCast(size - 1))) {
                    upward = true;
                    break;
                }
                y += 1;
            }
        }
    }
}

fn maskCondition(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (x / 3 + y / 2) % 2 == 0,
        5 => ((x * y) % 2 + (x * y) % 3) == 0,
        6 => (((x * y) % 2 + (x * y) % 3) % 2) == 0,
        7 => (((x + y) % 2 + (x * y) % 3) % 2) == 0,
    };
}

fn drawFormatBits(modules: []u8, function_modules: []u8, size: usize, mask: u3) void {
    const bits = formatBits(mask);

    for (0..6) |i| setFunction(modules, function_modules, size, 8, i, bit(bits, i));
    setFunction(modules, function_modules, size, 8, 7, bit(bits, 6));
    setFunction(modules, function_modules, size, 8, 8, bit(bits, 7));
    setFunction(modules, function_modules, size, 7, 8, bit(bits, 8));
    for (9..15) |i| setFunction(modules, function_modules, size, 14 - i, 8, bit(bits, i));

    for (0..8) |i| setFunction(modules, function_modules, size, size - 1 - i, 8, bit(bits, i));
    for (8..15) |i| setFunction(modules, function_modules, size, 8, size - 15 + i, bit(bits, i));
    setFunction(modules, function_modules, size, 8, size - 8, true);
}

fn formatBits(mask: u3) u16 {
    const ecc_low_format_bits: u16 = 1;
    const data: u16 = (ecc_low_format_bits << 3) | mask;
    var rem: u16 = data;
    for (0..10) |_| {
        rem = (rem << 1) ^ if ((rem & (1 << 9)) != 0) @as(u16, 0x537) else @as(u16, 0);
    }
    return ((data << 10) | (rem & 0x03FF)) ^ 0x5412;
}

fn drawVersionBits(modules: []u8, function_modules: []u8, size: usize, version: u8) void {
    if (version < 7) return;
    const bits = versionBits(version);
    for (0..18) |i| {
        const a = size - 11 + i % 3;
        const b = i / 3;
        const black = bit(bits, i);
        setFunction(modules, function_modules, size, a, b, black);
        setFunction(modules, function_modules, size, b, a, black);
    }
}

fn versionBits(version: u8) u32 {
    var rem: u32 = version;
    for (0..12) |_| {
        rem = (rem << 1) ^ if ((rem & (1 << 11)) != 0) @as(u32, 0x1F25) else @as(u32, 0);
    }
    return (@as(u32, version) << 12) | (rem & 0x0FFF);
}

fn bit(value: anytype, index_value: usize) bool {
    return ((value >> @intCast(index_value)) & 1) != 0;
}

fn setFunction(modules: []u8, function_modules: []u8, size: usize, x: usize, y: usize, black: bool) void {
    const idx = index(size, x, y);
    modules[idx] = if (black) 1 else 0;
    function_modules[idx] = 1;
}

fn index(size: usize, x: usize, y: usize) usize {
    return y * size + x;
}

fn reedSolomonRemainder(data: []const u8, degree: usize, out: []u8) void {
    var divisor: [MAX_ECC_CODEWORDS]u8 = undefined;
    reedSolomonGenerator(degree, divisor[0..degree]);

    @memset(out[0..degree], 0);
    for (data) |byte| {
        const factor = byte ^ out[0];
        std.mem.copyForwards(u8, out[0 .. degree - 1], out[1..degree]);
        out[degree - 1] = 0;
        for (0..degree) |i| out[i] ^= reedSolomonMultiply(divisor[i], factor);
    }
}

fn reedSolomonGenerator(degree: usize, out: []u8) void {
    @memset(out[0..degree], 0);
    out[degree - 1] = 1;

    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |i| {
            out[i] = reedSolomonMultiply(out[i], root);
            if (i + 1 < degree) out[i] ^= out[i + 1];
        }
        root = reedSolomonMultiply(root, 0x02);
    }
}

fn reedSolomonMultiply(x: u8, y: u8) u8 {
    var z: u16 = 0;
    var a: u16 = x;
    var b: u16 = y;
    while (b != 0) {
        if ((b & 1) != 0) z ^= a;
        b >>= 1;
        a <<= 1;
        if ((a & 0x100) != 0) a ^= 0x11D;
    }
    return @intCast(z & 0xFF);
}

test "qr_code: encodes a small byte payload" {
    var qr = try encodeText(std.testing.allocator, "weixin://qr-content");
    defer qr.deinit();

    try std.testing.expectEqual(@as(usize, 25), qr.size);
    try std.testing.expectEqual(@as(u8, 2), qr.version);
    try std.testing.expect(qr.isBlack(0, 0));
    try std.testing.expect(qr.isBlack(6, 0));
    try std.testing.expect(qr.isBlack(0, 6));
    try std.testing.expect(!qr.isBlack(7, 7));
}

test "qr_code: byte payload matches a reference encoder with mask 0" {
    const expected_rows = [_][]const u8{
        "1111111001001111001111111",
        "1000001000111011101000001",
        "1011101011101010001011101",
        "1011101001110011001011101",
        "1011101000100001001011101",
        "1000001001000111001000001",
        "1111111010101010101111111",
        "0000000011101101100000000",
        "1110111110110010011000100",
        "1011100000110000101001111",
        "1011111001000100101101111",
        "0111000100010000100010000",
        "1110001000001001111001011",
        "0111000110011100101101111",
        "1011101010111010001100111",
        "0110010100101110111010001",
        "1011011010110011111110011",
        "0000000010110011100011101",
        "1111111011000101101011111",
        "1000001010010000100010001",
        "1011101011101000111110001",
        "1011101001011100110110100",
        "1011101011011010100010001",
        "1000001010101111101111010",
        "1111111011010011111001011",
    };

    var qr = try encodeText(std.testing.allocator, "weixin://qr-content");
    defer qr.deinit();

    try std.testing.expectEqual(expected_rows.len, qr.size);
    for (expected_rows, 0..) |row, y| {
        try std.testing.expectEqual(row.len, qr.size);
        for (row, 0..) |expected, x| {
            const actual = qr.isBlack(x, y);
            if ((expected == '1') != actual) {
                std.debug.print("QR mismatch at row {d}, column {d}: expected {c}, actual {c}\n", .{
                    y,
                    x,
                    expected,
                    if (actual) @as(u8, '1') else @as(u8, '0'),
                });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "qr_code: grows through supported versions" {
    const payload = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var qr = try encodeText(std.testing.allocator, payload);
    defer qr.deinit();

    try std.testing.expect(qr.version > 4);
    try std.testing.expect(qr.size == 17 + 4 * @as(usize, qr.version));
}

test "qr_code: rejects empty and oversized payloads" {
    try std.testing.expectError(EncodeError.EmptyPayload, encodeText(std.testing.allocator, ""));

    const payload = [_]u8{'x'} ** 400;
    try std.testing.expectError(EncodeError.PayloadTooLong, encodeText(std.testing.allocator, &payload));
}
