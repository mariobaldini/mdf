#include "bundled-fonts.hpp"
#include <atomic>

namespace {
std::atomic<uint32_t> loaded_styles{3};
}
Buffer bundled_font(unsigned style) {
  if (style >= 4) throw std::runtime_error("Invalid bundled font style");
  Buffer resource;
  if (style >= 2 && !(loaded_styles.load(std::memory_order_acquire) & (1u << style))) {
    Phase phase(style == 2 ? "Get required Open Sans italic data" : "Get required Open Sans bold italic data", __FILE__, __LINE__);
    resource = mdf_font_resource(0, style);
  } else resource = mdf_font_resource(0, style);
  if (!resource.ptr || !resource.len)
    throw std::runtime_error(style >= 2 ? "Corrupt compressed bundled font" : "Bundled font resource unavailable");
  loaded_styles.fetch_or(1u << style, std::memory_order_release);
  return resource;
}
uint32_t bundled_font_data_styles() { return loaded_styles.load(std::memory_order_acquire); }

// Renderer modules call this C callback. Exceptions stay inside the UI boundary.
extern "C" Buffer mdf_builtin_font(uint32_t family, uint32_t style) {
  if (family || style >= 4) return {};
  try { return bundled_font(style); } catch (...) { return {}; }
}
