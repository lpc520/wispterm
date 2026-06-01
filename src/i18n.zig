//! UI 文案国际化（i18n）核心：扁平字段目录 + 当前语言。
//! 设计见 docs/superpowers/specs/2026-06-01-i18n-infrastructure-design.md
const std = @import("std");

pub const Lang = enum { en, zh_CN };

/// 调用点直接替换的扁平文案。字段无默认值 → 任一 locale 漏填某字段编译期报错，
/// 这是「方案 A」comptime 完整性保证的落地（无需手写 assert）。
pub const Strings = struct {
    language_name: []const u8,
};

const en = Strings{
    .language_name = "English",
};

const zh_CN = Strings{
    .language_name = "中文",
};

var current: *const Strings = &en;
var active_lang: Lang = .en;

/// 当前语言的文案表。调用点：`i18n.s().language_name`。
pub fn s() *const Strings {
    return current;
}

pub fn lang() Lang {
    return active_lang;
}

pub fn setLang(l: Lang) void {
    active_lang = l;
    current = switch (l) {
        .en => &en,
        .zh_CN => &zh_CN,
    };
}

test "setLang switches the active strings table" {
    defer setLang(.en); // 复位，避免污染其它测试
    setLang(.en);
    try std.testing.expectEqualStrings("English", s().language_name);
    try std.testing.expect(lang() == .en);
    setLang(.zh_CN);
    try std.testing.expectEqualStrings("中文", s().language_name);
    try std.testing.expect(lang() == .zh_CN);
}
