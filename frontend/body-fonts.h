#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct MdfBodyFontsView { void *config; void *coverage; const int *fds; size_t count; uint32_t styles; };
void *mdf_body_fonts_create(void);
void mdf_body_fonts_destroy(void *);
int mdf_body_fonts_add(void *, uint32_t style, const unsigned char *, size_t, int profile, size_t depth, char *, size_t);
struct MdfBodyFontsView mdf_body_fonts_view(void *);
int mdf_body_fonts_activate(void *);
int mdf_body_fonts_adopt_default(void *);
void mdf_body_fonts_refresh_default(void);
int mdf_body_fonts_add_fallback(void *, void *prepared, char *, size_t);
#ifdef __cplusplus
}
#endif
