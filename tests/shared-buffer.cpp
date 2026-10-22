#include "../zig-pkg/fltk/src/drivers/Wayland/Fl_Wayland_Graphics_Driver.H"
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>

int main() {
  using Driver = Fl_Wayland_Graphics_Driver;
  for (size_t bytes : {size_t(1), size_t(4096), size_t(4097), size_t(1040 * 780 * 4), size_t(20000000)}) {
    const auto pool = Driver::mdf_pool_size(bytes, true);
    assert(pool >= bytes && pool - bytes < 4096 && pool % 4096 == 0);
  }
  assert(Driver::mdf_pool_size(1040 * 780 * 4, true) < Driver::mdf_pool_size(1040 * 780 * 4, false));
  assert(Driver::mdf_pool_size(0, true) == 0);
  assert(Driver::mdf_pool_size(std::numeric_limits<size_t>::max(), true) == 0);
  const int width = 73, height = 41;
  const int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, width);
  std::vector<unsigned char> shared(size_t(stride) * height, 0xcc);
  Driver::wld_buffer buffer{};
  buffer.data = shared.data();
  buffer.mdf_shared_drawing = true;
  Driver::cairo_init(&buffer.draw_buffer, width, height, stride,
                     CAIRO_FORMAT_ARGB32, shared.data());
  assert(buffer.draw_buffer.buffer == shared.data());
  for (auto byte : shared)
    assert(byte == 0);
  cairo_set_source_rgb(buffer.draw_buffer.cairo_, 1, 0, 0);
  cairo_paint(buffer.draw_buffer.cairo_);
  cairo_surface_flush(cairo_get_target(buffer.draw_buffer.cairo_));
  const auto first_frame = shared;
  Driver::mdf_make_writable(&buffer); // Client still owns the buffer.
  assert(buffer.mdf_shared_drawing &&
         buffer.draw_buffer.buffer == shared.data());
  buffer.in_use = true; // The compositor owns the submitted image now.
  Driver::mdf_make_writable(&buffer);
  assert(!buffer.mdf_shared_drawing &&
         buffer.draw_buffer.buffer != shared.data());
  assert(!std::memcmp(buffer.draw_buffer.buffer, shared.data(), shared.size()));
  cairo_set_source_rgb(buffer.draw_buffer.cairo_, 0, 1, 0);
  cairo_paint(buffer.draw_buffer.cairo_);
  cairo_surface_flush(cairo_get_target(buffer.draw_buffer.cairo_));
  assert(shared == first_frame); // A repaint must not alter submitted pixels.
  assert(std::memcmp(buffer.draw_buffer.buffer, shared.data(), shared.size()));
  auto *private_pixels = buffer.draw_buffer.buffer;
  buffer.in_use = false;
  Driver::mdf_make_writable(&buffer);
  assert(buffer.draw_buffer.buffer == private_pixels);
  cairo_destroy(buffer.draw_buffer.cairo_);
  delete[] private_pixels;
  Driver::draw_buffer offscreen{};
  Driver::cairo_init(&offscreen, width, height, stride, CAIRO_FORMAT_ARGB32);
  assert(offscreen.buffer != shared.data());
  cairo_destroy(offscreen.cairo_);
  delete[] offscreen.buffer;
  std::cout << "PASS: shared first-frame drawing, initialized pixels, "
               "ownership handoff, private repaint and offscreen lifetime\n";
}
