#pragma once
#include "core-api.h"
#include <pango/pango.h>
#include <algorithm>
#include <limits>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

// Pango's character attributes describe positions between Unicode characters.
// Translate cursor positions to byte offsets for the renderer-independent core.
struct TextBoundaries {
  std::string joined;
  std::vector<unsigned char> positions;
  std::vector<PangoLogAttr> attributes;

  void assign(std::string_view text) {
    if (text.size() >= size_t(std::numeric_limits<int>::max()))
      throw std::runtime_error("Text is too large for Pango boundaries");
    const bool ascii = std::all_of(text.begin(), text.end(), [](unsigned char c) { return c < 128 && c != '\r'; });
    positions.assign(text.size() + 1, ascii ? 1 : 0);
    if (ascii) return;
    const int count = int(g_utf8_strlen(text.data(), text.size())) + 1;
    attributes.resize(count);
    pango_get_log_attrs(text.data(), int(text.size()), 0, pango_language_from_string("en"), attributes.data(), count);
    const char *at = text.data();
    for (int i = 0; i < count; ++i) {
      positions[size_t(at - text.data())] = attributes[i].is_cursor_position;
      if (i + 1 < count) at = g_utf8_next_char(at);
    }
    positions.front() = positions.back() = 1;
  }
  const unsigned char *spans(const MdfFlowSpan *spans, size_t count) {
    joined.clear();
    for (size_t i = 0; i < count; ++i)
      if (spans[i].len) joined.append(reinterpret_cast<const char *>(spans[i].text), spans[i].len);
    assign(joined);
    return positions.data();
  }
  size_t before(size_t position) const {
    position = std::min(position, positions.size() - 1);
    while (position && !positions[position]) --position;
    return position;
  }
  size_t after(size_t position) const {
    position = std::min(position, positions.size() - 1);
    while (position + 1 < positions.size() && !positions[position]) ++position;
    return position;
  }
};
