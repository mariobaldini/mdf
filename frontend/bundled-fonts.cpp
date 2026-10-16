#include "bundled-fonts.hpp"
#include "../zig-pkg/fltk/zlib/zlib.h"
#include <atomic>
#include <mutex>

namespace {
std::atomic<uint32_t> loaded_styles{3};
uint32_t little32(const unsigned char *p) {
  return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
}
Buffer bundled_font(unsigned style) {
  if (style >= 4) throw std::runtime_error("Invalid bundled font style");
  const auto resource = mdf_font_resource(0, style);
  if (!resource.ptr || !resource.len) throw std::runtime_error("Bundled font resource unavailable");
  if (style < 2) return resource;
  struct Face { std::once_flag once; std::vector<unsigned char> bytes; };
  static Face faces[2];
  auto &face = faces[style - 2];
  std::call_once(face.once, [&] {
    Phase phase(style == 2 ? "Decompress Open Sans italic" : "Decompress Open Sans bold italic", __FILE__, __LINE__);
    if (resource.len < 16 || std::memcmp(resource.ptr, "MDFONT1\0", 8))
      throw std::runtime_error("Invalid compressed bundled font header");
    const auto expanded = little32(resource.ptr + 8), checksum = little32(resource.ptr + 12);
    if (!expanded || expanded > 16 * 1024 * 1024)
      throw std::runtime_error("Invalid compressed bundled font size");
    std::vector<unsigned char> bytes(expanded);
    uLongf size = expanded;
    uLong packed = resource.len - 16;
    if (uncompress2(bytes.data(), &size, resource.ptr + 16, &packed) != Z_OK ||
        size != expanded || packed != resource.len - 16 || crc32(0, bytes.data(), size) != checksum)
      throw std::runtime_error("Corrupt compressed bundled font");
    face.bytes = std::move(bytes);
    loaded_styles.fetch_or(1u << style, std::memory_order_release);
  });
  return {face.bytes.data(), face.bytes.size()};
}
uint32_t bundled_font_data_styles() { return loaded_styles.load(std::memory_order_acquire); }

// Rust calls through this C callback. Required-font failures remain rendering
// errors; a C++ exception must never unwind through Rust.
extern "C" Buffer mdf_builtin_font(uint32_t family, uint32_t style) {
  if (family || style >= 4) return {};
  try { return bundled_font(style); } catch (...) { return {}; }
}
