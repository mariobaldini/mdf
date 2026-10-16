#include "view.hpp"
#include "bundled-fonts.hpp"
#include <FL/Fl.H>
#include <FL/Fl_Image_Surface.H>
#include <FL/platform.H>
#include <cctype>
#include <cerrno>
#include <cstdio>
#include <linux/memfd.h>
#include <sys/syscall.h>
#include <unistd.h>

static Fl_Color rgb(unsigned c) {
  return fl_rgb_color(c >> 16, (c >> 8) & 255, c & 255);
}
Palette Palette::get(const Settings &s) {
  unsigned bg = s.dark ? 0x202124 : 0xffffff, fg = s.dark ? 0xd7d9dc : 0x42464b,
           panel = s.dark ? 0x292c31 : 0xf5f6f7,
           border = s.dark ? 0x3c3e42 : 0xd8dce1,
           link = s.dark ? 0x8ab4e5 : 0x3276b0;
  if (s.theme == "paper") {
    bg = s.dark ? 0x29251f : 0xfbf5e9;
    fg = s.dark ? 0xe1d5bf : 0x514635;
    panel = s.dark ? 0x342e25 : 0xf0e7d6;
    border = s.dark ? 0x4b4033 : 0xe2d7c3;
    link = s.dark ? 0xdfb77b : 0x8c542b;
  }
  if (s.theme == "terminal") {
    bg = s.dark ? 0x141c19 : 0xf2f7f3;
    fg = s.dark ? 0xc4d7cb : 0x304b3b;
    panel = s.dark ? 0x1e2c24 : 0xe6efe8;
    border = s.dark ? 0x2d4237 : 0xd4e2d7;
    link = s.dark ? 0x8dcca5 : 0x326c48;
  }
  return {rgb(bg),
          rgb(fg),
          rgb(panel),
          rgb(border),
          rgb(link),
          rgb(s.dark ? 0xadb4be : 0x6b6f75),
          rgb(s.dark ? 0x385779 : 0xc5ddf5)};
}
FontStore::~FontStore() {
  if (coverage) FcCharSetDestroy(coverage);
  if (config)
    FcConfigDestroy(config);
  for (int fd : fds)
    close(fd);
}
void FontStore::prepare() {
  PHASE("Prepare bundled Open Sans");
  {
    PHASE("Create private Fontconfig configuration");
    config = FcConfigCreate();
    if (!config)
      throw std::runtime_error("Cannot create private font configuration");
    // No XML, font directories, extracted files, or disk caches are used.
    FcConfigSetRescanInterval(config, 0);
  }
  const char *names[] = {"Register Open Sans regular",
                         "Register Open Sans bold", "Register Open Sans italic",
                         "Register Open Sans bold italic"};
  fds.reserve(4);
  for (unsigned style = 0; style < 2; ++style)
    add(bundled_font(style), names[style]);
  styles = 3;
  auto *faces = FcConfigGetFonts(config, FcSetApplication);
  FcCharSet *first = nullptr;
  if (!faces || !faces->nfont ||
      FcPatternGetCharSet(faces->fonts[0], FC_CHARSET, 0, &first) != FcResultMatch)
    throw std::runtime_error("Embedded Open Sans coverage unavailable");
  coverage = FcCharSetCopy(first);
}
void FontStore::ensure_styles(uint32_t required) {
  const uint32_t added = required & ~styles & 12;
  if (!added) return;
  PHASE("Prepare required Open Sans italic faces");
  for (unsigned style = 2; style < 4; ++style) if (added & (1u << style)) {
    add(bundled_font(style), style == 2 ? "Register Open Sans italic" : "Register Open Sans bold italic");
    styles |= 1u << style;
  }
  if (adopted) {
    pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(pango_cairo_font_map_get_default()));
    const char *names[] = {"Open Sans", "Open Sans Bold", "Open Sans Italic", "Open Sans Bold Italic"};
    for (int i = 0; i < FL_FREE_FONT + 4; ++i) if (added & (1u << (i % 4))) {
      Fl::set_font(i, "");
      Fl::set_font(i, names[i % 4]);
    }
  }
}
void FontStore::add_fallback(const CodeFont &font) {
  PHASE("Publish selected fallback fonts for native labels");
  auto retained = font.resources();
  auto *from = FcConfigGetFonts(retained->config, FcSetApplication);
  auto *to = FcConfigGetFonts(config, FcSetApplication);
  // Retain data before publishing patterns that refer to its anonymous files.
  fallbacks.push_back(std::move(retained));
  for (int i = 0; i < from->nfont; ++i) {
    FcChar8 *family = nullptr;
    if (FcPatternGetString(from->fonts[i], FC_FAMILY, 0, &family) == FcResultMatch &&
        std::string(reinterpret_cast<const char *>(family)) == "Open Sans") continue;
    FcPatternReference(from->fonts[i]);
    if (!FcFontSetAdd(to, from->fonts[i])) {
      FcPatternDestroy(from->fonts[i]);
      throw std::runtime_error("Cannot publish document fallback font");
    }
  }
  pango_fc_font_map_config_changed(PANGO_FC_FONT_MAP(pango_cairo_font_map_get_default()));
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
    if (!config || !FcConfigSetCurrent(config))
      throw std::runtime_error(
          "Cannot activate bundled Open Sans configuration");
  }
  {
    PHASE("Adopt Fontconfig configuration in Pango");
    auto *map = pango_cairo_font_map_get_default();
    if (!PANGO_IS_FC_FONT_MAP(map))
      throw std::runtime_error("Pango Fontconfig backend unavailable");
    pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), config);
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
void FontStore::add(Buffer bytes, const char *name) {
  if (!bytes.ptr || !bytes.len)
    throw std::runtime_error("Embedded Open Sans face unavailable");
  int fd;
  {
    PHASE("Prepare anonymous font data");
    fd = syscall(SYS_memfd_create, "mdf-font", MFD_CLOEXEC);
    if (fd < 0)
      throw std::runtime_error("Cannot create font memory file");
    fds.push_back(fd);
    size_t off = 0;
    while (off < bytes.len) {
      auto n = write(fd, bytes.ptr + off, bytes.len - off);
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0)
        throw std::runtime_error("Cannot prepare embedded Open Sans data");
      off += n;
    }
  }
  {
    Phase registration(name, __FILE__, __LINE__);
    auto path = "/proc/self/fd/" + std::to_string(fd);
    if (!FcConfigAppFontAddFile(config, (const FcChar8 *)path.c_str()))
      throw std::runtime_error("Fontconfig rejected embedded Open Sans face");
  }
}
DocumentView::DocumentView(int X, int Y, int W, int H, const Settings &s)
    : Fl_Widget(X, Y, W, H), settings(s), palette(Palette::get(s)) {}
