#include <cairo.h>
#include <cassert>
#include <cstdint>
#include <iostream>

#if MDF_BUNDLED_CAIRO
#if !CAIRO_HAS_IMAGE_SURFACE || !CAIRO_HAS_FT_FONT || !CAIRO_HAS_FC_FONT
#error "MDF requires Cairo image, FreeType and Fontconfig support"
#endif
#if defined(CAIRO_HAS_XLIB_SURFACE) || defined(CAIRO_HAS_XCB_SURFACE) || \
    defined(CAIRO_HAS_PDF_SURFACE) || defined(CAIRO_HAS_PS_SURFACE) || \
    defined(CAIRO_HAS_SVG_SURFACE) || defined(CAIRO_HAS_PNG_FUNCTIONS) || \
    defined(CAIRO_HAS_SCRIPT_SURFACE)
#error "Unused Cairo backends must stay disabled"
#endif
#endif

int main() {
  assert(cairo_version() == CAIRO_VERSION);
  auto *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 8, 8);
  auto *context = cairo_create(surface);
  cairo_set_source_rgb(context, 0, 0, 1);
  cairo_paint(context);
  cairo_save(context);
  cairo_rectangle(context, 2, 2, 4, 4);
  cairo_clip(context);
  cairo_set_source_rgb(context, 1, 0, 0);
  cairo_paint(context);
  cairo_restore(context);
  cairo_surface_flush(surface);
  const auto *pixels = reinterpret_cast<const uint32_t *>(cairo_image_surface_get_data(surface));
  const int stride = cairo_image_surface_get_stride(surface) / sizeof(uint32_t);
  for (int y = 0; y < 8; ++y) for (int x = 0; x < 8; ++x)
    assert(pixels[y * stride + x] == (x >= 2 && x < 6 && y >= 2 && y < 6 ? 0xffff0000u : 0xff0000ffu));
  cairo_set_source_rgba(context, 1, 0, 0, .5);
  cairo_rectangle(context, 0, 0, 1, 1);
  cairo_fill(context);
  cairo_surface_flush(surface);
  assert(pixels[0] == 0xff80007fu);
  cairo_save(context);
  cairo_translate(context, 4, 4);
  cairo_scale(context, 2, 2);
  cairo_push_group(context);
  cairo_set_source_rgb(context, 0, 1, 0);
  cairo_rectangle(context, 0, 0, 1, 1);
  cairo_fill(context);
  cairo_pop_group_to_source(context);
  cairo_paint(context);
  cairo_restore(context);
  cairo_surface_flush(surface);
  assert(pixels[4 * stride + 4] == 0xff00ff00u && pixels[5 * stride + 5] == 0xff00ff00u);
  assert(pixels[3 * stride + 3] == 0xffff0000u && pixels[6 * stride + 6] == 0xff0000ffu);
  assert(cairo_status(context) == CAIRO_STATUS_SUCCESS && cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS);
  cairo_destroy(context);
  cairo_surface_destroy(surface);
  std::cout << "PASS: Cairo backend contract, clipping, alpha composition, transforms and group surfaces\n";
}
