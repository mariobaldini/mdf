#include "image-pixels.h"
#include <limits.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../zig-pkg/fltk/png/png.h"
#include "../zig-pkg/fltk/jpeg/jpeglib.h"

static int valid_size(size_t width, size_t height, size_t channels, size_t limit) {
  return width && height && width <= INT_MAX && height <= INT_MAX && channels && channels <= 4 &&
         width <= SIZE_MAX / channels && height <= SIZE_MAX / (width * channels) &&
         width * height * channels <= limit;
}

struct PngInput {
  const unsigned char *bytes;
  size_t length, offset;
  png_structp png;
  png_infop info;
  unsigned char *pixels;
  png_bytep *rows;
};
static void png_fail(png_structp png, png_const_charp message) {
  (void)message;
  png_longjmp(png, 1);
}
static void png_warn(png_structp png, png_const_charp message) {
  (void)png; (void)message;
}
static void png_read_memory(png_structp png, png_bytep output, png_size_t count) {
  struct PngInput *input = png_get_io_ptr(png);
  if (count > input->length - input->offset) png_error(png, "Truncated PNG");
  memcpy(output, input->bytes + input->offset, count);
  input->offset += count;
}
static int decode_png(const unsigned char *bytes, size_t length, size_t limit, struct MdfPixels *out) {
  /* Longjmp cleanup state lives on the heap; no C++ destructors are bypassed. */
  struct PngInput *input = calloc(1, sizeof(*input));
  if (!input) return 0;
  input->bytes = bytes; input->length = length;
  input->png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, png_fail, png_warn);
  if (!input->png) { free(input); return 0; }
  input->info = png_create_info_struct(input->png);
  if (!input->info || setjmp(png_jmpbuf(input->png))) {
    free(input->rows); free(input->pixels);
    png_destroy_read_struct(&input->png, &input->info, NULL);
    free(input); return 0;
  }
  png_set_read_fn(input->png, input, png_read_memory);
  png_read_info(input->png, input->info);
  /* Match FLTK's Linux transformations, including palette/tRNS and 16-bit
     stripping. Do not introduce gamma or colorspace changes. */
  int color = png_get_color_type(input->png, input->info);
  int bits = png_get_bit_depth(input->png, input->info);
  if (color == PNG_COLOR_TYPE_PALETTE) png_set_expand(input->png);
  if (bits < 8) { png_set_packing(input->png); png_set_expand(input->png); }
  else if (bits == 16) png_set_strip_16(input->png);
  if (png_get_valid(input->png, input->info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(input->png);
  int passes = png_set_interlace_handling(input->png);
  png_read_update_info(input->png, input->info);
  size_t width = png_get_image_width(input->png, input->info);
  size_t height = png_get_image_height(input->png, input->info);
  size_t channels = png_get_channels(input->png, input->info);
  if (!valid_size(width, height, channels, limit) || height > SIZE_MAX / sizeof(png_bytep) ||
      png_get_rowbytes(input->png, input->info) != width * channels)
    png_error(input->png, "Image too large");
  input->pixels = malloc(width * height * channels);
  input->rows = malloc(height * sizeof(png_bytep));
  if (!input->pixels || !input->rows) png_error(input->png, "Out of memory");
  for (size_t row = 0; row < height; ++row) input->rows[row] = input->pixels + row * width * channels;
  for (int pass = 0; pass < passes; ++pass) png_read_rows(input->png, input->rows, NULL, (png_uint_32)height);
  png_read_end(input->png, input->info);
  *out = (struct MdfPixels){input->pixels, (int)width, (int)height, (int)channels};
  free(input->rows);
  png_destroy_read_struct(&input->png, &input->info, NULL);
  free(input);
  return 1;
}

struct JpegInput {
  struct jpeg_decompress_struct decoder;
  struct jpeg_error_mgr error;
  jmp_buf jump;
  unsigned char *pixels;
};
static void jpeg_fail(j_common_ptr decoder) {
  struct JpegInput *input = (struct JpegInput *)decoder;
  longjmp(input->jump, 1);
}
static void jpeg_warn(j_common_ptr decoder) { (void)decoder; }
static int decode_jpeg(const unsigned char *bytes, size_t length, size_t limit, struct MdfPixels *out) {
  struct JpegInput *input = calloc(1, sizeof(*input));
  if (!input) return 0;
  input->decoder.err = jpeg_std_error(&input->error);
  input->error.error_exit = jpeg_fail;
  input->error.output_message = jpeg_warn;
  if (setjmp(input->jump)) {
    jpeg_destroy_decompress(&input->decoder);
    free(input->pixels); free(input); return 0;
  }
  jpeg_create_decompress(&input->decoder);
  jpeg_mem_src(&input->decoder, bytes, length);
  jpeg_read_header(&input->decoder, TRUE);
  input->decoder.quantize_colors = FALSE;
  input->decoder.out_color_space = JCS_RGB;
  input->decoder.out_color_components = 3;
  input->decoder.output_components = 3;
  jpeg_calc_output_dimensions(&input->decoder);
  size_t width = input->decoder.output_width, height = input->decoder.output_height;
  if (!valid_size(width, height, 3, limit)) jpeg_fail((j_common_ptr)&input->decoder);
  input->pixels = malloc(width * height * 3);
  if (!input->pixels) jpeg_fail((j_common_ptr)&input->decoder);
  jpeg_start_decompress(&input->decoder);
  while (input->decoder.output_scanline < input->decoder.output_height) {
    JSAMPROW row = input->pixels + input->decoder.output_scanline * width * 3;
    jpeg_read_scanlines(&input->decoder, &row, 1);
  }
  jpeg_finish_decompress(&input->decoder);
  jpeg_destroy_decompress(&input->decoder);
  *out = (struct MdfPixels){input->pixels, (int)width, (int)height, 3};
  free(input);
  return 1;
}

int mdf_decode_pixels(const unsigned char *bytes, size_t length, size_t limit, struct MdfPixels *out) {
  memset(out, 0, sizeof(*out));
  if (length >= 8 && !png_sig_cmp(bytes, 0, 8)) return decode_png(bytes, length, limit, out);
  if (length >= 4 && bytes[0] == 255 && bytes[1] == 216) return decode_jpeg(bytes, length, limit, out);
  return 0;
}
