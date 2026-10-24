#include "view.hpp"
#include "bundled-fonts.hpp"
#include "startup.hpp"
#include "diagrams.hpp"
#include "../tests/text-layout.hpp"
#include <FL/Fl.H>
#include <FL/Fl_Box.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Double_Window.H>
#include <FL/Fl_Hold_Browser.H>
#include <FL/Fl_Menu_Bar.H>
#include <FL/Fl_Native_File_Chooser.H>
#include <FL/Fl_RGB_Image.H>
#include <FL/Fl_Scrollbar.H>
#include <FL/filename.H>
#include <FL/fl_ask.H>
#include <FL/fl_config.h>
#include <FL/platform.H>
#include <cassert>
#include <cerrno>
#include <chrono>
#include <fstream>
#include <iostream>
#include <pango/pangofc-font.h>
#include <sys/prctl.h>
#include <poll.h>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>
#include <wayland-client-core.h>
#if !FLTK_USE_WAYLAND || (defined(FLTK_USE_X11) && FLTK_USE_X11)
#error "Markdown FAST requires an FLTK Wayland-only build"
#endif
#if FLTK_USE_GL
#error "The Markdown FAST FLTK renderer must not use OpenGL"
#endif

struct App;
static App *active_app = nullptr;
static void wake();
class MainWindow : public Fl_Double_Window {
public:
  App *app = nullptr;
  MainWindow(int w, int h) : Fl_Double_Window(w, h, "Markdown FAST") {}
  void flush() override;
  void draw() override;
  void resize(int x, int y, int w, int h) override;
  int handle(int e) override;
};
struct MenuAction {
  App *app;
  std::string action;
};
class ContentsBrowser : public Fl_Hold_Browser {
public:
  using Fl_Hold_Browser::Fl_Hold_Browser;

protected:
  int item_height(void *item) const override {
    return Fl_Hold_Browser::item_height(item) + 10;
  }
  int incr_height() const override {
    return Fl_Hold_Browser::incr_height() + 10;
  }
  void item_draw(void *item, int x, int y, int w, int h) const override {
    Fl_Hold_Browser::item_draw(item, x + 10, y + 5, w - 12, h - 10);
  }
};
class IconButton : public Fl_Button {
public:
  enum Icon { contents, moon, sun, reset, wrap } icon;
  IconButton(int x, int y, int w, int h, Icon icon)
      : Fl_Button(x, y, w, h), icon(icon) {}
  void draw() override {
    Fl_Button::draw();
    const int cx = x() + w() / 2 + (value() ? 1 : 0),
              cy = y() + h() / 2 + (value() ? 1 : 0);
    fl_push_clip(x() + 2, y() + 2, w() - 4, h() - 4);
    fl_color(active_r() ? labelcolor() : fl_inactive(labelcolor()));
    fl_line_style(FL_SOLID, 2);
    if (icon == contents) {
      for (int yy : {-7, 0, 7}) {
        fl_line(cx - 9, cy + yy, cx - 7, cy + yy);
        fl_line(cx - 3, cy + yy, cx + 9, cy + yy);
      }
    } else if (icon == sun) {
      fl_arc(cx - 5, cy - 5, 10, 10, 0, 360);
      for (int i = 0; i < 8; ++i) {
        const double a = i * 3.141592653589793 / 4;
        fl_line(cx + std::round(7 * std::cos(a)),
                cy + std::round(7 * std::sin(a)),
                cx + std::round(10 * std::cos(a)),
                cy + std::round(10 * std::sin(a)));
      }
    } else if (icon == moon) {
      // Two circular arcs form a crescent, independent of the background color.
      fl_begin_loop();
      const double a = std::acos(1.0 / 3);
      for (int i = 0; i <= 32; ++i) {
        const double t = -a - i * (2 * 3.141592653589793 - 2 * a) / 32;
        fl_vertex(cx + 9 * std::cos(t), cy + 9 * std::sin(t));
      }
      for (int i = 0; i <= 24; ++i) {
        const double t = 3.141592653589793 - a + i * 2 * a / 24;
        fl_vertex(cx + 6 + 9 * std::cos(t), cy + 9 * std::sin(t));
      }
      fl_end_loop();
    } else if (icon == wrap) {
      fl_line(cx - 9, cy - 7, cx + 9, cy - 7);
      fl_line(cx - 9, cy, cx + 6, cy);
      fl_arc(cx + 2, cy, 8, 8, -90, 90);
      fl_line(cx + 6, cy + 8, cx - 1, cy + 8);
      fl_line(cx + 2, cy + 5, cx - 1, cy + 8, cx + 2, cy + 11);
      fl_line(cx - 9, cy + 7, cx - 5, cy + 7);
    } else {
      fl_line_style(FL_SOLID | FL_CAP_ROUND | FL_JOIN_ROUND, 2);
      fl_arc(cx - 7, cy - 7, 14, 14, -135, 155);
      fl_line(cx - 6, cy - 8, cx - 6, cy - 3, cx - 1, cy - 3);
    }
    fl_line_style(0);
    fl_pop_clip();
  }
};
static const MdfStartup *launch_context = nullptr;
struct App {
  static constexpr int scrollbar_width = 20;
  Core &core;
  MdfDiagramStats startup_image_module{};
  FontStore &fonts;
  Settings settings;
  std::unique_ptr<MainWindow> window;
  Fl_Menu_Bar *menu;
  Fl_Group *toolbar;
  IconButton *toc_button, *theme_button, *wrap_button;
  Fl_Button *width_button, *preview_button;
  Fl_Button *font_decrease_button, *font_reset_button, *font_increase_button;
  Fl_Box *font_group_start, *font_group_end;
  Fl_Box *status, *toc_title;
  Fl_Hold_Browser *toc;
  DocumentView *reader;
  Minimap *minimap;
  Fl_Scrollbar *scrollbar, *horizontal_scrollbar;
  std::vector<std::unique_ptr<MenuAction>> commands;
  std::vector<int> toc_indices;
  enum Stage { scaffold, document, chrome, ready } stage = scaffold;
  uint64_t origin, backend_ready = 0, scaffold_ns = 0, first_document = 0, first_document_commit = 0,
                   first_buffer_flush = 0, first_document_flush = 0, commit_sequence = 0, flushed_sequence = 0,
                   full_ready = 0, read_ns = 0, parse_ns = 0, source_bytes = 0,
                   layout_ns = 0, frames = 0, document_frames = 0;
  bool profiling = false, benchmark = false, self_test = false,
       scroll_profile = false, after_pending = false,
       navigation_started = false, navigation_ready = false, failed = false,
       done = false, capture_reader = false, initialized = false;
  uint64_t painted_revision = 0;
  bool painted_navigation = false;
  struct FrameSnapshot {
    uint64_t revision = 0;
    bool navigation = false, monospace = false, mono_finished = false;
    unsigned fallback = 0;
  } submitted;
  bool socket_write_pending = false;
  double measured_window_scale = 0;
  bool painted_monospace = false, painted_mono_finished = false, first_viewport_monospace = false;
  MonospaceWorker monospace_worker;
  bool mono_requested = false, mono_finished = false;
  uint64_t mono_request_ns = 0, mono_adopted_ns = 0, mono_frame_ns = 0;
  std::string mono_error;
  FallbackWorker fallback_worker;
  bool fallback_requested = false, fallback_finished = false, first_viewport_fallback = false;
  uint64_t fallback_request_ns = 0, fallback_adopted_ns = 0, fallback_frame_ns = 0;
  unsigned fallback_generation = 0, painted_fallback_generation = 0;
  std::vector<FcChar32> attempted_glyphs;
  std::string fallback_error;
  ImageWorker image_worker;
  uint64_t first_diagram_ns = 0;
  bool images_started = false, images_ready = false;
  bool refresh_diagram_fonts = false;
  bool svg_present = false;
  float navigation_width = 0, navigation_zoom = 0;
  std::string capture, capture_anchor, initial_path, error;
  std::vector<double> scroll_draw_ms;
  Json startup_usage;
  uint64_t startup_frames = 0, scroll_frames = 0;
  bool drop_pending = false;
  App(Core &c, FontStore &f, Settings prefs, uint64_t started, bool prof,
      bool bench, bool test, bool scroll, const std::string &path,
      const std::string &capture)
      : core(c), fonts(f), settings(prefs), origin(started), profiling(prof),
        benchmark(bench), self_test(test), scroll_profile(scroll),
        capture(capture), initial_path(path) {
    PHASE("Create native FLTK widgets");
    window = std::make_unique<MainWindow>(settings.window_w, settings.window_h);
    window->app = this;
    window->size_range(420, 240);
    window->begin();
    menu = new Fl_Menu_Bar(0, 0, window->w(), 28);
    toolbar = new Fl_Group(0, 28, window->w(), 46);
    toolbar->begin();
    toc_button = new IconButton(10, 35, 36, 32, IconButton::contents);
    toc_button->tooltip("Show or hide table of contents");
    theme_button = new IconButton(53, 35, 36, 32, IconButton::moon);
    width_button = new Fl_Button(96, 35, 64, 32, "80%");
    width_button->tooltip("Switch between 80% and 100% text width");
    font_group_start = new Fl_Box(167, 40, 1, 22);
    font_decrease_button = new Fl_Button(174, 35, 32, 32, "−");
    font_reset_button = new IconButton(213, 35, 32, 32, IconButton::reset);
    font_increase_button = new Fl_Button(252, 35, 32, 32, "+");
    font_decrease_button->tooltip("Decrease font size");
    font_reset_button->tooltip("Reset font size to theme default");
    font_increase_button->tooltip("Increase font size");
    font_group_end = new Fl_Box(291, 40, 1, 22);
    wrap_button = new IconButton(298, 35, 28, 32, IconButton::wrap);
    for (auto *divider : {font_group_start, font_group_end})
      divider->box(FL_FLAT_BOX);
    preview_button = new Fl_Button(window->w() - 90, 35, 80, 32, "Preview");
    toolbar->resizable(nullptr);
    toolbar->end();
    toc_title = new Fl_Box(14, 82, 200, 24, "Contents");
    toc_title->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE);
    toc_title->labelsize(15);
    toc = new ContentsBrowser(0, 110, 220, window->h() - 134);
    toc->format_char(0);
    toc->has_scrollbar(Fl_Browser_::VERTICAL);
    toc->box(FL_FLAT_BOX);
    toc->textfont(FL_FREE_FONT);
    toc->textsize(15);
    toc->callback(
        [](Fl_Widget *, void *ptr) {
          auto &a = *(App *)ptr;
          int row = a.toc->value() - 1;
          if (row >= 0 && row < (int)a.toc_indices.size()) {
            a.reader->jump(a.toc_indices[row]);
            a.scroll_changed();
          }
        },
        this);
    reader = new DocumentView(220, 74, window->w() - 370, window->h() - 98,
                              settings);
    scrollbar = new Fl_Scrollbar(window->w() - 150, 74, scrollbar_width,
                                 window->h() - 98);
    scrollbar->type(FL_VERTICAL);
    scrollbar->callback(
        [](Fl_Widget *w, void *p) {
          auto &a = *(App *)p;
          a.reader->move_scroll(((Fl_Scrollbar *)w)->value());
        },
        this);
    horizontal_scrollbar = new Fl_Scrollbar(220, window->h() - 24 - scrollbar_width,
                                            reader->w(), scrollbar_width);
    horizontal_scrollbar->type(FL_HORIZONTAL);
    horizontal_scrollbar->callback(
        [](Fl_Widget *w, void *p) {
          static_cast<App *>(p)->reader->move_horizontal(static_cast<Fl_Scrollbar *>(w)->value());
        }, this);
    horizontal_scrollbar->hide();
    minimap = new Minimap(window->w() - 130, 94, 130, window->h() - 138,
                          *reader, *scrollbar);
    status = new Fl_Box(10, window->h() - 24, window->w() - 20, 24,
                        "Opening document…");
    status->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_CLIP);
    status->labelsize(11);
    window->end();
    for (auto *w :
         {(Fl_Widget *)menu, (Fl_Widget *)toc_button, (Fl_Widget *)theme_button,
          (Fl_Widget *)width_button, (Fl_Widget *)preview_button,
          (Fl_Widget *)font_decrease_button, (Fl_Widget *)font_reset_button,
          (Fl_Widget *)font_increase_button, (Fl_Widget *)status,
          (Fl_Widget *)wrap_button,
          (Fl_Widget *)toc_title})
      w->labelfont(FL_FREE_FONT);
    menu->textfont(FL_FREE_FONT);
    menu->textsize(16);
    bind(toc_button, "toc");
    bind(theme_button, "dark");
    bind(width_button, "width-cycle");
    bind(font_decrease_button, "smaller");
    bind(font_reset_button, "font-reset");
    bind(font_increase_button, "larger");
    bind(preview_button, "preview");
    bind(wrap_button, "line-wrap");
    add_menu("File/Open…", FL_CTRL + 'o', "open");
    add_menu("File/Reload", FL_CTRL + 'r', "reload");
    add_menu("File/Quit", FL_CTRL + 'q', "quit");
    add_menu("View/Table of contents", 0, "toc", FL_MENU_TOGGLE);
    add_menu("View/Preview", 0, "preview", FL_MENU_TOGGLE);
    add_menu("View/Line wrap", 0, "line-wrap", FL_MENU_TOGGLE);
    add_menu("View/80% width", 0, "width80", FL_MENU_RADIO);
    add_menu("View/100% width", 0, "width100", FL_MENU_RADIO);
    add_menu("View/Copy selection", FL_CTRL + 'c', "copy");
    add_menu("View/Select all", FL_CTRL + 'a', "select-all");
    for (int size :
         {8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72}) {
      auto label = "Font/Size/" + std::to_string(size);
      auto action = "size:" + std::to_string(size);
      add_menu(label.c_str(), 0, action.c_str(), FL_MENU_RADIO);
    }
    add_menu("Font/Larger", FL_CTRL + '=', "larger");
    add_menu("Font/Smaller", FL_CTRL + '-', "smaller");
    add_menu("Font/Default size", FL_CTRL + '0', "font-reset");
    for (size_t i = 0; i < mdf_theme_count(); ++i) {
      const auto theme = mdf_theme_info(i);
      add_menu(("Theme/" + view_text(theme.name)).c_str(), 0,
               ("theme:" + view_text(theme.id)).c_str(), FL_MENU_RADIO);
    }
    add_menu("Settings/Automatic reload", 0, "auto-reload", FL_MENU_TOGGLE);
    add_menu("Settings/Save settings across sessions", 0, "save-settings",
             FL_MENU_TOGGLE);
    add_menu("Settings/Reset settings", 0, "reset");
    add_menu("Help/About Markdown FAST", 0, "about");
    add_menu("Help/Third-party licenses", 0, "licenses");
    reader->changed = [this]() { scroll_changed(); };
    reader->follow = [this](auto &url) { follow(url); };
    window->callback(
        [](Fl_Widget *, void *p) {
          auto &a = *(App *)p;
          a.save_geometry();
          a.done = true;
          a.window->hide();
        },
        this);
    active_app = this;
    set_title(path);
  }
  // Widget construction above performs no text measurement or presentation.
  // Finalize geometry only after the GUI thread has adopted all four faces.
  void initialize() {
    PHASE("Configure scaffold geometry and colors");
    reader->bundled_coverage = fonts.coverage;
    apply_chrome();
    layout();
    reader->invalidate();
    initialized = true;
  }
  ~App() {
    if (socket_write_pending) Fl::remove_fd(wl_display_get_fd(fl_wl_display()), FL_WRITE);
    fl_mdf_wayland_startup_shutdown();
    active_app = nullptr;
    window.reset();
  }
  static void callback(Fl_Widget *, void *p) {
    auto &c = *(MenuAction *)p;
    c.app->action(c.action);
  }
  MenuAction *command(const std::string &a) {
    commands.push_back(std::make_unique<MenuAction>(MenuAction{this, a}));
    return commands.back().get();
  }
  void bind(Fl_Widget *w, const std::string &a) {
    w->callback(callback, command(a));
  }
  void add_menu(const char *label, int shortcut, const char *action,
                int flags = 0) {
    menu->add(label, shortcut, callback, command(action), flags);
  }
  void message(const std::string &s) {
    status->copy_label(s.c_str());
    status->redraw();
  }
  void trace(const char *step) {
    if (std::getenv("MDF_TRACE_STARTUP"))
      std::cerr << "mdf: " << (mdf_now_ns() - origin) / 1e6 << " ms: " << step
                << " (stage " << int(stage) << ", frames " << frames << ")\n";
  }
  void set_title(const std::string &path) {
    auto pos = path.find_last_of('/');
    auto name = path.empty()
                    ? "Markdown FAST"
                    : path.substr(pos == std::string::npos ? 0 : pos + 1);
    auto label = path.empty() ? name : name + " — Markdown FAST";
    if (!window->label() || label != window->label())
      window->copy_label(label.c_str());
  }
  void layout() {
    int W = window->w(), H = window->h(),
        left = settings.toc ? std::min(220, int(W * .22)) : 0,
        right = settings.preview ? std::min(130, int(W * .12)) : 0, Y = 74,
        view_h = std::max(1, H - Y - 24);
    menu->resize(0, 0, W, 28);
    toolbar->resize(0, 28, W, 46);
    toc_button->resize(10, 35, 36, 32);
    theme_button->resize(53, 35, 36, 32);
    width_button->resize(96, 35, 64, 32);
    font_group_start->resize(167, 40, 1, 22);
    font_decrease_button->resize(174, 35, 32, 32);
    font_reset_button->resize(213, 35, 32, 32);
    font_increase_button->resize(252, 35, 32, 32);
    font_group_end->resize(291, 40, 1, 22);
    wrap_button->resize(298, 35, 28, 32);
    preview_button->resize(W - 90, 35, 80, 32);
    toc_title->resize(14, Y + 8, std::max(1, left - 20), 24);
    toc->resize(0, Y + 36, left, std::max(1, view_h - 36));
    if (settings.toc) {
      toc->show();
      toc_title->show();
    } else {
      toc->hide();
      toc_title->hide();
    }
    const bool horizontal = !settings.line_wrap || reader->max_horizontal_scroll() > 0;
    reader->resize(left, Y, std::max(1, W - left - right - scrollbar_width),
                   std::max(1, view_h - (horizontal ? scrollbar_width : 0)));
    horizontal_scrollbar->resize(reader->x(), reader->y() + reader->h(), reader->w(), scrollbar_width);
    if (!horizontal) horizontal_scrollbar->hide();
    else horizontal_scrollbar->show();
    scrollbar->resize(W - right - scrollbar_width, Y, scrollbar_width, view_h);
    // The scrollbar's arrow buttons sit outside its document track.
    const int inset = view_h >= 3 * scrollbar_width ? scrollbar_width : 0;
    minimap->resize(W - right, Y + inset, std::max(1, right),
                    std::max(1, view_h - 2 * inset));
    if (settings.preview)
      minimap->show();
    else
      minimap->hide();
    status->resize(10, H - 24, W - 20, 24);
    window->redraw();
  }
  void apply_chrome() {
    auto p = Palette::get(settings);
    const auto buttons = Palette::get(Settings{});
    unsigned char r, g, b;
    Fl::get_color(p.panel, r, g, b);
    Fl::background(r, g, b);
    Fl::get_color(p.bg, r, g, b);
    Fl::background2(r, g, b);
    Fl::get_color(p.fg, r, g, b);
    Fl::foreground(r, g, b);
    Fl::set_color(FL_SELECTION_COLOR, p.link);
    window->color(p.bg);
    menu->color(p.panel);
    menu->box(settings.dark ? FL_FLAT_BOX : FL_UP_BOX);
    menu->textcolor(p.fg);
    toolbar->color(p.panel);
    toolbar->box(FL_FLAT_BOX);
    for (auto *divider : {font_group_start, font_group_end})
      divider->color(p.border);
    toc->color(p.panel);
    toc->textcolor(p.fg);
    toc->selection_color(fl_color_average(p.link, p.panel, .2f));
    toc_title->labelcolor(p.fg);
    toc_title->labelfont(FL_FREE_FONT + 1);
    status->labelcolor(p.muted);
    scrollbar->color(p.panel);
    horizontal_scrollbar->color(p.panel);
    for (auto *w :
         {static_cast<Fl_Button *>(toc_button),
          static_cast<Fl_Button *>(theme_button), width_button, preview_button,
          font_decrease_button, font_reset_button, font_increase_button,
          static_cast<Fl_Button *>(wrap_button)}) {
      w->labelsize(14);
      w->color(p.panel);
      w->labelcolor(p.fg);
      w->selection_color(buttons.link);
    }
    for (auto *w :
         {font_decrease_button, font_reset_button, font_increase_button})
      w->labelsize(18);
    if (settings.size <= 8)
      font_decrease_button->deactivate();
    else
      font_decrease_button->activate();
    if (settings.size >= 72)
      font_increase_button->deactivate();
    else
      font_increase_button->activate();
    for (auto *w :
         {settings.toc ? static_cast<Fl_Button *>(toc_button) : nullptr,
          settings.preview ? preview_button : nullptr})
      if (w) {
        w->color(buttons.link);
        w->labelcolor(FL_WHITE);
      }
    if (!settings.line_wrap) {
      wrap_button->color(buttons.link);
      wrap_button->labelcolor(FL_WHITE);
    }
    wrap_button->value(!settings.line_wrap);
    wrap_button->tooltip(settings.line_wrap ? "Enable no-wrap mode" : "No-wrap mode active — click to wrap lines");
    theme_button->icon = settings.dark ? IconButton::sun : IconButton::moon;
    theme_button->tooltip(settings.dark ? "Switch to light mode"
                                        : "Switch to dark mode");
    width_button->copy_label(settings.width == "percent_100" ? "100%" : "80%");
    preview_button->tooltip(settings.preview ? "Hide preview" : "Show preview");
    for (auto pair :
         {std::pair<const char *, bool>{"View/Table of contents", settings.toc},
          {"View/Preview", settings.preview},
          {"View/Line wrap", settings.line_wrap},
          {"Settings/Automatic reload", settings.reload},
          {"Settings/Save settings across sessions", settings.save}}) {
      if (auto *item =
              const_cast<Fl_Menu_Item *>(menu->find_item(pair.first))) {
        if (pair.second)
          item->set();
        else
          item->clear();
      }
    }
    for (auto &command : commands) {
      const auto &a = command->action;
      bool theme = a.rfind("theme:", 0) == 0;
      bool size = a.rfind("size:", 0) == 0;
      bool width = a == "width80" || a == "width100";
      if (!(theme || size || width))
        continue;
      bool selected =
          theme  ? a.substr(6) == settings.theme
          : size ? std::stoi(a.substr(5)) == settings.size
                 : (a == "width100") == (settings.width == "percent_100");
      for (int i = 0; i < menu->size(); ++i) {
        auto *item = const_cast<Fl_Menu_Item *>(menu->menu() + i);
        if (item->user_data() == command.get()) {
          if (selected)
            item->set();
          else
            item->clear();
        }
      }
    }
    window->redraw();
  }
  void scroll_changed() {
    const bool horizontal = !settings.line_wrap || reader->max_horizontal_scroll() > 0;
    if (bool(horizontal_scrollbar->visible()) != horizontal) layout();
    const int position = reader->scroll;
    const int total =
        std::max({reader->h(), int(reader->total()), position + reader->h()});
    scrollbar->bounds(0, total - reader->h());
    scrollbar->value(position);
    // A fixed 10% handle keeps preview navigation usable on large documents.
    scrollbar->slider_size(.1);
    if (horizontal_scrollbar->visible()) {
      const int total_width = std::max(reader->w(), int(reader->horizontal_total()));
      horizontal_scrollbar->value(int(std::round(reader->horizontal_scroll)), reader->w(), 0, total_width);
      horizontal_scrollbar->linesize(std::max(1, int(reader->body_size() * 3)));
      if (total_width > reader->w()) horizontal_scrollbar->activate();
      else horizontal_scrollbar->deactivate();
    }
    minimap->redraw();
    int index = reader->index_at(reader->scroll), row = 0;
    for (size_t i = 0; i < toc_indices.size(); ++i)
      if (toc_indices[i] <= index)
        row = i + 1;
    toc->select(row);
  }
  void settings_changed(bool navigation = true) {
    settings.size = std::clamp(settings.size, 8, 72);
    try {
      core.save(settings.json());
    } catch (std::exception &e) {
      message(e.what());
    }
    const bool diagram_colors = reader->has_diagrams && reader->settings.dark != settings.dark;
    reader->configure(settings);
    if (diagram_colors) {
      image_worker.reset();
      images_started = images_ready = false;
    }
    apply_chrome();
    layout();
    if (first_document && navigation)
      start_navigation();
  }
  void open(const std::string &path) {
    try {
      core.open(path);
      message("Opening " + path + "…");
    } catch (std::exception &e) {
      message(e.what());
    }
  }
  void start_navigation(bool pending_document = false) {
    if (!pending_document && reader->path.empty())
      return;
    navigation_ready = false;
    if (pending_document) {
      refresh_diagram_fonts = false;
      svg_present = false;
      images_started = images_ready = false;
      image_worker.reset();
    }
    navigation_started = false;
    try {
      navigation_width = reader->content_width;
      navigation_zoom = reader->zoom();
      core.start_navigation(reader->content_width, reader->zoom(),
                            reader->character_width());
      navigation_started = true;
    } catch (std::exception &e) {
      navigation_ready = images_ready = true;
      message(e.what());
    }
  }
  void poll() {
    if (!initialized)
      return;
    PHASE("Accept document and prepared workers");
    trace("poll workers");
    try {
      if (mono_requested && !mono_finished && monospace_worker.complete()) {
        auto prepared = monospace_worker.take();
        mono_finished = true;
        if (prepared && prepared->available()) {
          try {
            reader->adopt_code_font(std::move(prepared));
            mono_adopted_ns = mdf_now_ns();
            PROFILE_MARK("System monospace adopted");
          } catch (const std::exception &failure) {
            mono_error = failure.what();
          }
        } else mono_error = prepared ? prepared->error : "System monospace unavailable";
        if (!reader->code_font.ready()) PROFILE_MARK("System monospace unavailable");
        minimap->redraw();
        window->redraw();
      }
      if (fallback_requested && !fallback_finished && fallback_worker.complete()) {
        auto prepared = fallback_worker.take();
        fallback_finished = true;
        ++fallback_generation;
        if (prepared && prepared->available()) {
          try {
            reader->adopt_fallback_font(std::move(prepared));
            fonts.add_fallback(reader->fallback_font);
            for (const auto &block : reader->blocks) if (block.mermaid())
              for (const auto &span : block.spans)
                refresh_diagram_fonts = refresh_diagram_fonts || needs_fallback(span.text, fonts.coverage);
            refresh_diagram_fonts = refresh_diagram_fonts || svg_present;
            if (refresh_diagram_fonts && images_ready) {
              images_started = false;
              images_ready = false;
            }
            fallback_adopted_ns = mdf_now_ns();
            PROFILE_MARK("System Sans fallback adopted");
          } catch (const std::exception &failure) {
            fallback_error = failure.what();
          }
        } else fallback_error = prepared ? prepared->error : "System Sans fallback unavailable";
        if (!reader->fallback_font.ready()) PROFILE_MARK("System Sans fallback unavailable");
        minimap->redraw();
        toc->redraw();
        window->redraw();
      }
      auto doc = core.poll();
      if (!doc.is_null()) {
        trace("document model transferred");
        {
          PHASE("Accept loaded document");
          read_ns = doc.value("read_ns", 0ull);
          parse_ns = doc.value("parse_ns", 0ull);
          source_bytes = doc.value("source_bytes", 0ull);
          // The immutable Zig document is ready now. Start CPU/file work
          // before copying the reader model or waiting for a window frame.
          navigation_started = false;
          start_navigation(true);
          reader->document(doc, core, fonts);
          trace("document model accepted");
          set_title(reader->path);
          toc->clear();
          toc_indices.clear();
          stage = scaffold_ns ? document : scaffold;
          message("Document loaded");
          window->redraw();
        }
        return;
      }
      if (navigation_started && !images_started && mdf_core_navigation_ready(core.handle)) {
        PHASE("Prepare image decoding jobs");
        std::vector<EncodedImage> inputs;
        bool use_diagram_fallback = false;
        for (size_t i = 0; i < reader->blocks.size(); ++i) {
          if (reader->blocks[i].mermaid()) {
            bool missing = false;
            for (const auto &span : reader->blocks[i].spans)
              missing = missing || needs_fallback(span.text, fonts.coverage);
            std::vector<unsigned char> source;
            for (const auto &span : reader->blocks[i].spans)
              source.insert(source.end(), span.text.begin(), span.text.end());
            inputs.push_back({int(i), std::move(source), EncodedImage::mermaid, missing});
            use_diagram_fallback = use_diagram_fallback || (missing && reader->fallback_font.ready());
            continue;
          }
          if (reader->blocks[i].image_src.empty()) continue;
          if (reader->images.count(i) && !(refresh_diagram_fonts && reader->diagram_sizes.count(i))) continue;
          auto bytes = core.image(i);
          if (bytes.ptr && bytes.len >= 4 &&
              ((bytes.ptr[0] == 137 && bytes.ptr[1] == 'P') ||
               (bytes.ptr[0] == 255 && bytes.ptr[1] == 216) ||
               (bytes.ptr[0] == 'G' && bytes.ptr[1] == 'I') ||
               (bytes.ptr[0] == 'B' && bytes.ptr[1] == 'M')))
            inputs.push_back({int(i), std::vector<unsigned char>(bytes.ptr, bytes.ptr + bytes.len)});
          else if (svg_image(bytes.ptr, bytes.len)) {
            svg_present = true;
            inputs.push_back({int(i), std::vector<unsigned char>(bytes.ptr, bytes.ptr + bytes.len),
                              EncodedImage::svg, reader->fallback_font.ready()});
            use_diagram_fallback = use_diagram_fallback || reader->fallback_font.ready();
          }
        }
        if (inputs.empty()) images_ready = true;
        else image_worker.start(reader->revision, std::move(inputs), Fl_RGB_Image::max_size(), wake, settings.dark,
                                use_diagram_fallback ? reader->fallback_font.resources() : nullptr, first_document != 0);
        refresh_diagram_fonts = false;
        images_started = true;
      }
      // Do not manufacture a second frame if all optional work is already
      // prepared before the first paint. Otherwise keep Markdown responsive.
      if (!first_document &&
          !(images_ready || (images_started && image_worker.complete())))
        return;
      if (navigation_started && (std::abs(navigation_width - reader->content_width) >= 1 ||
                                  navigation_zoom != reader->zoom()))
        start_navigation();
      if (navigation_started && !navigation_ready) {
        trace("poll navigation");
        auto nav = core.navigation();
        auto state = text(nav, "status");
        if (state == "ready" &&
            nav.value("revision", 0ull) == reader->revision) {
          {
            PHASE("Apply table of contents and preview");
            toc->clear();
            toc_indices.clear();
            for (auto h : nav.get("headings")) {
              int index = h.value("index", 0), level = h.value("level", 1);
              toc_indices.push_back(index);
              auto label = std::string(std::min(4, level - 1) * 2, ' ') +
                           text(h, "title");
              toc->add(label.c_str());
            }
            reader->preview.clear();
            for (auto p : nav.get("preview"))
              reader->preview.push_back(
                  p.get("lines").as<std::vector<std::string>>());
            ++reader->preview_revision;
            ++reader->geometry_revision;
            navigation_ready = true;
            trace("navigation applied");
            minimap->redraw();
          }
          reader->redraw();
          minimap->redraw();
          scroll_changed();
        } else if (state == "failed") {
          navigation_ready = images_ready = true;
          message("Navigation preview unavailable");
        }
      }
      if (images_started && !images_ready && image_worker.complete()) {
        PHASE("Adopt decoded image pixels");
        reader->horizontal_dirty = true;
        PROFILE_MARK("Accept images");
        if (!first_diagram_ns) first_diagram_ns = image_worker.first_diagram_ns;
        for (auto &prepared : image_worker.take()) {
          if (image_worker.revision != reader->revision) continue;
          if (prepared.diagram) {
            reader->diagram_errors.erase(prepared.index);
            reader->diagram_sizes.erase(prepared.index);
            if (!prepared.error.empty()) {
              reader->has_code = reader->has_code || reader->blocks[prepared.index].mermaid();
              reader->images.erase(prepared.index);
              reader->image_pixels.erase(prepared.index);
              reader->diagram_errors[prepared.index] = prepared.error;
              reader->cache.erase(prepared.index);
              continue;
            }
            reader->diagram_sizes[prepared.index] = {prepared.logical_width, prepared.logical_height};
          }
          const auto &pixels = prepared.pixels->image;
          reader->images[prepared.index] = std::make_unique<Fl_RGB_Image>(pixels.data, pixels.width, pixels.height, pixels.channels);
          reader->image_pixels[prepared.index] = std::move(prepared.pixels);
          reader->cache.erase(prepared.index);
        }
        images_ready = !refresh_diagram_fonts;
        if (refresh_diagram_fonts) images_started = false;
        reader->redraw();
        minimap->redraw();
      }
      if (navigation_ready && images_ready && stage != ready) {
        const bool transition = stage != chrome;
        stage = chrome;
        if (std::strcmp(status->label(), "Ready")) message("Ready");
        if (transition) window->redraw();
      }
    } catch (std::exception &e) {
      error = e.what();
      message("Could not open document: " + error);
      if (profiling || benchmark || self_test) {
        failed = true;
        done = true;
        window->hide();
      }
    }
  }
  bool flush_frame_socket() {
    PHASE("Flush committed window buffer to Wayland socket");
    const int sent = wl_display_flush(fl_wl_display());
    if (sent < 0) {
      if (errno == EAGAIN && !socket_write_pending) {
        socket_write_pending = true;
        Fl::add_fd(wl_display_get_fd(fl_wl_display()), FL_WRITE, [](int, void *data) {
          auto &app = *static_cast<App *>(data);
          if (app.flush_frame_socket()) app.queue_presentation();
        }, this);
      }
      return false;
    }
    if (socket_write_pending) {
      Fl::remove_fd(wl_display_get_fd(fl_wl_display()), FL_WRITE);
      socket_write_pending = false;
    }
    flushed_sequence = commit_sequence;
    const auto now = mdf_now_ns();
    if (!first_buffer_flush) first_buffer_flush = now;
    if (submitted.revision && submitted.revision == reader->revision && !first_document_flush) {
      first_document_flush = now;
      PROFILE_MARK("First Markdown buffer flushed to socket");
    }
    return true;
  }
  void buffer_committed() {
    submitted = {painted_revision, painted_navigation, painted_monospace,
                 painted_mono_finished, painted_fallback_generation};
    ++commit_sequence;
    if (submitted.revision && submitted.revision == reader->revision && !first_document_commit) {
      first_document_commit = mdf_now_ns();
      PROFILE_MARK("First Markdown buffer committed");
    }
    // Commit can be deferred to a frame callback after draw() returns. Only
    // this hook knows which reader pixels actually reached the shared buffer.
    flush_frame_socket();
    queue_presentation();
  }
  void presented() {
    PHASE("Run deferred frame presentation callback");
    trace("frame presented");
    after_pending = false;
    if (!commit_sequence || flushed_sequence != commit_sequence || socket_write_pending) {
      poll();
      return;
    }
    const uint64_t submitted_at = mdf_now_ns();
    if (!scaffold_ns) {
      scaffold_ns = submitted_at;
      stage = document;
    }
    if (submitted.revision && submitted.revision == reader->revision &&
        (stage == document || !first_document)) {
      ++document_frames;
      if (!first_document) {
        first_document = submitted_at;
        first_viewport_monospace = submitted.monospace;
        first_viewport_fallback = submitted.fallback != 0;
        if (self_test || profiling) prctl(PR_SET_NAME, "mdf-viewport");
        image_worker.allow_diagrams();
      }
      stage = chrome;
    }
    if (submitted.revision && submitted.revision == reader->revision && reader->has_code && !mono_requested) {
      // No system configuration, font lookup, file read or thread creation
      // is permitted until this document has actually had a Markdown frame.
      mono_requested = true;
      mono_request_ns = mdf_now_ns();
      try {
        monospace_worker.start(wake);
      } catch (const std::exception &failure) {
        mono_finished = true;
        mono_error = failure.what();
        PROFILE_MARK("System monospace unavailable");
        window->redraw();
      }
    }
    if (submitted.monospace && submitted.revision == reader->revision && !mono_frame_ns)
      mono_frame_ns = submitted_at;
    if (submitted.revision && submitted.revision == reader->revision &&
        (!fallback_requested || fallback_finished)) {
      bool needed = false;
      for (auto ch : reader->required_glyphs)
        if (!reader->fallback_font.has_character(ch) &&
            !std::binary_search(attempted_glyphs.begin(), attempted_glyphs.end(), ch)) needed = true;
      if (needed) {
        attempted_glyphs.insert(attempted_glyphs.end(), reader->required_glyphs.begin(), reader->required_glyphs.end());
        std::sort(attempted_glyphs.begin(), attempted_glyphs.end());
        attempted_glyphs.erase(std::unique(attempted_glyphs.begin(), attempted_glyphs.end()), attempted_glyphs.end());
        fallback_requested = true;
        fallback_finished = false;
        fallback_error.clear();
        if (!fallback_request_ns) fallback_request_ns = mdf_now_ns();
        try {
          fallback_worker.start(reader->required_glyphs, fonts.fds, wake);
        } catch (const std::exception &failure) {
          fallback_finished = true;
          ++fallback_generation;
          fallback_error = failure.what();
          PROFILE_MARK("System Sans fallback unavailable");
          window->redraw();
        }
      }
    }
    if (submitted.fallback && submitted.fallback == fallback_generation &&
        submitted.revision == reader->revision && !fallback_frame_ns)
      fallback_frame_ns = submitted_at;
    if (stage == chrome && navigation_ready && images_ready && submitted.navigation &&
               fl_mdf_wayland_input_ready() &&
               submitted.revision == reader->revision &&
               (!mono_requested || (mono_finished && submitted.mono_finished)) &&
               (!fallback_requested || (fallback_finished && submitted.fallback == fallback_generation)) &&
               submitted.monospace == reader->code_font.ready()) {
      stage = ready;
      if (!full_ready)
        full_ready = submitted_at;
      if (profiling || benchmark || self_test) {
        startup_frames = frames;
        // Explicit screenshot encoding may load codecs after readiness.
        // Snapshot the document's requirements before capture or self-tests.
        startup_image_module = mdf_diagram_stats(MDF_MODULE_IMAGE);
        startup_usage = core.profile().get("usage");
        std::ifstream proc("/proc/self/status");
        std::string line;
        while (std::getline(proc, line))
          if (line.rfind("VmHWM:", 0) == 0) {
            std::istringstream values(line.substr(6));
            uint64_t rss;
            values >> rss;
            startup_usage.set("rss_kib", rss);
          }
      }
      if (self_test) {
        run_tests();
        done = true;
        window->hide();
      } else if (profiling || benchmark) {
        if (scroll_profile)
          measure_scroll();
        if (!capture.empty())
          capture_frame(capture);
        print_profile();
        done = true;
        window->hide();
      }
    }
    if (!done) {
      poll();
      const bool input_was_ready = fl_mdf_wayland_input_ready();
      fl_mdf_wayland_startup_poll();
      if (!input_was_ready && fl_mdf_wayland_input_ready() && flush_frame_socket())
        queue_presentation();
      if (reader->path.empty() && initial_path.empty())
        message("Open a Markdown file · Ctrl+O");
    }
  }
  void schedule_present() {
    painted_revision = reader->revision;
    painted_navigation = navigation_ready && images_ready;
    painted_monospace = reader->code_font.ready();
    painted_mono_finished = mono_finished;
    painted_fallback_generation = fallback_generation;
    queue_presentation();
  }
  void queue_presentation() {
    if (after_pending)
      return;
    after_pending = true;
    Fl::add_timeout(0, [](void *p) { ((App *)p)->presented(); }, this);
  }
  void save_geometry() {
    if (window->shown()) {
      settings.maximized = window->maximize_active();
      if (!settings.maximized && !window->fullscreen_active()) {
        settings.window_w = window->w();
        settings.window_h = window->h();
      }
    }
    try {
      core.save(settings.json());
    } catch (...) {
    }
  }
  void follow(const std::string &url) {
    try {
      auto link = core.link(url);
      auto kind = text(link, "kind"), value = text(link, "url");
      if (kind == "fragment") {
        for (int i = 0; i < (int)reader->blocks.size(); ++i)
          if (reader->blocks[i].anchor == value) {
            reader->jump(i);
            break;
          }
      } else if (kind == "local")
        open(value);
      else if (kind == "web") {
        pid_t pid = fork();
        if (!pid) {
          execlp("xdg-open", "xdg-open", value.c_str(), (char *)nullptr);
          _exit(127);
        }
      }
    } catch (std::exception &e) {
      message(e.what());
    }
  }
  void action(const std::string &name) {
    if (name == "quit") {
      save_geometry();
      done = true;
      window->hide();
      return;
    }
    if (name == "open") {
      Fl_Native_File_Chooser chooser;
      chooser.title("Open Markdown");
      chooser.type(Fl_Native_File_Chooser::BROWSE_FILE);
      chooser.filter("Markdown\t*.{md,markdown,txt}\nAll files\t*");
      if (chooser.show() == 0)
        open(chooser.filename());
      return;
    }
    if (name == "reload") {
      if (!reader->path.empty())
        open(reader->path);
      return;
    }
    if (name == "copy") {
      auto value = reader->selected();
      Fl::copy(value.c_str(), value.size(), 1);
      return;
    }
    if (name == "select-all") {
      reader->select_all();
      return;
    }
    if (name == "about") {
      fl_message_title("About Markdown FAST");
      fl_message(
          "Markdown FAST 0.2.0\n\nFLTK 1.4.5 · Wayland · Cairo/Pango\nZig 0.17 "
          "· MD4C\n\nhttps://github.com/mariobaldini/mdf");
      return;
    }
    if (name == "licenses") {
      fl_message_title("Third-party licenses");
      fl_message("License notices are embedded in the executable.\nRun mdf "
                 "--licenses to print the full notices.\n\nFLTK: "
                 "https://www.fltk.org/COPYING.php");
      return;
    }
    if (name == "toc")
      settings.toc = !settings.toc;
    else if (name == "dark")
      settings.dark = !settings.dark;
    else if (name == "preview")
      settings.preview = !settings.preview;
    else if (name == "line-wrap")
      settings.line_wrap = !settings.line_wrap;
    else if (name == "width-cycle")
      settings.width =
          settings.width == "percent_100" ? "percent_80" : "percent_100";
    else if (name == "width80")
      settings.width = "percent_80";
    else if (name == "width100")
      settings.width = "percent_100";
    else if (name == "larger")
      ++settings.size;
    else if (name == "smaller")
      --settings.size;
    else if (name == "font-reset")
      settings.size = settings.default_font_size();
    else if (name.rfind("size:", 0) == 0)
      settings.size = std::stoi(name.substr(5));
    else if (name == "auto-reload")
      settings.reload = !settings.reload;
    else if (name == "save-settings")
      settings.save = !settings.save;
    else if (name == "reset") {
      settings = Settings{};
      window->un_maximize();
      window->size(1040, 780);
    } else if (name.rfind("theme:", 0) == 0) {
      settings.theme = name.substr(6);
      settings.size = settings.default_font_size();
    } else
      return;
    settings_changed(name != "line-wrap");
  }
  int shortcut(int e) {
    if (e == FL_SHORTCUT && Fl::event_state(FL_CTRL) &&
        Fl::event_key() == '+') {
      action("larger");
      return 1;
    }
    return 0;
  }
  void capture_frame(const std::string &file) {
    if (!capture_anchor.empty()) {
      int target = -1;
      for (int i = 0; i < (int)reader->blocks.size(); ++i)
        if (reader->blocks[i].anchor == capture_anchor) { target = i; break; }
      if (target < 0)
        throw std::runtime_error("Screenshot heading not found: " + capture_anchor);
      reader->jump(target);
      Fl::flush();
      if (reader->offsets[target] >= reader->scroll + reader->h() ||
          reader->offsets[target] + reader->heights[target] <= reader->scroll)
        throw std::runtime_error("Screenshot heading is outside the viewport");
    }
    Fl::flush();
    window->make_current();
    const int x = capture_reader ? reader->x() : 0;
    const int y = capture_reader ? reader->y() : 0;
    const int w = capture_reader ? reader->w() : window->w();
    const int h = capture_reader ? reader->h() : window->h();
    auto *data = fl_read_image(nullptr, x, y, w, h, 0);
    if (!data)
      throw std::runtime_error("Cannot capture window");
    std::unique_ptr<unsigned char, decltype(&std::free)> pixels(data, std::free);
    const MdfPixels image{data, w, h, 3};
    MdfEncodedImage bytes{};
    if (!mdf_lazy_encode_png(&image, size_t(w) * size_t(h) * 3, &bytes))
      throw std::runtime_error("Cannot save screenshot");
    std::unique_ptr<unsigned char, decltype(&std::free)> encoded(bytes.data, std::free);
    std::ofstream output(file, std::ios::binary | std::ios::trunc);
    output.write(reinterpret_cast<const char *>(bytes.data), std::streamsize(bytes.length));
    output.close();
    if (!output) throw std::runtime_error("Cannot save screenshot");
  }
  void measure_scroll() {
    PHASE("Measure interactive document scrolling");
    int count = 80;
    float old = reader->scroll;
    for (int i = 0; i < count; ++i) {
      auto start = mdf_now_ns();
      auto paints = reader->paints;
      reader->move_scroll(reader->max_scroll() * i / (count - 1));
      Fl::check();
      Fl::flush();
      ensure(reader->paints > paints,
             "Scrolling must draw the reader viewport");
      scroll_draw_ms.push_back((mdf_now_ns() - start) / 1e6);
    }
    reader->move_scroll(old);
    Fl::flush();
    scroll_frames = scroll_draw_ms.size();
  }
  void print_profile() {
    auto result = core.profile();
    Json events = result.get("events");
    profile_wait_details(events, origin);
    auto metrics = startup_usage;
    auto ms = [this](uint64_t t) { return (t - origin) / 1e6; };
    metrics.set("first_frame_ms", ms(full_ready));
    metrics.set("full_ready_ms", ms(full_ready));
    metrics.set("window_present_ms", ms(scaffold_ns));
    metrics.set("scaffold_ms", ms(scaffold_ns));
    metrics.set("first_document_ms", ms(first_document));
    if (first_document_commit) metrics.set("first_document_commit_ms", ms(first_document_commit));
    if (first_document_flush) metrics.set("first_document_flush_ms", ms(first_document_flush));
    metrics.set("input_ready", bool(fl_mdf_wayland_input_ready()));
    metrics.set("cursor_backend", fl_mdf_cursor_shape_supported() ? "compositor-shape" : "theme");
    metrics.set("drawing_buffers", MDF_SHARED_DRAWING ? "shared-until-busy" : "private-copy");
    metrics.set("library_read_ahead", true);
    metrics.set("text_library", MDF_BUNDLED_PANGO ? "bundled-pango" : "system-pango");
    metrics.set("text_library_version", pango_version_string());
    metrics.set("drawing_library", MDF_BUNDLED_CAIRO ? "bundled-cairo" : "system-cairo");
    metrics.set("drawing_library_version", cairo_version_string());
    metrics.set("backend_ms", ms(backend_ready));
    metrics.set("window_ms", (scaffold_ns - backend_ready) / 1e6);
    metrics.set("read_ms", read_ns / 1e6);
    metrics.set("parse_ms", parse_ns / 1e6);
    metrics.set("layout_ms", layout_ns / 1e6);
    metrics.set("source_bytes", source_bytes);
    metrics.set("blocks", reader->blocks.size());
    metrics.set("document_frames", document_frames);
    metrics.set("total_frames", startup_frames);
    metrics.set("decoded_images", reader->images.size() - reader->diagram_sizes.size());
    size_t mermaid_count = 0;
    for (const auto &[index, dimensions] : reader->diagram_sizes)
      if (reader->blocks[index].mermaid()) ++mermaid_count;
    metrics.set("rendered_diagrams", mermaid_count);
    metrics.set("rendered_svgs", reader->diagram_sizes.size() - mermaid_count);
    metrics.set("diagram_errors", reader->diagram_errors.size());
    metrics.set("diagram_module_loaded", diagram_renderer_loaded());
    metrics.set("mermaid_engine", "pozeiden");
    metrics.set("svg_engine", "zig-svg");
    metrics.set("image_decoder", "zignal");
    metrics.set("png_encoder", "zignal");
    metrics.set("compression_engine", "std.compress.flate");
    metrics.set("markdown_parser", "zigmark");
    metrics.set("markdown_parser_version", "0.11.1");
    metrics.set("image_decoder_version", "0.11.0");
    metrics.set("json_engine", "std.json");
    if (launch_context) {
      metrics.set("ui_module_ready_ms", ms(launch_context->ui_ready_ns));
      metrics.set("ui_module_bytes", launch_context->ui_module_bytes);
    }
    metrics.set("bundled_font_styles", fonts.styles);
    metrics.set("bundled_font_data_styles", bundled_font_data_styles());
    metrics.set("image_module_loaded", startup_image_module.ready_ns != 0);
    if (startup_image_module.ready_ns) {
      metrics.set("image_module_ready_ms", ms(startup_image_module.ready_ns));
      metrics.set("image_module_stored_bytes", startup_image_module.packed);
      metrics.set("image_module_expanded_bytes", startup_image_module.expanded);
      metrics.set("image_module_codec", startup_image_module.flags & MDF_MODULE_PAYLOAD_RAW ? "raw" : "zlib");
    }
    for (auto kind : {DiagramModule::mermaid, DiagramModule::svg}) {
      const std::string prefix = kind == DiagramModule::svg ? "svg_module_" : "mermaid_module_";
      metrics.set(prefix + "loaded", diagram_renderer_loaded(kind));
      if (diagram_renderer_loaded(kind)) {
        metrics.set(prefix + "ready_ms", ms(diagram_renderer_ready_ns(kind)));
        metrics.set(prefix + "stored_bytes", diagram_renderer_packed_bytes(kind));
        metrics.set(prefix + "codec", mdf_diagram_stats(uint32_t(kind)).flags & MDF_MODULE_PAYLOAD_RAW ? "raw" : "zlib");
        metrics.set(prefix + "expanded_bytes", diagram_renderer_expanded_bytes(kind));
      }
    }
    if (first_diagram_ns) metrics.set("first_diagram_ms", ms(first_diagram_ns));
    if (diagram_renderer_loaded()) {
      metrics.set("diagram_module_ready_ms", ms(diagram_renderer_ready_ns()));
      metrics.set("diagram_module_stored_bytes", diagram_renderer_packed_bytes());
      metrics.set("diagram_module_expanded_bytes", diagram_renderer_expanded_bytes());
    }
    metrics.set("first_viewport_monospace", first_viewport_monospace);
    metrics.set("monospace_status", reader->code_font.ready() ? "ready" :
                                    mono_requested ? (mono_finished ? "unavailable" : "loading") : "not-needed");
    if (mono_request_ns) metrics.set("monospace_request_ms", ms(mono_request_ns));
    if (mono_adopted_ns) metrics.set("monospace_adopted_ms", ms(mono_adopted_ns));
    if (mono_frame_ns) metrics.set("monospace_frame_ms", ms(mono_frame_ns));
    if (auto *mono = reader->code_font.info()) {
      metrics.set("monospace_family", mono->family);
      metrics.set("monospace_bytes", mono->bytes);
      metrics.set("monospace_files", mono->sources);
    }
    if (!mono_error.empty()) metrics.set("monospace_error", mono_error);
    metrics.set("first_viewport_fallback", first_viewport_fallback);
    metrics.set("fallback_status", reader->fallback_font.ready() ? "ready" :
                                 fallback_requested ? (fallback_finished ? "unavailable" : "loading") : "not-needed");
    metrics.set("fallback_requested_glyphs", reader->required_glyphs);
    std::vector<FcChar32> unresolved;
    for (auto ch : reader->required_glyphs) if (!reader->fallback_font.has_character(ch)) unresolved.push_back(ch);
    metrics.set("fallback_missing_glyphs", unresolved);
    if (fallback_request_ns) metrics.set("fallback_request_ms", ms(fallback_request_ns));
    if (fallback_adopted_ns) metrics.set("fallback_adopted_ms", ms(fallback_adopted_ns));
    if (fallback_frame_ns) metrics.set("fallback_frame_ms", ms(fallback_frame_ns));
    if (auto *fallback = reader->fallback_font.info()) {
      metrics.set("fallback_families", fallback->family);
      metrics.set("fallback_bytes", fallback->bytes);
      metrics.set("fallback_files", fallback->sources);
    }
    if (!fallback_error.empty()) metrics.set("fallback_error", fallback_error);
    Json output = {{"profile_version", 1},
                   {"process_id", getpid()},
                   {"wayland_fd", wl_display_get_fd(fl_wl_display())},
                   {"main_started_ns", origin},
                   {"version", "0.2.0"},
                   {"mode", mdf_core_mode()},
                   {"gui", "FLTK 1.4.5"},
                   {"ui_mode",
#ifdef NDEBUG
                    "Release"
#else
                    "Debug"
#endif
                   },
                   {"font_initialization", "private-sync"},
                   {"fltk_patch_id", MDF_FLTK_PATCH_ID},
                   {"keyboard_preparation", MDF_ASYNC_INPUT ? "worker" : "synchronous"},
                   {"frame_preparation", MDF_PREPARE_FRAME ? "preconfigure" : "on-demand"},
                   {"startup_policy", "parallel-bootstrap"},
                   {"renderer", "cairo"},
                   {"video_driver", "wayland"},
                   {"navigation_status", "ready"},
                   {"file", reader->path},
                   {"metrics", metrics},
                   {"events", events},
                   {"dropped_events", result.get("dropped_events")}};
    if (!scroll_draw_ms.empty()) {
      output.set("scroll_draw_ms", scroll_draw_ms);
      output.set("scroll_frames", scroll_frames);
    }
    std::cout << output.dump() << std::endl;
  }
  void ensure(bool condition, const char *message) {
    if (!condition)
      throw std::runtime_error(message);
  }
  void run_tests() {
    ensure(first_document_commit && first_document_flush &&
               first_document_commit <= first_document_flush && first_document_flush <= first_document,
           "Markdown pixels are committed and flushed before viewport readiness");
    PHASE("Native FLTK integration checks");
    for (auto cursor : {FL_CURSOR_ARROW, FL_CURSOR_INSERT, FL_CURSOR_HAND,
                        FL_CURSOR_NS, FL_CURSOR_WE, FL_CURSOR_NONE})
      window->cursor(cursor);
    unsigned char cursor_pixel[] = {0x20, 0x80, 0xe0, 0xff};
    Fl_RGB_Image custom_cursor(cursor_pixel, 1, 1, 4);
    window->cursor(&custom_cursor, 0, 0);
    window->cursor(FL_CURSOR_ARROW);
    Fl::check();
    std::cout << "PASS: standard, hidden and custom cursors with "
              << (fl_mdf_cursor_shape_supported() ? "compositor shapes" : "theme fallback") << '\n';
    ensure(scaffold_ns <= first_document && first_document <= full_ready,
           "Startup staging order");
    ensure(!first_viewport_monospace && mono_requested && mono_finished && mono_request_ns > first_document,
           "The first Markdown frame uses Open Sans before system monospace is requested");
    if (reader->code_font.ready())
      ensure(mono_adopted_ns > first_document && mono_frame_ns >= mono_adopted_ns && mono_frame_ns <= full_ready,
             "System monospace is adopted and presented only after the initial viewport");
    else ensure(!mono_error.empty(), "Missing system monospace keeps an explained Open Sans fallback");
    ensure(reader->blocks.size() > 200, "Sample document blocks");
    ensure(!toc_indices.empty() &&
               reader->preview.size() == reader->blocks.size(),
           "TOC and minimap prepared");
    ensure(reader->images.size() - reader->diagram_sizes.size() == 5 &&
               reader->image_pixels.size() == reader->images.size(),
           "All five PNG/JPEG sample images were decoded by the pixel worker");
    ensure(reader->diagram_sizes.size() == 1 && reader->diagram_errors.empty(),
           "Sample Mermaid diagram is rendered with no errors");
    for (const auto &[index, size] : reader->diagram_sizes)
      ensure(reader->measure(index).image && reader->measure(index).runs.empty(),
             "Mermaid draws a diagram instead of its fenced source");
    for (const auto &[index, size] : reader->diagram_sizes) {
      if (!reader->blocks[index].mermaid()) continue;
      const auto *pixels = reader->image_pixels.at(index)->image.data;
      reader->jump(index);
      reader->prepare_visible();
      const auto natural = reader->measure(index);
      ensure(std::abs(natural.iw - size.first * reader->zoom()) < .01f,
             "FLTK keeps natural Mermaid label size");
      auto controls = reader->diagram_controls(index, natural.iy - reader->diagram_controls(index, 0).height);
      const auto plus = controls.boxes[2];
      float py = reader->offsets[index] - reader->scroll + plus.y + 14;
      reader->pointer(0, plus.x + plus.w / 2, py);
      reader->pointer(2, plus.x + plus.w / 2, py);
      ensure(reader->diagram_scale(index) > 1, "FLTK diagram zoom button responds");
      const auto enlarged = reader->measure(index);
      py = reader->offsets[index] - reader->scroll + enlarged.iy + 40;
      reader->pointer(0, reader->margin + 80, py);
      reader->pointer(1, reader->margin + 40, py);
      reader->pointer(2, reader->margin + 40, py);
      ensure(reader->horizontal_scroll > 0, "FLTK diagrams support drag panning");
      const auto fit = controls.boxes[3];
      py = reader->offsets[index] - reader->scroll + fit.y + 14;
      reader->pointer(0, fit.x + fit.w / 2, py);
      reader->pointer(2, fit.x + fit.w / 2, py);
      ensure(reader->diagram_states.at(index).fit && reader->measure(index).iw <= reader->content_width + .01f,
             "FLTK Fit control stays reachable after panning");
      reader->zoom_diagram(index, 1);
      ensure(std::abs(reader->diagram_scale(index) - 1) < .001f, "FLTK resets diagram zoom to 100%");
      for (int i = 0; i < 12; ++i) reader->zoom_diagram(index, 2);
      ensure(reader->diagram_scale(index) == 2, "FLTK diagram enlargement is bounded");
      for (int i = 0; i < 24; ++i) reader->zoom_diagram(index, 0);
      ensure(reader->diagram_scale(index) == .25f && reader->image_pixels.at(index)->image.data == pixels,
             "FLTK diagram zoom reuses the decoded pixels");
      reader->diagram_states.erase(index);
      reader->diagram_focus.reset();
      reader->invalidate();
    }
    size_t wide_tables = 0;
    for (int i = 0; i < int(reader->blocks.size()); ++i) {
      if (!reader->blocks[i].table_header || reader->blocks[i].cells.size() < 8) continue;
      reader->jump(i);
      reader->prepare_visible();
      scroll_changed();
      ensure(settings.line_wrap && reader->max_horizontal_scroll() > 0 && horizontal_scrollbar->visible(),
             "FLTK preserves readable wide-table columns with wrapping enabled");
      reader->move_horizontal(reader->max_horizontal_scroll());
      ensure(reader->horizontal_scroll > 0, "FLTK wide tables expose their last columns");
      ++wide_tables;
    }
    ensure(wide_tables >= 3, "FLTK checks the 8-, 16- and 24-column fixtures");
    reader->move_horizontal(0);
    reader->move_scroll(0);
    std::cout << "PASS: FLTK readable tables and Mermaid zoom, Fit, reset, panning and pixel reuse\n";
    ensure(fonts.fds.size() == 4, "Exactly four embedded font memory files");
    auto *map = pango_cairo_font_map_get_default();
    ensure(pango_fc_font_map_get_config(PANGO_FC_FONT_MAP(map)) ==
                   fonts.config &&
               FcConfigGetCurrent() == fonts.config,
           "Pango and Fontconfig use the adopted private configuration");
    auto *system_fonts = FcConfigGetFonts(fonts.config, FcSetSystem);
    auto *app_fonts = FcConfigGetFonts(fonts.config, FcSetApplication);
    ensure((!system_fonts || system_fonts->nfont == 0) && app_fonts &&
               app_fonts->nfont >= 4 && (reader->fallback_font.ready() || app_fonts->nfont == 4),
           "Private configuration contains bundled faces and explicitly selected fallback fonts");
    ensure(reader->required_glyphs.empty() && !first_viewport_fallback && !fallback_requested &&
               !reader->fallback_font.ready() && app_fonts->nfont == 4,
           "The regular sample uses bundled glyphs without Sans fallback discovery");
    std::cout << "PASS: Latin sample uses bundled glyphs without Sans fallback\n";
    auto *context = pango_font_map_create_context(map);
    for (int style = 0; style < 4; ++style) {
      auto *description = pango_font_description_new();
      pango_font_description_set_family(description, "Open Sans");
      pango_font_description_set_weight(
          description, style & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
      pango_font_description_set_style(
          description, style & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
      pango_font_description_set_size(description, 14 * PANGO_SCALE);
      auto *font = pango_font_map_load_font(map, context, description);
      pango_font_description_free(description);
      ensure(font && PANGO_IS_FC_FONT(font), "Pango loads each bundled style");
      auto *pattern = pango_fc_font_get_pattern(PANGO_FC_FONT(font));
      FcChar8 *family = nullptr, *file = nullptr;
      int weight = 0, slant = 0;
      ensure(
          FcPatternGetString(pattern, FC_FAMILY, 0, &family) == FcResultMatch &&
              std::string((const char *)family) == "Open Sans" &&
              FcPatternGetString(pattern, FC_FILE, 0, &file) == FcResultMatch &&
              std::string((const char *)file).rfind("/proc/self/fd/", 0) == 0 &&
              FcPatternGetInteger(pattern, FC_WEIGHT, 0, &weight) ==
                  FcResultMatch &&
              FcPatternGetInteger(pattern, FC_SLANT, 0, &slant) ==
                  FcResultMatch &&
              bool(weight >= FC_WEIGHT_BOLD) == bool(style & 1) &&
              bool(slant == FC_SLANT_ITALIC) == bool(style & 2),
          "Pango selects the real embedded face for all four styles");
      ensure(pango_font_has_char(font, 0x00e3) &&
                 pango_font_has_char(font, 0x00e9) &&
                 pango_font_has_char(font, 0x1ec7) &&
                 pango_font_has_char(font, 0x2026) &&
                 pango_font_has_char(font, 0x2212) &&
                 !pango_font_has_char(font, 0x03b1) &&
                 !pango_font_has_char(font, 0x0416) &&
                 !pango_font_has_char(font, 0x4e2d),
             "Latin accents and symbols remain; Greek, Cyrillic and CJK are absent");
      g_object_unref(font);
      Span span;
      span.bold = style & 1;
      span.italic = style & 2;
      Block block;
      block.kind = "code";
      auto code_style = reader->style(span, block);
      ensure(code_style.face == FL_FREE_FONT + style &&
                 code_style.monospace == reader->code_font.ready(),
             "Code preserves four styles and uses the deferred font when available");
      if (code_style.monospace) {
        auto narrow = reader->code_font.measure("iiii", 4, 16, style);
        auto wide = reader->code_font.measure("WWWW", 4, 16, style);
        ensure(std::abs(narrow.width - wide.width) < .1f,
               "Code has equal character advances in every style");
      }
      fl_font(FL_FREE_FONT + style, 16);
      ensure(fl_width("iiii") < fl_width("WWWW"),
             "Bundled text remains proportional");
    }
    g_object_unref(context);
    check_text_layout(*reader, [this](bool condition, const char *message) { ensure(condition, message); });
    std::cout << "PASS: bounded text measurement cache, font invalidation and retained run metrics\n";
    if (reader->code_font.ready()) {
      Block block;
      block.kind = "code";
      Span source;
      source.text = "i\tW\nWWWW";
      auto [runs, height, right] = reader->flow({source}, block, 0, 0, 500, 16, 100);
      const float cell = reader->code_font.measure("M", 1, 16, 0).width;
      ensure(runs.size() == 4 && runs[1].text == "\t" && runs[1].pos == 101 &&
                 runs[2].text == "W" && runs[2].pos == 102 && runs[3].pos == 104 &&
                 std::abs(runs[2].x - 4 * cell) < .1f,
             "Monospace tabs align to four cells and preserve source byte positions");
      ensure(reader->prefix_width(runs[1], 0) == 0 &&
                 reader->prefix_width(runs[1], 1) == runs[1].w,
             "Code tab selection and hit testing use the displayed advance");
    }
    if (auto *mono = reader->code_font.info())
      std::cout << "PASS: deferred system monospace: " << mono->family << "; Open Sans first frame and body map preserved\n";
    else std::cout << "PASS: deferred monospace unavailable; Open Sans code fallback preserved\n";
    {
      // Real font metrics and the sample's failing table, at narrow widths.
      DocumentView table(0, 0, 480, 500, Settings{});
      for (size_t i = 0; i < reader->blocks.size(); ++i) {
        const auto &block = reader->blocks[i];
        if (block.kind != "table_row" || !block.table_header ||
            block.cells.empty() || block.cells[0].spans.empty() ||
            block.cells[0].spans[0].text != "Short") continue;
        do {
          table.starts.push_back(0);
          table.blocks.push_back(reader->blocks[i]);
        } while (!reader->blocks[i].table_last && ++i < reader->blocks.size());
        break;
      }
      ensure(table.blocks.size() >= 4, "Sample contains the narrow-table regression case");
      for (int points : {12, 18}) for (int width : {480, 360}) {
        auto options = table.settings;
        options.size = points;
        table.configure(options);
        table.resize(0, 0, width, 500);
        table.invalidate();
        auto intact = [&](int row, const char *word) {
          const auto measured = table.measure(row);
          return std::any_of(measured.runs.begin(), measured.runs.end(),
                             [&](const Run &run) { return run.text == word; });
        };
        ensure(intact(0, "Short") && intact(0, "Result") && intact(1, "12345"),
               ("Short table words and numbers stay intact: font " + std::to_string(points) +
                ", viewport " + std::to_string(width)).c_str());
        const auto &columns = table.table_columns(0, table.content_width);
        float used = 0;
        for (float value : columns) used += value;
        ensure(used >= table.content_width - .1f &&
                   std::all_of(columns.begin(), columns.end(), [](float width) { return width > 0; }),
               "Measured table columns fill the viewport or overflow to keep words readable");
        ensure(&columns == &table.table_columns(1, table.content_width),
               "Header and body share the same column boundaries");
      }
      table.blocks[1].cells[1].spans = {Span{std::string(800, 'w')}};
      table.invalidate();
      auto measured = table.measure(0);
      ensure(std::any_of(measured.runs.begin(), measured.runs.end(),
                        [](const Run &run) { return run.text == "Result"; }),
             "An oversized token cannot squeeze the short neighboring column");
      auto options = table.settings;
      options.line_wrap = false;
      table.configure(options);
      const auto &columns = table.table_columns(0, table.content_width);
      const auto row = table.measure(1);
      auto long_cell = std::find_if(row.runs.begin(), row.runs.end(),
                                   [](const Run &run) { return run.text == std::string(800, 'w'); });
      ensure(long_cell != row.runs.end() && row.right > table.w() &&
                 long_cell->x + long_cell->w <= table.margin + columns[0] + columns[1] - 8 * table.zoom() + .1f,
             "Unwrapped tables widen their cells instead of overlapping adjacent columns");
    }
    ensure(menu->find_item("Theme/Classic") && menu->find_item("Theme/Paper") &&
               menu->find_item("Theme/Terminal") &&
               !menu->find_item("Theme/Light or dark") &&
               !menu->find_item("Font/Open Sans"),
           "Theme and size menus have no family controls");
    width_button->do_callback();
    ensure(settings.width == "percent_100" &&
               std::string(width_button->label()) == "100%",
           "Width button cycles to full width");
    width_button->do_callback();
    ensure(settings.width == "percent_80" &&
               std::string(width_button->label()) == "80%",
           "Width button cycles back to 80%");
    action("width100");
    ensure(std::string(width_button->label()) == "100%",
           "Width menu updates button");
    action("width80");
    ensure(settings.line_wrap && !wrap_button->value() &&
               wrap_button->color() == Palette::get(Settings{}).panel &&
               bool(horizontal_scrollbar->visible()) == (reader->max_horizontal_scroll() > 0) &&
               core.settings().value("line_wrap", false),
           "Line wrap defaults on; only overflowing tables/diagrams need a body scrollbar");
    const int wrapped_height = reader->h(), toc_height = toc->h(), preview_height = minimap->h();
    const bool wrapped_bar = horizontal_scrollbar->visible();
    wrap_button->do_callback();
    reader->prepare_visible();
    scroll_changed();
    ensure(!settings.line_wrap && wrap_button->value() &&
               wrap_button->color() == Palette::get(Settings{}).link && horizontal_scrollbar->visible() &&
               !core.settings().value("line_wrap", true) && reader->h() == wrapped_height - (wrapped_bar ? 0 : scrollbar_width) &&
               toc->h() == toc_height && minimap->h() == preview_height,
           "Disabling wrap reserves only document space and updates saved preferences");
    ensure(horizontal_scrollbar->x() == reader->x() && horizontal_scrollbar->w() == reader->w() &&
               horizontal_scrollbar->y() == reader->y() + reader->h() &&
               horizontal_scrollbar->h() == scrollbar->w() &&
               horizontal_scrollbar->x() + horizontal_scrollbar->w() == scrollbar->x(),
           "Horizontal scrollbar spans the body only and matches the vertical thickness");
    ensure(reader->max_horizontal_scroll() > 0 && horizontal_scrollbar->active(),
           "Unwrapped sample lines expose a horizontal scroll range");
    if (!capture.empty()) capture_frame(capture + ".nowrap.png");
    horizontal_scrollbar->value(std::min(128.f, reader->max_horizontal_scroll() / 2));
    horizontal_scrollbar->do_callback();
    ensure(reader->horizontal_scroll > 0, "Horizontal scrollbar pans the document");
    if (!capture.empty()) capture_frame(capture + ".panned.png");
    for (bool show_toc : {false, true}) for (bool show_preview : {false, true}) {
      settings.toc = show_toc;
      settings.preview = show_preview;
      settings_changed(false);
      ensure(horizontal_scrollbar->x() == reader->x() && horizontal_scrollbar->w() == reader->w() &&
                 horizontal_scrollbar->x() + horizontal_scrollbar->w() == scrollbar->x(),
             "Horizontal scrollbar follows the body when sidebars change");
    }
    action("line-wrap");
    ensure(settings.line_wrap && !wrap_button->value() &&
               wrap_button->color() == Palette::get(Settings{}).panel &&
               bool(horizontal_scrollbar->visible()) == (reader->max_horizontal_scroll() > 0) && reader->horizontal_scroll == 0 &&
               reader->h() == window->h() - 98 - (horizontal_scrollbar->visible() ? scrollbar_width : 0),
           "Enabling wrap restores body height and resets horizontal position");
    {
      Settings prefs;
      DocumentView text_view(0, 0, 360, 200, prefs);
      Span long_link;
      long_link.text = std::string(240, 'W');
      long_link.link = "#target";
      Span tail;
      tail.text = " styled text\nSecond hard line";
      tail.bold = true;
      Block paragraph;
      paragraph.kind = "paragraph";
      paragraph.spans = {long_link, tail};
      text_view.blocks = {paragraph};
      text_view.starts = {0};
      const std::string fixture_plain = long_link.text + tail.text;
      text_view.plain = fixture_plain;
      text_view.invalidate();
      const auto wrapped = text_view.measure(0);
      prefs.line_wrap = false;
      text_view.configure(prefs);
      text_view.prepare_visible();
      const auto &unwrapped = text_view.cache.at(0);
      const auto dimensions = text_view.measure(0, false);
      ensure(unwrapped.height < wrapped.height && unwrapped.right > text_view.w() &&
                 std::abs(unwrapped.right - dimensions.right) < .1f && dimensions.runs.empty(),
             "No-wrap measures full lines without retaining offscreen text runs");
      auto [runs, height, right] = text_view.flow(paragraph.spans, paragraph, 0, 0, 80, 16, 0);
      ensure(height == 48 && right > 80 && runs.front().text == long_link.text,
             "No-wrap preserves explicit newlines, styles and unbroken long tokens");
      text_view.move_horizontal(300);
      const auto &run = unwrapped.runs.front();
      const float y = text_view.offsets[0] + run.y - run.style.size * .4f;
      auto caret = [&](size_t pos) {
        fl_font(run.style.face, run.style.size);
        return run.x + text_view.prefix_width(run, pos) + .1f - text_view.horizontal_scroll;
      };
      auto target = text_view.hit(caret(25), y);
      ensure(target && target->pos == 25 && target->link == "#target",
             "Link hit testing accounts for horizontal scrolling");
      ensure(text_view.hover_cursor(caret(25), y) == FL_CURSOR_HAND,
             "Links retain a hand cursor after horizontal scrolling");
      text_view.pointer(0, caret(25), y);
      text_view.pointer(1, caret(30), y);
      text_view.pointer(2, caret(30), y);
      ensure(text_view.selected() == std::string(5, 'W'),
             "Selection uses original byte positions after horizontal scrolling");
      prefs.line_wrap = true;
      text_view.configure(prefs);
      ensure(text_view.horizontal_scroll == 0 && text_view.max_horizontal_scroll() == 0,
             "Wrapping removes the horizontal range after panning");
      prefs.line_wrap = false;
      text_view.blocks[0].spans = {Span{"Short text"}};
      text_view.configure(prefs);
      ensure(text_view.max_horizontal_scroll() == 0,
             "An unwrapped short line has no spurious horizontal overflow");
      text_view.prepare_visible();
      const auto &plain_run = text_view.cache.at(0).runs.front();
      ensure(text_view.hover_cursor(plain_run.x + 2, plain_run.y - plain_run.style.size * .4f) == FL_CURSOR_ARROW &&
                 text_view.hover_cursor(0, 0) == FL_CURSOR_ARROW,
             "Document text and empty space use the normal arrow cursor");
    }
    const int preview_width = minimap->w(), reader_width = reader->w();
    preview_button->do_callback();
    ensure(!settings.preview && !minimap->visible() &&
               reader->w() == reader_width + preview_width &&
               !core.settings().value("show_preview", true),
           "Preview hides and gives its space to the reader");
    preview_button->do_callback();
    ensure(settings.preview && minimap->visible() &&
               reader->w() == reader_width,
           "Preview shows and restores the reader width");
    action("toc");
    ensure(!settings.toc, "TOC hides");
    action("toc");
    ensure(settings.toc, "TOC shows");
    const auto quote_heading = std::find_if(reader->blocks.begin(), reader->blocks.end(),
        [](const Block &block) { return block.anchor == "block-quotes"; });
    auto capture_quotes = [&](const char *mode) {
      if (capture.empty() || quote_heading == reader->blocks.end()) return;
      reader->jump(int(quote_heading - reader->blocks.begin()));
      capture_frame(capture + ".quotes-" + mode + ".png");
    };
    capture_quotes("light");
    action("dark");
    ensure(settings.dark, "Dark mode");
    reader->jump(0);
    reader->prepare_visible();
    ensure(reader->cache.at(0).runs.front().style.color == reader->palette.fg,
           "Dark text cache recolored");
    capture_quotes("dark");
    action("dark");
    reader->jump(0);
    font_increase_button->do_callback();
    ensure(settings.size == 13, "Font step");
    font_decrease_button->do_callback();
    ensure(settings.size == 12, "Font decrease button");
    action("size:18");
    ensure(settings.size == 18, "Font size preset");
    font_reset_button->do_callback();
    ensure(settings.size == 12, "Font reset button uses Classic default");
    action("size:8");
    ensure(!font_decrease_button->active(),
           "Font decrease stops at minimum size");
    action("size:72");
    ensure(!font_increase_button->active(),
           "Font increase stops at maximum size");
    font_reset_button->do_callback();
    reader->select_all();
    ensure(reader->selected().find("Markdown FAST") != std::string::npos,
           "Text selection");
    action("copy");
    int details = -1;
    for (int i = 0; i < (int)reader->blocks.size(); ++i)
      if (reader->blocks[i].parent >= 0) {
        details = i;
        break;
      }
    ensure(details >= 0, "Nested details fixture");
    reader->jump(details);
    ensure(reader->visible(details), "TOC reveals collapsed ancestors");
    for (int W : {1040, 1440, 420, 1040}) {
      window->size(W, 700);
      layout();
      ensure(width_button->x() == 96 && width_button->w() == 64 &&
                 width_button->x() + width_button->w() + 12 <=
                     font_decrease_button->x() &&
                 font_decrease_button->x() + font_decrease_button->w() <
                     font_reset_button->x() &&
                 font_reset_button->x() + font_reset_button->w() <
                     font_increase_button->x() &&
                 font_increase_button->x() + font_increase_button->w() + 12 <=
                     wrap_button->x() &&
                 wrap_button->x() + wrap_button->w() + 4 <=
                     preview_button->x() &&
                 preview_button->x() + preview_button->w() <= W - 10,
             "Toolbar controls stay separated after resizing");
      ensure(scrollbar->w() == scrollbar_width &&
                 minimap->x() == scrollbar->x() + scrollbar->w() &&
                 minimap->y() == scrollbar->y() + scrollbar->w() &&
                 minimap->y() + minimap->h() ==
                     scrollbar->y() + scrollbar->h() - scrollbar->w(),
             "Preview aligns with the enlarged scrollbar track");
      reader->move_scroll(0);
      Fl::flush();
      ensure(minimap->thumb_top() == 0, "Preview and scrollbar start together");
      reader->move_scroll(reader->max_scroll());
      Fl::flush();
      ensure(minimap->thumb_top() + minimap->thumb_height() == minimap->h(),
             "Preview and scrollbar end together");
      for (int i = 0; i < (int)reader->blocks.size(); i += 12) {
        reader->jump(i);
        Fl::flush();
      }
    }
    minimap->navigate(0, minimap->h() * .9);
    minimap->navigate(1, minimap->h());
    minimap->navigate(2, minimap->h());
    ensure(reader->scroll > 0, "Minimap drag navigation");
    auto resolved = core.link("#text-styles");
    ensure(text(resolved, "kind") == "fragment", "Heading links");
    bool rejected = false;
    try {
      core.link("javascript:alert(1)");
    } catch (...) {
      rejected = true;
    }
    ensure(rejected, "Unsafe link rejected");
    action("theme:paper");
    ensure(settings.size == 14, "Paper theme");
    font_increase_button->do_callback();
    ensure(settings.size == 15, "Increase Paper font size");
    font_reset_button->do_callback();
    ensure(settings.size == 14, "Font reset button uses Paper default");
    action("theme:terminal");
    ensure(!settings.dark && settings.size == 11,
           "Terminal preserves light mode");
    font_decrease_button->do_callback();
    ensure(settings.size == 10, "Decrease Terminal font size");
    font_reset_button->do_callback();
    ensure(settings.size == 11, "Font reset button uses Terminal default");
    for (bool dark : {true, false}) {
      theme_button->do_callback();
      ensure(settings.dark == dark &&
                 theme_button->icon ==
                     (dark ? IconButton::sun : IconButton::moon),
             "Toolbar independently switches mode and its native icon");
      for (size_t i = 0; i < mdf_theme_count(); ++i) {
        const auto theme = mdf_theme_info(i);
        const auto id = view_text(theme.id);
        ensure(menu->find_item(("Theme/" + view_text(theme.name)).c_str()), "Every built-in theme appears in the native menu");
        action("theme:" + id);
        ensure(settings.dark == dark &&
                   settings.size == settings.default_font_size(),
               "Every palette preserves the current mode and sets its default "
               "size");
        ensure(reader->palette.bg == Palette::get(settings).bg && menu->color() == reader->palette.panel &&
                   theme_button->color() == reader->palette.panel,
               "Theme colors update the document, menus, and toolbar together");
        if (!capture.empty()) {
          reader->selection.reset();
          const auto heading = std::find_if(reader->blocks.begin(), reader->blocks.end(),
              [](const Block &block) { return block.anchor == "text-styles"; });
          if (heading != reader->blocks.end()) reader->jump(int(heading - reader->blocks.begin()));
          capture_frame(capture + ".theme-" + id + (dark ? "-dark.png" : "-light.png"));
          const auto alert_heading = std::find_if(reader->blocks.begin(), reader->blocks.end(),
              [](const Block &block) { return block.anchor == "github-alerts"; });
          if (alert_heading != reader->blocks.end()) reader->jump(int(alert_heading - reader->blocks.begin()));
          capture_frame(capture + ".theme-" + id + (dark ? "-dark.alerts.png" : "-light.alerts.png"));
        }
      }
    }
    action("reset");
    ensure(settings.size == 12 && !settings.save &&
               settings.width == "percent_80",
           "Reset defaults");
    ensure(settings.line_wrap && !wrap_button->value() &&
               bool(horizontal_scrollbar->visible()) == (reader->max_horizontal_scroll() > 0),
           "Reset restores line wrapping and an unselected button");
    measure_scroll();
    if (!capture.empty())
      capture_frame(capture);
    std::cout
        << "PASS: native Wayland FLTK sample, staged startup, controls, "
           "selection, links, details, images, fonts, resizing and minimap\n";
  }
};
extern "C" void fl_mdf_buffer_committed(void *window) {
  if (active_app && window == active_app->window.get()) active_app->buffer_committed();
}

extern "C" int fl_mdf_defer_cursors() {
  if (!MDF_ASYNC_INPUT || !active_app) return 0;
  if (active_app->first_document)
    return active_app->error.empty() && !active_app->images_started && !active_app->images_ready;
  // An empty window or an opening error still needs an interactive cursor.
  return !(active_app->scaffold_ns && (active_app->initial_path.empty() || !active_app->error.empty()));
}
extern "C" int fl_mdf_shared_drawing(void *window) {
  return MDF_SHARED_DRAWING && active_app && window == active_app->window.get();
}
extern "C" void fl_mdf_input_changed() {
  if (!active_app) return;
  fl_mdf_wayland_startup_poll();
  // Resource adoption has no document pixels to repaint. Reuse the latest
  // submitted frame to evaluate readiness; preserve its painted state.
  if (active_app->first_document && fl_mdf_wayland_input_ready() && !active_app->after_pending)
    active_app->presented();
}
const char *profile_gui_wait_reason() {
  if (!active_app || !active_app->scaffold_ns)
    return "Wait for first window / Wayland events";
  if (!active_app->first_document)
    return active_app->reader->path.empty()
               ? "Wait for document / Wayland events"
               : "Wait for Wayland events — Markdown frame";
  if (!active_app->navigation_ready)
    return "Wait for navigation / Wayland events";
  if (!active_app->images_ready)
    return "Wait for image decoding / Wayland events";
  if (active_app->mono_requested && !active_app->mono_finished)
    return "Wait for system monospace / Wayland events";
  if (active_app->fallback_requested && !active_app->fallback_finished)
    return "Wait for system glyph fallback / Wayland events";
  return "Wait for Wayland events — final frame";
}
void MainWindow::flush() {
  PHASE("FLTK window flush — paint & buffer work");
  Fl_Double_Window::flush();
}
void MainWindow::draw() {
  PHASE("Draw FLTK window and scaffold");
  if (app) {
    const double scale = fl_mdf_window_scale(this);
    if (app->measured_window_scale && app->measured_window_scale != scale) app->reader->invalidate();
    app->measured_window_scale = scale;
  }
  auto started = mdf_now_ns();
  const auto reader_paints = app ? app->reader->paints : 0;
  Fl_Double_Window::draw();
  if (app) {
    ++app->frames;
    if (!app->first_document)
      app->layout_ns += mdf_now_ns() - started;
    if (app->reader->paints != reader_paints) app->schedule_present();
  }
}
void MainWindow::resize(int X, int Y, int W, int H) {
  bool changed = W != w() || H != h();
  Fl_Double_Window::resize(X, Y, W, H);
  if (app && changed)
    app->layout();
}
int MainWindow::handle(int e) {
  if (app && app->shortcut(e))
    return 1;
  if (app && (e == FL_DND_ENTER || e == FL_DND_DRAG || e == FL_DND_RELEASE)) {
    app->drop_pending = true;
    return 1;
  }
  if (app && e == FL_PASTE && app->drop_pending) {
    app->drop_pending = false;
    std::string path = Fl::event_text();
    auto end = path.find_first_of("\r\n");
    path = path.substr(0, end);
    if (path.rfind("file://", 0) == 0)
      path = path.substr(7);
    std::vector<char> value(path.begin(), path.end());
    value.push_back(0);
    fl_decode_uri(value.data());
    app->open(value.data());
    return 1;
  }
  return Fl_Double_Window::handle(e);
}
static void wake() {
  Fl::awake(
      [](void *) {
        if (active_app)
          active_app->poll();
      },
      nullptr);
}
static int frontend_main(MdfStartup *startup) {
  try {
    if (!startup || startup->abi != MDF_FRONTEND_ABI || startup->size != sizeof(MdfStartup))
      throw std::runtime_error("Bootstrap/frontend ABI mismatch");
    launch_context = startup;
    const uint64_t origin = startup->origin_ns;
    const auto flags = startup->options.flags;
    const bool prof = flags & MDF_LAUNCH_PROFILE, bench = flags & MDF_LAUNCH_BENCHMARK,
               test = flags & MDF_LAUNCH_TEST, scroll = flags & MDF_LAUNCH_SCROLL,
               capture_reader = flags & MDF_LAUNCH_READER;
    const std::string path = startup->options.path, capture = startup->options.capture,
                      capture_anchor = startup->options.anchor;
    Fl::lock();
    profile_enabled = prof || bench;
    profile_gui_thread = true;
    Core core(startup, wake);
    PROFILE_MARK("UI frontend entered");
    Settings settings(core.settings());
    if (capture_reader) settings.toc = settings.preview = false;
    {
      PHASE("Initialize FLTK native scheme");
      Fl::scheme("gtk+");
      Fl::option(Fl::OPTION_FNFC_USES_GTK, false);
      Fl::option(Fl::OPTION_FNFC_USES_KDIALOG, false);
      Fl::option(Fl::OPTION_FNFC_USES_ZENITY, false);
    }
    FontStore fonts;
    fonts.prepare();
    App app(core, fonts, settings, origin, prof, bench, test, scroll, path,
            capture);
    app.capture_anchor = capture_anchor;
    app.capture_reader = capture_reader;
    fonts.adopt();
    app.initialize();
    app.poll();
    if (app.failed) throw std::runtime_error(app.error);
    {
      PHASE("Initialize Wayland window and Cairo renderer");
      app.window->show();
      if (settings.maximized)
        app.window->maximize();
      app.backend_ready = mdf_now_ns();
    }
#if MDF_PREPARE_FRAME
    {
      PHASE("Prepare first viewport during window configuration");
      // Send configure requests before doing local work. EAGAIN leaves the
      // regular FLTK event loop responsible for the next socket flush.
      const int sent = wl_display_flush(fl_wl_display());
      // A readable display can contain keyboard/output events while the
      // window is still unconfigured. Let the driver check its own window
      // state; fd readiness must not suppress useful local preparation.
      if (sent >= 0 && !settings.maximized) {
        fl_mdf_prepare_window(app.window.get());
        if (settings.line_wrap && !app.reader->blocks.empty()) {
          app.window->make_current();
          app.measured_window_scale = fl_mdf_window_scale(app.window.get());
          app.reader->prepare_visible();
        }
      }
    }
#endif
    if (prof || bench)
      Fl::add_timeout(
          30,
          [](void *) {
            if (active_app && active_app->stage != App::ready) {
              active_app->error = "Startup timed out";
              active_app->failed = true;
              active_app->window->hide();
            }
          },
          nullptr);
    Fl::run();
    app.save_geometry();
    if (app.failed) {
      std::cerr << "mdf: " << app.error << '\n';
      return 1;
    }
    return 0;
  } catch (std::exception &e) {
    std::cerr << "mdf: " << e.what() << '\n';
    return 1;
  }
}

extern "C" const MdfFrontendApi *mdf_frontend_api(uint32_t abi) {
  static const MdfFrontendApi api{MDF_FRONTEND_ABI, sizeof(MdfFrontendApi), frontend_main};
  return abi == MDF_FRONTEND_ABI ? &api : nullptr;
}
