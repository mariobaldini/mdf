#pragma once
#include "core.hpp"
#include <atomic>
#include <memory>
#include <pthread.h>
extern "C" {
#include "image-pixels.h"
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
  pthread_t thread{};
  bool joinable = false;
  std::atomic<bool> stop{false}, done{false};
  std::vector<PreparedImage> result;
  bool failed = false;
  // Constant initialization avoids a condition-variable constructor on the
  // initial GUI path, including documents that never request diagrams.
  pthread_mutex_t gate_mutex = PTHREAD_MUTEX_INITIALIZER;
  pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
  bool diagrams_allowed = false;
  struct Job;
  static void *run(void *);
public:
  uint64_t revision = 0;
  uint64_t first_diagram_ns = 0; // Read only after complete() publishes results.
  ~ImageWorker();
  void reset();
  void start(uint64_t revision, std::vector<EncodedImage> inputs, size_t limit,
             void (*notify)(), bool dark = false, std::shared_ptr<PreparedFont> fonts = {},
             bool allow_diagrams = true);
  void allow_diagrams();
  bool complete() const { return done.load(std::memory_order_acquire); }
  std::vector<PreparedImage> take();
};
