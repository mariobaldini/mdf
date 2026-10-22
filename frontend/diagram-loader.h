#pragma once
#include "mermaid.h"
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
const struct MdfDiagramApi *mdf_diagram_renderer(uint32_t, int (*)(const void *), const void *,
    MdfBuiltinFont, size_t, char *, size_t);
struct MdfDiagramStats { uint64_t ready_ns, packed, expanded; uint32_t flags; };
struct MdfDiagramStats mdf_diagram_stats(uint32_t);
bool mdf_svg_image(const unsigned char *, size_t);
#ifdef __cplusplus
}
#endif
