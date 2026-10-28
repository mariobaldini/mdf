#pragma once
#include "view.hpp"
#include <FL/Fl.H>
#include <FL/Fl_Text_Buffer.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Scrollbar.H>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <functional>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// Construct on the first source-view request, after bundled fonts are adopted.
// Fl_Text_Display permits selection and copying but has no editing bindings.
class SourceView : public Fl_Text_Display {
public:
  struct PreviewLine { size_t line; std::string text; };
  struct PreviewData {
    std::vector<PreviewLine> lines;
    size_t total_lines = 0;
    uint64_t revision = 0;
  };

private:
  std::unique_ptr<Fl_Text_Buffer> source_buffer_;
  std::string source_;
  std::vector<size_t> nul_positions_;
  PreviewData source_preview_;
  size_t source_preview_limit_ = 0;
  uint64_t source_preview_builds_ = 0;
  bool source_preview_valid_ = false;
  std::shared_ptr<PreparedFont> published_monospace_;
  Fl_Font source_face_ = FL_FREE_FONT;
  Fl_Callback *vertical_callback_ = nullptr;
  void *vertical_callback_data_ = nullptr;
  double last_value_ = -1, last_minimum_ = -1, last_maximum_ = -1, last_slider_ = -1;
  bool last_scrollbar_visible_ = false;

  // FLTK retains the font-name pointer instead of copying it. The name must
  // survive every source widget and stay valid until process exit.
  static std::string &monospace_family() {
    static auto *name = new std::string;
    return *name;
  }

