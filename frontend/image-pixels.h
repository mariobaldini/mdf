#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

struct MdfPixels {
  unsigned char *data;
  int width, height, channels;
};
struct MdfEncodedImage { unsigned char *data; size_t length; };

/* Pure Zig/Zignal codec work. The caller frees successful output with free(). */
int mdf_decode_pixels(const unsigned char *bytes, size_t length,
                      size_t limit, struct MdfPixels *out);
int mdf_encode_png(const struct MdfPixels *pixels, size_t length,
                   struct MdfEncodedImage *out);

#define MDF_IMAGE_ABI 1
#define MDF_MODULE_IMAGE 4
/* The codec module has no font or UI dependencies. Its allocations use free(). */
struct MdfImageApi {
  uint32_t abi, size, kind, reserved;
  int (*decode)(const unsigned char *, size_t, size_t, struct MdfPixels *);
  int (*encode)(const struct MdfPixels *, size_t, struct MdfEncodedImage *);
};
const struct MdfImageApi *mdf_image_api(uint32_t);
const struct MdfImageApi *mdf_image_renderer(int (*)(const void *), const void *,
    size_t, char *, size_t);
int mdf_lazy_encode_png(const struct MdfPixels *, size_t, struct MdfEncodedImage *);
#ifdef __cplusplus
}
#endif
