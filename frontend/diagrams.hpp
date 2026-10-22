#pragma once
#include "mermaid.h"
#include "diagram-loader.h"
#include <atomic>
#include <cstdint>

enum class DiagramModule : uint32_t { mermaid = MDF_MODULE_MERMAID, svg = MDF_MODULE_SVG };
const MdfDiagramApi *diagram_renderer(const std::atomic<bool> &stop, DiagramModule kind = DiagramModule::svg);
bool diagram_renderer_loaded(DiagramModule kind);
uint64_t diagram_renderer_ready_ns(DiagramModule kind);
uint64_t diagram_renderer_packed_bytes(DiagramModule kind);
uint64_t diagram_renderer_expanded_bytes(DiagramModule kind);
bool diagram_renderer_loaded();
uint64_t diagram_renderer_ready_ns();
uint64_t diagram_renderer_packed_bytes();
uint64_t diagram_renderer_expanded_bytes();
bool svg_image(const unsigned char *bytes, size_t length);
