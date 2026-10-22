#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct MdfFontBytes { const unsigned char *data; size_t length; };
struct MdfPreparedFontView {
  void *config;
  const int *fds;
  size_t fd_count, source_count;
  struct MdfFontBytes family, error;
  size_t bytes;
  int monospace;
  const uint32_t *unresolved;
  size_t unresolved_count;
};
void *mdf_font_worker_create(int monospace, const uint32_t *, size_t,
    const int *bundled_fds, size_t, void (*notify)(void), int profile);
void mdf_font_worker_destroy(void *);
int mdf_font_worker_complete(void *);
void *mdf_font_worker_take(void *);
struct MdfPreparedFontView mdf_font_prepared_view(void *);
struct MdfFontBytes mdf_font_prepared_source(void *, size_t);
void mdf_font_prepared_destroy(void *);
#ifdef __cplusplus
}
#endif
