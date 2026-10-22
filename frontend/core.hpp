#pragma once
#include "core-api.h"
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include "json.hpp"
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
template<class T> struct BorrowedArray {
  T *data = nullptr;
  size_t count = 0;
  bool empty() const { return count == 0; }
  size_t size() const { return count; }
  T &operator[](size_t index) const { return data[index]; }
  T &back() const { return data[count - 1]; }
  T *begin() const { return data; }
  T *end() const { return count ? data + count : data; }
};
inline Json take_json(Buffer b) {
  if (!b.ptr)
    return Json();
  struct Release {
    Buffer b;
    ~Release() { mdf_buffer_free(b); }
  } release{b};
  Json j = Json::parse(b.ptr, b.len);
  if (j.contains("err"))
    throw std::runtime_error(j.get("err").as<std::string>());
  return j;
}
struct Core {
  MdfCore *handle;
  MdfStartup *startup = nullptr;
  Core(bool profile, uint64_t origin, void (*notify)()) {
    const char *home = std::getenv("HOME");
    if (!home)
      home = "";
    handle = mdf_core_create((const unsigned char *)home, std::strlen(home),
                             profile, origin, notify);
    if (!handle)
      throw std::runtime_error("Could not start document loader");
  }
  Core(MdfStartup *prepared, void (*notify)()) : handle(prepared->core), startup(prepared) {
    if (!handle) throw std::runtime_error("Missing bootstrap document core");
    mdf_core_set_wake(handle, notify);
  }
  ~Core() {
    if (startup) mdf_core_set_wake(handle, nullptr);
    else mdf_core_destroy(handle);
  }
  Core(const Core &) = delete;
  void open(const std::string &path) {
    take_json(
        mdf_core_open(handle, (const unsigned char *)path.data(), path.size()));
  }
  Json poll() {
    if (startup && startup->document.ptr) {
      auto result = startup->document;
      startup->document = {};
      return take_json(result);
    }
    return take_json(mdf_core_poll(handle));
  }
  Json settings() { return take_json(mdf_core_settings(handle)); }
  void save(const Json &j) {
    auto bytes = j.dump();
    take_json(mdf_core_settings_update(
        handle, (const unsigned char *)bytes.data(), bytes.size()));
  }
  Json link(const std::string &url) {
    return take_json(
        mdf_core_link(handle, (const unsigned char *)url.data(), url.size()));
  }
  Json navigation() { return take_json(mdf_core_navigation(handle)); }
  void start_navigation(float width, float zoom, float advance) {
    if (!mdf_core_navigation_start(handle, width, zoom, advance))
      throw std::runtime_error("Cannot start navigation worker");
  }
  Buffer image(size_t i) { return mdf_core_image(handle, i); }
  Json profile() { return take_json(mdf_core_profile(handle)); }
};
inline bool profile_enabled = false;
inline thread_local size_t profile_depth = 0;
inline thread_local bool profile_gui_thread = false;
inline thread_local uint8_t profile_track = 0;
const char *profile_gui_wait_reason();
void profile_wait_details(Json &events, uint64_t origin);
struct Phase {
  const char *name;
  const char *file;
  uint32_t line;
  uint64_t start;
  uint64_t finished = 0;
  size_t depth;
  bool waiting;
  Phase(const char *n, const char *f, int l, bool waiting = false)
      : name(n), file(f), line(l), start(profile_enabled ? mdf_now_ns() : 0),
        depth(profile_depth), waiting(waiting) {
    if (start)
      ++profile_depth;
  }
  ~Phase() {
    if (start) {
      mdf_profile_event(profile_track, (const unsigned char *)name, std::strlen(name),
                        (const unsigned char *)file, std::strlen(file), line,
                        start, (finished ? finished : mdf_now_ns()) - start,
                        depth, waiting);
      --profile_depth;
    }
  }
};
#define MDF_JOIN_I(a, b) a##b
#define MDF_JOIN(a, b) MDF_JOIN_I(a, b)
#define PHASE(name) Phase MDF_JOIN(phase_, __LINE__)(name, __FILE__, __LINE__)
#define PROFILE_MARK(name) do { if (profile_enabled) mdf_profile_signal(profile_track, \
    (const unsigned char *)name, std::strlen(name), (const unsigned char *)__FILE__, \
    std::strlen(__FILE__), __LINE__, mdf_now_ns()); } while (0)
