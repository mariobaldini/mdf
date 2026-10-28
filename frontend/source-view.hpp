#pragma once
#include "view.hpp"
#include <FL/Fl_Text_Buffer.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Scrollbar.H>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// Construct on the first source-view request, after bundled fonts are adopted.
// Fl_Text_Display permits selection and copying but has no editing bindings.
class SourceView : public Fl_Text_Display {
  std::unique_ptr<Fl_Text_Buffer> source_buffer_;
  std::string source_;
  std::vector<size_t> nul_positions_;

  size_t source_offset(size_t position) const {
    // Each visible replacement occupies three bytes instead of one NUL.
    auto next = std::upper_bound(nul_positions_.begin(), nul_positions_.end(), position,
        [](size_t pos, size_t start) { return pos < start + 3; });
    const size_t completed = size_t(next - nul_positions_.begin());
    if (next != nul_positions_.end() && position > *next) position = *next;
    return std::min(source_.size(), position - 2 * completed);
  }

public:
  SourceView(int x, int y, int w, int h, const Settings &settings,
             const Palette &palette, Fl_Font face = FL_FREE_FONT)
      : Fl_Text_Display(x, y, w, h), source_buffer_(std::make_unique<Fl_Text_Buffer>()) {
    hide();
    box(FL_NO_BOX);
    source_buffer_->canUndo(0);
    configure(settings, palette, face);
    Fl_Text_Display::buffer(source_buffer_.get());
  }
  ~SourceView() override {
    // The base destructor also accesses its buffer callbacks.
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
    Fl_Text_Display::buffer(source_buffer_.get());
    insert_position(0);
    scroll(1, 0);
    redraw();
  }
  void configure(const Settings &settings, const Palette &palette,
                 Fl_Font face = FL_FREE_FONT) {
    textfont(face);
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
