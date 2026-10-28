#pragma once
#include "../frontend/source-view.hpp"

template<class Check> void check_source_view(const Settings &settings,
                                            const Palette &palette, Check check) {
  SourceView source(0, 0, 640, 480, settings, palette);
  check(!source.visible(), "The read-only source pane starts hidden");
  check(source.vertical_scrollbar() != nullptr, "Source view exposes its real scrollbar for preview navigation");
  const std::string markdown = "# Raw **Markdown**\r\n\r\n- [ ] Task\n\n```zig\n\tconst x = 1;\n```\n";
  source.set_source(markdown);
  check(source.source_preview_builds() == 0, "Opening source does not pre-generate the source preview");
  const auto &preview = source.source_preview(256);
  check(preview.total_lines == 8 && preview.lines.size() == 8 &&
        preview.lines[0].text == "# Raw **Markdown**" && preview.lines[2].text == "- [ ] Task" &&
        preview.lines[4].text == "```zig" && preview.lines[5].text == "\tconst x = 1;",
        "Source preview retains raw syntax, blank lines and CRLF boundaries");
  const auto preview_revision = preview.revision;
  source.source_preview(256);
  check(source.source_preview_builds() == 1 && source.source_preview(256).revision == preview_revision,
        "Reopening an unchanged source preview reuses its cached sample");
  source.select_all();
  check(source.source_size() == markdown.size() && source.selected() == markdown,
        "Source selection preserves Markdown syntax, CRLF, tabs and trailing newlines");
  const char binary[] = {'\0', '#', ' ', 'x', '\n', 'y', '\0', 'z', '\n'};
  const std::string bytes(binary, sizeof(binary));
  source.set_source(bytes);
  source.select_all();
  check(source.source_size() == bytes.size() && source.selected() == bytes,
        "Source storage and explicit-length selection preserve embedded NUL bytes");
  source.buffer()->select(0, 3);
  check(source.selected() == std::string(1, '\0'), "Selecting a displayed replacement copies its original NUL");
  source.buffer()->select(3, 6);
  check(source.selected() == "# x", "Selections after a NUL map to the original byte offsets");
  source.set_source(std::string("é\0世", 6));
  check(source.source_preview_builds() == 1, "Changing source invalidates the preview without rebuilding it");
  check(source.source_preview(256).lines[0].text == "é\xef\xbf\xbd世",
        "Source preview makes embedded NUL visible without losing Unicode");
  source.select_all();
  check(source.selected() == std::string("é\0世", 6), "Unicode and NUL source bytes survive together");
  source.buffer()->select(2, 5);
  check(source.selected() == std::string(1, '\0'), "Unicode before a NUL preserves selection offsets");
  source.set_source("New document\n");
  check(source.selected().empty(), "Document replacement clears the previous source selection");
  source.select_all();
  check(source.selected() == "New document\n", "Source replacement does not retain previous document bytes");
  source.set_source({});
  source.select_all();
  check(source.source_size() == 0 && source.selected().empty(), "An empty document has empty source and selection");
  check(source.source_preview(256).lines.empty() && source.source_preview(256).total_lines == 0,
        "An empty source produces an empty preview");
  std::string many;
  for (int i = 0; i < 10000; ++i) many += "sample `code`\n";
  source.set_source(many);
  const auto &bounded = source.source_preview(64);
  check(bounded.total_lines == 10001 && bounded.lines.size() == 64 && bounded.lines.front().line == 0 &&
        bounded.lines.back().line == 10000,
        "Large source previews sample a bounded number of lines across the entire file");
  source.set_source(std::string(510, 'a') + "世世");
  const auto &truncated = source.source_preview(64);
  check(truncated.lines[0].text == std::string(510, 'a'),
        "Source preview truncation does not split UTF-8 characters");
  auto changed = settings;
  changed.line_wrap = false;
  changed.dark = !changed.dark;
  const auto other = Palette::get(changed);
  source.configure(changed, other);
  check(source.textfont() == FL_FREE_FONT && source.color() == other.bg && source.textcolor() == other.fg,
        "Source view uses the bundled font and the current theme without discovering system fonts");
}

template<class Check> void check_source_monospace(const Settings &settings,
                                                  const Palette &palette,
                                                  FontStore &fonts, const CodeFont &font,
                                                  Check check) {
  SourceView source(0, 0, 640, 480, settings, palette);
  if (!font.ready()) {
    check(!source.set_monospace(fonts, font), "Unavailable monospace preserves the existing fallback");
    return;
  }
  check(source.set_monospace(fonts, font), "Prepared system monospace is available to source view");
  fl_font(source.textfont(), source.textsize());
  check(std::abs(fl_width("iiii") - fl_width("WWWW")) < .01,
        "Source view renders narrow and wide Latin glyphs with equal advances");
  const auto face = source.textfont();
  auto changed = settings;
  changed.dark = !changed.dark;
  source.configure(changed, Palette::get(changed));
  check(source.textfont() == face, "Theme changes retain the source monospace font");
  source.set_source("    a\n\tb\n");
  source.select_all();
  check(source.selected() == "    a\n\tb\n", "Monospace source view preserves indentation and tabs");
}
