#pragma once
#include "../frontend/view.hpp"
#include <cstring>

// Runs with the real FLTK surface and adopted fonts in the GUI integration
// suite. Compare against the uncached backend, including kerning and styles.
template<class Check> void check_text_layout(DocumentView &reader, Check check) {
  DocumentView probe(0, 0, 640, 480, reader.settings);
  probe.bundled_coverage = reader.bundled_coverage;
  Block block;
  block.kind = "paragraph";
  for (int face = 0; face < 4; ++face) for (int size : {12, 16, 24}) {
    Span span;
    span.bold = face & 1;
    span.italic = face & 2;
    auto style = probe.style(span, block);
    style.size = size;
    fl_font(style.face, size);
    for (const char *word : {"AV", "To", "Hello", "caf\xc3\xa9", " "}) {
      const size_t length = std::strlen(word);
      const TextMetrics expected{float(fl_width(word, length)), float(fl_height()), float(fl_descent())};
      auto actual = probe.text_metrics(style, word, length);
      check(actual.width == expected.width && actual.height == expected.height && actual.descent == expected.descent,
            "Cached word metrics preserve kerning, accents, styles and sizes");
      const auto count = probe.cached_words;
      actual = probe.text_metrics(style, word, length);
      check(probe.cached_words == count && actual.width == expected.width,
            "Repeated words reuse the same measurement");
    }
  }
  const auto style = probe.style(Span{}, block);
  fl_font(style.face, style.size);
  for (int i = 0; i < 2500; ++i) {
    const auto word = "distinct" + std::to_string(i);
    probe.text_metrics(style, word.data(), word.size());
  }
  check(probe.cached_words == 2048, "Word measurements have a fixed memory bound");
  const std::string long_word(1024, 'W');
  check(probe.text_metrics(style, long_word.data(), long_word.size()).width == float(fl_width(long_word.c_str(), long_word.size())),
        "Long uncached tokens retain their exact width");
  probe.invalidate();
  check(probe.cached_words == 0 && probe.text_measurements.empty(), "Layout invalidation clears surface-dependent font metrics");
  probe.text_metrics(style, "again", 5);
  probe.reflow_fonts(false);
  check(probe.cached_words == 0 && probe.text_measurements.empty(), "Deferred font adoption clears old metrics");
  Span text;
  text.text = "AV wider-than-the-viewport";
  for (float width : {35.f, 500.f}) {
    auto flow = probe.flow({text}, block, 0, 0, width, 16, 0);
    for (const auto &run : flow.runs) {
      fl_font(run.style.face, run.style.size);
      check(run.font_height == float(fl_height()) && run.font_descent == float(fl_descent()) &&
                run.w == float(fl_width(run.text.c_str(), run.text.size())),
            "Wrapped words and split glyphs retain their painting metrics");
    }
  }
  if (reader.code_font.ready()) {
    block.kind = "code";
    text.text = "i\tW";
    auto flow = reader.flow({text}, block, 0, 0, 500, 16, 0);
    for (const auto &run : flow.runs) {
      const auto measured = reader.text_metrics(run.style, run.text == "\t" ? " " : run.text.data(), run.text.size());
      check(run.font_height == measured.height && run.font_descent == measured.descent,
            "Deferred monospace words and tabs retain their painting metrics");
    }
  }
}
