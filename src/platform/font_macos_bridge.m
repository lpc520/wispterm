#import <CoreFoundation/CoreFoundation.h>
#import <CoreText/CoreText.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

uint16_t wispterm_coretext_font_glyph_index(void *handle, uint32_t codepoint);

bool wispterm_coretext_is_available(void) {
    return true;
}

static char *wispterm_coretext_copy_cfstring(CFStringRef string) {
    if (string == NULL) return NULL;
    CFIndex length = CFStringGetLength(string);
    CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    char *buf = malloc((size_t)max_size);
    if (buf == NULL) return NULL;
    if (!CFStringGetCString(string, buf, max_size, kCFStringEncodingUTF8)) {
        free(buf);
        return NULL;
    }
    return buf;
}

static CFStringRef wispterm_coretext_create_string(const char *bytes) {
    if (bytes == NULL) return NULL;
    return CFStringCreateWithCString(kCFAllocatorDefault, bytes, kCFStringEncodingUTF8);
}

static CFStringRef wispterm_coretext_create_string_for_codepoint(uint32_t codepoint, CFIndex *utf16_len) {
    UniChar chars[2] = {0, 0};
    if (codepoint > 0xFFFF) {
        uint32_t scalar = codepoint - 0x10000;
        chars[0] = (UniChar)(0xD800 + (scalar >> 10));
        chars[1] = (UniChar)(0xDC00 + (scalar & 0x3FF));
        if (utf16_len != NULL) *utf16_len = 2;
        return CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 2);
    }
    chars[0] = (UniChar)codepoint;
    if (utf16_len != NULL) *utf16_len = 1;
    return CFStringCreateWithCharacters(kCFAllocatorDefault, chars, 1);
}

static bool wispterm_coretext_font_is_last_resort(CTFontRef font) {
    if (font == NULL) return true;
    CFStringRef name = CTFontCopyPostScriptName(font);
    if (name == NULL) return false;
    bool result = CFStringCompare(name, CFSTR("LastResort"), 0) == kCFCompareEqualTo;
    CFRelease(name);
    return result;
}

void *wispterm_coretext_find_font(const char *family, uint16_t weight) {
    CFStringRef family_name = wispterm_coretext_create_string(family);
    if (family_name == NULL) return NULL;

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (attrs == NULL) {
        CFRelease(family_name);
        return NULL;
    }
    CFDictionarySetValue(attrs, kCTFontFamilyNameAttribute, family_name);

    CGFloat normalized_weight = ((CGFloat)weight - 400.0) / 500.0;
    if (normalized_weight < -1.0) normalized_weight = -1.0;
    if (normalized_weight > 1.0) normalized_weight = 1.0;
    CFNumberRef weight_number = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &normalized_weight);
    const void *trait_keys[] = { kCTFontWeightTrait };
    const void *trait_values[] = { weight_number };
    CFDictionaryRef traits = CFDictionaryCreate(
        kCFAllocatorDefault,
        trait_keys,
        trait_values,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (traits != NULL) CFDictionarySetValue(attrs, kCTFontTraitsAttribute, traits);

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attrs);
    CTFontDescriptorRef match = descriptor != NULL
        ? CTFontDescriptorCreateMatchingFontDescriptor(descriptor, NULL)
        : NULL;
    CTFontRef font = match != NULL ? CTFontCreateWithFontDescriptor(match, 12.0, NULL) : NULL;

    if (traits != NULL) CFRelease(traits);
    if (weight_number != NULL) CFRelease(weight_number);
    if (match != NULL) CFRelease(match);
    if (descriptor != NULL) CFRelease(descriptor);
    CFRelease(attrs);
    CFRelease(family_name);
    return font;
}

void *wispterm_coretext_find_fallback(uint32_t codepoint) {
    CFIndex len = 0;
    CFStringRef string = wispterm_coretext_create_string_for_codepoint(codepoint, &len);
    if (string == NULL) return NULL;

    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12.0, NULL);
    if (base == NULL) {
        CFRelease(string);
        return NULL;
    }

    CFArrayRef cascade = CTFontCopyDefaultCascadeListForLanguages(base, NULL);
    if (cascade != NULL) {
        CFIndex count = CFArrayGetCount(cascade);
        for (CFIndex i = 0; i < count; i++) {
            CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(cascade, i);
            if (descriptor == NULL) continue;
            CTFontRef candidate = CTFontCreateWithFontDescriptor(descriptor, 12.0, NULL);
            if (candidate == NULL) continue;
            if (!wispterm_coretext_font_is_last_resort(candidate) &&
                wispterm_coretext_font_glyph_index(candidate, codepoint) != 0)
            {
                CFRelease(cascade);
                CFRelease(base);
                CFRelease(string);
                return candidate;
            }
            CFRelease(candidate);
        }
        CFRelease(cascade);
    }

    CTFontRef font = CTFontCreateForString(base, string, CFRangeMake(0, len));
    CFRelease(base);
    CFRelease(string);
    if (font == NULL) return NULL;
    if (wispterm_coretext_font_is_last_resort(font)) {
        CFRelease(font);
        return NULL;
    }
    return font;
}

void wispterm_coretext_font_retain(void *handle) {
    if (handle != NULL) CFRetain(handle);
}

void wispterm_coretext_font_release(void *handle) {
    if (handle != NULL) CFRelease(handle);
}

bool wispterm_coretext_font_has_character(void *handle, uint32_t codepoint) {
    return wispterm_coretext_font_glyph_index(handle, codepoint) != 0;
}

uint16_t wispterm_coretext_font_glyph_index(void *handle, uint32_t codepoint) {
    CTFontRef font = (CTFontRef)handle;
    if (font == NULL) return 0;

    CFIndex len = 0;
    CFStringRef string = wispterm_coretext_create_string_for_codepoint(codepoint, &len);
    if (string == NULL) return 0;

    UniChar chars[2] = {0, 0};
    CFStringGetCharacters(string, CFRangeMake(0, len), chars);
    CGGlyph glyphs[2] = {0, 0};
    bool ok = CTFontGetGlyphsForCharacters(font, chars, glyphs, len);
    CFRelease(string);
    return ok ? glyphs[0] : 0;
}

char *wispterm_coretext_font_copy_path(void *handle) {
    CTFontRef font = (CTFontRef)handle;
    if (font == NULL) return NULL;

    CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
    if (url == NULL) return NULL;
    CFStringRef path = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    CFRelease(url);
    if (path == NULL) return NULL;

    char *result = wispterm_coretext_copy_cfstring(path);
    CFRelease(path);
    return result;
}

size_t wispterm_coretext_family_count(void) {
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families == NULL) return 0;
    CFIndex count = CFArrayGetCount(families);
    CFRelease(families);
    return count > 0 ? (size_t)count : 0;
}

char *wispterm_coretext_copy_family_name(size_t index) {
    CFArrayRef families = CTFontManagerCopyAvailableFontFamilyNames();
    if (families == NULL) return NULL;
    CFIndex count = CFArrayGetCount(families);
    if (index >= (size_t)count) {
        CFRelease(families);
        return NULL;
    }
    CFStringRef family = (CFStringRef)CFArrayGetValueAtIndex(families, (CFIndex)index);
    char *result = wispterm_coretext_copy_cfstring(family);
    CFRelease(families);
    return result;
}

void wispterm_coretext_free(void *ptr) {
    free(ptr);
}