float DocumentView::character_width() const {
  fl_font(FL_FREE_FONT, body_size());
  return fl_width("m");
}
void DocumentView::document(const Json &j, Core &core, FontStore &fonts) {
  int anchor = index_at(scroll);
  float delta = scroll - (offsets.empty() ? 0 : offsets[anchor]);
  bool automatic = j.value("automatic", false);
  blocks.clear();
  starts.clear();
  plain.clear();
  images.clear();
  image_pixels.clear();
  diagram_sizes.clear();
  diagram_errors.clear();
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
  starts.reserve(count);
  plain.reserve(j.value("source_bytes", size_t(0)));
  uint32_t required_styles = 0;
  for (size_t i = 0; i < count; ++i) {
    auto b = read_block(core, i);
    has_diagrams = has_diagrams || b.mermaid();
    has_code = has_code || (b.kind == "code" && !b.mermaid());
    starts.push_back(plain.size());
    plain += b.prefix;
    for (auto &s : b.spans) {
      plain += s.text;
      if (s.italic && !s.text.empty()) required_styles |= 1u << (style(s, b).face - FL_FREE_FONT);
    }
    for (size_t i = 0; i < b.cells.size(); ++i) {
      if (i)
        plain += '\t';
      for (auto &s : b.cells[i].spans) {
        plain += s.text;
        if (s.italic && !s.text.empty()) required_styles |= 1u << (style(s, b).face - FL_FREE_FONT);
      }
    }
    plain += "\n\n";
    blocks.push_back(std::move(b));
  }
  // Parsed spans cover nested emphasis, HTML, and table headers. Adopt final
  // faces before invalidate() can measure any document block.
  fonts.ensure_styles(required_styles);
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
  if (blocks.empty())
    return 0;
  auto i = std::upper_bound(offsets.begin(), offsets.end(), y);
  return std::clamp(int(i - offsets.begin()) - 1, 0, (int)blocks.size() - 1);
}
void DocumentView::reindex() {
  offsets.assign(1, 24);
  for (float h : heights)
    offsets.push_back(offsets.back() + h);
  ++geometry_revision;
}
void DocumentView::invalidate() {
  int anchor = index_at(scroll);
  float delta = scroll - (offsets.empty() ? 0 : offsets[anchor]);
  float available = std::max(40, w() - 48);
  content_width = std::min(
      available, settings.width == "percent_100"      ? available
                 : settings.width == "characters_100" ? character_width() * 100
                                                      : w() * .8f);
  margin = std::max(0.f, (w() - content_width) / 2);
  horizontal_dirty = true;
  if (settings.line_wrap) horizontal_scroll = 0;
  cache.clear();
  table_widths.clear();
  heights.resize(blocks.size());
  for (int i = 0; i < (int)blocks.size(); ++i)
    heights[i] = estimate(i);
  reindex();
  scroll = offsets.empty()
               ? 0
               : offsets[std::min(anchor, (int)blocks.size())] + delta;
  scroll = std::clamp(scroll, 0.f, max_scroll());
}
Style DocumentView::style(const Span &s, const Block &b) const {
  float points =
      b.kind == "heading"
          ? std::vector<int>{12, 26, 20, 16, 14, 12, 12}[std::min(6, b.heading)]
      : b.kind == "code" ? 11
                         : 12;
  return {FL_FREE_FONT + int(s.bold || b.kind == "heading" || b.table_header) +
              2 * int(s.italic),
          std::max(
              1, int(std::round(points * 1.4f * zoom() * (s.small ? .8f : 1)))),
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
  return {length ? float(fl_width(text, length)) : 0.f, float(fl_height()), float(fl_descent())};
}
float DocumentView::prefix_width(const Run &run, size_t length) const {
  if (run.style.monospace && run.text == "\t") return length ? run.w : 0;
  return text_metrics(run.style, run.text.data(), length).width;
}
float DocumentView::estimate(int index) const {
  if (!visible(index))
    return 0;
  auto &b = blocks[index];
  float z = zoom(), sz = style(Span{}, b).size;
  float avail =
      std::max(40.f, content_width - std::min(20, b.indent + b.quote) * 22 * z);
  float lines = settings.line_wrap ? std::max(float(std::max(1, b.lines)),
                         std::ceil(b.bytes * sz * .5f / avail)) : float(std::max(1, b.lines));
  return b.kind == "rule"
             ? 24 * z
             : lines * sz * 1.5f + 24 * z + (b.kind == "heading" ? 24 * z : 0);
}
static size_t utf8_len(unsigned char c) {
  return c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
}
Flow
DocumentView::flow(const std::vector<Span> &ss, const Block &b, float left,
                   float top, float width, int sz, size_t start,
                   const std::string &align, bool collect_runs) const {
  std::vector<Run> out;
  float x = left, y = top, line_h = sz * 1.5f, right = left;
  size_t pos = start, line_start = 0;
  auto endline = [&]() {
    float used = x - left, shift = align == "right"    ? width - used
                                   : align == "center" ? (width - used) / 2
                                                       : 0;
    right = std::max(right, x + std::max(0.f, shift));
    for (size_t i = line_start; i < out.size(); ++i)
      out[i].x += std::max(0.f, shift);
    line_start = out.size();
  };
  for (auto &s : ss) {
    auto st = style(s, b);
    st.size = std::max(1, int(sz * (s.small ? .8f : 1)));
    fl_font(st.face, st.size);
    size_t at = 0;
    while (at < s.text.size()) {
      if (s.text[at] == '\n') {
        endline();
        x = left;
        y += line_h;
        ++at;
        ++pos;
        continue;
      }
      if (st.monospace && s.text[at] == '\t') {
        const auto metrics = text_metrics(st, " ", 1);
        const float stop = std::max(1.f, metrics.width * 4);
        float gap = stop - std::fmod(std::max(0.f, x - left), stop);
        if (gap < .01f) gap = stop;
        if (collect_runs)
          out.push_back({"\t", st, x, y + (line_h - metrics.height) / 2 + metrics.height - metrics.descent,
                         gap, line_h, pos});
        x += gap; ++pos; ++at;
        continue;
      }
      size_t end = at;
      bool space = std::isspace((unsigned char)s.text[at]);
      while (end < s.text.size() && s.text[end] != '\n' &&
             !(st.monospace && s.text[end] == '\t') &&
             bool(std::isspace((unsigned char)s.text[end])) == space)
        end += utf8_len((unsigned char)s.text[end]);
      std::string word = s.text.substr(at, end - at);
      const auto metrics = text_metrics(st, word.data(), word.size());
      float width_word = metrics.width;
      if (settings.line_wrap && x > left && x + width_word > left + width && !space) {
        endline();
        x = left;
        y += line_h;
      }
      if (!settings.line_wrap || width_word <= width || space) {
        if (space && x == left && b.kind != "code") {
          pos += word.size();
          at = end;
          continue;
        }
        float asc = metrics.height - metrics.descent;
        if (collect_runs)
          out.push_back({word, st, x, y + (line_h - metrics.height) / 2 + asc,
                         width_word, line_h, pos});
        x += width_word;
        pos += word.size();
      } else {
        size_t p = 0;
        while (p < word.size()) {
          size_t n = utf8_len((unsigned char)word[p]);
          std::string part = word.substr(p, n);
          const auto glyph = text_metrics(st, part.data(), part.size());
          float cw = glyph.width;
          if (x > left && x + cw > left + width) {
            endline();
            x = left;
            y += line_h;
          }
          if (collect_runs) out.push_back(
              {part, st, x,
               y + (line_h - glyph.height) / 2 + glyph.height - glyph.descent, cw,
               line_h, pos});
          x += cw;
          pos += n;
          p += n;
        }
      }
      at = end;
    }
  }
  endline();
  return {std::move(out), y - top + line_h, right};
}
const std::vector<float> &DocumentView::table_columns(int index, float width) const {
  while (index > 0 && !blocks[index].table_header &&
         blocks[index - 1].kind == "table_row")
    --index;
  if (auto found = table_widths.find(index); found != table_widths.end())
    return found->second;
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
  float min_sum = 0, preferred_sum = 0;
  for (size_t col = 0; col < minimum.size(); ++col) {
    preferred[col] = std::max(minimum[col], preferred[col]);
    min_sum += minimum[col];
    preferred_sum += preferred[col];
  }
  std::vector<float> widths = minimum;
  if (!settings.line_wrap && preferred_sum > width) {
    widths = preferred;
  } else if (min_sum > width) {
    // Compact columns (labels/numbers whose whole cell fits on one line)
    // retain their intrinsic width while paragraph columns wrap more tightly.
    float compact = 0;
    int flexible = 0;
    auto compact_column = [&](size_t col) {
      return preferred[col] <= minimum[col] + .01f && minimum[col] <= width * .5f;
    };
    for (size_t col = 0; col < minimum.size(); ++col) {
      if (compact_column(col)) compact += minimum[col];
      else ++flexible;
    }
    const bool protect = flexible && compact + flexible * (padding + 1) <= width;
    // A single oversized token also needs a cap. Preserve smaller columns
    // where possible instead of shrinking them by its character-count weight.
    float low = 0, high = min_sum;
    for (int step = 0; step < 24; ++step) {
      const float cap = (low + high) / 2;
      float used = 0;
      for (size_t col = 0; col < minimum.size(); ++col)
        used += protect && compact_column(col) ? minimum[col] : std::min(minimum[col], cap);
      if (used > width) high = cap;
      else low = cap;
    }
    for (size_t col = 0; col < widths.size(); ++col)
      if (!protect || !compact_column(col))
        widths[col] = std::min(widths[col], low);
  } else {
    for (size_t col = 0; col < widths.size(); ++col) {
      if (preferred_sum > width)
        widths[col] += (width - min_sum) * (preferred[col] - minimum[col]) /
                      (preferred_sum - min_sum);
      else
        widths[col] = preferred[col] + (width - preferred_sum) * preferred[col] /
                     std::max(1.f, preferred_sum);
    }
  }
  return table_widths.emplace(index, std::move(widths)).first->second;
}
Measured DocumentView::measure(int index, bool collect_runs) const {
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
  float pw =
      b.task.has_value() || details ? sz * 1.5f : fl_width(prefix.c_str());
  if (!prefix.empty() && b.kind != "table_row") {
    Span s;
    s.text = prefix;
    auto [r, h, right] = flow({s}, b, left, y, width, sz, starts[index], "left", collect_runs);
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
      float cx = left + 2 * z, cy = y + pad + sz * .35f, side = sz * .65f;
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
  if (settings.line_wrap) return w();
  if (horizontal_dirty) {
    PHASE("Measure unwrapped document width");
    float right = w();
    // Keep the existing lazy viewport cache. This pass measures width without
    // retaining all the document's text runs or changing its vertical layout.
    for (int i = 0; i < (int)blocks.size(); ++i) {
      const auto cached = cache.find(i);
      const float edge = cached == cache.end() ? measure(i, false).right : cached->second.right;
      if (edge > 0) right = std::max(right, edge + margin);
    }
    horizontal_extent = std::max(float(w()), std::ceil(right - .01f));
    horizontal_dirty = false;
  }
  return horizontal_extent;
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
    return FL_WHITE;
  case 5:
    return rgb(settings.dark ? 0x79b8ff : 0x0969da);
  case 6:
    return rgb(settings.dark ? 0x7ee787 : 0x1a7f37);
  case 7:
    return rgb(settings.dark ? 0xd2a8ff : 0x8250df);
  case 8:
    return rgb(settings.dark ? 0xe3b341 : 0x9a6700);
  case 9:
    return rgb(settings.dark ? 0xff7b72 : 0xcf222e);
  default:
    return palette.bg;
  }
}
void DocumentView::prepare_visible() {
  PHASE("Measure visible Markdown blocks");
  if (!settings.line_wrap)
    horizontal_scroll = std::clamp(horizontal_scroll, 0.f, max_horizontal_scroll());
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
        change = true;
      }
    }
    if (!change)
      break;
    reindex();
    scroll = offsets[first] + delta;
  }
  scroll = std::clamp(scroll, 0.f, max_scroll());
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
      }
      for (auto &r : m.runs) {
        float xx = origin_x + r.x, base = dy + r.y;
        fl_font(r.style.face, r.style.size);
        const bool fallback = fallback_font.ready() && needs_fallback(r.text, bundled_coverage);
        const bool custom = r.style.monospace || fallback;
        const auto metrics = text_metrics(r.style, custom ? r.text.data() : "", custom ? r.text.size() : 0);
        float asc = metrics.height - metrics.descent, top = base - asc;
        if (r.style.code || r.style.highlight) {
          fl_color(r.style.highlight ? rgb(0xebd77f) : palette.panel);
          fl_rectf(xx - 1, top - 1, r.w + 2, metrics.height + 2);
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
            fl_rectf(xx + sx, top, sw, metrics.height + 2);
          }
        }
        fl_color(r.style.color);
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
  scroll = std::clamp(value, 0.f, max_scroll());
  redraw();
  if (changed)
    changed();
}
void DocumentView::move_horizontal(float value) {
  horizontal_scroll = settings.line_wrap ? 0.f : std::clamp(value, 0.f, max_horizontal_scroll());
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
  return plain.substr(std::min(a, plain.size()),
                      std::min(b, plain.size()) - std::min(a, plain.size()));
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
    if (!settings.line_wrap && (Fl::event_dx() || Fl::event_state(FL_SHIFT)))
      move_horizontal(horizontal_scroll + (Fl::event_dx() +
                      (Fl::event_state(FL_SHIFT) ? Fl::event_dy() : 0)) * body_size() * 3);
    if (!Fl::event_state(FL_SHIFT) || settings.line_wrap)
      move_scroll(scroll + Fl::event_dy() * body_size() * 3);
    return 1;
  case FL_ENTER:
    fl_cursor(FL_CURSOR_INSERT);
    return 1;
  case FL_LEAVE:
    fl_cursor(FL_CURSOR_DEFAULT);
    return 1;
  case FL_FOCUS:
  case FL_UNFOCUS:
    return 1;
  case FL_KEYDOWN:
    if (!settings.line_wrap && (Fl::event_key() == FL_Left || Fl::event_key() == FL_Right)) {
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
