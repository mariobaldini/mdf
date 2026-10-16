#pragma once
#include "core.hpp"
#include <atomic>
#include <fontconfig/fontconfig.h>
#include <memory>
#include <pango/pangocairo.h>
#include <pthread.h>
#include <unordered_map>
#include <string_view>

// Coverage is taken from the already registered embedded fonts; no lookup.
std::vector<FcChar32> missing_characters(std::string_view text, const FcCharSet *coverage);
bool needs_fallback(std::string_view text, const FcCharSet *coverage);

struct PreparedFont {
  FcConfig *config = nullptr;
  std::vector<int> fds;
  std::vector<std::string> sources;
  std::string family, error;
  size_t bytes = 0;
  bool monospace = true;
  std::vector<FcChar32> unresolved;
  ~PreparedFont();
  bool available() const { return config && !fds.empty() && !family.empty(); }
};
using PreparedMonospace = PreparedFont;

class MonospaceWorker {
  pthread_t thread{};
  bool joinable = false;
  std::atomic<bool> stop{false}, done{false};
  std::unique_ptr<PreparedMonospace> result;
  struct Job;
  static void *run(void *);
public:
  ~MonospaceWorker() { reset(); }
  void start(void (*notify)());
  void reset();
  bool complete() const { return done.load(std::memory_order_acquire); }
  std::unique_ptr<PreparedMonospace> take();
};

class FallbackWorker {
  pthread_t thread{};
  bool joinable = false;
  std::atomic<bool> stop{false}, done{false};
  std::unique_ptr<PreparedFont> result;
  struct Job;
  static void *run(void *);
public:
  ~FallbackWorker() { reset(); }
  void start(std::vector<FcChar32> characters, const std::vector<int> &bundled_fds, void (*notify)());
  void reset();
  bool complete() const { return done.load(std::memory_order_acquire); }
  std::unique_ptr<PreparedFont> take();
};

struct TextMetrics {
  float width = 0, height = 0, descent = 0;
};

// GUI-owned private Pango map for code or mixed Open Sans/fallback text.
class CodeFont {
  std::shared_ptr<PreparedFont> data;
  std::vector<std::shared_ptr<PreparedFont>> fallback_data;
  FcCharSet *coverage = nullptr;
  PangoFontMap *map = nullptr;
  PangoContext *context = nullptr;
  PangoLayout *layout = nullptr;
  PangoFontDescription *description = nullptr;
  int last_size = -1, last_style = -1;
  std::unordered_map<unsigned, TextMetrics> metric_cache;
  void configure(int size, int style);
  TextMetrics extents();
  void clear();
public:
  ~CodeFont() { clear(); }
  bool ready() const { return bool(data); }
  const PreparedFont *info() const { return data.get(); }
  std::shared_ptr<PreparedFont> resources() const { return data; }
  bool has_character(FcChar32 ch) const { return coverage && FcCharSetHasChar(coverage, ch); }
  void adopt(std::unique_ptr<PreparedFont> prepared);
  void add_fallback(const CodeFont &font);
  int unknown_glyphs(const std::string &text, int style = 0);
  TextMetrics measure(const char *text, size_t length, int size, int style);
  void draw(const char *text, size_t length, int size, int style, float x, float baseline);
};
