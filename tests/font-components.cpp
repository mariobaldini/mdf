// Isolated diagnostic for tools/scripts/benchmark-fonts.py; never linked into mdf.
#include "view.hpp"
#include <cairo.h>
#include <cstdio>
#include <ctime>

static double now(clockid_t clock) {
  timespec value{};
  clock_gettime(clock, &value);
  return value.tv_sec * 1000.0 + value.tv_nsec / 1e6;
}
const char *profile_gui_wait_reason() { return "unused component diagnostic"; }

int main() {
  profile_enabled = false;
  const auto wall = now(CLOCK_MONOTONIC), cpu = now(CLOCK_THREAD_CPUTIME_ID);
  FontStore fonts;
  fonts.prepare();
  fonts.ensure_styles(12); // This diagnostic explicitly measures all four styles.
  const auto first_cpu = now(CLOCK_THREAD_CPUTIME_ID) - cpu;
  const auto first_wall = now(CLOCK_MONOTONIC) - wall;
  double prepare_cpu = 0, prepare_wall = 0;
  for (int i = 0; i < 20; ++i) {
    const auto w = now(CLOCK_MONOTONIC), c = now(CLOCK_THREAD_CPUTIME_ID);
    { FontStore temporary; temporary.prepare(); temporary.ensure_styles(12); }
    prepare_cpu += now(CLOCK_THREAD_CPUTIME_ID) - c;
    prepare_wall += now(CLOCK_MONOTONIC) - w;
  }
  if (!FcConfigSetCurrent(fonts.config)) return 2;
  auto *map = pango_cairo_font_map_new();
  pango_fc_font_map_set_config(PANGO_FC_FONT_MAP(map), fonts.config);
  auto *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1200, 500);
  auto *cr = cairo_create(surface);
  auto *context = pango_font_map_create_context(map);
  pango_cairo_update_context(cr, context);
  const char *texts[2][2] = {
      {"AVATAR WA To fi ffi 0123456789 — ação café português Tiếng Việt. The quick brown fox jumps over the lazy dog.",
       "Português: informação, coração, útil. Tiếng Việt: Việt Nam. Typography AV WA To 9876543210 − + … € •."},
      {"Καλημέρα κόσμε. Α Β Γ Δ Ε Ζ Ω. α β γ δ ε ζ ω. Привет, мир. Добро пожаловать.",
       "Русский: Привет, мир. Українська: Добро. Ελληνικά: Καλημέρα κόσμε. Α Β Γ α β γ."}};
  int unknown[2] = {};
  double render_cpu[2] = {}, render_wall[2] = {};
  uint64_t latin_pixels = 14695981039346656037ULL;
  for (int kind = 0; kind < 2; ++kind) {
    for (int pass = -8; pass < 100; ++pass) {
      const auto w = now(CLOCK_MONOTONIC), c = now(CLOCK_THREAD_CPUTIME_ID);
      for (int style = 0; style < 4; ++style) {
        auto *desc = pango_font_description_new();
        pango_font_description_set_family(desc, "Open Sans");
        pango_font_description_set_weight(desc, style & 1 ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
        pango_font_description_set_style(desc, style & 2 ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
        pango_font_description_set_absolute_size(desc, 17 * PANGO_SCALE);
        auto *layout = pango_layout_new(context);
        pango_layout_set_font_description(layout, desc);
        pango_layout_set_width(layout, 1100 * PANGO_SCALE);
        pango_layout_set_text(layout, texts[kind][(pass + 8) % 2], -1);
        pango_cairo_update_layout(cr, layout);
        cairo_move_to(cr, 5, 5 + style * 100);
        pango_cairo_show_layout(cr, layout);
        if (pass == 0) unknown[kind] += pango_layout_get_unknown_glyphs_count(layout);
        g_object_unref(layout);
        pango_font_description_free(desc);
      }
      if (pass >= 0) {
        render_cpu[kind] += now(CLOCK_THREAD_CPUTIME_ID) - c;
        render_wall[kind] += now(CLOCK_MONOTONIC) - w;
      }
    }
    if (kind == 0) {
      cairo_surface_flush(surface);
      auto *pixels = cairo_image_surface_get_data(surface);
      const int bytes = cairo_image_surface_get_stride(surface) * 500;
      for (int i = 0; i < bytes; ++i) { latin_pixels ^= pixels[i]; latin_pixels *= 1099511628211ULL; }
    }
  }
  if (cairo_status(cr) != CAIRO_STATUS_SUCCESS || unknown[0]) return 3;
  std::printf("%.9f\t%.9f\t%.9f\t%.9f\t%.9f\t%.9f\t%.9f\t%.9f\t%d\t%d\t%llu\n",
              first_wall, first_cpu, prepare_wall/20, prepare_cpu/20,
              render_wall[0]/100, render_cpu[0]/100, render_wall[1]/100, render_cpu[1]/100,
              unknown[0], unknown[1], static_cast<unsigned long long>(latin_pixels));
  g_object_unref(context);
  cairo_destroy(cr);
  cairo_surface_destroy(surface);
  g_object_unref(map);
}
