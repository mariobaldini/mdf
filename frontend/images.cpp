#include "images.hpp"
#include "monospace.hpp"

ImageWorker::~ImageWorker() { reset(); }
void ImageWorker::reset() {
  mdf_image_worker_destroy(worker);
  worker = nullptr;
  sources.clear();
  fonts.reset();
  first_diagram_ns = 0;
}
void ImageWorker::start(uint64_t version, std::vector<EncodedImage> inputs, size_t limit,
                         void (*notify)(), bool dark, std::shared_ptr<PreparedFont> prepared_fonts,
                         bool allow_diagrams) {
  reset();
  revision = version;
  sources = std::move(inputs);
  fonts = std::move(prepared_fonts);
  std::vector<MdfImageInput> descriptors;
  descriptors.reserve(sources.size());
  for (const auto &input : sources)
    descriptors.push_back({input.index, uint32_t(input.kind), input.bytes.data(), input.bytes.size(), input.fallback});
  const auto provider = +[](uint32_t style) -> MdfFontData {
    const auto font = mdf_builtin_font(0, style);
    return {font.ptr, font.len};
  };
  PROFILE_MARK("Request image decoding");
  worker = mdf_image_worker_create(descriptors.data(), descriptors.size(), limit, notify, dark,
      fonts ? fonts->fds.data() : nullptr, fonts ? fonts->sources.size() : 0, allow_diagrams, provider, profile_enabled);
  if (!worker) throw std::runtime_error("Cannot start image decoding worker");
}
void ImageWorker::allow_diagrams() {
  if (worker) mdf_image_worker_allow_diagrams(worker);
}
bool ImageWorker::complete() const {
  if (!worker || !mdf_image_worker_complete(worker)) return false;
  first_diagram_ns = mdf_image_worker_first_diagram(worker);
  return true;
}
std::vector<PreparedImage> ImageWorker::take() {
  if (!complete()) return {};
  if (mdf_image_worker_join(worker) < 0) throw std::runtime_error("Cannot prepare local image pixels");
  sources.clear();
  fonts.reset();
  std::vector<PreparedImage> result;
  MdfPreparedImage item{};
  while (mdf_image_worker_pop(worker, &item)) {
    // Guard the transferred allocation before constructing the GUI owner.
    std::unique_ptr<unsigned char, decltype(&std::free)> transferred(item.pixels.data, std::free);
    std::unique_ptr<unsigned char, decltype(&std::free)> glyphs(const_cast<unsigned char *>(item.missing_glyphs.data), std::free);
    auto pixels = std::make_unique<PixelBuffer>();
    pixels->image = item.pixels;
    transferred.release();
    result.push_back({item.index, std::move(pixels), bool(item.diagram), item.logical_width,
                      item.logical_height, item.error, bool(item.svg)});
  }
  return result;
}
