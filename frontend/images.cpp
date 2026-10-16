#include "images.hpp"
#include "diagrams.hpp"
#include "monospace.hpp"
#include <sys/mman.h>
#include <sys/stat.h>
#include <algorithm>

struct ImageWorker::Job {
  ImageWorker *owner;
  std::vector<EncodedImage> inputs;
  size_t limit;
  void (*notify)();
  bool dark;
  std::shared_ptr<PreparedFont> fonts;
};
namespace {
struct GateLock {
  pthread_mutex_t &mutex;
  explicit GateLock(pthread_mutex_t &value) : mutex(value) {
    if (pthread_mutex_lock(&mutex)) throw std::runtime_error("Cannot lock diagram presentation gate");
  }
  ~GateLock() { pthread_mutex_unlock(&mutex); }
};
}

ImageWorker::~ImageWorker() {
  reset();
  pthread_cond_destroy(&gate_changed);
  pthread_mutex_destroy(&gate_mutex);
}

void ImageWorker::reset() {
  {
    GateLock lock(gate_mutex);
    stop.store(true, std::memory_order_relaxed);
  }
  pthread_cond_broadcast(&gate_changed);
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  result.clear();
  failed = false;
  done.store(false, std::memory_order_relaxed);
  first_diagram_ns = 0;
}
void ImageWorker::start(uint64_t version, std::vector<EncodedImage> inputs, size_t limit,
                         void (*notify)(), bool dark, std::shared_ptr<PreparedFont> fonts,
                         bool allow_diagrams) {
  reset();
  revision = version;
  stop.store(false, std::memory_order_relaxed);
  diagrams_allowed = allow_diagrams;
  PROFILE_MARK("Request image decoding");
  auto *job = new Job{this, std::move(inputs), limit, notify, dark, std::move(fonts)};
  if (pthread_create(&thread, nullptr, run, job)) {
    delete job;
    throw std::runtime_error("Cannot start image decoding worker");
  }
  joinable = true;
}
void ImageWorker::allow_diagrams() {
  {
    GateLock lock(gate_mutex);
    diagrams_allowed = true;
  }
  pthread_cond_broadcast(&gate_changed);
}
void *ImageWorker::run(void *raw) {
    std::unique_ptr<Job> job(static_cast<Job *>(raw));
    auto &self = *job->owner;
    profile_track = 4; // profiling.Track.images; no FLTK calls on this worker.
    struct MappedFonts {
      std::vector<MdfFontData> buffers;
      ~MappedFonts() { for (auto &font : buffers) munmap(const_cast<unsigned char *>(font.data), font.length); }
    } mapped;
    try {
      PHASE("Prepare image and diagram pixels");
      // Finish ordinary decoding before waiting for the optional-module gate.
      for (const auto &input : job->inputs) {
        if (self.stop.load(std::memory_order_relaxed)) return nullptr;
        if (input.kind != EncodedImage::encoded || input.bytes.size() < 4) continue;
        auto pixels = std::make_unique<PixelBuffer>();
        {
          Phase decode(input.bytes[0] == 137 ? "Decode PNG pixels" : "Decode JPEG pixels", __FILE__, __LINE__);
          if (!mdf_decode_pixels(input.bytes.data(), input.bytes.size(), job->limit, &pixels->image)) continue;
        }
        self.result.push_back({input.index, std::move(pixels)});
      }
      const bool optional = std::any_of(job->inputs.begin(), job->inputs.end(),
          [](const auto &input) { return input.kind != EncodedImage::encoded; });
      if (optional) {
        GateLock lock(self.gate_mutex);
        if (!self.diagrams_allowed) {
          Phase wait("Wait for first Markdown viewport before diagram loading", __FILE__, __LINE__, true);
          while (!self.diagrams_allowed && !self.stop.load(std::memory_order_relaxed))
            if (pthread_cond_wait(&self.gate_changed, &self.gate_mutex))
              throw std::runtime_error("Cannot wait for the first Markdown viewport");
        }
        if (self.stop.load(std::memory_order_relaxed)) return nullptr;
      }
      if (job->fonts) {
        PHASE("Map prepared fallback fonts for diagram labels");
        for (size_t i = 0; i < job->fonts->sources.size(); ++i) {
          if (self.stop.load(std::memory_order_relaxed)) return nullptr;
          struct stat info{};
          const int fd = job->fonts->fds[i];
          if (fstat(fd, &info) || info.st_size <= 0) throw std::runtime_error("Cannot inspect prepared diagram font");
          void *data = mmap(nullptr, info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
          if (data == MAP_FAILED) throw std::runtime_error("Cannot map prepared diagram font");
          mapped.buffers.push_back({static_cast<const unsigned char *>(data), size_t(info.st_size)});
        }
      }
      for (const auto &input : job->inputs) {
        if (self.stop.load(std::memory_order_relaxed)) return nullptr;
        if (input.kind != EncodedImage::encoded) {
          Phase rendering(input.kind == EncodedImage::svg ? "Render SVG image" : "Render Mermaid diagram", __FILE__, __LINE__);
          PreparedImage prepared{input.index, std::make_unique<PixelBuffer>(), true};
          prepared.svg = input.kind == EncodedImage::svg;
          try {
            char error[512]{};
            const auto *fonts = input.fallback ? mapped.buffers.data() : nullptr;
            const auto font_count = input.fallback ? mapped.buffers.size() : 0;
            MdfSvgText generated{};
            struct SvgRelease { MdfSvgText &text; ~SvgRelease() { std::free(const_cast<unsigned char *>(text.data)); } } release{generated};
            const unsigned char *svg = input.bytes.data();
            size_t svg_length = input.bytes.size();
            if (!prepared.svg) {
              const auto *layout = diagram_renderer(self.stop, DiagramModule::mermaid);
              PHASE("Generate Mermaid SVG");
              if (!layout->mermaid_svg(svg, svg_length, job->dark, fonts, font_count, job->limit,
                                      &generated, error, sizeof(error))) {
                prepared.error = error[0] ? error : "Cannot lay out Mermaid diagram";
              } else { svg = generated.data; svg_length = generated.length; }
            }
            if (prepared.error.empty() && !self.stop.load(std::memory_order_relaxed) &&
                !diagram_renderer(self.stop, DiagramModule::svg)->svg(svg, svg_length, job->dark,
                                  fonts, font_count, job->limit,
                                  &prepared.pixels->image, &prepared.logical_width,
                                  &prepared.logical_height, error, sizeof(error)))
              prepared.error = error[0] ? error : "Cannot render diagram or SVG";
          } catch (const std::exception &failure) {
            if (self.stop.load(std::memory_order_relaxed)) return nullptr;
            prepared.error = failure.what();
          }
          self.result.push_back(std::move(prepared));
          if (!self.first_diagram_ns && self.result.back().pixels->image.data) {
            self.first_diagram_ns = mdf_now_ns();
            PROFILE_MARK("First diagram pixels ready");
          }
          continue;
        }
      }
      job->inputs.clear();
    } catch (...) {
      self.failed = true;
    }
    PROFILE_MARK("Images ready");
    self.done.store(true, std::memory_order_release);
    job->notify();
    return nullptr;
}
std::vector<PreparedImage> ImageWorker::take() {
  if (!complete()) return {};
  if (joinable) pthread_join(thread, nullptr);
  joinable = false;
  if (failed) throw std::runtime_error("Cannot prepare local image pixels");
  return std::move(result);
}