  size_t source_offset(size_t position) const {
    // Each visible replacement occupies three bytes instead of one NUL.
    auto next = std::upper_bound(nul_positions_.begin(), nul_positions_.end(), position,
        [](size_t pos, size_t start) { return pos < start + 3; });
    const size_t completed = size_t(next - nul_positions_.begin());
    if (next != nul_positions_.end() && position > *next) position = *next;
    return std::min(source_.size(), position - 2 * completed);
  }

public:
  std::function<void()> viewport_changed;
  SourceView(int x, int y, int w, int h, const Settings &settings,
             const Palette &palette, Fl_Font face = FL_FREE_FONT)
      : Fl_Text_Display(x, y, w, h), source_buffer_(std::make_unique<Fl_Text_Buffer>()) {
    hide();
    box(FL_NO_BOX);
    source_buffer_->canUndo(0);
    vertical_callback_ = mVScrollBar->callback();
    vertical_callback_data_ = mVScrollBar->user_data();
    mVScrollBar->callback([](Fl_Widget *widget, void *data) {
      auto &source = *static_cast<SourceView *>(data);
      if (source.vertical_callback_) source.vertical_callback_(widget, source.vertical_callback_data_);
      // The FLTK callback can return early without scheduling a source draw.
      // The preview still needs to reflect the scrollbar's new value.
      if (source.viewport_changed) source.viewport_changed();
    }, this);
    configure(settings, palette, face);
    Fl_Text_Display::buffer(source_buffer_.get());
  }
  ~SourceView() override {
    // The base destructor also accesses its buffer callbacks.
    mVScrollBar->callback(vertical_callback_, vertical_callback_data_);
    Fl_Text_Display::buffer(nullptr);
  }
  void set_source(std::string_view bytes) {
    if (bytes.size() >= size_t(std::numeric_limits<int>::max()))
      throw std::length_error("Markdown source is too large for the source view");
    const auto nul_count = size_t(std::count(bytes.begin(), bytes.end(), '\0'));
    if (nul_count > (size_t(std::numeric_limits<int>::max()) - 1 - bytes.size()) / 2)
      throw std::length_error("Markdown source is too large for the source view");
    std::string original(bytes);
    std::string display;
    std::vector<size_t> positions;
    display.reserve(bytes.size() + 2 * nul_count);
    positions.reserve(nul_count);
    for (char byte : bytes) {
      if (byte == '\0') {
        positions.push_back(display.size());
        display.append("\xef\xbf\xbd", 3);
      } else display.push_back(byte);
    }
    auto next = std::make_unique<Fl_Text_Buffer>(int(display.size()));
    next->canUndo(0);
    if (!display.empty()) next->append(display.data(), int(display.size()));
    Fl_Text_Display::buffer(nullptr);
    source_buffer_.swap(next);
    source_.swap(original);
    nul_positions_.swap(positions);
    source_preview_.lines.clear();
    source_preview_.total_lines = 0;
    source_preview_valid_ = false;
    Fl_Text_Display::buffer(source_buffer_.get());
    insert_position(0);
    scroll(1, 0);
    redraw();
  }
  void configure(const Settings &settings, const Palette &palette,
                 Fl_Font face = Fl_Font(-1)) {
    if (face >= 0) source_face_ = face;
    textfont(source_face_);
    textsize(std::max(1, int(std::round(settings.size * 1.4f))));
    color(palette.bg);
    textcolor(palette.fg);
    selection_color(palette.selection);
    cursor_color(palette.fg);
    mVScrollBar->color(palette.panel);
    mHScrollBar->color(palette.panel);
    mVScrollBar->labelcolor(palette.fg);
    mHScrollBar->labelcolor(palette.fg);
    wrap_mode(settings.line_wrap ? WRAP_AT_BOUNDS : WRAP_NONE, 0);
    redraw();
  }
  bool set_monospace(FontStore &fonts, const CodeFont &font) {
    if (!font.ready() || !font.info()->monospace) return false;
    const auto prepared = font.resources();
    if (published_monospace_ != prepared) {
      fonts.add_fallback(font);
      published_monospace_ = prepared;
    }
    auto &family = monospace_family();
    if (family != prepared->family || source_face_ != FL_FREE_FONT + 4) {
      Fl::set_font(FL_FREE_FONT + 4, "");
      family = prepared->family;
      Fl::set_font(FL_FREE_FONT + 4, family.c_str());
    }
    source_face_ = FL_FREE_FONT + 4;
    textfont(source_face_);
    redraw();
    return true;
  }
  Fl_Scrollbar *vertical_scrollbar() const { return mVScrollBar; }
  // Build only for an open source preview. Keep the original line positions
  // so the minimap can spread a bounded sample over the complete document.
  const PreviewData &source_preview(size_t limit) {
    if (source_preview_valid_ && source_preview_limit_ == limit) return source_preview_;
    PreviewData next;
    next.total_lines = source_.empty() ? 0 : 1 + size_t(std::count(source_.begin(), source_.end(), '\n'));
    const size_t count = std::min(limit, next.total_lines);
    next.lines.reserve(count);
    size_t start = 0, line = 0, selected = 0;
    while (selected < count) {
      const size_t target = count > 1 ? selected * (next.total_lines - 1) / (count - 1) : 0;
      const size_t newline = source_.find('\n', start);
      size_t end = newline == std::string::npos ? source_.size() : newline;
      if (newline != std::string::npos && end > start && source_[end - 1] == '\r') --end;
      if (line == target) {
        // Long lines need only their visible prefix. Avoid splitting a UTF-8
        // sequence at the cutoff and make embedded NULs visible to FLTK.
        size_t stop = std::min(end, start + size_t(512));
        while (stop < end && stop > start && (static_cast<unsigned char>(source_[stop]) & 0xc0) == 0x80) --stop;
        std::string text;
        text.reserve(stop - start);
        for (size_t i = start; i < stop; ++i) {
          if (source_[i] == '\0') text.append("\xef\xbf\xbd", 3);
          else text.push_back(source_[i]);
        }
        next.lines.push_back({line, std::move(text)});
        ++selected;
      }
      if (newline == std::string::npos) break;
      start = newline + 1;
      ++line;
    }
    next.revision = ++source_preview_builds_;
    source_preview_ = std::move(next);
    source_preview_limit_ = limit;
    source_preview_valid_ = true;
    return source_preview_;
  }
  uint64_t source_preview_builds() const { return source_preview_builds_; }
  void draw() override {
    Fl_Text_Display::draw();
    const double value = mVScrollBar->value(), minimum = mVScrollBar->minimum();
    const double maximum = mVScrollBar->maximum(), slider = mVScrollBar->slider_size();
    const bool visible = mVScrollBar->visible();
    if (value != last_value_ || minimum != last_minimum_ || maximum != last_maximum_ ||
        slider != last_slider_ || visible != last_scrollbar_visible_) {
      last_value_ = value; last_minimum_ = minimum; last_maximum_ = maximum;
      last_slider_ = slider; last_scrollbar_visible_ = visible;
      if (viewport_changed) viewport_changed();
    }
  }
  std::string selected() const {
    int start = 0, end = 0;
    if (!source_buffer_->selection_position(&start, &end)) return {};
    const size_t first = source_offset(size_t(start)), last = source_offset(size_t(end));
    return source_.substr(first, last - first);
  }
  void select_all() {
    source_buffer_->select(0, source_buffer_->length());
    redraw();
  }
  size_t source_size() const { return source_.size(); }
};
