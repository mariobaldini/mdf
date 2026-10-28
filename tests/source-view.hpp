#pragma once
#include "../frontend/source-view.hpp"

template<class Check> void check_source_view(const Settings &settings,
                                            const Palette &palette, Check check) {
  SourceView source(0, 0, 640, 480, settings, palette);
  check(!source.visible(), "The read-only source pane starts hidden");
  const std::string markdown = "# Raw **Markdown**\r\n\r\n- [ ] Task\n\n```zig\n\tconst x = 1;\n```\n";
  source.set_source(markdown);
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
  auto changed = settings;
  changed.line_wrap = false;
  changed.dark = !changed.dark;
  const auto other = Palette::get(changed);
  source.configure(changed, other);
  check(source.textfont() == FL_FREE_FONT && source.color() == other.bg && source.textcolor() == other.fg,
        "Source view uses the bundled font and the current theme without discovering system fonts");
}
