#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct MdfSystemTextMetrics { float width, height, descent; };
struct MdfTextMask { unsigned char *data; int width, height, left, top; };
struct MdfMissingGlyphs { uint32_t *data; size_t count; int failed; };
void *mdf_system_text_create(void *prepared, char *error, size_t error_length);
void mdf_system_text_destroy(void *);
int mdf_system_text_add_fallback(void *, void *, char *, size_t);
int mdf_system_text_has_character(void *, uint32_t);
int mdf_system_text_unknown_glyphs(void *, const char *, size_t, int style);
int mdf_system_text_measure(void *, const char *, size_t, int size, int style, struct MdfSystemTextMetrics *);
void mdf_system_text_draw(void *, const char *, size_t, int size, int style, void *cairo, float x, float baseline);
int mdf_system_text_bitmap(void *, const unsigned char *, size_t, int, int,
    float x, float baseline, int width, int height, struct MdfTextMask *);
struct MdfMissingGlyphs mdf_missing_glyphs(const unsigned char *, size_t, const void *coverage);
int mdf_needs_fallback(const unsigned char *, size_t, const void *coverage);
#ifdef __cplusplus
}
#endif