inline std::string text(const JsonView &j, const char *name, const char *def = "") {
  auto value = j.get(name);
  return value.is_string() ? value.as<std::string>() : def;
}
struct Span {
  std::string text, link;
  bool bold = false, italic = false, code = false, strike = false,
       underline = false, highlight = false, small = false;
};
struct Cell {
  std::vector<Span> spans;
  std::string align;
};
struct Block {
  std::string kind, prefix, language, anchor, alert, image_src;
  std::vector<Span> spans;
  std::vector<Cell> cells;
  std::vector<int> columns;
  int heading = 0, indent = 0, quote = 0, bytes = 0, lines = 1, parent = -1;
  bool details_open = false, alert_start = false, table_header = false,
       table_last = false, table_stripe = false;
  std::optional<bool> task;
  bool mermaid() const { return kind == "code" && language == "mermaid"; }
};
// The parser owns borrowed views until the next successful poll. Copy them
// directly into the reader model, without constructing an intermediate JSON
// DOM.
inline std::string view_text(Buffer v) {
  return v.len ? std::string(reinterpret_cast<const char *>(v.ptr), v.len) : "";
}
inline std::vector<Span> read_spans(Core &core, size_t block, ptrdiff_t cell,
                                    size_t count) {
  std::vector<Span> result;
  result.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    auto s = mdf_core_span(core.handle, block, cell, i);
    result.push_back({view_text(s.text), view_text(s.link), bool(s.flags & 1),
                      bool(s.flags & 2), bool(s.flags & 4), bool(s.flags & 8),
                      bool(s.flags & 16), bool(s.flags & 32),
                      bool(s.flags & 64)});
  }
  return result;
}
inline Block read_block(Core &core, size_t index) {
  auto v = mdf_core_block(core.handle, index);
  Block b;
  b.kind = view_text(v.kind);
  b.prefix = view_text(v.prefix);
  b.language = view_text(v.language);
  b.anchor = view_text(v.anchor);
  b.alert = view_text(v.alert);
  b.image_src = view_text(v.image_src);
  b.heading = v.heading;
  b.indent = v.indent;
  b.quote = v.quote;
  b.bytes = v.bytes;
  b.lines = v.lines;
  b.parent = v.parent;
  b.details_open = v.flags & 1;
  b.alert_start = v.flags & 2;
  b.table_header = v.flags & 4;
  b.table_last = v.flags & 8;
  b.table_stripe = v.flags & 16;
  if (v.task >= 0)
    b.task = v.task != 0;
  b.spans = read_spans(core, index, -1, v.spans);
  b.cells.reserve(v.cells);
  for (size_t i = 0; i < v.cells; ++i) {
    auto cell = mdf_core_cell(core.handle, index, i);
    b.cells.push_back({read_spans(core, index, i, cell.spans),
                       cell.alignment == 1   ? "center"
                       : cell.alignment == 2 ? "right"
                                             : "left"});
  }
  b.columns.reserve(v.columns);
  for (size_t i = 0; i < v.columns; ++i)
    b.columns.push_back(mdf_core_column(core.handle, index, i));
  return b;
}
struct Settings {
  bool save = false, dark = false, toc = true, preview = true, reload = true,
       maximized = false, line_wrap = true;
  std::string theme = "classic", width = "percent_80";
  int size = 12, window_w = 1040, window_h = 780;
  Settings() = default;
  int default_font_size() const {
    return int(mdf_theme_info(mdf_theme_index(reinterpret_cast<const unsigned char *>(theme.data()), theme.size())).font_size);
  }
  explicit Settings(const Json &j) {
    save = j.value("save_settings_across_sessions", false);
    dark = j.value("dark_mode", false);
    toc = j.value("show_toc", true);
    preview = j.value("show_preview", true);
    reload = j.value("auto_reload", true);
    line_wrap = j.value("line_wrap", true);
    theme = text(j, "theme", "classic");
    width = text(j, "max_width", "percent_80");
    size = j.value("font_size", 12);
    if (j.contains("window")) {
      auto w = j.get("window");
      window_w = w.value("width", 1040);
      window_h = w.value("height", 780);
      maximized = w.value("maximized", false);
    }
  }
  Json json() const {
    return {{"save_settings_across_sessions", save},
            {"dark_mode", dark},
            {"show_toc", toc},
            {"show_preview", preview},
            {"auto_reload", reload},
            {"theme", theme},
            {"font_size", size},
            {"max_width", width},
            {"line_wrap", line_wrap},
            {"window",
             {{"width", window_w},
              {"height", window_h},
              {"maximized", maximized}}}};
  }
};
