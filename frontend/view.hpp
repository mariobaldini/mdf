#pragma once
#include "core.hpp"
#include "images.hpp"
#include "monospace.hpp"
#include "body-fonts.h"
#include "text-boundaries.hpp"
#include <FL/Fl_RGB_Image.H>
#include <FL/Fl_Scrollbar.H>
#include <FL/Fl_Widget.H>
#include <FL/fl_draw.H>
#include <algorithm>
#include <array>
#include <cmath>
#include <fontconfig/fontconfig.h>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <string_view>
#include <pango/pangocairo.h>
#include <pango/pangofc-fontmap.h>
#include <unordered_map>

struct Palette {
  Fl_Color bg, fg, panel, border, link, muted, selection;
  Fl_Color highlight, note, tip, important, warning, caution;
  static Palette get(const Settings &s);
};
struct FontStore {
  void *owner = nullptr;
  FcConfig *config = nullptr;
  FcCharSet *coverage = nullptr;
  uint32_t styles = 0;
  bool adopted = false;
  std::vector<int> fds;
  FontStore() = default;
  FontStore(const FontStore &) = delete;
  ~FontStore();
  void prepare();
  void adopt();
  void ensure_styles(uint32_t required);
  void add(Buffer bytes, uint32_t style);
  void add_fallback(const CodeFont &font);
};
struct Style {
  Fl_Font face;
  int size;
  bool strike = false, underline = false, code = false, highlight = false;
  std::string link;
  int color_role = 0;
  bool monospace = false;
};
struct Run {
  std::string text;
  Style style;
  float x = 0, y = 0, w = 0, h = 0;
  size_t pos = std::numeric_limits<size_t>::max();
  float font_height = 0, font_descent = 0;
};
struct Rect {
  float x, y, w, h;
  int role;
};
struct Measured {
  float height = 0;
  float right = 0;
  std::vector<Run> runs;
  std::vector<Rect> rects;
  bool image = false;
  float ix = 0, iy = 0, iw = 0, ih = 0;
};
struct Flow {
  std::vector<Run> runs;
  float height = 0, right = 0;
};
struct Hit {
  size_t pos;
  std::string link;
  int block;
};
class DocumentView : public Fl_Widget {
  MdfCore *model = nullptr;
  struct ViewportOwner {
    MdfViewport *handle;
    MdfViewportFields *fields;
    ViewportOwner() : handle(mdf_viewport_create()) {
      if (!handle) throw std::bad_alloc();
      fields = mdf_viewport_fields(handle);
    }
    ~ViewportOwner() { mdf_viewport_destroy(handle); }
    ViewportOwner(const ViewportOwner &) = delete;
  } geometry;
  void borrow_geometry();
public:
  Settings settings;
  Palette palette;
  std::vector<Block> blocks;
  BorrowedArray<float> heights;
  BorrowedArray<const float> offsets;
  std::vector<size_t> starts;
  std::string_view plain;
  std::string path;
  uint64_t revision = 0, &geometry_revision, preview_revision = 0;
  uint64_t paints = 0;
  float &scroll, &horizontal_scroll, &content_width, &margin, &horizontal_extent;
  bool &horizontal_dirty;
  std::optional<std::pair<size_t, size_t>> selection;
  std::optional<Hit> pressed;
  float press_x = 0, press_y = 0;
  bool dragging = false;
  std::unordered_map<int, Measured> cache;
  mutable std::unordered_map<int, std::vector<float>> table_widths;
  struct FontMeasurements {
    float height, descent;
    std::unordered_map<std::string, float> widths;
  };
  // Font measurements survive width and color changes. Font/scale adoption
  // invalidates them separately from width-dependent block and table geometry.
  mutable std::map<std::pair<Fl_Font, int>, FontMeasurements> text_measurements;
  mutable size_t cached_words = 0;
  mutable uint64_t measurement_hits = 0, measurement_misses = 0, layout_builds = 0;
  uint64_t layout_invalidations = 0, font_invalidations = 0;
  mutable TextBoundaries hit_boundaries;
  mutable int hit_boundary_block = -1;
  mutable CodeFont code_font;
  mutable CodeFont fallback_font;
  const FcCharSet *bundled_coverage = nullptr;
  std::vector<FcChar32> required_glyphs;
  bool has_code = false;
  // Declare owners first so images (and their GUI caches) die before pixels.
  std::unordered_map<int, std::unique_ptr<PixelBuffer>> image_pixels;
  std::unordered_map<int, std::unique_ptr<Fl_RGB_Image>> images;
  struct RasterState { int width, height; size_t bytes; uint64_t used; bool failed = false; };
  std::unordered_map<int, RasterState> rasters;
  static constexpr size_t raster_budget = 32 * 1024 * 1024;
  size_t raster_bytes = 0;
  uint64_t raster_clock = 0;
  uint64_t raster_cache_miss_paints = 0, raster_reload_failures = 0;
  void adopt_raster(int index, std::unique_ptr<PixelBuffer> pixels);
  std::vector<int> wanted_rasters() const;
  bool visible_rasters_missing() const;
  void trim_rasters();
  std::unordered_map<int, std::pair<float, float>> diagram_sizes;
  std::unordered_map<int, std::string> diagram_errors;
  bool has_diagrams = false;
  struct DiagramState { float zoom = 1; bool fit = false; };
  struct DiagramBox { float x, y, w, h; };
  struct DiagramControls { std::array<DiagramBox, 4> boxes; float height; };
  std::unordered_map<int, DiagramState> diagram_states;
  std::optional<int> diagram_focus;
  bool diagram_control = false;
  std::optional<std::pair<float, float>> diagram_drag;
  DiagramControls diagram_controls(int index, float top) const;
  float diagram_scale(int index) const;
  void zoom_diagram(int index, int action);
  std::optional<std::pair<int, int>> diagram_hit(float px, float py) const;
  std::vector<std::vector<std::string>> preview;
  std::function<void()> changed;
  std::function<void(const std::string &)> follow;
  DocumentView(int x, int y, int w, int h, const Settings &s);
  void document(const Json &doc, Core &core, FontStore &fonts);
  void configure(const Settings &s);
  void adopt_code_font(std::unique_ptr<PreparedMonospace> font);
  void adopt_fallback_font(std::unique_ptr<PreparedFont> font);
  void reflow_fonts(bool fallback);
  bool visible(int index) const;
  int index_at(float y) const;
  float total() const { return mdf_viewport_total(geometry.handle); }
  float max_scroll() const { return std::max(0.f, total() - h()); }
  float horizontal_total() const;
  float max_horizontal_scroll() const { return std::max(0.f, horizontal_total() - w()); }
  float zoom() const { return settings.size / 12.f; }
  float body_size() const { return settings.size * 1.4f; }
  float character_width() const;
  void invalidate();
  void invalidate_fonts();
  void invalidate_visibility(int first, int end);
  void reindex();
  void prepare_visible();
  void jump(int index);
  void toggle(int index);
  void move_scroll(float value);
  void move_horizontal(float value);
  std::optional<Hit> hit(float x, float y) const;
  Fl_Cursor hover_cursor(float x, float y) const;
  std::string selected() const;
  void select_word(size_t pos);
  void select_all();
  void pointer(int kind, float x, float y);
  void resize(int x, int y, int w, int h) override;
  int handle(int event) override;
  void draw() override;
  Measured measure(int index, bool collect_runs = true) const;
  Measured measure_reference(int index, bool collect_runs) const;
  const std::vector<float> &table_columns(int index, float width) const;
  Style style(const Span &s, const Block &b) const;
  TextMetrics text_metrics(const Style &style, const char *text, size_t length) const;
  float prefix_width(const Run &run, size_t length) const;
  Flow
  flow(const std::vector<Span> &spans, const Block &b, float x, float y,
       float width, int size, size_t pos,
       const std::string &align = "left", bool collect_runs = true) const;
  float estimate(int index) const;
  Fl_Color role(int r) const;
  Fl_Color text_color(const Style &s) const;
};
class Minimap : public Fl_Widget {
  DocumentView &doc;
  Fl_Scrollbar &scrollbar;
  bool dragging = false;
  float grab = 0;
  std::unique_ptr<Fl_RGB_Image> cached, overlay;
  struct PreviewLine {
    int block, line, slot;
  };
  std::unique_ptr<Fl_RGB_Image> text_atlas;
  std::vector<PreviewLine> atlas_lines;
  uint64_t atlas_revision = std::numeric_limits<uint64_t>::max();
  Fl_Color atlas_bg = 0, atlas_fg = 0;
  int atlas_font_size = 0, atlas_w = 0, atlas_limit = 0, slot_height = 0,
      atlas_baseline = 0;
  uint64_t cached_revision = std::numeric_limits<uint64_t>::max();
  int cached_w = 0, cached_h = 0, overlay_h = 0;
  Fl_Color overlay_color = 0;

public:
  uint64_t atlas_builds = 0, layout_builds = 0;
  Minimap(int x, int y, int w, int h, DocumentView &doc,
          Fl_Scrollbar &scrollbar)
      : Fl_Widget(x, y, w, h), doc(doc), scrollbar(scrollbar) {}
  int thumb_height() const;
  int thumb_top() const;
  void draw() override;
  int handle(int e) override;
  void navigate(int kind, float y);
};
