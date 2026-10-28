#pragma once
#include "core.hpp"
#include <atomic>
#include <memory>
extern "C" {
#include "image-pixels.h"
#include "image-worker.h"
}

struct PixelBuffer {
  MdfPixels image{};
  size_t bytes() const { return image.data ? size_t(image.width) * image.height * image.channels : 0; }
  ~PixelBuffer() { std::free(image.data); }
};
struct PreparedFont;
struct EncodedImage {
  int index;
  std::vector<unsigned char> bytes;
  enum Kind { encoded, mermaid, svg } kind = encoded;
  bool fallback = false;
};
struct PreparedImage {
  int index;
  std::unique_ptr<PixelBuffer> pixels;
  bool diagram = false;
  float logical_width = 0, logical_height = 0;
  std::string error;
  bool svg = false;
};
class ImageWorker {
  void *worker = nullptr;
  std::vector<EncodedImage> sources;
  std::shared_ptr<PreparedFont> fonts;
  size_t pending_limit = 0;
public:
  static constexpr size_t pending_budget = 8 * 1024 * 1024;
  uint64_t revision = 0;
  mutable uint64_t first_diagram_ns = 0;
  ~ImageWorker();
  void reset();
  void start(uint64_t revision, std::vector<EncodedImage> inputs, size_t limit,
             void (*notify)(), bool dark = false, std::shared_ptr<PreparedFont> fonts = {},
             bool allow_diagrams = true, size_t pending_limit = 0);
  void allow_diagrams();
  bool complete() const;
  size_t pending() const;
  std::vector<PreparedImage> take(bool all = true);
};
