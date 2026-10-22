#include "view.hpp"
#include "bundled-fonts.hpp"
#include <FL/Fl.H>
#include <FL/Fl_Image_Surface.H>
#include <FL/platform.H>
#include <cctype>
#include <cstdio>
#include <unistd.h>

namespace {
struct LayoutMeasurements {
  const DocumentView *view;
  int face = -1, size = -1;
  std::exception_ptr failed;
  static MdfFlowMetrics measure(void *opaque, MdfLayoutFont font, const unsigned char *text, size_t len) noexcept {
    auto &ctx = *static_cast<LayoutMeasurements *>(opaque);
    try {
      const auto face = FL_FREE_FONT + int(font.face);
      if (ctx.face != face || ctx.size != font.size) {
        fl_font(face, font.size);
        ctx.face = face; ctx.size = font.size;
      }
      if (font.flags & 2) return {float(fl_width(reinterpret_cast<const char *>(text), len)), float(fl_height()), float(fl_descent())};
      Style style{};
      style.face = face; style.size = font.size; style.monospace = font.flags & 1;
      const auto metrics = ctx.view->text_metrics(style, reinterpret_cast<const char *>(text), len);
      return {metrics.width, metrics.height, metrics.descent};
    } catch (...) {
      ctx.failed = std::current_exception();
      return {std::numeric_limits<float>::quiet_NaN(), 0, 0};
    }
  }
  static const float *columns(void *opaque, size_t index, float width, size_t *count) noexcept {
    auto &ctx = *static_cast<LayoutMeasurements *>(opaque);
    try {
      const auto &values = ctx.view->table_columns(int(index), width);
      // Intrinsic measurement uses another context and can change FLTK's
      // current face. The next run must select its own font again.
      ctx.face = ctx.size = -1;
      *count = values.size();
      return values.data();
    } catch (...) {
      ctx.face = ctx.size = -1;
      ctx.failed = std::current_exception();
      *count = 0;
      return nullptr;
    }
  }

};
}

static Fl_Color rgb(unsigned c) {
  return fl_rgb_color(c >> 16, (c >> 8) & 255, c & 255);
}
Palette Palette::get(const Settings &s) {
  const auto p = mdf_theme_palette(mdf_theme_index(reinterpret_cast<const unsigned char *>(s.theme.data()), s.theme.size()), s.dark);
  return {rgb(p.bg), rgb(p.fg), rgb(p.panel), rgb(p.border), rgb(p.link), rgb(p.muted),
          rgb(p.selection), rgb(p.highlight), rgb(p.note), rgb(p.tip), rgb(p.important), rgb(p.warning), rgb(p.caution)};
}
FontStore::~FontStore() { mdf_body_fonts_destroy(owner); }
void FontStore::prepare() {
  PHASE("Prepare bundled Open Sans");
  {
    PHASE("Create private Fontconfig configuration");
    owner = mdf_body_fonts_create();
    if (!owner) throw std::runtime_error("Cannot create private font configuration");
  }
  fds.reserve(4);
  for (unsigned style = 0; style < 2; ++style) add(bundled_font(style), style);
}
void FontStore::ensure_styles(uint32_t required) {
  const uint32_t added = required & ~styles & 12;
  if (!added) return;
  PHASE("Prepare required Open Sans italic faces");
  for (unsigned style = 2; style < 4; ++style) if (added & (1u << style)) {
    add(bundled_font(style), style);
  }
  if (adopted) {
    mdf_body_fonts_refresh_default();
    const char *names[] = {"Open Sans", "Open Sans Bold", "Open Sans Italic", "Open Sans Bold Italic"};
    for (int i = 0; i < FL_FREE_FONT + 4; ++i) if (added & (1u << (i % 4))) {
      Fl::set_font(i, "");
      Fl::set_font(i, names[i % 4]);
    }
  }
}
void FontStore::add_fallback(const CodeFont &font) {
  PHASE("Publish selected fallback fonts for native labels");
  char error[512]{};
  if (!mdf_body_fonts_add_fallback(owner, font.resources()->owner, error, sizeof error))
    throw std::runtime_error(error[0] ? error : "Cannot publish document fallback font");
  mdf_body_fonts_refresh_default();
  // FLTK caches single-character advances outside Pango. Discard the old
  // descriptors so headings/TOC/minimap cannot retain missing-glyph widths.
  const char *names[] = {"Open Sans", "Open Sans Bold", "Open Sans Italic", "Open Sans Bold Italic"};
  for (int i = 0; i < FL_FREE_FONT + 4; ++i) {
    Fl::set_font(i, "");
    Fl::set_font(i, names[i % 4]);
  }
}
void FontStore::adopt() {
  {
    // Publish before Pango or Fl::set_font can initialize the system config.
    PHASE("Publish private Fontconfig configuration");
    if (!owner || !mdf_body_fonts_activate(owner))
      throw std::runtime_error(
          "Cannot activate bundled Open Sans configuration");
  }
  {
    PHASE("Adopt Fontconfig configuration in Pango");
    if (!mdf_body_fonts_adopt_default(owner))
      throw std::runtime_error("Pango Fontconfig backend unavailable");
  }
  {
    // Fl::set_font otherwise opens the display implicitly, hiding this cost.
    PHASE("Initialize Wayland display");
    fl_open_display();
  }
  {
    PHASE("Register FLTK font names");
    const char *names[] = {"Open Sans", "Open Sans Bold", "Open Sans Italic",
                           "Open Sans Bold Italic"};
    for (int i = 0; i < 4; ++i)
      Fl::set_font(FL_FREE_FONT + i, names[i]);
    // Native dialogs and menus can use FLTK's built-in font slots as well.
    for (int i = 0; i < FL_FREE_FONT; ++i)
      Fl::set_font(i, names[i % 4]);
  }
  adopted = true;
}
void FontStore::add(Buffer bytes, uint32_t style) {
  if (!bytes.ptr || !bytes.len) throw std::runtime_error("Embedded Open Sans face unavailable");
  char error[512]{};
  if (!mdf_body_fonts_add(owner, style, bytes.ptr, bytes.len, profile_enabled, profile_depth, error, sizeof error))
    throw std::runtime_error(error[0] ? error : "Cannot prepare embedded Open Sans data");
  const auto view = mdf_body_fonts_view(owner);
  config = static_cast<FcConfig *>(view.config);
  coverage = static_cast<FcCharSet *>(view.coverage);
  fds.assign(view.fds, view.fds + view.count);
  styles = view.styles;
}

DocumentView::DocumentView(int X, int Y, int W, int H, const Settings &s)
    : Fl_Widget(X, Y, W, H), settings(s), palette(Palette::get(s)),
      geometry_revision(geometry.fields->geometry_revision), scroll(geometry.fields->scroll),
      horizontal_scroll(geometry.fields->horizontal_scroll), content_width(geometry.fields->content_width),
      margin(geometry.fields->margin), horizontal_extent(geometry.fields->horizontal_extent),
      horizontal_dirty(geometry.fields->horizontal_dirty) {}
