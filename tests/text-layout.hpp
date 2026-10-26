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
  check(probe.cached_words == 2048, "Width-dependent invalidation retains bounded word measurements");
  probe.invalidate_fonts();
  check(probe.cached_words == 0 && probe.text_measurements.empty(), "Font or display-scale invalidation clears old metrics");
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
  bool checked_table = false;
  for (size_t index = 0; index < reader.blocks.size(); ++index) {
    const auto &table = reader.blocks[index];
    if (table.kind != "table_row" || !table.table_header || table.cells.size() < 16) continue;
    reader.invalidate();
    const auto measured = reader.measure(index);
    for (const auto &run : measured.runs) {
      if (run.style.monospace || needs_fallback(run.text, reader.bundled_coverage)) continue;
      fl_font(run.style.face, run.style.size);
      check(run.w == float(fl_width(run.text.data(), run.text.size())) &&
                run.font_height == float(fl_height()) && run.font_descent == float(fl_descent()),
            "Table glyphs restore their own font after measuring column widths");
    }
    reader.invalidate();
    checked_table = true;
    break;
  }
  check(checked_table, "Large table font-state regression fixture exists");
}

template<class Check> void check_latin_boundaries(DocumentView &reader, Check check) {
  DocumentView probe(0, 0, 480, 500, reader.settings);
  probe.bundled_coverage = reader.bundled_coverage;
  Block block;
  block.kind = "paragraph";
  Span first{"one ab"}, bold{"cd"}, link{"ef x"};
  bold.bold = true;
  link.link = "#target";
  for (int size : {12, 18, 28}) {
    auto st = probe.style(first, block);
    st.size = size;
    fl_font(st.face, size);
    const float prefix = probe.text_metrics(st, "one ", 4).width;
    float word = 0;
    for (const auto &span : {first, bold, link}) {
      auto part = probe.style(span, block);
      part.size = size;
      fl_font(part.face, size);
      word += probe.text_metrics(part, span.text.data() + (span.bold || !span.link.empty() ? 0 : 4), 2).width;
    }
    const auto flow = probe.flow({first, bold, link}, block, 0, 0, std::max(word, prefix) + 1, size, 100);
    const auto &a = flow.runs.at(2), &b = flow.runs.at(3), &c = flow.runs.at(4);
    check(a.y > flow.runs[0].y && a.y == b.y && b.y == c.y && a.x == 0 &&
          a.pos == 104 && b.pos == 106 && c.pos == 108 && b.style.face != a.style.face && c.style.link == "#target",
          "A word across bold and link boundaries wraps together with styles and byte positions");
  }
  const std::string accent = "e\xcc\x81";
  const std::string source = accent + accent + accent;
  for (int size : {12, 18, 28}) for (int width : {480, 1040}) {
    auto prefs = probe.settings;
    prefs.size = size;
    probe.configure(prefs);
    probe.resize(0, 0, width, 500);
    Span text{source};
    const auto style = probe.style(text, block);
    fl_font(style.face, style.size);
    const float cluster_width = probe.text_metrics(style, accent.data(), accent.size()).width;
    const auto flow = probe.flow({text}, block, 0, 0, cluster_width + .1f, style.size, 0);
    check(flow.runs.size() == 3, "Oversized decomposed Latin tokens split into complete graphemes");
    for (const auto &run : flow.runs)
      check(run.text == accent && run.pos % accent.size() == 0 && std::abs(run.w - cluster_width) < .01f,
            "Accent runs retain the original UTF-8 bytes and shaped width");
    probe.blocks = {block};
    probe.blocks[0].spans = {text};
    probe.starts = {0};
    probe.plain = source;
    probe.invalidate();
    probe.prepare_visible();
    const auto &run = probe.cache.at(0).runs.front();
    const float y = probe.offsets[0] + run.y - run.style.size * .4f;
    for (float x = run.x - 1; x < run.x + run.w + 1; x += .25f) {
      const auto hit = probe.hit(x, y);
      check(hit && hit->pos % accent.size() == 0, "Pointer selection never enters a decomposed accent");
    }
    probe.pointer(0, run.x - 1, y);
    probe.pointer(1, run.x + cluster_width + .1f, y);
    probe.pointer(2, run.x + cluster_width + .1f, y);
    check(probe.selected() == accent, "Dragging and copying retain a complete decomposed accent");
    probe.hit_boundary_block = -1;
  }
  // A style split inside a grapheme must not create a line or cursor break.
  Span base{"e"}, mark{"\xcc\x81x"};
  mark.bold = true;
  auto split = probe.flow({base, mark}, block, 0, 0, 1, 16, 0);
  check(split.runs.size() == 3 && split.runs[0].y == split.runs[1].y &&
        split.runs[2].y > split.runs[1].y, "A styled combining mark stays on its base character's line");
}

