#include "image-pixels.h"

const struct MdfImageApi *mdf_image_api(uint32_t abi) {
  static const struct MdfImageApi api = {
    MDF_IMAGE_ABI, sizeof(struct MdfImageApi), MDF_MODULE_IMAGE, 0,
    mdf_decode_pixels, mdf_encode_png
  };
  return abi == MDF_IMAGE_ABI ? &api : NULL;
}
