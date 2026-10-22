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
public:
  uint64_t revision = 0;
  mutable uint64_t first_diagram_ns = 0;
  ~ImageWorker();
  void reset();
  void start(uint64_t revision, std::vector<EncodedImage> inputs, size_t limit,
             void (*notify)(), bool dark = false, std::shared_ptr<PreparedFont> fonts = {},
             bool allow_diagrams = true);
  void allow_diagrams();
  bool complete() const;
  std::vector<PreparedImage> take();
};
