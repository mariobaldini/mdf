#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

struct MdfPixels {
  unsigned char *data;
  int width, height, channels;
};

/* Pure Zig/Zignal codec work. The caller frees successful output with free(). */
int mdf_decode_pixels(const unsigned char *bytes, size_t length,
                      size_t limit, struct MdfPixels *out);
#ifdef __cplusplus
}
#endif
