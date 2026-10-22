#include "diagrams.hpp"
#include "core.hpp"
#include <algorithm>

const MdfDiagramApi *diagram_renderer(const std::atomic<bool> &stop, DiagramModule kind) {
  const auto cancel = +[](const void *context) -> int {
    return static_cast<const std::atomic<bool> *>(context)->load(std::memory_order_relaxed);
  };
  const auto fonts = +[](uint32_t style) -> MdfFontData {
    const auto font = mdf_builtin_font(0, style);
    return {font.ptr, font.len};
  };
  char error[512]{};
  const auto *api = mdf_diagram_renderer(uint32_t(kind), cancel, &stop, fonts,
                                          profile_depth, error, sizeof error);
  if (!api) throw std::runtime_error(error[0] ? error : "Cannot load bundled diagram module");
  return api;
}
bool diagram_renderer_loaded(DiagramModule kind) { return mdf_diagram_stats(uint32_t(kind)).ready_ns != 0; }
uint64_t diagram_renderer_ready_ns(DiagramModule kind) { return mdf_diagram_stats(uint32_t(kind)).ready_ns; }
uint64_t diagram_renderer_packed_bytes(DiagramModule kind) { return mdf_diagram_stats(uint32_t(kind)).packed; }
uint64_t diagram_renderer_expanded_bytes(DiagramModule kind) { return mdf_diagram_stats(uint32_t(kind)).expanded; }
bool diagram_renderer_loaded() { return diagram_renderer_loaded(DiagramModule::svg) || diagram_renderer_loaded(DiagramModule::mermaid); }
uint64_t diagram_renderer_ready_ns() { return std::max(diagram_renderer_ready_ns(DiagramModule::svg), diagram_renderer_ready_ns(DiagramModule::mermaid)); }
uint64_t diagram_renderer_packed_bytes() { return diagram_renderer_packed_bytes(DiagramModule::svg) + diagram_renderer_packed_bytes(DiagramModule::mermaid); }
uint64_t diagram_renderer_expanded_bytes() { return diagram_renderer_expanded_bytes(DiagramModule::svg) + diagram_renderer_expanded_bytes(DiagramModule::mermaid); }
bool svg_image(const unsigned char *bytes, size_t length) { return mdf_svg_image(bytes, length); }
