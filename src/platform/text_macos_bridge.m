#import <Foundation/Foundation.h>
#include <stdint.h>

// Foundation-only case-insensitive comparison bridge for `text_macos.zig`.
// Kept separate from `services_macos_bridge.m` (AppKit/Carbon) so the
// lightweight `platform/text.zig` path — pulled into the native fast-test
// suite via `local_path.zig` — links against Foundation alone.
int32_t wispterm_macos_text_case_insensitive_equal(const char *a, const char *b) {
    @autoreleasepool {
        if (a == NULL || b == NULL) return -1;
        NSString *lhs = [NSString stringWithUTF8String:a];
        NSString *rhs = [NSString stringWithUTF8String:b];
        if (lhs == nil || rhs == nil) return -1;
        return [lhs caseInsensitiveCompare:rhs] == NSOrderedSame ? 1 : 0;
    }
}
