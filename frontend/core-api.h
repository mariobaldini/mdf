#pragma once
#include "launch.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#define MDF_API_DEFAULT(value) = value
#else
#define MDF_API_DEFAULT(value)
#endif
/* This private ABI is packed with its matching host in the same executable.
   Borrowed document/layout views remain valid until replacement or release. */
typedef struct Buffer Buffer;
typedef struct MdfCore MdfCore;
typedef struct MdfBlockView MdfBlockView;
typedef struct MdfThemeInfo MdfThemeInfo;
typedef struct MdfThemePalette MdfThemePalette;
typedef struct MdfSpanView MdfSpanView;
typedef struct MdfCellView MdfCellView;
typedef struct MdfDocumentText MdfDocumentText;
typedef struct MdfTextStyle MdfTextStyle;
typedef struct MdfFlowSpan MdfFlowSpan;
typedef struct MdfFlowSpec MdfFlowSpec;
typedef struct MdfFlowMetrics MdfFlowMetrics;
typedef struct MdfLayoutFont MdfLayoutFont;
typedef struct MdfFloatBuffer MdfFloatBuffer;
typedef struct MdfLayoutOptions MdfLayoutOptions;
typedef struct MdfLayoutRun MdfLayoutRun;
typedef struct MdfLayoutRect MdfLayoutRect;
typedef struct MdfLayoutView MdfLayoutView;
typedef struct MdfBlockLayout MdfBlockLayout;
typedef struct MdfFlowRun MdfFlowRun;
typedef struct MdfFlowResult MdfFlowResult;
typedef struct MdfViewport MdfViewport;
typedef struct MdfViewportFields MdfViewportFields;
typedef struct MdfViewportView MdfViewportView;
struct MdfBlockView {
  Buffer kind, prefix, language, anchor, alert, image_src;
  size_t spans, cells, columns, bytes, lines, indent, quote;
  ptrdiff_t parent;
  uint32_t heading, flags;
  int32_t task;
};
struct MdfSpanView {
  Buffer text, link;
  uint32_t flags;
};
struct MdfCellView {
  size_t spans;
  uint32_t alignment;
};
struct MdfDocumentText { Buffer text; const size_t *starts; size_t count; uint32_t styles, flags; };
MdfDocumentText mdf_core_document_text(MdfCore *);
/* Resolve an already-decoded fragment to a rendered block without replacing
   its generated heading ID. Explicit HTML id/name aliases are also accepted. */
bool mdf_core_find_anchor(MdfCore *, const unsigned char *, size_t, size_t *);
/* Original loaded Markdown bytes, borrowed until document replacement. */
Buffer mdf_core_source(MdfCore *);
/* Theme names/IDs borrow immutable catalog storage. Indexes 0..2 retain the
   original Classic/Paper/Terminal order. Palette values are packed RGB. */
struct MdfThemeInfo { Buffer id, name; uint32_t font_size; };
struct MdfThemePalette {
  uint32_t bg, fg, panel, border, link, muted, selection, highlight;
  uint32_t note, tip, important, warning, caution;
};
size_t mdf_theme_count(void);
MdfThemeInfo mdf_theme_info(size_t);
/* Menu positions do not change stable theme/palette indexes. */
MdfThemeInfo mdf_theme_menu_info(size_t);
uint32_t mdf_theme_index(const unsigned char *, size_t);
MdfThemePalette mdf_theme_palette(uint32_t, bool dark);
struct MdfTextStyle { uint32_t face; int32_t size; };
MdfTextStyle mdf_text_style(uint32_t kind, uint32_t heading, uint32_t span_flags, bool table_header, float zoom);
float mdf_document_width(float viewport, uint32_t mode, float character_width);
bool mdf_table_widths(const float *minimum, const float *preferred, size_t count,
                      float width, float padding, bool wrap, float *output);
struct MdfFlowSpan { const unsigned char *text; size_t len; uint32_t flags; };
// Borrowed byte mask over concatenated spans, including the final position.
// Nonzero permits a cursor / grapheme break. Valid until layout returns.
typedef const unsigned char *(*MdfTextBoundaries)(void *, const MdfFlowSpan *, size_t);
struct MdfFlowSpec {
  float left, top, width;
  int32_t size;
  size_t start;
  uint32_t alignment, flags;
  MdfTextBoundaries boundaries MDF_API_DEFAULT(nullptr);
};
struct MdfFlowMetrics { float width, height, descent; };
struct MdfLayoutFont { uint32_t face; int32_t size; uint32_t flags; };
struct MdfFloatBuffer { float *data MDF_API_DEFAULT(nullptr); size_t count MDF_API_DEFAULT(0); };
bool mdf_core_table_columns(MdfCore *, size_t, float width, float zoom, bool wrap, bool mono_ready,
    MdfFlowMetrics (*)(void *, MdfLayoutFont, const unsigned char *, size_t), void *, size_t depth, MdfFloatBuffer *);