float DocumentView::character_width() const {
  fl_font(FL_FREE_FONT, body_size());
  return fl_width("m");
}
void DocumentView::document(const Json &j, Core &core, FontStore &fonts) {
  model = core.handle;
  int anchor = index_at(scroll);
  float delta = scroll - (offsets.empty() ? 0 : offsets[anchor]);
  bool automatic = j.value("automatic", false);
  blocks.clear();
  starts.clear();
  plain = {};
  images.clear();
  image_pixels.clear();
  diagram_sizes.clear();
  diagram_errors.clear();
  diagram_states.clear();
  diagram_focus.reset();
  diagram_drag.reset();
  diagram_control = false;
  has_diagrams = false;
  has_code = false;
  cache.clear();
  preview.clear();
  ++preview_revision;
  selection.reset();
  revision = j.value("revision", 0ull);
  path = text(j, "path");
  const size_t count = j.value("block_count", size_t(0));
  blocks.reserve(count);
  const auto projection = mdf_core_document_text(core.handle);
  if (projection.count != count) throw std::runtime_error("Inconsistent document text projection");
  plain = projection.text.len ? std::string_view(reinterpret_cast<const char *>(projection.text.ptr), projection.text.len) : std::string_view{};
  if (count) starts.assign(projection.starts, projection.starts + count);
  has_code = projection.flags & 1;
  has_diagrams = projection.flags & 2;
  for (size_t i = 0; i < count; ++i) blocks.push_back(read_block(core, i));
  // Parsed spans cover nested emphasis, HTML, and table headers. Adopt final
  // faces before invalidate() can measure any document block.
  fonts.ensure_styles(projection.styles);
  {
    PHASE("Check document against bundled glyph coverage");
    required_glyphs = missing_characters(plain, bundled_coverage);
  }
  scroll = 0;
  if (!automatic) horizontal_scroll = 0;
  invalidate();
  if (automatic && !blocks.empty())
    scroll = offsets[std::min(anchor, (int)blocks.size() - 1)] + delta;
  redraw();
}
void DocumentView::adopt_code_font(std::unique_ptr<PreparedMonospace> font) {
  PHASE("Adopt system monospace and reflow code");
  code_font.adopt(std::move(font));
  if (fallback_font.ready()) code_font.add_fallback(fallback_font);
  reflow_fonts(false);
}
void DocumentView::adopt_fallback_font(std::unique_ptr<PreparedFont> font) {
  PHASE("Adopt system Sans fallback and reflow missing glyphs");
  fallback_font.adopt(std::move(font));
  if (code_font.ready()) code_font.add_fallback(fallback_font);
  reflow_fonts(true);
}
void DocumentView::reflow_fonts(bool fallback) {
  text_measurements.clear();
  cached_words = 0;
  horizontal_dirty = true;
  const int anchor = index_at(scroll);
  const float delta = scroll - (offsets.empty() ? 0 : offsets[anchor]);
  auto inline_code = [](const std::vector<Span> &spans) {
    return std::any_of(spans.begin(), spans.end(), [](const Span &span) { return span.code; });
  };
  for (int i = 0; i < (int)blocks.size(); ++i) {
    const auto &block = blocks[i];
    bool affected = (block.kind == "code" && (!block.mermaid() || diagram_errors.count(i))) || inline_code(block.spans);
    for (const auto &cell : block.cells) affected = affected || inline_code(cell.spans);
    if (fallback) {
      affected = needs_fallback(block.prefix, bundled_coverage);
      for (const auto &span : block.spans) affected = affected || needs_fallback(span.text, bundled_coverage);
      for (const auto &cell : block.cells) for (const auto &span : cell.spans)
        affected = affected || needs_fallback(span.text, bundled_coverage);
    }
    if (!affected) continue;
    int first = i, end = i + 1;
    if (block.kind == "table_row") {
      while (first > 0 && !blocks[first].table_header && blocks[first - 1].kind == "table_row") --first;
      while (end < (int)blocks.size() && blocks[end].kind == "table_row" && !blocks[end].table_header) ++end;
      table_widths.erase(first);
    }
    for (int row = first; row < end; ++row) {
      cache.erase(row);
      heights[row] = estimate(row);
    }
    i = end - 1;
  }
  reindex();
  if (fallback) ++preview_revision;
  scroll = offsets.empty() ? 0 : offsets[std::min(anchor, (int)blocks.size())] + delta;
  scroll = std::clamp(scroll, 0.f, max_scroll());
  redraw();
}
void DocumentView::configure(const Settings &s) {
  bool layout = settings.size != s.size || settings.width != s.width || settings.line_wrap != s.line_wrap;
  bool colors = settings.dark != s.dark || settings.theme != s.theme;
  settings = s;
  palette = Palette::get(s);
  ++geometry_revision;
  if (layout)
    invalidate();
  else if (colors)
    cache.clear();
  redraw();
}
bool DocumentView::visible(int index) const {
  int parent = blocks[index].parent;
  size_t limit = blocks.size();
  while (parent >= 0) {
    if (!limit-- || parent >= (int)blocks.size() ||
        !blocks[parent].details_open)
      return false;
    parent = blocks[parent].parent;
  }
  return true;
}
int DocumentView::index_at(float y) const {
  return int(mdf_viewport_index_at(geometry.handle, y, blocks.size()));
}
void DocumentView::borrow_geometry() {
  const auto view = mdf_viewport_view(geometry.handle);
  heights = {view.heights, view.count};
  offsets = {view.offsets, view.offset_count};
}
void DocumentView::reindex() {
  if (!mdf_viewport_reindex(geometry.handle)) throw std::bad_alloc();
  borrow_geometry();
}
void DocumentView::invalidate() {
  text_measurements.clear();
  cached_words = 0;
  int anchor = index_at(scroll);
  float delta = scroll - (offsets.empty() ? 0 : offsets[anchor]);
  const uint32_t mode = settings.width == "characters_100" ? 0 : settings.width == "percent_100" ? 2 : 1;
  mdf_viewport_configure(geometry.handle, w(), mode, mode == 0 ? character_width() : 0, settings.line_wrap);
  cache.clear();
  table_widths.clear();
  if (!mdf_viewport_resize(geometry.handle, blocks.size())) throw std::bad_alloc();
  borrow_geometry();
  for (int i = 0; i < (int)blocks.size(); ++i)
    heights[i] = estimate(i);
  reindex();
  scroll = offsets.empty()
               ? 0
               : offsets[std::min(anchor, (int)blocks.size())] + delta;
  scroll = std::clamp(scroll, 0.f, max_scroll());
}
Style DocumentView::style(const Span &s, const Block &b) const {
  const uint32_t flags = uint32_t(s.bold) | uint32_t(s.italic) << 1 | uint32_t(s.small) << 6;
  const auto numeric = mdf_text_style(b.kind == "heading" ? 1 : b.kind == "code" ? 2 : 0,
                                      b.heading, flags, b.table_header, zoom());
  return {FL_FREE_FONT + int(numeric.face), numeric.size,
          s.strike,
          s.underline,
          s.code,
          s.highlight,
          s.link,
          s.link.empty() ? palette.fg : palette.link,
          code_font.ready() && (b.kind == "code" || s.code)};
}
TextMetrics DocumentView::text_metrics(const Style &s, const char *text, size_t length) const {
  if (s.monospace) return code_font.measure(text, length, s.size, (s.face - FL_FREE_FONT) & 3);
  if (fallback_font.ready() && needs_fallback({text, length}, bundled_coverage))
    return fallback_font.measure(text, length, s.size, (s.face - FL_FREE_FONT) & 3);
  const auto key = std::make_pair(s.face, s.size);
  auto font = text_measurements.find(key);
  if (font == text_measurements.end())
    font = text_measurements.emplace(key, FontMeasurements{float(fl_height()), float(fl_descent()), {}}).first;
  auto &metrics = font->second;
  float width = 0;
  if (length) {
    if (length <= 128) {
      std::string word(text, length);
      auto found = metrics.widths.find(word);
      if (found != metrics.widths.end()) width = found->second;
      else {
        width = float(fl_width(text, length));
        if (cached_words < 2048) {
          metrics.widths.emplace(std::move(word), width);
          ++cached_words;
        }
      }
    } else width = float(fl_width(text, length));
  }
  return {width, metrics.height, metrics.descent};
}
float DocumentView::prefix_width(const Run &run, size_t length) const {
  if (run.style.monospace && run.text == "\t") return length ? run.w : 0;
  return text_metrics(run.style, run.text.data(), length).width;
}
float DocumentView::estimate(int index) const {
  if (!visible(index))
    return 0;
  auto &b = blocks[index];
  return mdf_estimate_block(b.kind == "rule" ? 3 : b.kind == "heading" ? 1 : 0,
      b.bytes, b.lines, b.indent, b.quote, style(Span{}, b).size, zoom(), content_width, settings.line_wrap);
}
static size_t utf8_len(unsigned char c) {
  return c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
}
Flow
DocumentView::flow(const std::vector<Span> &ss, const Block &b, float left,
                   float top, float width, int sz, size_t start,
                   const std::string &align, bool collect_runs) const {
  std::vector<Style> styles;
  std::vector<MdfFlowSpan> spans;
  styles.reserve(ss.size());
  spans.reserve(ss.size());
  for (const auto &span : ss) {
    auto st = style(span, b);
    st.size = std::max(1, int(sz * (span.small ? .8f : 1)));
    spans.push_back({reinterpret_cast<const unsigned char *>(span.text.data()),
                     span.text.size(), uint32_t(st.monospace)});
    styles.push_back(std::move(st));
  }
  struct Context {
    const DocumentView *view;
    const std::vector<Style> *styles;
    size_t current = std::numeric_limits<size_t>::max();
    std::exception_ptr failed;
  } context{this, &styles};
  auto measure = [](void *opaque, size_t span, const unsigned char *text, size_t len) noexcept -> MdfFlowMetrics {
    auto &ctx = *static_cast<Context *>(opaque);
    try {
      const auto &st = (*ctx.styles)[span];
      if (ctx.current != span) {
        fl_font(st.face, st.size);
        ctx.current = span;
      }
      const auto metrics = ctx.view->text_metrics(st, reinterpret_cast<const char *>(text), len);
      return {metrics.width, metrics.height, metrics.descent};
    } catch (...) {
      ctx.failed = std::current_exception();
      return {std::numeric_limits<float>::quiet_NaN(), 0, 0};
    }
  };
  const MdfFlowSpec spec{left, top, width, sz, start,
    align == "right" ? 2u : align == "center" ? 1u : 0u,
    uint32_t(settings.line_wrap) | (b.kind == "code" ? 2u : 0u) | (collect_runs ? 4u : 0u)};
  MdfFlowResult result;
  if (!mdf_text_flow(spans.data(), spans.size(), spec, measure, &context, &result)) {
    if (context.failed) std::rethrow_exception(context.failed);
    throw std::runtime_error("Cannot lay out text");
  }
  struct Release {
    MdfFlowResult result;
    ~Release() { mdf_text_flow_free(result); }
  } release{result};
  Flow output{{}, result.height, result.right};
  output.runs.reserve(result.count);
  for (size_t i = 0; i < result.count; ++i) {
    const auto &run = result.runs[i];
    output.runs.push_back({ss[run.span].text.substr(run.offset, run.len), styles[run.span],
      run.x, run.y, run.width, run.height, run.position, run.font_height, run.font_descent});
  }
  return output;
}
const std::vector<float> &DocumentView::table_columns(int index, float width) const {
  while (index > 0 && !blocks[index].table_header &&
         blocks[index - 1].kind == "table_row")
    --index;
  if (auto found = table_widths.find(index); found != table_widths.end())
    return found->second;
  if (model) {
    LayoutMeasurements context{this};
    MdfFloatBuffer measured;
    if (!mdf_core_table_columns(model, index, width, zoom(), settings.line_wrap, code_font.ready(),
                                 LayoutMeasurements::measure, &context, profile_depth, &measured)) {
      if (context.failed) std::rethrow_exception(context.failed);
      throw std::runtime_error("Cannot measure intrinsic table columns");
    }
    struct Release { MdfFloatBuffer buffer; ~Release() { mdf_float_buffer_free(buffer); } } release{measured};
    std::vector<float> widths;
    if (measured.count) widths.assign(measured.data, measured.data + measured.count);
    return table_widths.emplace(index, std::move(widths)).first->second;
  }
  // Hand-built native font regression fixtures retain the reference adapter.
  PHASE("Measure intrinsic table column widths");
  const float padding = 16 * zoom();
  std::vector<float> minimum(blocks[index].cells.size(), padding + 1), preferred = minimum;
  for (int row = index; row < (int)blocks.size() && blocks[row].kind == "table_row" &&
                        (row == index || !blocks[row].table_header); ++row) {
    const auto &block = blocks[row];
    const int size = style(Span{}, block).size;
    for (size_t col = 0; col < block.cells.size(); ++col) {
      float word = 0, line = 0, longest_word = 0, longest_line = 0;
      for (const auto &span : block.cells[col].spans) {
        auto st = style(span, block);
        st.size = std::max(1, int(size * (span.small ? .8f : 1)));
        fl_font(st.face, st.size);
        size_t at = 0;
        while (at < span.text.size()) {
          const bool space = std::isspace((unsigned char)span.text[at]);
          size_t end = at + 1;
          if (span.text[at] != '\n')
            while (end < span.text.size() && span.text[end] != '\n' &&
                   bool(std::isspace((unsigned char)span.text[end])) == space)
              ++end;
          const float part = text_metrics(st, span.text.data() + at, end - at).width;
          if (space) {
            longest_word = std::max(longest_word, word);
            word = 0;
          } else word += part;
          if (span.text[at] == '\n') {
            longest_line = std::max(longest_line, line);
            line = 0;
          } else line += part;
          at = end;
        }
      }
      minimum[col] = std::max(minimum[col], std::max(longest_word, word) + padding + 1);
      preferred[col] = std::max(preferred[col], std::max(longest_line, line) + padding + 1);
    }
  }
  std::vector<float> widths(minimum.size());
  if (!mdf_table_widths(minimum.data(), preferred.data(), minimum.size(), width, padding,
                        settings.line_wrap, widths.data()))
    throw std::runtime_error("Cannot fit intrinsic table columns");
  return table_widths.emplace(index, std::move(widths)).first->second;
}
Measured DocumentView::measure(int index, bool collect_runs) const {
  if (!model) return measure_reference(index, collect_runs);
  const auto image = images.find(index);
  const auto dimensions = diagram_sizes.find(index);
  const auto failure = diagram_errors.find(index);
  const std::string_view message = failure == diagram_errors.end() ? std::string_view{} : failure->second;
  const MdfLayoutOptions options{content_width, margin, zoom(), settings.line_wrap, collect_runs,
      code_font.ready(), visible(index), image != images.end(), dimensions != diagram_sizes.end(),
      dimensions != diagram_sizes.end() ? dimensions->second.first : image != images.end() ? float(image->second->data_w()) : 0,
      dimensions != diagram_sizes.end() ? dimensions->second.second : image != images.end() ? float(image->second->data_h()) : 0,
      {reinterpret_cast<const unsigned char *>(message.data()), message.size()},
      blocks[index].mermaid() && image != images.end() ? diagram_scale(index) : 0,
      blocks[index].mermaid() && image != images.end() ? diagram_controls(index, 0).height : 0};
  LayoutMeasurements context{this};
  auto *layout = mdf_core_layout_block(model, index, &options, LayoutMeasurements::measure, LayoutMeasurements::columns, &context);
  if (!layout) {
    if (context.failed) std::rethrow_exception(context.failed);
    throw std::runtime_error("Cannot lay out Markdown block");
  }
  struct Release { MdfBlockLayout *layout; ~Release() { mdf_layout_result_free(layout); } } release{layout};
  const auto view = mdf_layout_result_view(layout);
  Measured result;
  result.height = view.height; result.right = view.right; result.image = view.image;
  result.ix = view.ix; result.iy = view.iy; result.iw = view.iw; result.ih = view.ih;
  result.runs.reserve(view.run_count);
  for (size_t i = 0; i < view.run_count; ++i) {
    const auto &run = view.runs[i];
    auto link = view_text(run.link);
    Style style{FL_FREE_FONT + int(run.font.face), run.font.size, bool(run.flags & 8), bool(run.flags & 16),
      bool(run.flags & 4), bool(run.flags & 32), link, run.role ? role(run.role) : link.empty() ? palette.fg : palette.link,
      bool(run.font.flags & 1)};
    result.runs.push_back({view_text(run.text), std::move(style), run.x, run.y, run.width, run.height,
                            run.position, run.font_height, run.font_descent});
  }
  result.rects.reserve(view.rect_count);
  for (size_t i = 0; i < view.rect_count; ++i) {
    const auto &rect = view.rects[i];
    result.rects.push_back({rect.x, rect.y, rect.width, rect.height, int(rect.role)});
  }
  return result;
}
Measured DocumentView::measure_reference(int index, bool collect_runs) const {
  Measured m;
  if (!visible(index))
    return m;
  auto &b = blocks[index];
  float z = zoom();
  int sz = style(Span{}, b).size;
  float left = margin + std::min(20, b.indent + b.quote) * 22 * z,
        width = std::max(30.f, content_width - (left - margin));
  float before = b.kind == "heading" && index ? 16 * z : 0, y = before,
        after = b.kind == "table_row" && !b.table_last ? 0
                : b.indent                             ? 6 * z
                                                       : 12 * z;
  m.right = left + width;
  if (b.kind == "rule") {
    m.rects.push_back({left, 10 * z, width, 1, 1});
    m.height = 24 * z;
    return m;
  }
  auto label = [&](std::string value, float x, float top, int role = 0) {
    Span s;
    s.text = value;
    s.bold = true;
    auto [r, h, right] = flow({s}, b, x, top, width - 24 * z, sz, 0, "left", collect_runs);
    m.right = std::max(m.right, right + 12 * z);
    for (auto &v : r) {
      v.pos = std::numeric_limits<size_t>::max();
      if (role)
        v.style.color = this->role(role);
    }
    m.runs.insert(m.runs.end(), r.begin(), r.end());
    return h;
  };
  int alert_role = b.alert == "tip"         ? 6
                   : b.alert == "important" ? 7
                   : b.alert == "warning"   ? 8
                   : b.alert == "caution"   ? 9
                                            : 5;
  if (b.alert_start) {
    auto title = b.alert;
    if (!title.empty())
      title[0] = std::toupper((unsigned char)title[0]);
    y += label(title, left + 12 * z, y + 8 * z, alert_role) + 8 * z;
  }
  const bool diagram = b.mermaid() && images.count(index);
  if (b.kind == "code" && !b.language.empty() && !diagram) {
    const auto failure = diagram_errors.find(index);
    y += label(failure == diagram_errors.end() ? b.language : "Mermaid: " + failure->second,
               left + 12 * z, y + 8 * z);
  }
  const bool details = b.kind == "details";
  std::string prefix = details ? "" : b.prefix;
  fl_font(style(Span{}, b).face, sz);
  float pw = b.task.has_value() || details || b.indent
                 ? std::max(sz * 1.5f, float(fl_width(prefix.c_str())))
                 : fl_width(prefix.c_str());
  const float prefix_pad = b.kind == "code" || b.quote ? 12 * z : 0;
  if (!prefix.empty() && b.kind != "table_row") {
    Span s;
    s.text = prefix;
    auto [r, h, right] = flow({s}, b, left + prefix_pad, y + prefix_pad, width, sz, starts[index], "left", collect_runs);
    m.right = std::max(m.right, right);
    m.runs.insert(m.runs.end(), r.begin(), r.end());
  }
  if (b.kind == "table_row") {
    const auto &columns = table_columns(index, width);
    float x = left, mh = 0;
    size_t pos = starts[index];
    for (size_t c = 0; c < b.cells.size(); ++c) {
      float cw = columns[c];
      auto [r, h, right] =
          flow(b.cells[c].spans, b, x + 8 * z, y + 8 * z,
               std::max(12.f, cw - 16 * z), sz, pos, b.cells[c].align, collect_runs);
      m.runs.insert(m.runs.end(), r.begin(), r.end());
      mh = std::max(mh, h + 16 * z);
      m.rects.push_back({x, y, 1, 0, 1});
      x += cw;
      for (auto &s : b.cells[c].spans)
        pos += s.text.size();
      ++pos;
    }
    width = x - left;
    m.right = std::max(m.right, x);
    for (auto &r : m.rects)
      if (r.h == 0)
        r.h = mh;
    if (b.table_header || b.table_stripe)
      m.rects.insert(m.rects.begin(), {left, y, width, mh, 2});
    m.rects.push_back({x, y, 1, mh, 1});
    m.rects.push_back({left, y, width, 1, 1});
    m.rects.push_back({left, y + mh - 1, width, 1, 1});
    y += mh;
  } else if ((b.kind == "image" || diagram) && images.count(index)) {
    auto &img = images.at(index);
    m.image = true;
    m.ix = left;
    m.iy = y;
    const auto dimensions = diagram_sizes.find(index);
    const float natural_width = dimensions == diagram_sizes.end() ? img->data_w() : dimensions->second.first * z;
    const float natural_height = dimensions == diagram_sizes.end() ? img->data_h() : dimensions->second.second * z;
    m.iw = std::min(natural_width, width);
    m.ih = m.iw * natural_height / std::max(1.f, natural_width);
    if (diagram) m.ix += (width - m.iw) / 2;
    y += m.ih;
  } else {
    if (b.kind == "image" && diagram_errors.count(index))
      y += label("SVG: " + diagram_errors.at(index), left, y);
    float pad = b.kind == "code" || b.quote ? 12 * z : 0;
    auto [r, h, right] = flow(b.spans, b, left + pad + pw, y + pad,
                       std::max(20.f, width - 2 * pad - pw), sz,
                       starts[index] + b.prefix.size(), "left", collect_runs);
    m.right = std::max(m.right, right + pad);
    if (!settings.line_wrap) width = std::max(width, m.right - left);
    m.runs.insert(m.runs.end(), r.begin(), r.end());
    if (b.kind == "code" || b.quote)
      m.rects.insert(m.rects.begin(),
                     {left, before, width, y - before + h + 2 * pad, 2});
    if (b.quote)
      m.rects.push_back({left, before, 3 * z, y - before + h + 2 * pad,
                         b.alert.empty() ? 1 : alert_role});
    if (b.task) {
      float cx = left + pad + 2 * z, cy = y + pad + sz * .35f, side = sz * .65f;
      if (*b.task) {
        m.rects.push_back({cx, cy, side, side, 3});
        for (int i = 0; i < 7; ++i) {
          float dy =
              i < 3 ? (.48f + i * .1f) * side : (.68f - (i - 2) * .11f) * side;
          m.rects.push_back({cx + (.18f + i * .09f) * side, cy + dy,
                             std::max(1.f, side * .15f),
                             std::max(1.f, side * .15f), 4});
        }
      } else {
        m.rects.push_back({cx, cy, side, 1, 1});
        m.rects.push_back({cx, cy + side - 1, side, 1, 1});
        m.rects.push_back({cx, cy, 1, side, 1});
        m.rects.push_back({cx + side - 1, cy, 1, side, 1});
      }
    }
    y += h + 2 * pad;
  }
  if (b.kind == "heading" && b.heading <= 2) {
    m.rects.push_back({left, y + 6 * z, width, 1, 1});
    y += 12 * z;
  }
  m.height = y + after;
  return m;
}
float DocumentView::horizontal_total() const {
  if (horizontal_dirty) {
    PHASE("Measure document horizontal extent");
    float right = w();
    // Keep the existing lazy viewport cache. This pass measures width without
    // retaining all the document's text runs or changing its vertical layout.
    for (int i = 0; i < (int)blocks.size(); ++i) {
      const auto cached = cache.find(i);
      if (settings.line_wrap && (cached == cache.end() ||
          (blocks[i].kind != "table_row" && !blocks[i].mermaid()))) continue;
      const float edge = cached == cache.end() ? measure(i, false).right : cached->second.right;
      if (edge > 0) right = std::max(right, edge + margin);
    }
    mdf_viewport_horizontal(geometry.handle, w(), right);
  }
  return horizontal_extent;
}
DocumentView::DiagramControls DocumentView::diagram_controls(int index, float top) const {
  const float indent = std::min(20, blocks[index].indent + blocks[index].quote) * 22 * zoom();
  const float left = margin + indent, width = std::max(30.f, content_width - indent);
  DiagramControls result;
  float x = left, y = top + 2;
  const float widths[] = {28, 62, 28, 44};
  for (int i = 0; i < 4; ++i) {
    const float w = std::min(widths[i], width);
    if (x > left && x + w > left + width) { x = left; y += 32; }
    result.boxes[i] = {x, y, w, 28}; x += w + 4;
  }
  result.height = y - top + 30;
  return result;
}
float DocumentView::diagram_scale(int index) const {
  const auto state = diagram_states.find(index);
  if (state == diagram_states.end()) return 1;
  if (!state->second.fit) return state->second.zoom;
  const float indent = std::min(20, blocks[index].indent + blocks[index].quote) * 22 * zoom();
  return std::min(1.f, std::max(30.f, content_width - indent) /
      std::max(1.f, diagram_sizes.at(index).first * zoom()));
}
void DocumentView::zoom_diagram(int index, int action) {
  if (!images.count(index) || !blocks[index].mermaid()) return;
  const float current = diagram_scale(index);
  diagram_focus = index;
  if ((action == 0 && current <= .25f) || (action == 2 && current >= 2)) return;
  auto &state = diagram_states[index];
  if (action == 1) state = {};
  else if (action == 3) state = {1, true};
  else state = {std::clamp(current * (action == 0 ? .8f : 1.25f), .25f, 2.f), false};
  const int anchor = index_at(scroll);
  const float delta = scroll - offsets[anchor];
  cache.erase(index);
  auto measured = measure(index);
  heights[index] = measured.height;
  cache.emplace(index, std::move(measured));
  reindex();
  scroll = std::clamp(offsets[anchor] + delta, 0.f, max_scroll());
  horizontal_dirty = true;
  horizontal_scroll = std::clamp(horizontal_scroll, 0.f, max_horizontal_scroll());
  redraw();
  if (changed) changed();
}
std::optional<std::pair<int, int>> DocumentView::diagram_hit(float px, float py) const {
  if (blocks.empty()) return {};
  const int index = index_at(py + scroll);
  const auto found = cache.find(index);
  if (!blocks[index].mermaid() || found == cache.end() || !found->second.image) return {};
  const auto &m = found->second;
  py += scroll - offsets[index];
  auto group = diagram_controls(index, 0);
  group = diagram_controls(index, m.iy - group.height);
  for (int i = 0; i < 4; ++i) {
    const auto &b = group.boxes[i];
    if (px >= b.x && px < b.x + b.w && py >= b.y && py < b.y + b.h) return std::pair{index, i};
  }
  if (px + horizontal_scroll >= m.ix && px + horizontal_scroll < m.ix + m.iw &&
      py >= m.iy && py < m.iy + m.ih) return std::pair{index, -1};
  return {};
}
Fl_Color DocumentView::role(int r) const {
  switch (r) {
  case 1:
    return palette.border;
  case 2:
    return palette.panel;
  case 3:
    return palette.link;
  case 4:
    return settings.dark ? palette.bg : FL_WHITE;
  case 5:
    return palette.note;
  case 6:
    return palette.tip;
  case 7:
    return palette.important;
  case 8:
    return palette.warning;
  case 9:
    return palette.caution;
  default:
    return palette.bg;
  }
}
void DocumentView::prepare_visible() {
  PHASE("Measure visible Markdown blocks");
  for (int pass = 0; pass < 8; ++pass) {
    int first = index_at(scroll);
    float delta = scroll - offsets[first];
    bool change = false;
    for (int i = first;
         i < (int)blocks.size() && offsets[i] < scroll + h() + 100; ++i) {
      if (!cache.count(i)) {
        auto m = measure(i);
        heights[i] = m.height;
        cache.emplace(i, std::move(m));
        horizontal_dirty = true;
        change = true;
      }
    }
    if (!change)
      break;
    reindex();
    scroll = offsets[first] + delta;
  }
  scroll = std::clamp(scroll, 0.f, max_scroll());
  horizontal_scroll = std::clamp(horizontal_scroll, 0.f, max_horizontal_scroll());
}
void DocumentView::draw() {
  PHASE("Draw native FLTK reader viewport");
  ++paints;
  prepare_visible();
  fl_push_clip(x(), y(), w(), h());
  fl_color(palette.bg);
  fl_rectf(x(), y(), w(), h());
  const float origin_x = x() - horizontal_scroll;
  if (!blocks.empty())
    for (int i = index_at(scroll);
         i < (int)blocks.size() && offsets[i] < scroll + h(); ++i) {
      auto item = cache.find(i);
      if (item == cache.end())
        continue;
      auto &m = item->second;
      float dy = y() + offsets[i] - scroll;
      for (auto &r : m.rects) {
        fl_color(role(r.role));
        fl_rectf(std::round(origin_x + r.x), std::round(dy + r.y), std::ceil(r.w),
                 std::ceil(r.h));
      }
      if (blocks[i].kind == "details") {
        const float z = zoom(), side = style(Span{}, blocks[i]).size * .55f;
        const float tx =
            origin_x + margin +
            std::min(20, blocks[i].indent + blocks[i].quote) * 22 * z;
        const float ty = dy + side * .7f;
        fl_color(palette.fg);
        if (blocks[i].details_open)
          fl_polygon(tx, ty, tx + side, ty, tx + side / 2, ty + side * .7f);
        else
          fl_polygon(tx, ty, tx, ty + side, tx + side * .7f, ty + side / 2);
      }
      if (m.image) {
        auto &image = images[i];
        image->scale(m.iw, m.ih, 0, 1);
        image->draw(origin_x + m.ix, dy + m.iy);
        if (model && blocks[i].mermaid()) {
          const float scale = diagram_scale(i);
          const auto group = diagram_controls(i, m.iy - diagram_controls(i, 0).height);
          for (int action = 0; action < 4; ++action) {
            const auto &b = group.boxes[action];
            const auto state = diagram_states.find(i);
            const bool fit = state != diagram_states.end() && state->second.fit;
            const bool active = action == 3 ? fit : action == 1 && !fit && std::abs(scale - 1) < .001f;
            fl_draw_box(active ? FL_DOWN_BOX : FL_UP_BOX, x() + b.x, dy + b.y, b.w, b.h,
                        active ? rgb(0x3276b0) : palette.panel);
            const bool enabled = !((action == 0 && scale <= .25f) || (action == 2 && scale >= 2));
            fl_color(!enabled ? palette.muted : active ? FL_WHITE : palette.fg);
            fl_font(FL_FREE_FONT, b.w < 40 ? 11 : 13);
            const auto label = action == 0 ? std::string("−") : action == 2 ? std::string("+") :
                action == 3 ? std::string("Fit") : scale < .01f ? std::string("<1%") : std::to_string(int(std::round(scale * 100))) + "%";
            fl_draw(label.c_str(), x() + b.x, dy + b.y, b.w, b.h, FL_ALIGN_CENTER);
          }
        }
      }
      for (auto &r : m.runs) {
        float xx = origin_x + r.x, base = dy + r.y;
        fl_font(r.style.face, r.style.size);
        const bool fallback = fallback_font.ready() && needs_fallback(r.text, bundled_coverage);
        float asc = r.font_height - r.font_descent, top = base - asc;
        if (r.style.code || r.style.highlight) {
          fl_color(r.style.highlight ? palette.highlight : palette.panel);
          fl_rectf(xx - 1, top - 1, r.w + 2, r.font_height + 2);
        }
        if (selection && r.pos != std::numeric_limits<size_t>::max()) {
          auto [a, b] = *selection;
          if (a > b)
            std::swap(a, b);
          size_t begin = std::max(a, r.pos),
                 end = std::min(b, r.pos + r.text.size());
          if (begin < end) {
            float sx = prefix_width(r, begin - r.pos),
                  sw = prefix_width(r, end - r.pos) - sx;
            fl_color(palette.selection);
            fl_rectf(xx + sx, top, sw, r.font_height + 2);
          }
        }
        fl_color(r.style.highlight ? palette.fg : r.style.color);
        if (r.style.monospace)
          code_font.draw(r.text.data(), r.text.size(), r.style.size,
                          (r.style.face - FL_FREE_FONT) & 3, xx, base);
        else if (fallback)
          fallback_font.draw(r.text.data(), r.text.size(), r.style.size,
                              (r.style.face - FL_FREE_FONT) & 3, xx, base);
        else fl_draw(r.text.c_str(), r.text.size(), xx, base);
        if (r.style.strike)
          fl_line(xx, base - r.style.size * .28f, xx + r.w,
                  base - r.style.size * .28f);
        if (r.style.underline || !r.style.link.empty())
          fl_line(xx, base + 2, xx + r.w, base + 2);
      }
    }
  fl_pop_clip();
  if (changed)
    changed();
}
void DocumentView::resize(int X, int Y, int W, int H) {
  bool reflow = W != w();
  Fl_Widget::resize(X, Y, W, H);
  if (reflow)
    invalidate();
  redraw();
}
void DocumentView::move_scroll(float value) {
  mdf_viewport_move(geometry.handle, value, h());
  redraw();
  if (changed)
    changed();
}
void DocumentView::move_horizontal(float value) {
  mdf_viewport_move_horizontal(geometry.handle, value, max_horizontal_scroll(), false);
  redraw();
  if (changed) changed();
}
void DocumentView::jump(int index) {
  if (index < 0 || index >= (int)blocks.size())
    return;
  for (int p = blocks[index].parent; p >= 0; p = blocks[p].parent)
    blocks[p].details_open = true;
  invalidate();
  scroll = std::min(offsets[index], max_scroll());
  redraw();
  if (changed)
    changed();
}
void DocumentView::toggle(int i) {
  if (i < 0 || i >= (int)blocks.size() || blocks[i].kind != "details")
    return;
  blocks[i].details_open = !blocks[i].details_open;
  invalidate();
  redraw();
}
std::optional<Hit> DocumentView::hit(float xx, float yy) const {
  if (blocks.empty())
    return {};
  xx += horizontal_scroll;
  int index = index_at(yy + scroll);
  auto it = cache.find(index);
  if (it == cache.end())
    return {};
  float py = yy + scroll - offsets[index], dist = 1e30;
  std::optional<Hit> best;
  for (auto &r : it->second.runs) {
    if (r.pos == std::numeric_limits<size_t>::max())
      continue;
    float dy = std::abs(py - (r.y - r.style.size * .4f)),
          dx = xx < r.x         ? r.x - xx
               : xx > r.x + r.w ? xx - r.x - r.w
                                : 0,
          d = dy * 20 + dx;
    if (d < dist) {
      dist = d;
      fl_font(r.style.face, r.style.size);
      size_t at = 0;
      while (at < r.text.size()) {
        size_t next = at + utf8_len((unsigned char)r.text[at]);
        float mid =
            (prefix_width(r, at) + prefix_width(r, next)) / 2;
        if (xx < r.x + mid)
          break;
        at = next;
      }
      best = Hit{r.pos + at, dy < r.style.size && dx < 3 ? r.style.link : "",
                 index};
    }
  }
  return best ? best : std::optional<Hit>(Hit{starts[index], "", index});
}
std::string DocumentView::selected() const {
  if (!selection)
    return {};
  auto [a, b] = *selection;
  if (a > b)
    std::swap(a, b);
  return std::string(plain.substr(std::min(a, plain.size()),
                      std::min(b, plain.size()) - std::min(a, plain.size())));
}
Fl_Cursor DocumentView::hover_cursor(float xx, float yy) const {
  if (diagram_hit(xx, yy)) return FL_CURSOR_HAND;
  if (blocks.empty()) return FL_CURSOR_ARROW;
  const int index = index_at(yy + scroll);
  const auto found = cache.find(index);
  if (found == cache.end()) return FL_CURSOR_ARROW;
  xx += horizontal_scroll;
  const float local_y = yy + scroll - offsets[index];
  for (const auto &run : found->second.runs) {
    if (run.style.link.empty()) continue;
    const float top = run.y - run.font_height + run.font_descent;
    if (xx >= run.x && xx < run.x + run.w && local_y >= top && local_y < top + run.font_height)
      return FL_CURSOR_HAND;
  }
  return FL_CURSOR_ARROW;
}
void DocumentView::select_all() {
  selection = std::pair<size_t, size_t>{0, plain.size()};
  redraw();
}
void DocumentView::select_word(size_t p) {
  size_t a = p, b = p;
  while (a &&
         ((unsigned char)plain[a - 1] >= 128 ||
          std::isalnum((unsigned char)plain[a - 1]) || plain[a - 1] == '_'))
    --a;
  while (b < plain.size() &&
         ((unsigned char)plain[b] >= 128 ||
          std::isalnum((unsigned char)plain[b]) || plain[b] == '_'))
    ++b;
  selection = std::make_pair(a, b);
  redraw();
}
void DocumentView::pointer(int kind, float px, float py) {
  if (kind == 0 || kind == 3) {
    diagram_control = false; diagram_drag.reset();
    if (const auto target = diagram_hit(px, py)) {
      pressed.reset(); diagram_focus = target->first;
      if (target->second >= 0) { zoom_diagram(target->first, target->second); diagram_control = true; }
      else diagram_drag = std::pair{px, horizontal_scroll};
      return;
    }
    diagram_focus.reset();
  } else if (diagram_control) {
    if (kind == 2) diagram_control = false;
    return;
  } else if (diagram_drag) {
    if (kind == 1) move_horizontal(diagram_drag->second + diagram_drag->first - px);
    else diagram_drag.reset();
    return;
  }
  auto target = hit(px, py);
  if (!target)
    return;
  if (kind == 0) {
    pressed = target;
    press_x = px;
    press_y = py;
    selection = std::make_pair(target->pos, target->pos);
    dragging = false;
  } else if (kind == 1 && pressed) {
    dragging = true;
    selection = std::make_pair(pressed->pos, target->pos);
    if (py < 0)
      move_scroll(scroll - 20);
    if (py > h())
      move_scroll(scroll + 20);
    if (!settings.line_wrap && px < 0) move_horizontal(horizontal_scroll - 20);
    if (!settings.line_wrap && px > w()) move_horizontal(horizontal_scroll + 20);
  } else if (kind == 2 && pressed) {
    if (!dragging && std::abs(px - press_x) + std::abs(py - press_y) < 4) {
      if (blocks[pressed->block].kind == "details")
        toggle(pressed->block);
      else if (!pressed->link.empty() && follow)
        follow(pressed->link);
    } else
      selection = std::make_pair(pressed->pos, target->pos);
    pressed.reset();
  } else if (kind == 3)
    select_word(target->pos);
  redraw();
}
int DocumentView::handle(int e) {
  switch (e) {
  case FL_PUSH:
    if (Fl::event_button() == FL_LEFT_MOUSE) {
      take_focus();
      pointer(Fl::event_clicks() ? 3 : 0, Fl::event_x() - x(),
              Fl::event_y() - y());
      return 1;
    }
    break;
  case FL_DRAG:
    pointer(1, Fl::event_x() - x(), Fl::event_y() - y());
    return 1;
  case FL_RELEASE:
    pointer(2, Fl::event_x() - x(), Fl::event_y() - y());
    return 1;
  case FL_MOUSEWHEEL:
    if (Fl::event_dx() || Fl::event_state(FL_SHIFT))
      move_horizontal(horizontal_scroll + (Fl::event_dx() +
                      (Fl::event_state(FL_SHIFT) ? Fl::event_dy() : 0)) * body_size() * 3);
    if (!Fl::event_state(FL_SHIFT))
      move_scroll(scroll + Fl::event_dy() * body_size() * 3);
    return 1;
  case FL_ENTER:
  case FL_MOVE:
    fl_cursor(hover_cursor(Fl::event_x() - x(), Fl::event_y() - y()));
    return 1;
  case FL_LEAVE:
    fl_cursor(FL_CURSOR_DEFAULT);
    return 1;
  case FL_FOCUS:
  case FL_UNFOCUS:
    return 1;
  case FL_KEYDOWN:
    if (diagram_focus && !Fl::event_state(FL_CTRL)) {
      const int key = Fl::event_key();
      if (key == '-' || key == '+' || key == '=' || key == '0') {
        zoom_diagram(*diagram_focus, key == '-' ? 0 : key == '0' ? 1 : 2); return 1;
      }
      if (key == FL_Escape) { diagram_focus.reset(); redraw(); return 1; }
    }
    if (max_horizontal_scroll() > 0 && (Fl::event_key() == FL_Left || Fl::event_key() == FL_Right)) {
      move_horizontal(horizontal_scroll + (Fl::event_key() == FL_Left ? -1 : 1) * body_size() * 3);
      return 1;
    }
    if (Fl::event_state(FL_CTRL) && Fl::event_key() == 'c') {
      auto s = selected();
      Fl::copy(s.c_str(), s.size(), 1);
      return 1;
    }
    if (Fl::event_state(FL_CTRL) && Fl::event_key() == 'a') {
      select_all();
      return 1;
    }
    if (Fl::event_key() == FL_Down) {
      move_scroll(scroll + body_size() * 2);
      return 1;
    }
    if (Fl::event_key() == FL_Up) {
      move_scroll(scroll - body_size() * 2);
      return 1;
    }
    if (Fl::event_key() == FL_Page_Down) {
      move_scroll(scroll + h() * .9);
      return 1;
    }
    if (Fl::event_key() == FL_Page_Up) {
      move_scroll(scroll - h() * .9);
      return 1;
    }
    if (Fl::event_key() == FL_Home) {
      move_scroll(0);
      return 1;
    }
    if (Fl::event_key() == FL_End) {
      move_scroll(max_scroll());
      return 1;
    }
    break;
  }
  return Fl_Widget::handle(e);
}
int Minimap::thumb_height() const {
  return std::min(h(), std::max(scrollbar.w() / 2 + 1,
                                int(scrollbar.slider_size() * h() + .5)));
}
int Minimap::thumb_top() const {
  double range = scrollbar.maximum() - scrollbar.minimum();
  double value =
      range > 0 ? (scrollbar.value() - scrollbar.minimum()) / range : 0;
  return int(std::clamp(value, 0., 1.) * (h() - thumb_height()) + .5);
}
void Minimap::draw() {
  PHASE("Draw native FLTK minimap");
  auto p = doc.palette;
  fl_push_clip(x(), y(), w(), h());
  if (doc.preview.empty()) {
    fl_color(p.panel);
    fl_rectf(x(), y(), w(), h());
    fl_pop_clip();
    return;
  }
  int fs = std::clamp(
      int(std::round(doc.body_size() * w() / std::max(1.f, doc.content_width))),
      2, 4);
  int limit = std::max(256, h() * 2);
  // Shape tiny preview text once. Geometry changes then only copy its pixels.
  // Bound the atlas by the minimap height, including for very large documents.
  if (!text_atlas || atlas_revision != doc.preview_revision ||
      atlas_font_size != fs || atlas_w != w() || atlas_limit != limit ||
      atlas_bg != p.panel || atlas_fg != p.muted) {
    PHASE("Rasterize cached minimap text");
    size_t count = 0;
    for (auto &block : doc.preview)
      count += block.size();
    size_t stride = std::max(size_t(1), (count + limit - 1) / limit), n = 0;
    atlas_lines.clear();
    for (size_t b = 0; b < doc.preview.size(); ++b)
      for (size_t line = 0; line < doc.preview[b].size(); ++line, ++n)
        if (n % stride == 0)
          atlas_lines.push_back({int(b), int(line), int(atlas_lines.size())});
    fl_font(FL_FREE_FONT, fs);
    slot_height = fl_height() + 2;
    atlas_baseline = fl_height() - fl_descent() + 1;
    int atlas_height = std::max(1, int(atlas_lines.size())) * slot_height;
    Fl_Image_Surface surface(w(), atlas_height);
    Fl_Surface_Device::push_current(&surface);
    fl_color(p.panel);
    fl_rectf(0, 0, w(), atlas_height);
    fl_color(p.muted);
    fl_font(FL_FREE_FONT, fs);
    for (auto &line : atlas_lines) {
      fl_push_clip(0, line.slot * slot_height, w(), slot_height);
      fl_draw(doc.preview[line.block][line.line].c_str(), 3,
              line.slot * slot_height + atlas_baseline);
      fl_pop_clip();
    }
    text_atlas.reset(surface.image());
    Fl_Surface_Device::pop_current();
    atlas_revision = doc.preview_revision;
    atlas_font_size = fs;
    atlas_w = w();
    atlas_limit = limit;
    atlas_bg = p.panel;
    atlas_fg = p.muted;
    cached.reset();
  }
  if (!cached || cached_revision != doc.geometry_revision || cached_w != w() ||
      cached_h != h()) {
    {
      PHASE("Build cached FLTK preview");
      unsigned char r, g, b;
      Fl::get_color(p.panel, r, g, b);
      auto *pixels = new unsigned char[size_t(w()) * h() * 3];
      for (size_t i = 0; i < size_t(w()) * h(); ++i) {
        pixels[i * 3] = r;
        pixels[i * 3 + 1] = g;
        pixels[i * 3 + 2] = b;
      }
      float ratio = h() / std::max(1.f, doc.total());
      auto *atlas = (const unsigned char *)text_atlas->data()[0];
      int depth = text_atlas->d();
      int row_bytes =
          text_atlas->ld() ? text_atlas->ld() : text_atlas->data_w() * depth;
      for (auto &line : atlas_lines) {
        int i = line.block;
        if (i >= int(doc.blocks.size()))
          continue;
        if (!doc.visible(i))
          continue;
        float top = doc.offsets[i] * ratio, available = doc.heights[i] * ratio,
              line_h = std::min(fs * 1.4f,
                                available /
                                    std::max(size_t(1), doc.preview[i].size()));
        float yy = top + (line.line + 1) * std::max(1.f, line_h);
        if (yy > top + available + fs || yy > h())
          continue;
        int target_y = int(std::round(yy)) - atlas_baseline;
        for (int y = 0; y < slot_height; ++y) {
          if (target_y + y < 0 || target_y + y >= h())
            continue;
          auto *src = atlas + (line.slot * slot_height + y) * row_bytes;
          auto *dst = pixels + size_t(target_y + y) * w() * 3;
          for (int x = 0; x < w(); ++x, src += depth, dst += 3)
            if (src[0] != r || src[1] != g || src[2] != b) {
              dst[0] = src[0];
              dst[1] = src[1];
              dst[2] = src[2];
            }
        }
      }
      cached = std::make_unique<Fl_RGB_Image>(pixels, w(), h(), 3);
      cached->alloc_array = 1;
      cached_revision = doc.geometry_revision;
      cached_w = w();
      cached_h = h();
    }
  }
  if (cached)
    cached->draw(x(), y());
  if (!doc.blocks.empty()) {
    int thumb = thumb_height(), top = thumb_top();
    if (!overlay || overlay_h != thumb || overlay->w() != w() ||
        overlay_color != p.link) {
      unsigned char r, g, b;
      Fl::get_color(p.link, r, g, b);
      unsigned char rgba[] = {r, g, b, 35};
      Fl_RGB_Image pixel(rgba, 1, 1, 4);
      overlay.reset((Fl_RGB_Image *)pixel.copy(w(), thumb));
      overlay_h = thumb;
      overlay_color = p.link;
    }
    overlay->draw(x(), y() + top);
    fl_color(fl_color_average(p.link, p.panel, .5f));
    fl_rect(x(), y() + top, w(), thumb);
  }
  fl_pop_clip();
}
void Minimap::navigate(int kind, float yy) {
  float th = thumb_height(), top = thumb_top();
  if (kind == 0) {
    dragging = true;
    grab = yy >= top && yy <= top + th ? yy - top : th / 2;
  }
  if (dragging) {
    doc.move_scroll((h() - th) > 0
                        ? std::clamp((yy - grab) / (h() - th), 0.f, 1.f) *
                              doc.max_scroll()
                        : 0);
  }
  if (kind == 2)
    dragging = false;
}
int Minimap::handle(int e) {
  if (e == FL_PUSH) {
    navigate(0, Fl::event_y() - y());
    return 1;
  }
  if (e == FL_DRAG) {
    navigate(1, Fl::event_y() - y());
    return 1;
  }
  if (e == FL_RELEASE) {
    navigate(2, Fl::event_y() - y());
    return 1;
  }
  if (e == FL_MOUSEWHEEL) {
    doc.move_scroll(doc.scroll + Fl::event_dy() * doc.body_size() * 3);
    return 1;
  }
  return Fl_Widget::handle(e);
}
