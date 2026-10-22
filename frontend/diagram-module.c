#include "mermaid.h"

struct FontBuffer { const unsigned char *ptr; size_t len; };
static MdfBuiltinFont provider;

/* Resolve only the exact requested face. Loading an SVG module must not
   inflate italic faces or load Mermaid. The provider retains its data. */
struct FontBuffer mdf_builtin_font(uint32_t family, uint32_t style) {
  if (family || style >= 4 || !provider) return (struct FontBuffer){0};
  const struct MdfFontData font = provider(style);
  return (struct FontBuffer){font.data, font.length};
}
static int initialize(MdfBuiltinFont fonts) {
  if (!fonts || (provider && provider != fonts)) return 0;
  for (uint32_t style = 0; style < 2; ++style) {
    const struct MdfFontData font = fonts(style);
    if (!font.data || !font.length) return 0;
  }
  provider = fonts;
  return 1;
}
#if MDF_MODULE_KIND == MDF_MODULE_MERMAID
extern int mdf_mermaid_svg(const unsigned char *, size_t, int,
    const struct MdfFontData *, size_t, size_t, struct MdfSvgText *, char *, size_t);
#else
extern int mdf_render_svg(const unsigned char *, size_t, int,
    const struct MdfFontData *, size_t, size_t, struct MdfPixels *, float *, float *, char *, size_t, struct MdfSvgText *);
#endif
const struct MdfDiagramApi *mdf_diagram_api(uint32_t abi) {
  static const struct MdfDiagramApi api = {
    MDF_DIAGRAM_ABI, sizeof(struct MdfDiagramApi), MDF_MODULE_KIND, 0, initialize,
#if MDF_MODULE_KIND == MDF_MODULE_MERMAID
    mdf_mermaid_svg, 0
#else
    0, mdf_render_svg
#endif
  };
  return abi == MDF_DIAGRAM_ABI ? &api : NULL;
}
