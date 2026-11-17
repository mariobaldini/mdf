#pragma once
#include <FL/Fl.H>
#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>
#include <unistd.h>

// The private compositor sends real keys/buttons and consumes the offered
// Wayland data source. Reading FLTK's own paste buffer would hide a rejected
// clipboard publication.
template<class App> void check_clipboard(App &app) {
  const char *directory = std::getenv("MDF_TEST_CLIPBOARD");
  if (!directory) return;
  const std::string base = std::string(directory) + "/";
  unsigned sequence = 0;
  auto read = [&](const char *name) {
    std::ifstream input(base + name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(input), {});
  };
  auto send = [&](const char *mode, const std::string &expected, const char *message) {
    auto *view = app.source_mode ? static_cast<Fl_Widget *>(app.source_view) : app.reader;
    std::ofstream command(base + "command");
    command << getpid() << ' ' << ++sequence << ' ' << mode << ' '
            << view->x() + 40 << ' ' << view->y() + 30 << '\n';
    command.close();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    const auto done = std::to_string(sequence) + "\n";
    while ((read("done") != done || read("clipboard") != expected) &&
           std::chrono::steady_clock::now() < deadline) Fl::wait(.01);
    // Dispatch the key/button batch after the compositor acknowledges it.
    Fl::check();
    if (read("done") != done || read("clipboard") != expected) {
      std::cerr << "Clipboard check: " << mode << ", expected " << expected.size()
                << " bytes, received " << read("clipboard").size() << ", selection "
                << (app.source_mode ? app.source_view->selected().size() : app.reader->selected().size()) << "\n";
      app.ensure(false, message);
    }
  };
  app.reader->selection = std::pair<size_t, size_t>{0, 13};
  const auto first = app.reader->selected();
  send("key", first, "Ctrl+C publishes the formatted selection to the Wayland clipboard");
  app.reader->selection = std::pair<size_t, size_t>{30, 14};
  const auto reversed = app.reader->selected();
  send("menu", reversed, "Right-click Copy preserves and copies a reversed selection");
  app.ensure(app.reader->selected() == reversed, "Right-click Copy retains the formatted selection");
  send("dismiss", reversed, "Dismissing the context menu preserves the clipboard");
  app.ensure(app.reader->selected() == reversed, "Dismissing the context menu retains the selection");
  app.reader->selection.reset();
  send("empty", reversed, "Ctrl+C without a selection preserves the clipboard");
  send("select", reversed, "The context menu disables Copy without a selection");
  app.ensure(app.reader->selected() == app.reader->plain, "Select all remains available without a selection");

  app.action("source");
  const char fixture[] = "# Copy café\r\n\t**text**\n\0end\n";
  app.source_view->set_source(std::string_view(fixture, sizeof(fixture) - 1));
  app.source_view->buffer()->select(0, 14);
  send("key", app.source_view->selected(), "Ctrl+C copies the selected original Markdown");
  app.source_view->select_all();
  const auto source = app.source_view->selected();
  send("menu", source, "Right-click Copy copies source text through the Wayland clipboard");
  app.ensure(app.source_view->selected() == source, "Right-click retains the source selection");
  app.source_view->set_source(view_text(app.core.source()));
  app.action("source");
  std::cout << "PASS: keyboard and context-menu clipboard transfers in formatted and source views\n";
}
