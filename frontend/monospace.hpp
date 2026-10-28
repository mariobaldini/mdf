#pragma once
#include "core.hpp"
#include "font-worker.h"
#include "system-text.h"
#include <atomic>
#include <fontconfig/fontconfig.h>
#include <memory>
#include <pango/pangocairo.h>
#include <unordered_map>
#include <string_view>

// Coverage is taken from the already registered embedded fonts; no lookup.
std::vector<FcChar32> missing_characters(std::string_view text, const FcCharSet *coverage);
bool needs_fallback(std::string_view text, const FcCharSet *coverage);

struct PreparedFont {
  void *owner = nullptr;
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
  void *worker = nullptr;
public:
  ~MonospaceWorker() { reset(); }
  void start(void (*notify)());
  void reset();
  bool complete() const { return worker && mdf_font_worker_complete(worker); }
  std::unique_ptr<PreparedMonospace> take();
};

class FallbackWorker {
  void *worker = nullptr;
public:
  ~FallbackWorker() { reset(); }
  void start(std::vector<FcChar32> characters, const std::vector<int> &bundled_fds, void (*notify)());
  void reset();
  bool complete() const { return worker && mdf_font_worker_complete(worker); }
  std::unique_ptr<PreparedFont> take();
};

struct TextMetrics {
  float width = 0, height = 0, descent = 0;
};

// GUI-owned private Pango map for code or mixed Open Sans/fallback text.
class CodeFont {
  std::shared_ptr<PreparedFont> data;
  void *text = nullptr;
  void clear();
public:
  ~CodeFont() { clear(); }
  bool ready() const { return bool(data); }
  const PreparedFont *info() const { return data.get(); }
  std::shared_ptr<PreparedFont> resources() const { return data; }
  bool has_character(FcChar32 ch) const { return text && mdf_system_text_has_character(text, ch); }
  void adopt(std::unique_ptr<PreparedFont> prepared);
  void adopt(std::shared_ptr<PreparedFont> prepared);
  void add_fallback(const CodeFont &font);
  int unknown_glyphs(const std::string &text, int style = 0);
  TextMetrics measure(const char *text, size_t length, int size, int style);
  void draw(const char *text, size_t length, int size, int style, float x, float baseline);
};