void mdf_float_buffer_free(MdfFloatBuffer);
struct MdfLayoutOptions {
  float content_width, margin, zoom;
  bool wrap, collect, mono_ready, visible, image_ready, logical_image;
  float image_width, image_height;
  Buffer failure;
  float diagram_scale MDF_API_DEFAULT(0);
  float diagram_controls_height MDF_API_DEFAULT(0);
  MdfTextBoundaries boundaries MDF_API_DEFAULT(nullptr);
};
struct MdfLayoutRun {
  Buffer text, link;
  MdfLayoutFont font;
  uint32_t flags, role;
  float x, y, width, height;
  size_t position;
  float font_height, font_descent;
};
struct MdfLayoutRect { float x, y, width, height; uint32_t role; };
struct MdfLayoutView {
  const MdfLayoutRun *runs;
  size_t run_count;
  const MdfLayoutRect *rects;
  size_t rect_count;
  float height, right;
  bool image;
  float ix, iy, iw, ih;
};
struct MdfBlockLayout;
MdfBlockLayout *mdf_core_layout_block(MdfCore *, size_t, const MdfLayoutOptions *,
    MdfFlowMetrics (*)(void *, MdfLayoutFont, const unsigned char *, size_t),
    const float *(*)(void *, size_t, float, size_t *), void *);
MdfLayoutView mdf_layout_result_view(MdfBlockLayout *);
void mdf_layout_result_free(MdfBlockLayout *);
struct MdfFlowRun {
  size_t span, offset, len, position;
  float x, y, width, height, font_height, font_descent;
};
struct MdfFlowResult { MdfFlowRun *runs MDF_API_DEFAULT(nullptr); size_t count MDF_API_DEFAULT(0); float height MDF_API_DEFAULT(0), right MDF_API_DEFAULT(0); };
bool mdf_text_flow(const MdfFlowSpan *, size_t, MdfFlowSpec,
                   MdfFlowMetrics (*)(void *, size_t, const unsigned char *, size_t),
                   void *, MdfFlowResult *);
void mdf_text_flow_free(MdfFlowResult);
struct MdfViewport;
struct MdfViewportFields {
  float scroll, horizontal_scroll, content_width, margin, horizontal_extent;
  bool horizontal_dirty;
  uint64_t geometry_revision;
};
struct MdfViewportView { float *heights; const float *offsets; size_t count, offset_count; };
MdfViewport *mdf_viewport_create(void);
void mdf_viewport_destroy(MdfViewport *);
MdfViewportFields *mdf_viewport_fields(MdfViewport *);
bool mdf_viewport_resize(MdfViewport *, size_t);
MdfViewportView mdf_viewport_view(MdfViewport *);
bool mdf_viewport_reindex(MdfViewport *);
size_t mdf_viewport_index_at(MdfViewport *, float, size_t);
float mdf_viewport_total(MdfViewport *);
void mdf_viewport_configure(MdfViewport *, float, uint32_t, float, bool);
void mdf_viewport_move(MdfViewport *, float, float);
void mdf_viewport_move_horizontal(MdfViewport *, float, float, bool);
void mdf_viewport_horizontal(MdfViewport *, float, float);
float mdf_estimate_block(uint32_t, size_t, size_t, size_t, size_t, float, float, float, bool);
void mdf_buffer_free(Buffer);
uint64_t mdf_now_ns(void);
const char *mdf_core_mode(void);
MdfCore *mdf_core_create(const unsigned char *, size_t, bool, uint64_t,
                         void (*)(void));
void mdf_core_destroy(MdfCore *);
void mdf_core_set_wake(MdfCore *, void (*)(void));
Buffer mdf_core_open(MdfCore *, const unsigned char *, size_t);
Buffer mdf_core_poll(MdfCore *);
MdfBlockView mdf_core_block(MdfCore *, size_t);
MdfSpanView mdf_core_span(MdfCore *, size_t, ptrdiff_t, size_t);
MdfCellView mdf_core_cell(MdfCore *, size_t, size_t);
size_t mdf_core_column(MdfCore *, size_t, size_t);
Buffer mdf_core_settings(MdfCore *);
Buffer mdf_core_settings_update(MdfCore *, const unsigned char *, size_t);
bool mdf_core_navigation_start(MdfCore *, float, float, float);
bool mdf_core_navigation_ready(MdfCore *);
uint32_t mdf_core_navigation_state(MdfCore *); /* 0 idle, 1 working, 2 ready, 3 failed */
Buffer mdf_core_navigation(MdfCore *);
/* Preview views are borrowed until open/poll/navigation_start/destroy. */
size_t mdf_core_preview_count(MdfCore *);
size_t mdf_core_preview_lines(MdfCore *, size_t);
Buffer mdf_core_preview_line(MdfCore *, size_t, size_t);
Buffer mdf_core_image(MdfCore *, size_t);
Buffer mdf_builtin_font(uint32_t, uint32_t);
Buffer mdf_font_resource(uint32_t, uint32_t);
int mdf_inflate_zlib(const unsigned char *, size_t, unsigned char *, size_t,
                     uint32_t, int (*)(const void *), const void *);
Buffer mdf_notices(void);
Buffer mdf_core_link(MdfCore *, const unsigned char *, size_t);
Buffer mdf_drop_path(const unsigned char *, size_t);
Buffer mdf_core_profile(MdfCore *);
void mdf_profile_event(uint8_t, const unsigned char *, size_t,
                       const unsigned char *, size_t, uint32_t, uint64_t,
                       uint64_t, size_t, bool);
void mdf_profile_signal(uint8_t, const unsigned char *, size_t,
                       const unsigned char *, size_t, uint32_t, uint64_t);
#undef MDF_API_DEFAULT
#ifdef __cplusplus
}
#endif
