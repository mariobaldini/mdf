#pragma once
#include "image-pixels.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/* Successful pixels and missing-glyph UTF-8 use malloc/free. The glyph output
   is optional and contains unique characters absent from rendered label runs. */
struct MdfFontData { const unsigned char *data; size_t length; };
typedef struct MdfFontData (*MdfBuiltinFont)(uint32_t style);
struct MdfSvgText { const unsigned char *data; size_t length; };
typedef int (*MdfGenerateSvg)(const unsigned char *source, size_t length, int dark,
                       const struct MdfFontData *fonts, size_t font_count,
                       size_t limit, struct MdfSvgText *out, char *error, size_t error_length);
typedef int (*MdfRenderDiagram)(const unsigned char *source, size_t length, int dark,
                       const struct MdfFontData *fonts, size_t font_count,
                       size_t limit, struct MdfPixels *out,
                       float *logical_width, float *logical_height,
                       char *error, size_t error_length, struct MdfSvgText *missing_glyphs);
#define MDF_DIAGRAM_ABI 3
#define MDF_MODULE_CONTAINER_ABI 2
#define MDF_MODULE_PAYLOAD_RAW 1u
#define MDF_MODULE_MERMAID 1
#define MDF_MODULE_SVG 2
/* Only this table crosses the private module boundary. The provider retains its
   immutable built-in views. Additional font views are borrowed for each render.
   Transferred pixels and glyph text use libc malloc/free. */
struct MdfDiagramApi {
  uint32_t abi, size, kind, reserved;
  int (*initialize)(MdfBuiltinFont);
  MdfGenerateSvg mermaid_svg;
  MdfRenderDiagram svg;
};
const struct MdfDiagramApi *mdf_diagram_api(uint32_t abi);
#ifdef __cplusplus
}
#endif
