#pragma once
#include "../zig-pkg/fltk/jpeg/jpeglib.h"
#include <cmath>

// JPEG implementations can differ in IDCT rounding and chroma interpolation.
// Keep PNG exact; bound JPEG differences against the independent IJG decoder.
static bool same_pixels(const MdfPixels &image, const Fl_RGB_Image &reference,
                        bool lossless, const std::string &name) {
  if (reference.data_w() != image.width || reference.data_h() != image.height || reference.d() != image.channels)
    return false;
  const size_t count = size_t(image.width) * image.height * image.channels;
  if (lossless) return !std::memcmp(image.data, reference.array, count);
  uint64_t absolute = 0, squared = 0;
  for (size_t i = 0; i < count; ++i) {
    const int delta = int(image.data[i]) - reference.array[i];
    absolute += std::abs(delta);
    squared += delta * delta;
  }
  const double mean = double(absolute) / count;
  const double psnr = squared ? 10 * std::log10(255. * 255. * count / squared) : 100.;
  if (mean > 1. || psnr < 40.) {
    std::cerr << name << ": JPEG mean error " << mean << ", PSNR " << psnr << " dB\n";
    return false;
  }
  return true;
}

static void jpeg_fixtures() {
  for (bool gray : {false, true}) for (bool progressive : {false, true})
    for (int sampling : {0, 1, 2}) for (bool restart : {false, true}) {
      jpeg_compress_struct encoder{};
      jpeg_error_mgr error{};
      encoder.err = jpeg_std_error(&error);
      jpeg_create_compress(&encoder);
      unsigned char *encoded = nullptr;
      unsigned long length = 0;
      jpeg_mem_dest(&encoder, &encoded, &length);
      encoder.image_width = 35; encoder.image_height = 33;
      encoder.input_components = gray ? 1 : 3;
      encoder.in_color_space = gray ? JCS_GRAYSCALE : JCS_RGB;
      jpeg_set_defaults(&encoder);
      if (!gray) {
        encoder.comp_info[0].h_samp_factor = sampling ? 2 : 1;
        encoder.comp_info[0].v_samp_factor = sampling == 2 ? 2 : 1;
      }
      jpeg_set_quality(&encoder, 95, TRUE);
      if (progressive) jpeg_simple_progression(&encoder);
      encoder.restart_interval = restart ? 2 : 0;
      jpeg_start_compress(&encoder, TRUE);
      std::vector<unsigned char> row(35 * encoder.input_components);
      while (encoder.next_scanline < encoder.image_height) {
        for (unsigned x = 0; x < 35; ++x) for (int c = 0; c < encoder.input_components; ++c)
          row[x * encoder.input_components + c] = 20 + x * 2 + encoder.next_scanline * 2 + c * 9;
        JSAMPROW rows[] = {row.data()};
        jpeg_write_scanlines(&encoder, rows, 1);
      }
      jpeg_finish_compress(&encoder);
      jpeg_destroy_compress(&encoder);
      MdfPixels image{};
      assert(mdf_decode_pixels(encoded, length, SIZE_MAX, &image));
      Fl_JPEG_Image reference(nullptr, encoded, length);
      assert(same_pixels(image, reference, false, "generated JPEG"));
      std::free(image.data);
      assert(!mdf_decode_pixels(encoded, length, 35 * 33 * 3 - 1, &image) && !image.data);
      assert(!mdf_decode_pixels(encoded, 16, SIZE_MAX, &image) && !image.data);
      std::free(encoded);
    }
  std::cout << "PASS: baseline/progressive, grayscale, 4:4:4/4:2:2/4:2:0 and restart-marker JPEGs\n";
}