template<class Check> void check_reflow_caches(DocumentView &reader, Check check) {
  DocumentView probe(0, 0, 1040, 500, reader.settings);
  Block block;
  block.kind = "paragraph";
  block.spans = {Span{"Retained measurements across widths and paint colors."}};
  probe.blocks = {block};
  probe.starts = {0};
  probe.invalidate();
  probe.prepare_visible();
  const auto misses = probe.measurement_misses, hits = probe.measurement_hits;
  probe.resize(0, 0, 480, 500);
  probe.prepare_visible();
  check(probe.measurement_misses == misses && probe.measurement_hits > hits,
        "Resizing reuses font measurements while rebuilding width-dependent layout");
  const auto builds = probe.layout_builds, words = probe.cached_words, geometry = probe.geometry_revision;
  const auto *runs = probe.cache.at(0).runs.data();
  auto prefs = probe.settings;
  prefs.dark = !prefs.dark;
  probe.configure(prefs);
  probe.prepare_visible();
  check(probe.layout_builds == builds && probe.cached_words == words && probe.geometry_revision == geometry &&
        probe.cache.at(0).runs.data() == runs && probe.text_color(probe.cache.at(0).runs.front().style) == probe.palette.fg,
        "Color-only settings preserve text runs, measurements and geometry");
  Style link{}; link.link = "#target";
  Style alert{}; alert.color_role = 8;
  check(probe.text_color(link) == probe.palette.link && probe.text_color(alert) == probe.palette.warning,
        "Retained links and alert labels resolve the active theme");
  probe.jump(0);
  probe.prepare_visible();
  check(probe.layout_builds == builds && probe.cache.at(0).runs.data() == runs,
        "TOC jumps through open ancestors retain layout");
  prefs.size += 1;
  probe.configure(prefs);
  check(probe.cached_words == 0 && probe.text_measurements.empty(), "Font-size changes invalidate measurements");

  Block details; details.kind = "details"; details.spans = {Span{"Summary"}};
  Block child = block; child.parent = 1;
  Block nested = details; nested.parent = 1;
  Block grandchild = block; grandchild.parent = 3;
  probe.blocks = {block, details, child, nested, grandchild, block};
  probe.starts = {0, 60, 70, 130, 140, 200};
  probe.resize(0, 0, 480, 70);
  probe.invalidate();
  probe.cache[0] = probe.measure(0);
  probe.heights[0] = probe.cache.at(0).height;
  probe.cache[5] = probe.measure(5);
  probe.heights[5] = probe.cache.at(5).height;
  probe.reindex();
  const auto *outside = probe.cache.at(0).runs.data();
  probe.scroll = probe.offsets[5] + 2;
  probe.toggle(1);
  check(probe.cache.at(0).runs.data() == outside && probe.cache.count(5) &&
        probe.index_at(probe.scroll) == 5 && std::abs(probe.scroll - probe.offsets[5] - 2) < .01f,
        "Details expansion retains outside layout and the reader's scroll anchor");
  probe.jump(4);
  check(probe.visible(4) && probe.blocks[1].details_open && probe.blocks[3].details_open &&
        probe.cache.at(0).runs.data() == outside, "TOC opens nested details without clearing unrelated layout");
  probe.scroll = probe.offsets[4] + 1;
  probe.toggle(1);
  check(!probe.visible(4) && probe.index_at(probe.scroll) == 1,
        "Collapsing the anchor's ancestor moves the anchor to its summary");
}
