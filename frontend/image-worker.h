#pragma once
#include "mermaid.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Input bytes and font descriptors are borrowed until join/destroy. Results
   transfer their malloc-owned pixels once through pop. */
struct MdfImageInput {
  int index;
  uint32_t kind; /* 0: encoded raster, 1: Mermaid, 2: SVG */
  const unsigned char *bytes;
  size_t length;
  int fallback;
};
struct MdfPreparedImage {
  int index;
  struct MdfPixels pixels;
  int diagram;
  float logical_width, logical_height;
  char error[512];
  int svg;
  struct MdfSvgText missing_glyphs; /* transferred malloc-owned UTF-8 */
};
void *mdf_image_worker_create(const struct MdfImageInput *, size_t, size_t limit,
    void (*notify)(void), int dark, const int *font_fds, size_t font_count,
    int allow_diagrams, MdfBuiltinFont, int profile);
void mdf_image_worker_destroy(void *);
void mdf_image_worker_allow_diagrams(void *);
int mdf_image_worker_complete(void *);
int mdf_image_worker_join(void *);
int mdf_image_worker_pop(void *, struct MdfPreparedImage *);
uint64_t mdf_image_worker_first_diagram(void *);
#ifdef __cplusplus
}
#endif
